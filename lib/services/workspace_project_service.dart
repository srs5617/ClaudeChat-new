import 'dart:convert';

class WorkspaceProjectInspection {
  const WorkspaceProjectInspection({
    required this.detectedType,
    required this.runtime,
    required this.runnable,
    required this.requiresNetwork,
    required this.diagnostics,
    this.entryFile,
  });

  final String detectedType;
  final String runtime;
  final String? entryFile;
  final bool runnable;
  final bool requiresNetwork;
  final List<String> diagnostics;
}

class WorkspaceRunDocument {
  const WorkspaceRunDocument({
    required this.html,
    required this.title,
    required this.entryFile,
    required this.runtime,
    required this.requiresNetwork,
    required this.diagnostics,
  });

  final String html;
  final String title;
  final String entryFile;
  final String runtime;
  final bool requiresNetwork;
  final List<String> diagnostics;
}

class WorkspaceProjectService {
  const WorkspaceProjectService._();

  /// Pinned runtimes keep a workspace reproducible. They are downloaded by the
  /// isolated preview on first use and then use the platform WebView cache.
  static const pythonRuntimeIndexUrl =
      'https://cdn.jsdelivr.net/pyodide/v0.27.7/full/';
  static const babelRuntimeUrl =
      'https://unpkg.com/@babel/standalone@7.26.10/babel.min.js';
  static const reactRuntimeUrl =
      'https://unpkg.com/react@18.3.1/umd/react.production.min.js';
  static const reactDomRuntimeUrl =
      'https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js';

  static WorkspaceProjectInspection inspect(Map<String, String> inputFiles) {
    final files = _normalized(inputFiles);
    final detectedType = detectType(files);
    final buildManaged = const <String>{
      'react',
      'vue',
      'svelte',
      'angular',
      'node',
    }.contains(detectedType);
    final builtEntry = buildManaged ? _builtWebEntryFile(files) : null;
    final runtime = switch (detectedType) {
      'python' => 'python-wasm',
      'react' when builtEntry == null => 'react-browser',
      _ => 'static-web',
    };
    final entry = switch (runtime) {
      'python-wasm' => _pythonEntryFile(files),
      'react-browser' => _reactSourceEntryFile(files),
      _ => builtEntry ?? _entryFile(files),
    };
    final diagnostics = <String>[];
    var runnable = entry != null;
    if (entry == null) {
      diagnostics.add(switch (detectedType) {
        'python' => '检测到 Python 项目，但没有找到 main.py、app.py 或其他可执行 .py 入口。',
        'java' => '检测到 Java/Gradle 项目。手机端不具备 JDK/Gradle 原生构建链，当前只能查看、编辑和版本化源码。',
        'react' => '检测到 React 源码，但没有找到 src/main、src/index 或 HTML 中声明的模块入口。',
        'vue' => '检测到 Vue 源码，但没有可直接运行的 HTML 入口或 dist 产物。',
        'svelte' => '检测到 Svelte 源码，但没有可直接运行的 HTML 入口或 build 产物。',
        'angular' => '检测到 Angular 源码，但没有可直接运行的 browser/dist 产物。',
        'node' => '检测到 npm/Node 项目，但没有可直接预览的静态 HTML 或构建产物。',
        'flutter' =>
          '检测到 Flutter/Dart 项目。iOS 原生构建必须使用 macOS/Xcode 和签名链，手机端只能查看、编辑和版本化源码。',
        _ => '没有找到可运行的 HTML 入口文件。',
      });
    } else if (buildManaged &&
        runtime == 'static-web' &&
        !_isBuiltWebEntry(entry, files[entry]!)) {
      runnable = false;
      diagnostics.add(
        '检测到需要 npm/Vite 等工具编译的 $detectedType 源码；当前移动端运行器只执行静态 Web 产物，请提供 dist/build/out 产物后再运行。',
      );
    } else if (runtime == 'python-wasm') {
      diagnostics.add(
        'Python 项目已准备运行；项目会在与其他工作区隔离的安全环境中运行，请放心。首次启动需要联网加载固定版本运行组件。',
      );
    } else if (runtime == 'react-browser') {
      diagnostics.add(
        'React/JSX/TSX 项目已准备运行；项目会在与其他工作区隔离的安全环境中运行，请放心。首次启动需要联网加载固定版本编译组件。',
      );
    }
    return WorkspaceProjectInspection(
      detectedType: detectedType,
      runtime: runtime,
      entryFile: entry,
      runnable: runnable,
      requiresNetwork: runtime == 'python-wasm' || runtime == 'react-browser',
      diagnostics: diagnostics,
    );
  }

  static String detectType(Map<String, String> inputFiles) {
    final files = _normalized(inputFiles);
    final names = files.keys.toList(growable: false);
    final packageJson = files.entries
        .where((entry) => entry.key.toLowerCase().endsWith('package.json'))
        .map((entry) => entry.value)
        .firstOrNull;
    if (packageJson != null) {
      try {
        final decoded = jsonDecode(packageJson);
        if (decoded is Map) {
          final dependencies = <String>{
            if (decoded['dependencies'] is Map)
              ...(decoded['dependencies'] as Map).keys.map((key) => '$key'),
            if (decoded['devDependencies'] is Map)
              ...(decoded['devDependencies'] as Map).keys.map((key) => '$key'),
          };
          if (dependencies.contains('react') ||
              dependencies.contains('react-dom') ||
              dependencies.contains('next')) {
            return 'react';
          }
          if (dependencies.contains('vue') || dependencies.contains('nuxt')) {
            return 'vue';
          }
          if (dependencies.contains('svelte') ||
              dependencies.contains('@sveltejs/kit')) {
            return 'svelte';
          }
          if (dependencies.contains('@angular/core')) return 'angular';
          if (dependencies.contains('vite') || dependencies.isNotEmpty) {
            return 'node';
          }
        }
      } on FormatException {
        // A malformed package.json does not prevent extension-based detection.
      }
    }
    if (names.any(
      (name) =>
          name.endsWith('.tsx') ||
          name.endsWith('.jsx') ||
          name.toLowerCase().endsWith('vite.config.ts') ||
          name.toLowerCase().endsWith('vite.config.js'),
    )) {
      return 'react';
    }
    if (names.any((name) => name.endsWith('.vue'))) return 'vue';
    if (names.any((name) => name.endsWith('.svelte'))) return 'svelte';
    if (names.any((name) => name.toLowerCase().endsWith('angular.json'))) {
      return 'angular';
    }
    if (names.any(
      (name) =>
          name.toLowerCase().endsWith('pubspec.yaml') ||
          name.toLowerCase().endsWith('pubspec.yml'),
    )) {
      return 'flutter';
    }
    if (names.any(
      (name) =>
          name.endsWith('.py') ||
          name.toLowerCase().endsWith('requirements.txt') ||
          name.toLowerCase().endsWith('pyproject.toml'),
    )) {
      return 'python';
    }
    if (names.any(
      (name) =>
          name.endsWith('.java') ||
          name.toLowerCase().endsWith('pom.xml') ||
          name.toLowerCase().endsWith('build.gradle') ||
          name.toLowerCase().endsWith('build.gradle.kts'),
    )) {
      return 'java';
    }
    if (names.any(
      (name) =>
          name.endsWith('.html') ||
          name.endsWith('.css') ||
          name.endsWith('.js') ||
          name.endsWith('.mjs'),
    )) {
      return 'web';
    }
    return 'general';
  }

  static WorkspaceRunDocument? build(
    Map<String, String> inputFiles, {
    required String fallbackTitle,
  }) {
    final files = _normalized(inputFiles);
    final inspection = inspect(files);
    final entry = inspection.entryFile;
    if (entry == null || !inspection.runnable) return null;
    if (inspection.runtime == 'python-wasm') {
      return _buildPythonDocument(
        files,
        entry: entry,
        fallbackTitle: fallbackTitle,
        diagnostics: inspection.diagnostics,
      );
    }
    if (inspection.runtime == 'react-browser') {
      return _buildReactDocument(
        files,
        entry: entry,
        fallbackTitle: fallbackTitle,
        diagnostics: inspection.diagnostics,
      );
    }
    final diagnostics = <String>[];
    var html = files[entry]!;

    html = html.replaceAllMapped(
      RegExp(r'<link\b[^>]*>', caseSensitive: false),
      (match) {
        final tag = match.group(0)!;
        final rel = _attribute(tag, 'rel').toLowerCase();
        final href = _attribute(tag, 'href');
        if (!rel.split(RegExp(r'\s+')).contains('stylesheet') ||
            href.isEmpty ||
            _isExternal(href)) {
          return tag;
        }
        final resolved = _resolve(entry, href);
        final css = files[resolved];
        if (css == null) {
          diagnostics.add('未找到样式文件：$href');
          return tag;
        }
        return '<style data-claudechat-source="${_escapeAttribute(resolved)}">'
            '${css.replaceAll('</style', r'<\/style')}</style>';
      },
    );
    html = html.replaceAllMapped(
      RegExp(
        r'''<script\b[^>]*\bsrc\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*>\s*</script\s*>''',
        caseSensitive: false,
      ),
      (match) {
        final tag = match.group(0)!;
        final src = _attribute(tag, 'src');
        if (src.isEmpty || _isExternal(src)) return tag;
        final resolved = _resolve(entry, src);
        final script = files[resolved];
        if (script == null) {
          diagnostics.add('未找到脚本文件：$src');
          return tag;
        }
        return '<script data-claudechat-source="${_escapeAttribute(resolved)}">'
            '${script.replaceAll('</script', r'<\/script')}</script>';
      },
    );

    final titleMatch = RegExp(
      r'<title\b[^>]*>(.*?)</title\s*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    final title = (titleMatch?.group(1) ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim();
    return WorkspaceRunDocument(
      html: html,
      title: title.isEmpty ? fallbackTitle : title,
      entryFile: entry,
      runtime: inspection.runtime,
      requiresNetwork: inspection.requiresNetwork,
      diagnostics: diagnostics,
    );
  }

  static WorkspaceRunDocument _buildPythonDocument(
    Map<String, String> files, {
    required String entry,
    required String fallbackTitle,
    required List<String> diagnostics,
  }) {
    final payload = jsonEncode(<String, Object?>{
      'files': files,
      'entry': entry,
      'requirements': _pythonRequirements(files),
      'indexURL': pythonRuntimeIndexUrl,
    }).replaceAll('<', r'\u003c');
    final workerSource = jsonEncode(r'''
self.onmessage = async ({ data }) => {
  const emit = (kind, value) => self.postMessage({ kind, value: String(value ?? '') });
  try {
    emit('status', '正在加载 Python 运行时…');
    importScripts(data.indexURL + 'pyodide.js');
    const pyodide = await loadPyodide({ indexURL: data.indexURL });
    pyodide.setStdout({ batched: value => emit('stdout', value) });
    pyodide.setStderr({ batched: value => emit('stderr', value) });
    pyodide.registerJsModule('claudechat_ui', {
      render_html: value => emit('html', value),
    });
    pyodide.FS.mkdirTree('/workspace');
    for (const [name, content] of Object.entries(data.files)) {
      const safe = String(name).replace(/\\/g, '/').replace(/^\/+/, '');
      const slash = safe.lastIndexOf('/');
      if (slash > 0) pyodide.FS.mkdirTree('/workspace/' + safe.slice(0, slash));
      pyodide.FS.writeFile('/workspace/' + safe, String(content), { encoding: 'utf8' });
    }
    emit('status', '正在准备 Python 依赖…');
    const source = String(data.files[data.entry] || '');
    await pyodide.loadPackagesFromImports(source);
    if (Array.isArray(data.requirements) && data.requirements.length) {
      await pyodide.loadPackage('micropip');
      await pyodide.runPythonAsync(
        'import micropip\nawait micropip.install(' + JSON.stringify(data.requirements) + ')'
      );
    }
    emit('status', '正在运行 ' + data.entry);
    pyodide.globals.set('__claudechat_entry__', '/workspace/' + data.entry);
    await pyodide.runPythonAsync(`
import os, sys
entry = str(__claudechat_entry__)
entry_dir = os.path.dirname(entry) or '/workspace'
os.chdir(entry_dir)
if '/workspace' not in sys.path:
    sys.path.insert(0, '/workspace')
if entry_dir not in sys.path:
    sys.path.insert(0, entry_dir)
globals_dict = {'__name__': '__main__', '__file__': entry}
with open(entry, 'r', encoding='utf-8') as source_file:
    source_code = source_file.read()
exec(compile(source_code, entry, 'exec'), globals_dict, globals_dict)
`);
    emit('done', '运行完成');
  } catch (error) {
    emit('error', error && error.stack ? error.stack : error);
  }
};
''');
    final title = _escapeHtml(fallbackTitle);
    return WorkspaceRunDocument(
      title: fallbackTitle,
      entryFile: entry,
      runtime: 'python-wasm',
      requiresNetwork: true,
      diagnostics: diagnostics,
      html:
          '''<!doctype html>
<html><head><meta charset="utf-8"><title>$title</title>
<style>
:root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
html,body{margin:0;min-height:100%;background:#fff;color:#171717}
#plain-output{box-sizing:border-box;min-height:100vh;padding:24px;white-space:pre-wrap;overflow-wrap:anywhere;font:15px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace}
#html-output{position:fixed;inset:0;width:100%;height:100%;border:0;background:#fff;display:none}
#progress{position:fixed;inset:0;z-index:3;display:grid;place-content:center;justify-items:center;gap:12px;background:inherit;color:#746e68;font-size:13px;transition:opacity .18s ease}
#progress.hidden{opacity:0;visibility:hidden;pointer-events:none}.spinner{width:24px;height:24px;border:2px solid rgba(194,118,66,.2);border-top-color:#c27642;border-radius:50%;animation:spin .8s linear infinite}
#stop{position:fixed;right:18px;bottom:18px;z-index:4;width:42px;height:42px;border:1px solid rgba(201,111,71,.38);border-radius:50%;background:rgba(255,255,255,.9);color:#b95f3b;box-shadow:0 5px 18px rgba(0,0,0,.1);font-size:0}
#stop::after{content:'';display:block;width:10px;height:10px;margin:auto;border-radius:2px;background:currentColor}#stop.hidden{display:none}.stderr,.error{color:#bd3e3e}.empty{color:#aaa29a}
@keyframes spin{to{transform:rotate(360deg)}}
@media(prefers-color-scheme:dark){html,body{background:#1c1b1f;color:#f5f2ef}#html-output{background:#1c1b1f}#progress{color:#aaa29a}#stop{background:rgba(42,42,40,.92)}}
</style></head><body>
<pre id="plain-output" aria-live="polite"></pre>
<iframe id="html-output" title="$title" sandbox="allow-scripts allow-forms allow-modals allow-downloads"></iframe>
<div id="progress" role="status"><span class="spinner"></span><span id="status">正在准备运行…</span></div>
<button id="stop" type="button" aria-label="终止运行" title="终止运行">终止运行</button>
<script id="claudechat-python-project" type="application/json">$payload</script>
<script>
(() => {
  const data = JSON.parse(document.getElementById('claudechat-python-project').textContent);
  const output = document.getElementById('plain-output');
  const htmlOutput = document.getElementById('html-output');
  const progress = document.getElementById('progress');
  const status = document.getElementById('status');
  const stop = document.getElementById('stop');
  const worker = new Worker(URL.createObjectURL(new Blob([$workerSource], {type:'text/javascript'})));
  let hasOutput = false;
  const reveal = () => { progress.classList.add('hidden'); };
  const append = (text, css) => { hasOutput=true; reveal(); const line=document.createElement('span'); line.className=css||''; line.textContent=text+'\n'; output.appendChild(line); };
  worker.onmessage = ({data: message}) => {
    if (message.kind === 'status') status.textContent = message.value;
    else if (message.kind === 'html') { hasOutput=true; reveal(); output.style.display='none'; htmlOutput.style.display='block'; htmlOutput.srcdoc=message.value; }
    else if (message.kind === 'done') { reveal(); stop.classList.add('hidden'); if (!hasOutput) { output.textContent='运行完成，没有输出内容。'; output.className='empty'; } }
    else if (message.kind === 'error') { reveal(); stop.classList.add('hidden'); append(message.value,'error'); }
    else append(message.value, message.kind === 'stderr' ? 'stderr' : '');
  };
  worker.onerror = event => { reveal(); stop.classList.add('hidden'); append(event.message || '无法启动 Python 运行时，请检查网络后重试。','error'); };
  stop.onclick = () => { worker.terminate(); reveal(); stop.classList.add('hidden'); if (!hasOutput) { output.textContent='运行已终止。'; output.className='empty'; } };
  worker.postMessage(data);
})();
</script></body></html>''',
    );
  }

  static WorkspaceRunDocument _buildReactDocument(
    Map<String, String> files, {
    required String entry,
    required String fallbackTitle,
    required List<String> diagnostics,
  }) {
    final htmlEntry = _entryFile(files);
    var shell = htmlEntry == null
        ? '<!doctype html><html><head><meta charset="utf-8"><title>${_escapeHtml(fallbackTitle)}</title></head><body><div id="root"></div></body></html>'
        : files[htmlEntry]!;
    shell = shell.replaceAllMapped(
      RegExp(
        r'''<script\b[^>]*\btype\s*=\s*(?:"module"|'module'|module)[^>]*>\s*</script\s*>''',
        caseSensitive: false,
      ),
      (_) => '',
    );
    if (htmlEntry != null) {
      shell = shell.replaceAllMapped(
        RegExp(r'<link\b[^>]*>', caseSensitive: false),
        (match) {
          final tag = match.group(0)!;
          final rel = _attribute(tag, 'rel').toLowerCase();
          final href = _attribute(tag, 'href');
          if (!rel.split(RegExp(r'\s+')).contains('stylesheet') ||
              href.isEmpty ||
              _isExternal(href)) {
            return tag;
          }
          final resolved = _resolve(htmlEntry, href);
          final css = files[resolved];
          return css == null
              ? tag
              : '<style data-claudechat-source="${_escapeAttribute(resolved)}">${css.replaceAll('</style', r'<\/style')}</style>';
        },
      );
    }
    final payload = jsonEncode(<String, Object?>{
      'files': files,
      'entry': entry,
    }).replaceAll('<', r'\u003c');
    final runtime =
        r'''
<script src="__CLAUDECHAT_REACT_RUNTIME__"></script>
<script src="__CLAUDECHAT_REACT_DOM_RUNTIME__"></script>
<script src="__CLAUDECHAT_BABEL_RUNTIME__"></script>
<script id="claudechat-react-project" type="application/json">__CLAUDECHAT_PROJECT_PAYLOAD__</script>
<script data-claudechat-runtime="react-browser">
(() => {
  const project = JSON.parse(document.getElementById('claudechat-react-project').textContent);
  const files = project.files;
  const cache = Object.create(null);
  const extensions = ['', '.js', '.jsx', '.ts', '.tsx', '.mjs', '.json', '.css', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.webp'];
  const normalize = value => {
    const parts=[];
    for (const part of String(value).replace(/\\/g,'/').split('/')) {
      if (!part || part === '.') continue;
      if (part === '..') parts.pop(); else parts.push(part);
    }
    return parts.join('/');
  };
  const resolve = (from, request) => {
    if (!request.startsWith('.') && !request.startsWith('/')) return request;
    const base = request.startsWith('/') ? '' : from.slice(0, Math.max(0, from.lastIndexOf('/') + 1));
    const raw = normalize(base + request);
    for (const extension of extensions) {
      if (Object.prototype.hasOwnProperty.call(files, raw + extension)) return raw + extension;
    }
    for (const extension of extensions.slice(1)) {
      if (Object.prototype.hasOwnProperty.call(files, raw + '/index' + extension)) return raw + '/index' + extension;
    }
    throw new Error('找不到模块：' + request + '（来自 ' + from + '）');
  };
  const external = request => {
    if (request === 'react') return window.React;
    if (request === 'react-dom') return window.ReactDOM;
    if (request === 'react-dom/client') return { createRoot: window.ReactDOM.createRoot.bind(window.ReactDOM), hydrateRoot: window.ReactDOM.hydrateRoot && window.ReactDOM.hydrateRoot.bind(window.ReactDOM) };
    if (request === 'react/jsx-runtime' || request === 'react/jsx-dev-runtime') return window.React;
    throw new Error('当前移动端运行环境尚未内置 npm 依赖：' + request + '。请改用本地模块或提交 dist/build 产物。');
  };
  const load = path => {
    if (!path.startsWith('.') && !path.startsWith('/') && !Object.prototype.hasOwnProperty.call(files, path)) return external(path);
    path = normalize(path);
    if (cache[path]) return cache[path].exports;
    if (path.endsWith('.css')) { const style=document.createElement('style'); style.dataset.claudechatSource=path; style.textContent=files[path]; document.head.appendChild(style); return {}; }
    if (path.endsWith('.json')) return JSON.parse(files[path]);
    if (/\.(?:svg|png|jpe?g|gif|webp)$/.test(path)) {
      const mime = path.endsWith('.svg') ? 'image/svg+xml' : 'image/' + path.split('.').pop().replace('jpg','jpeg');
      return String(files[path]).startsWith('data:') ? files[path] : 'data:' + mime + ';charset=utf-8,' + encodeURIComponent(files[path]);
    }
    const module = {exports:{}}; cache[path]=module;
    let source = String(files[path] ?? '')
      .replace(/import\.meta\.env\.DEV/g, 'true')
      .replace(/import\.meta\.env\.PROD/g, 'false')
      .replace(/import\.meta\.env\.MODE/g, '"development"');
    const presets = [['env',{modules:'commonjs'}], ['react',{runtime:'classic'}]];
    if (/\.(?:ts|tsx)$/.test(path)) presets.push(['typescript',{allExtensions:true,isTSX:path.endsWith('.tsx')}]);
    const code = Babel.transform(source, {filename:path, sourceType:'module', presets}).code;
    const localRequire = request => load(resolve(path, request));
    const execute = new Function('require','module','exports','process','__filename','__dirname', code + '\n//# sourceURL=claudechat-workspace://' + path);
    execute(localRequire, module, module.exports, {env:{NODE_ENV:'development'}}, path, path.includes('/') ? path.slice(0,path.lastIndexOf('/')) : '');
    return module.exports;
  };
  const showError = error => {
    const box=document.createElement('pre'); box.style.cssText='white-space:pre-wrap;margin:16px;padding:14px;border:1px solid #d66;border-radius:12px;color:#b22;background:rgba(180,30,30,.06)'; box.textContent=error && error.stack ? error.stack : String(error); document.body.prepend(box);
  };
  try { load(project.entry); } catch (error) { showError(error); }
})();
</script>'''
            .replaceAll('__CLAUDECHAT_REACT_RUNTIME__', reactRuntimeUrl)
            .replaceAll('__CLAUDECHAT_REACT_DOM_RUNTIME__', reactDomRuntimeUrl)
            .replaceAll('__CLAUDECHAT_BABEL_RUNTIME__', babelRuntimeUrl)
            .replaceAll('__CLAUDECHAT_PROJECT_PAYLOAD__', payload);
    shell = shell.contains(RegExp(r'</body\s*>', caseSensitive: false))
        ? shell.replaceFirst(
            RegExp(r'</body\s*>', caseSensitive: false),
            '$runtime</body>',
          )
        : '$shell$runtime';
    final titleMatch = RegExp(
      r'<title\b[^>]*>(.*?)</title\s*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(shell);
    final title = (titleMatch?.group(1) ?? '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim();
    return WorkspaceRunDocument(
      html: shell,
      title: title.isEmpty ? fallbackTitle : title,
      entryFile: entry,
      runtime: 'react-browser',
      requiresNetwork: true,
      diagnostics: diagnostics,
    );
  }

  static List<String> _pythonRequirements(Map<String, String> files) {
    final source = files.entries
        .where((entry) => entry.key.toLowerCase().endsWith('requirements.txt'))
        .map((entry) => entry.value)
        .firstOrNull;
    if (source == null) return const <String>[];
    return source
        .split(RegExp(r'\r?\n'))
        .map((line) => line.split('#').first.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('-'))
        .toList(growable: false);
  }

  static Map<String, String> _normalized(
    Map<String, String> input,
  ) => <String, String>{
    for (final entry in input.entries) _normalizePath(entry.key): entry.value,
  };

  static String? _entryFile(Map<String, String> files) {
    if (files.containsKey('index.html')) return 'index.html';
    final nestedIndexes =
        files.keys
            .where((name) => name.toLowerCase().endsWith('/index.html'))
            .toList()
          ..sort((left, right) {
            final depth = left
                .split('/')
                .length
                .compareTo(right.split('/').length);
            return depth != 0 ? depth : left.compareTo(right);
          });
    if (nestedIndexes.isNotEmpty) return nestedIndexes.first;
    final htmlFiles =
        files.keys
            .where((name) => name.toLowerCase().endsWith('.html'))
            .toList()
          ..sort();
    return htmlFiles.firstOrNull;
  }

  static String? _builtWebEntryFile(Map<String, String> files) {
    for (final preferred in const <String>[
      'dist/index.html',
      'build/index.html',
      'out/index.html',
      'dist/browser/index.html',
      'browser/index.html',
    ]) {
      if (files.containsKey(preferred)) return preferred;
    }
    return null;
  }

  static String? _pythonEntryFile(Map<String, String> files) {
    for (final preferred in const <String>[
      'main.py',
      'app.py',
      'src/main.py',
      'src/app.py',
      '__main__.py',
    ]) {
      if (files.containsKey(preferred)) return preferred;
    }
    final candidates =
        files.keys
            .where(
              (name) =>
                  name.toLowerCase().endsWith('.py') &&
                  !name
                      .split('/')
                      .any(
                        (part) =>
                            part == 'test' ||
                            part == 'tests' ||
                            part.startsWith('.'),
                      ),
            )
            .toList()
          ..sort((left, right) {
            final depth = left
                .split('/')
                .length
                .compareTo(right.split('/').length);
            return depth != 0 ? depth : left.compareTo(right);
          });
    return candidates.firstOrNull;
  }

  static String? _reactSourceEntryFile(Map<String, String> files) {
    final html = _entryFile(files);
    if (html != null) {
      final source = files[html]!;
      final module = RegExp(
        r'''<script\b[^>]*\btype\s*=\s*(?:"module"|'module'|module)[^>]*\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))''',
        caseSensitive: false,
      ).firstMatch(source);
      final reference =
          module?.group(1) ?? module?.group(2) ?? module?.group(3);
      if (reference != null && reference.trim().isNotEmpty) {
        final resolved = _resolve(html, reference);
        if (files.containsKey(resolved)) return resolved;
      }
    }
    for (final preferred in const <String>[
      'src/main.tsx',
      'src/main.jsx',
      'src/index.tsx',
      'src/index.jsx',
      'src/main.ts',
      'src/main.js',
      'src/index.ts',
      'src/index.js',
      'main.tsx',
      'main.jsx',
      'index.tsx',
      'index.jsx',
    ]) {
      if (files.containsKey(preferred)) return preferred;
    }
    return null;
  }

  static bool _isBuiltWebEntry(String entry, String html) {
    if (entry.startsWith('dist/') ||
        entry.startsWith('build/') ||
        entry.startsWith('out/') ||
        entry.startsWith('browser/')) {
      return true;
    }
    return !RegExp(
      r'''(?:src|href)\s*=\s*["'][^"']*(?:/src/|\.tsx?\b|\.jsx\b)''',
      caseSensitive: false,
    ).hasMatch(html);
  }

  static String _attribute(String tag, String name) {
    final match = RegExp(
      '$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
      caseSensitive: false,
    ).firstMatch(tag);
    return match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '';
  }

  static bool _isExternal(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.startsWith('http://') ||
        normalized.startsWith('https://') ||
        normalized.startsWith('//') ||
        normalized.startsWith('data:') ||
        normalized.startsWith('blob:') ||
        normalized.startsWith('#');
  }

  static String _resolve(String entry, String reference) {
    final clean = reference.split('#').first.split('?').first;
    if (clean.startsWith('/')) return _normalizePath(clean.substring(1));
    final directory = entry.contains('/')
        ? entry.substring(0, entry.lastIndexOf('/') + 1)
        : '';
    return _normalizePath('$directory$clean');
  }

  static String _normalizePath(String value) {
    final segments = <String>[];
    for (final segment in value.replaceAll('\\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else {
        segments.add(segment);
      }
    }
    return segments.join('/');
  }

  static String _escapeAttribute(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
