import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file history previews the selected version in an isolated scope', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains('required this.onRunVersion'));
    expect(source, contains('await widget.onRunVersion(version, body)'));
    expect(
      source,
      contains("runtimeScope: 'file-\${file.id}-version-\${version.id}'"),
    );
  });
}
