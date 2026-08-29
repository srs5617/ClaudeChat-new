import 'package:claudechat/services/workspace_project_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects common workspace project types without user configuration', () {
    expect(
      WorkspaceProjectService.detectType(<String, String>{
        'package.json': '{"dependencies":{"react":"latest"}}',
        'src/App.tsx': 'export default function App() {}',
      }),
      'react',
    );
    expect(
      WorkspaceProjectService.detectType(<String, String>{
        'main.py': 'print("hello")',
      }),
      'python',
    );
    expect(
      WorkspaceProjectService.detectType(<String, String>{
        'src/Main.java': 'class Main {}',
      }),
      'java',
    );
    expect(
      WorkspaceProjectService.detectType(<String, String>{
        'index.html': '<!doctype html>',
      }),
      'web',
    );
    expect(
      WorkspaceProjectService.detectType(<String, String>{
        'package.json': '{"dependencies":{"vue":"latest","vite":"latest"}}',
        'src/App.vue': '<template>Hello</template>',
      }),
      'vue',
    );
    expect(
      WorkspaceProjectService.detectType(<String, String>{
        'pubspec.yaml': 'name: mobile_app',
        'lib/main.dart': 'void main() {}',
      }),
      'flutter',
    );
  });

  test('builds a runnable web document with local css and js inlined', () {
    final result = WorkspaceProjectService.build(<String, String>{
      'site/index.html': '''<!doctype html><html><head>
<title>团子的小游戏</title><link rel="stylesheet" href="./css/app.css">
</head><body><button id="play">玩</button><script src="./js/app.js"></script></body></html>''',
      'site/css/app.css': 'body { background: pink; }',
      'site/js/app.js': 'document.body.dataset.ready = "yes";',
    }, fallbackTitle: '备用标题');

    expect(result, isNotNull);
    expect(result!.entryFile, 'site/index.html');
    expect(result.title, '团子的小游戏');
    expect(result.html, contains('data-claudechat-source="site/css/app.css"'));
    expect(result.html, contains('background: pink'));
    expect(result.html, contains('data-claudechat-source="site/js/app.js"'));
    expect(result.html, contains('dataset.ready'));
  });

  test('builds isolated mobile runtimes for React source and Python', () {
    final react = WorkspaceProjectService.inspect(<String, String>{
      'package.json': '{"dependencies":{"react":"latest"}}',
      'index.html': '<script type="module" src="/src/main.jsx"></script>',
      'src/main.jsx': 'root.render(<App />);',
    });
    final python = WorkspaceProjectService.inspect(<String, String>{
      'main.py': 'print("hello")',
    });

    expect(react.detectedType, 'react');
    expect(react.runtime, 'react-browser');
    expect(react.entryFile, 'src/main.jsx');
    expect(react.runnable, isTrue);
    expect(react.requiresNetwork, isTrue);
    expect(python.detectedType, 'python');
    expect(python.runtime, 'python-wasm');
    expect(python.entryFile, 'main.py');
    expect(python.runnable, isTrue);
    expect(python.requiresNetwork, isTrue);

    final reactDocument = WorkspaceProjectService.build(<String, String>{
      'package.json': '{"dependencies":{"react":"latest"}}',
      'index.html':
          '<div id="root"></div><script type="module" src="/src/main.jsx"></script>',
      'src/main.jsx':
          'import React from "react"; import {createRoot} from "react-dom/client"; createRoot(document.getElementById("root")).render(<b>hello</b>);',
    }, fallbackTitle: 'React test');
    final pythonDocument = WorkspaceProjectService.build(<String, String>{
      'main.py': 'from helper import value\nprint(value)',
      'helper.py': 'value = 42',
    }, fallbackTitle: 'Python test');

    expect(reactDocument, isNotNull);
    expect(reactDocument!.runtime, 'react-browser');
    expect(reactDocument.html, contains('data-claudechat-runtime="react-browser"'));
    expect(reactDocument.html, contains('src/main.jsx'));
    expect(pythonDocument, isNotNull);
    expect(pythonDocument!.runtime, 'python-wasm');
    expect(pythonDocument.title, 'Python test');
    expect(pythonDocument.html, contains('<strong>main.py</strong>'));
    expect(pythonDocument.html, isNot(contains('沙箱')));
    expect(pythonDocument.html, contains('helper.py'));
  });

  test('prefers a built React entry when source and dist coexist', () {
    final inspection = WorkspaceProjectService.inspect(<String, String>{
      'package.json': '{"dependencies":{"react":"latest"}}',
      'index.html': '<script type="module" src="/src/main.jsx"></script>',
      'src/main.jsx': 'root.render(<App />);',
      'dist/index.html':
          '<title>Build</title><script src="assets/app.js"></script>',
      'dist/assets/app.js': 'console.log("built")',
    });

    expect(inspection.entryFile, 'dist/index.html');
    expect(inspection.runnable, isTrue);
    expect(inspection.runtime, 'static-web');
  });

  test('npm framework source needs a static build product', () {
    final sourceOnly = WorkspaceProjectService.inspect(<String, String>{
      'package.json': '{"dependencies":{"vue":"latest","vite":"latest"}}',
      'index.html': '<script type="module" src="/src/main.ts"></script>',
      'src/main.ts': 'createApp(App).mount("#app")',
    });
    final built = WorkspaceProjectService.inspect(<String, String>{
      'package.json': '{"dependencies":{"vue":"latest","vite":"latest"}}',
      'dist/index.html': '<script src="assets/app.js"></script>',
      'dist/assets/app.js': 'console.log("built")',
    });

    expect(sourceOnly.detectedType, 'vue');
    expect(sourceOnly.runnable, isFalse);
    expect(sourceOnly.diagnostics.single, contains('dist/build/out'));
    expect(built.detectedType, 'vue');
    expect(built.runnable, isTrue);
  });
}
