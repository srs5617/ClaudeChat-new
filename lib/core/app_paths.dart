import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppPaths {
  AppPaths._(this.root);

  final Directory root;

  Directory get database =>
      Directory('${root.path}${Platform.pathSeparator}database');
  Directory get data => Directory('${root.path}${Platform.pathSeparator}data');
  Directory get conversations =>
      Directory('${data.path}${Platform.pathSeparator}conversations');
  Directory get memories =>
      Directory('${data.path}${Platform.pathSeparator}memories');
  Directory get diary =>
      Directory('${data.path}${Platform.pathSeparator}diary');
  Directory get dataFiles =>
      Directory('${data.path}${Platform.pathSeparator}files');
  Directory get workspaces =>
      Directory('${data.path}${Platform.pathSeparator}workspaces');
  Directory get settings =>
      Directory('${data.path}${Platform.pathSeparator}settings');
  Directory get diagnostics =>
      Directory('${data.path}${Platform.pathSeparator}diagnostics');
  Directory get reminders =>
      Directory('${data.path}${Platform.pathSeparator}reminders');
  Directory get voices =>
      Directory('${data.path}${Platform.pathSeparator}voices');
  Directory get attachments =>
      Directory('${root.path}${Platform.pathSeparator}attachments');
  Directory get files =>
      Directory('${root.path}${Platform.pathSeparator}files');
  Directory get fonts =>
      Directory('${root.path}${Platform.pathSeparator}fonts');
  Directory get icons =>
      Directory('${root.path}${Platform.pathSeparator}icons');
  Directory get temp => Directory('${root.path}${Platform.pathSeparator}temp');
  Directory get importStaging =>
      Directory('${root.path}${Platform.pathSeparator}import-staging');

  static Future<AppPaths> create() async {
    final support = await getApplicationSupportDirectory();
    final paths = AppPaths._(
      Directory('${support.path}${Platform.pathSeparator}claudechat'),
    );
    await paths.ensureCreated();
    return paths;
  }

  /// Creates inert paths for the browser-based visual audit entrypoint.
  ///
  /// The audit renders the production widget tree with deterministic fixture
  /// state and never performs file I/O. Keeping this constructor here avoids
  /// replacing production widgets with a second, visually similar test app.
  static AppPaths visualAudit() => AppPaths._(Directory('visual-audit'));

  Future<void> ensureCreated() async {
    for (final directory in <Directory>[
      root,
      database,
      data,
      conversations,
      memories,
      diary,
      dataFiles,
      workspaces,
      settings,
      diagnostics,
      reminders,
      voices,
      attachments,
      files,
      fonts,
      icons,
      temp,
      importStaging,
    ]) {
      await directory.create(recursive: true);
    }
  }
}
