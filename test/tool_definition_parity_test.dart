import 'dart:io';

import 'package:claudechat/core/app_paths.dart';
import 'package:claudechat/data/app_database.dart';
import 'package:claudechat/services/content_repository.dart';
import 'package:claudechat/services/platform_service.dart';
import 'package:claudechat/services/secure_vault.dart';
import 'package:claudechat/services/settings_service.dart';
import 'package:claudechat/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final paths = AppPaths.visualAudit();
  final database = AppDatabase.visualAudit(paths, 'tool-parity-device');
  final settings = SettingsService(database, SecureVault());
  final tools = ToolService(
    database,
    ContentRepository(database),
    settings,
    PlatformService(),
  );

  test('all 19 legacy chat tools remain present in original order', () {
    const legacyNames = <String, String>{
      'get_time': '读取当前时间',
      'search_memory': '搜索记忆',
      'create_memory': '创建记忆',
      'update_memory': '更新记忆',
      'delete_memory': '删除记忆',
      'create_diary_entry': '写 AI 日记',
      'revise_diary_entry': '修订 AI 日记',
      'request_delete_diary_entry': '删除 AI 日记',
      'search_diary_entries': '搜索 AI 日记',
      'read_diary_entry': '读取 AI 日记',
      'web_search': '网络搜索',
      'fetch_url': '抓取网页',
      'create_file': '创建文件',
      'search_files': '搜索文件',
      'read_file': '读取文件',
      'edit_file': '编辑文件',
      'delete_file': '删除文件',
      'set_greeting': '修改欢迎语',
      'set_splash_phrases': '修改开屏语',
    };

    expect(
      ToolService.legacyChatDefinitions.map((item) => item.name),
      legacyNames.keys,
    );
    expect(<String, String?>{
      for (final item in ToolService.legacyChatDefinitions)
        item.name: item.label,
    }, legacyNames);
  });

  test('legacy delete tools preserve the original soft-delete contract', () {
    final memory = tools.definition('delete_memory')!;
    final diary = tools.definition('request_delete_diary_entry')!;
    final file = tools.definition('delete_file')!;

    expect(memory.requiresApproval, isTrue);
    expect(memory.approvalText, 'AI 想删除一条本地记忆。');
    expect(diary.requiresApproval, isFalse);
    expect(file.requiresApproval, isFalse);
    expect(file.description, contains('软删除'));
  });

  test('legacy approval boundary matches the browser project', () {
    final legacy = ToolService.legacyChatDefinitions;
    expect(
      legacy.where((item) => item.requiresApproval).map((item) => item.name),
      const <String>['delete_memory'],
    );
    expect(
      ToolService.definitions
          .where((item) => item.requiresApproval)
          .map((item) => item.name),
      const <String>['delete_memory'],
    );
  });

  test('interim diary-delete name resolves to the canonical legacy tool', () {
    expect(
      tools.definition('delete_diary_entry')?.name,
      'request_delete_diary_entry',
    );
  });

  test('welcome and splash tools persist the values used by the UI', () {
    final source = File('lib/services/tool_service.dart').readAsStringSync();

    expect(source, contains("await settings.set('greeting', value.trim())"));
    expect(source, contains("await settings.set('splashPhrases', phrases)"));
    expect(source, contains("{'greeting': value.trim()}"));
    expect(source, contains("{'phrases': phrases}"));
  });

  test('workspace tools do not retain the removed write-approval prompt', () {
    final source = File('lib/app_controller.dart').readAsStringSync();
    expect(source, isNot(contains('写入前必须取得用户批准')));
  });

  test(
    'every chat and workspace tool has progress and completion coverage',
    () {
      final app = File('lib/app.dart').readAsStringSync();
      final controller = File('lib/app_controller.dart').readAsStringSync();
      final names = <String>{
        ...ToolService.definitions.map((item) => item.name),
        'list_workspace_files',
        'read_workspace_file',
        'list_workspace_file_versions',
        'read_workspace_file_version',
        'restore_workspace_file_version',
        'create_workspace_file',
        'edit_workspace_file',
      };

      for (final name in names) {
        final progressName = name == 'request_delete_diary_entry'
            ? "'request_delete_diary_entry' || 'delete_diary_entry'"
            : "'$name'";
        expect(
          app,
          contains('($progressName, false)'),
          reason: '$name 缺少准备阶段提示',
        );
        expect(
          app,
          contains('($progressName, true)'),
          reason: '$name 缺少执行阶段提示',
        );
      }
      for (final name in ToolService.definitions.map((item) => item.name)) {
        expect(controller, contains("'$name'"), reason: '$name 缺少完成性校验或调度覆盖');
      }
      expect(app, contains("'set_greeting' => '修改了欢迎语"));
      expect(app, contains("'set_splash_phrases' => '修改了开屏语"));
    },
  );
}
