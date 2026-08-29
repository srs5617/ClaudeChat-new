import 'dart:convert';

class WorkspaceProjectInspection {
  const WorkspaceProjectInspection({
    required this.detectedType,
    required this.runnable,
    required this.diagnostics,
    this.entryFile,
  });

  final String detectedType;
  final String? entryFile;
  final bool runnable;
  final List<String> diagnostics;
}

class WorkspaceRunDocument {
  const WorkspaceRunDocument({
    required this.html,
    required this.title,
    required this.entryFile,
    required this.diagnostics,
  });

  final String html;
  final String title;
  final String entryFile;
  final List<String> diagnostics;
}

class WorkspaceProjectService {
  const WorkspaceProjectService._();

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
    final entry = buildManaged ? _builtWebEntryFile(files) : _entryFile(files);
    final diagnostics = <String>[];
    var runnable = entry != null;
    if (entry == null) {
      diagnostics.add(switch (detectedType) {
        'python' => '检测到 Python 项目，但设备内 Python 运行时尚未接入。',
        'java' => '检测到 Java 项目，但设备内 Java 运行时尚未接入。',
        'react' => '检测到 React 源码，但没有可直接运行的 HTML 入口或 dist/build 产物。',
        'vue' => '检测到 Vue 源码，但没有可直接运行的 HTML 入口或 dist 产物。',
        'svelte' => '检测到 Svelte 源码，但没有可直接运行的 HTML 入口或 build 产物。',
        'angular' => '检测到 Angular 源码，但没有可直接运行的 browser/dist 产物。',
        'node' => '检测到 npm/Node 项目，但没有可直接预览的静态 HTML 或构建产物。',
        'flutter' => '检测到 Flutter/Dart 项目，但设备内 Flutter/Dart 构建运行时尚未接入。',
        _ => '没有找到可运行的 HTML 入口文件。',
      });
    } else if (buildManaged && !_isBuiltWebEntry(entry, files[entry]!)) {
      runnable = false;
      diagnostics.add(
        '检测到需要 npm/Vite 等工具编译的 $detectedType 源码；当前移动端运行器只执行静态 Web 产物，请提供 dist/build/out 产物后再运行。',
      );
    }
    return WorkspaceProjectInspection(
      detectedType: detectedType,
      entryFile: entry,
      runnable: runnable,
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
      diagnostics: diagnostics,
    );
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
    return _entryFile(files);
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
}
