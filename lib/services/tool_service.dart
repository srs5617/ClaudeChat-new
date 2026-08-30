import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../domain/entities.dart';
import 'content_repository.dart';
import 'safe_web_service.dart';
import 'settings_service.dart';
import 'platform_service.dart';

const _uuid = Uuid();

class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    this.requiresApproval = false,
    this.label,
    this.approvalText,
  });
  final String name;
  final String description;
  final Map<String, Object?> parameters;
  final bool requiresApproval;
  final String? label;
  final String? approvalText;

  Map<String, Object?> toApi() => <String, Object?>{
    'type': 'function',
    'function': <String, Object?>{
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

class ToolRequest {
  const ToolRequest({
    required this.callId,
    required this.name,
    required this.arguments,
  });
  final String callId;
  final String name;
  final Map<String, Object?> arguments;
}

class ToolService {
  ToolService(
    this.store,
    this.content,
    this.settings,
    this.platform, {
    SafeWebService? web,
  }) : web = web ?? SafeWebService();

  final AppDatabase store;
  final ContentRepository content;
  final SettingsService settings;
  final PlatformService platform;
  final SafeWebService web;

  static const definitions = <ToolDefinition>[
    ToolDefinition(
      name: 'get_time',
      label: '读取当前时间',
      description: '读取用户本机的当前日期、时间、时区和时间段，用于时间感知。',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'search_memory',
      label: '搜索记忆',
      description:
          '从本地记忆库搜索非私密记忆，返回匹配的记忆列表（含完整UUID、等级、标签、内容）。critical 记忆已默认注入，其它等级需要按需搜索。',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, String>{
            'type': 'string',
            'description': '要搜索的关键词或问题，可以为空。',
          },
          'levels': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'string',
              'enum': <String>[
                'critical',
                'important',
                'daily',
                'trivial',
                'archived',
              ],
            },
            'description': '限制记忆等级。',
          },
          'tags': <String, Object?>{
            'type': 'array',
            'items': <String, String>{'type': 'string'},
            'description': '限制标签。',
          },
          'limit': <String, String>{
            'type': 'number',
            'description': '最多返回多少条，默认 8。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'create_memory',
      label: '创建记忆',
      description: '把具有长期价值的信息写入本地记忆库。不要把普通寒暄或一次性信息写入记忆。创建成功后返回新记忆的完整UUID。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['content'],
        'properties': <String, Object?>{
          'content': <String, String>{'type': 'string', 'description': '记忆正文。'},
          'level': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'critical',
              'important',
              'daily',
              'trivial',
              'archived',
            ],
            'description': '记忆等级，默认 daily。',
          },
          'tags': <String, Object?>{
            'type': 'array',
            'items': <String, String>{'type': 'string'},
            'description': '标签。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'update_memory',
      label: '更新记忆',
      description:
          '更新一条已有记忆。必须先通过 search_memory 获取记忆的UUID（形如 a1b2c3-... 的长字符串），不能使用数字序号。不要猜测ID，必须用搜索结果中返回的确切UUID。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id'],
        'properties': <String, Object?>{
          'id': <String, String>{
            'type': 'string',
            'description': '记忆的唯一UUID（从 search_memory 返回结果中获取的长字符串，不是数字序号）。',
          },
          'content': <String, String>{
            'type': 'string',
            'description': '新的记忆正文。',
          },
          'level': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'critical',
              'important',
              'daily',
              'trivial',
              'archived',
            ],
            'description': '新的等级。',
          },
          'tags': <String, Object?>{
            'type': 'array',
            'items': <String, String>{'type': 'string'},
            'description': '新的标签。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'delete_memory',
      description:
          '请求删除一条本地记忆。必须先通过 search_memory 获取记忆的UUID，确认是正确的那条后再提交删除。必须提供删除原因。此操作需要用户审批。',
      requiresApproval: true,
      label: '删除记忆',
      approvalText: 'AI 想删除一条本地记忆。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id', 'reason'],
        'properties': <String, Object?>{
          'id': <String, String>{
            'type': 'string',
            'description': '记忆的唯一UUID（从 search_memory 返回结果中获取的长字符串，不是数字序号）。',
          },
          'reason': <String, String>{'type': 'string', 'description': '删除原因。'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'create_diary_entry',
      label: '写 AI 日记',
      description: '创建一篇 AI 自己的日记。用户不能编辑正文，但可以查看和导出。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['title', 'content'],
        'properties': <String, Object?>{
          'title': <String, String>{'type': 'string', 'description': '日记标题。'},
          'content': <String, String>{'type': 'string', 'description': '日记正文。'},
          'mood': <String, String>{'type': 'string', 'description': '心情或语气。'},
          'tags': <String, Object?>{
            'type': 'array',
            'items': <String, String>{'type': 'string'},
            'description': '标签。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'revise_diary_entry',
      label: '修订 AI 日记',
      description: '修订一篇 AI 日记，旧版本会保留在历史记录里，不需要用户审批。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id'],
        'properties': <String, Object?>{
          'id': <String, String>{'type': 'string', 'description': '日记 ID。'},
          'title': <String, String>{'type': 'string', 'description': '新标题。'},
          'content': <String, String>{'type': 'string', 'description': '新正文。'},
          'mood': <String, String>{'type': 'string', 'description': '新的心情。'},
          'tags': <String, Object?>{
            'type': 'array',
            'items': <String, String>{'type': 'string'},
            'description': '新的标签。',
          },
          'reason': <String, String>{'type': 'string', 'description': '修订原因。'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'request_delete_diary_entry',
      label: '删除 AI 日记',
      description: '删除一篇 AI 日记。需要提供删除理由。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id', 'reason'],
        'properties': <String, Object?>{
          'id': <String, String>{'type': 'string', 'description': '日记 ID。'},
          'reason': <String, String>{
            'type': 'string',
            'description': 'AI 给出的删除理由。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'search_diary_entries',
      label: '搜索 AI 日记',
      description: '搜索所有AI日记（包含已删除的日记），可按关键词、标签和状态筛选。已删除的日记内容会显示删除原因。',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, String>{
            'type': 'string',
            'description': '标题、正文或理由里的关键词，可以为空。',
          },
          'status': <String, Object?>{
            'type': 'string',
            'enum': <String>['active', 'deleted', 'all'],
            'description': '日记状态，默认 all（全部）。',
          },
          'tags': <String, Object?>{
            'type': 'array',
            'items': <String, String>{'type': 'string'},
            'description': '限制标签。',
          },
          'limit': <String, String>{
            'type': 'number',
            'description': '最多返回多少条，默认 8。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'read_diary_entry',
      label: '读取 AI 日记',
      description: '读取一篇 AI 日记的当前内容和版本历史。已删除日记也可以读取历史。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id'],
        'properties': <String, Object?>{
          'id': <String, String>{'type': 'string', 'description': '日记 ID。'},
          'includeVersions': <String, String>{
            'type': 'boolean',
            'description': '是否返回版本历史，默认 true。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'search_files',
      label: '搜索文件',
      description: '搜索Ta的文件区中的文件，可按文件名或内容关键词搜索。不包含已删除文件。',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, String>{
            'type': 'string',
            'description': '文件名或内容关键词，可以为空以列出所有文件。',
          },
          'limit': <String, String>{
            'type': 'number',
            'description': '最多返回多少条，默认 8。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'read_file',
      label: '读取文件',
      description:
          '读取文件区中一个文件的完整内容。使用文件UUID（id），不是文件名。先通过 search_files 获取文件id，编辑前建议先 read_file 确认原文。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id'],
        'properties': <String, Object?>{
          'id': <String, String>{
            'type': 'string',
            'description': '文件的UUID（从 search_files 返回结果中获取，不是文件名）。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'create_file',
      label: '创建文件',
      description: '创建文件保存到Ta的文件区。会自动记录版本历史；成功后返回文件UUID（id），后续读取、编辑或删除必须复用该id。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['name', 'content'],
        'properties': <String, Object?>{
          'name': <String, String>{
            'type': 'string',
            'description': '文件名，包含扩展名，如 index.html、app.js',
          },
          'content': <String, String>{'type': 'string', 'description': '文件内容。'},
          'type': <String, String>{
            'type': 'string',
            'description': '文件类型，如 html、svg、js、css、md、json、text，默认根据文件名推测。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'edit_file',
      label: '编辑文件',
      description:
          '编辑文件区中已存在的文件。使用 create_file 返回或 search_files 查到的文件UUID（id），不是版本ID。不要猜测ID；如果需要参考原文，先用 read_file 读取完整内容。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id', 'content'],
        'properties': <String, Object?>{
          'id': <String, String>{
            'type': 'string',
            'description': '文件的UUID（从 search_files 返回结果中获取，不是文件名）。',
          },
          'content': <String, String>{
            'type': 'string',
            'description': '新的完整文件内容。',
          },
          'type': <String, String>{
            'type': 'string',
            'description': '文件类型，如 html、svg、js、css、md、json、text，默认根据文件名推测。',
          },
          'reason': <String, String>{
            'type': 'string',
            'description': '编辑原因，用于版本历史记录。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'delete_file',
      label: '删除文件',
      approvalText: 'AI 想删除Ta的文件区中的一个文件。',
      description: '删除文件区中的一个文件（软删除，前端保留记录）。使用文件UUID（id），需要提供删除原因。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['id', 'reason'],
        'properties': <String, Object?>{
          'id': <String, String>{
            'type': 'string',
            'description': '文件的UUID（从 search_files 返回结果中获取，不是文件名）。',
          },
          'reason': <String, String>{'type': 'string', 'description': '删除原因。'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'web_search',
      label: '网络搜索',
      description: '搜索网络上的信息。当用户需要实时信息或你知识之外的内容时使用此工具。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['query'],
        'properties': <String, Object?>{
          'query': <String, String>{
            'type': 'string',
            'description': '搜索关键词，尽量简洁有效。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'fetch_url',
      label: '抓取网页',
      description: '读取指定 URL 的内容。当用户提供链接需要你查看内容时使用。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['url'],
        'properties': <String, Object?>{
          'url': <String, String>{
            'type': 'string',
            'description': '要抓取的完整 URL。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'set_greeting',
      label: '修改欢迎语',
      description: '修改对话首页欢迎语。当用户想让你更改欢迎问候时使用此工具。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['greeting'],
        'properties': <String, Object?>{
          'greeting': <String, String>{
            'type': 'string',
            'description': '新的欢迎语，如"晚上好"。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'set_splash_phrases',
      label: '修改开屏语',
      description: '修改开屏语列表。用户可能需要更新应用开屏时的问候语。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['phrases'],
        'properties': <String, Object?>{
          'phrases': <String, String>{
            'type': 'string',
            'description': '开屏语，每行一句。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'create_calendar_event',
      description: '在用户系统日历中创建日程。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['title', 'start', 'end'],
        'properties': <String, Object?>{
          'title': <String, String>{'type': 'string'},
          'notes': <String, String>{'type': 'string'},
          'start': <String, String>{
            'type': 'string',
            'description': 'ISO 8601 时间',
          },
          'end': <String, String>{
            'type': 'string',
            'description': 'ISO 8601 时间',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'schedule_notification',
      description: '在 ClaudeChat 中建立本地定时通知。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['title', 'scheduled_at'],
        'properties': <String, Object?>{
          'title': <String, String>{'type': 'string'},
          'body': <String, String>{'type': 'string'},
          'scheduled_at': <String, String>{
            'type': 'string',
            'description': 'ISO 8601 时间',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'create_system_reminder',
      description: '写入 iOS 提醒事项或 Android 系统日历提醒。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['title', 'due'],
        'properties': <String, Object?>{
          'title': <String, String>{'type': 'string'},
          'notes': <String, String>{'type': 'string'},
          'due': <String, String>{
            'type': 'string',
            'description': 'ISO 8601 时间',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'update_home_widget',
      description: '更新 ClaudeChat 桌面小组件显示的标题和正文。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['title', 'body'],
        'properties': <String, Object?>{
          'title': <String, String>{'type': 'string'},
          'body': <String, String>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
  ];

  static const legacyChatToolNames = <String>[
    'get_time',
    'search_memory',
    'create_memory',
    'update_memory',
    'delete_memory',
    'create_diary_entry',
    'revise_diary_entry',
    'request_delete_diary_entry',
    'search_diary_entries',
    'read_diary_entry',
    'web_search',
    'fetch_url',
    'create_file',
    'search_files',
    'read_file',
    'edit_file',
    'delete_file',
    'set_greeting',
    'set_splash_phrases',
  ];

  static List<ToolDefinition> get legacyChatDefinitions => legacyChatToolNames
      .map(
        (name) =>
            definitions.firstWhere((definition) => definition.name == name),
      )
      .toList(growable: false);

  static List<ToolDefinition> get orderedDefinitions => <ToolDefinition>[
    ...legacyChatDefinitions,
    ...definitions.where(
      (definition) => !legacyChatToolNames.contains(definition.name),
    ),
  ];

  ToolDefinition? definition(String name) {
    final canonical = name == 'delete_diary_entry'
        ? 'request_delete_diary_entry'
        : name;
    return definitions.where((item) => item.name == canonical).firstOrNull;
  }

  Future<String> execute(
    ToolRequest request, {
    required bool approved,
    String? conversationId,
  }) async {
    activeConversationId = conversationId;
    final definition = this.definition(request.name);
    if (definition == null)
      return jsonEncode(<String, String>{'error': '未知工具 ${request.name}'});
    if (definition.requiresApproval && !approved)
      return jsonEncode(<String, String>{'error': '用户未批准该操作'});
    final args = request.arguments;
    try {
      final result = switch (request.name) {
        'get_time' => await _time(),
        'search_memory' => await _searchMemory(args),
        'create_memory' => await _createMemory(args),
        'update_memory' => await _updateMemory(args),
        'delete_memory' => await _deleteMemory(args),
        'create_diary_entry' => await _createDiary(args),
        'revise_diary_entry' => await _reviseDiary(args),
        'request_delete_diary_entry' ||
        'delete_diary_entry' => await _requestDeleteDiary(args),
        'search_diary_entries' => await _searchDiaries(args),
        'read_diary_entry' => await _readDiary(args),
        'search_files' => await _searchFiles(args),
        'read_file' => await _readFile(args),
        'create_file' => await _createFile(args),
        'edit_file' => await _editFile(args),
        'delete_file' => await _deleteFile(args),
        'web_search' => await _webSearch(args),
        'fetch_url' => await _fetchUrl(args),
        'set_greeting' => await _setGreeting('${args['greeting'] ?? ''}'),
        'set_splash_phrases' => await _setSplash('${args['phrases'] ?? ''}'),
        'create_calendar_event' => await _calendar(args),
        'schedule_notification' => await _notification(args),
        'create_system_reminder' => await _systemReminder(args),
        'update_home_widget' => await _widget(args),
        _ => <String, String>{'error': '工具尚未实现'},
      };
      return jsonEncode(result);
    } on Object catch (error) {
      final message = error is FormatException ? error.message : '$error';
      return jsonEncode(<String, String>{'error': message});
    }
  }

  String? activeConversationId;

  Future<Map<String, Object?>> _time() async {
    final now = DateTime.now();
    final hour = now.hour;
    return <String, Object?>{
      'iso': now.toUtc().toIso8601String(),
      'local':
          '${now.year}年${now.month}月${now.day}日${_weekdays[now.weekday - 1]} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}',
      'timeZone': await platform.timeZoneIdentifier(),
      'period': hour < 6
          ? '凌晨'
          : hour < 11
          ? '早上'
          : hour < 14
          ? '中午'
          : hour < 18
          ? '下午'
          : '晚上',
    };
  }

  Future<Map<String, Object?>> _searchMemory(Map<String, Object?> args) async {
    await cleanStaleTrivialMemories();
    final query = '${args['query'] ?? ''}'.trim().toLowerCase();
    final levels = _toolStringList(
      args['levels'],
    ).where(_memoryLevels.contains).toSet();
    final tags = _toolStringList(
      args['tags'],
    ).map((value) => value.toLowerCase()).toSet();
    final scored =
        (await content.memories())
            .where((item) => levels.isEmpty || levels.contains(item.level))
            .where(
              (item) =>
                  tags.isEmpty ||
                  tags.every(
                    item.tags
                        .map((value) => value.toLowerCase())
                        .toSet()
                        .contains,
                  ),
            )
            .map((item) => (item: item, score: _memoryScore(item, query, tags)))
            .where((entry) => query.isEmpty || entry.score > 0)
            .toList()
          ..sort(
            (a, b) => b.score.compareTo(a.score) != 0
                ? b.score.compareTo(a.score)
                : (b.item.lastAccessedAt?.toIso8601String() ?? '').compareTo(
                    a.item.lastAccessedAt?.toIso8601String() ?? '',
                  ),
          );
    final matches = scored.take(_limit(args['limit'])).toList();
    final accessedAt = DateTime.now().toUtc().toIso8601String();
    for (final entry in matches) {
      await store.database.update(
        'memories',
        <String, Object?>{
          'last_accessed_at': accessedAt,
          'use_frequency': entry.item.useFrequency + 1,
        },
        where: 'id = ?',
        whereArgs: <Object?>[entry.item.id],
      );
    }
    return <String, Object?>{
      'matches': matches.map((entry) => _publicMemory(entry.item)).toList(),
      'total': matches.length,
    };
  }

  Future<Map<String, Object?>> _createMemory(Map<String, Object?> args) async {
    final value = '${args['content'] ?? ''}'.trim();
    if (value.isEmpty) throw const FormatException('content 不能为空');
    final id = await content.saveMemory(
      content: value,
      level: _memoryLevels.contains('${args['level']}')
          ? '${args['level']}'
          : 'daily',
      tags: _normalizeTags(args['tags']),
      source: 'ai',
      sourceConversationId: activeConversationId,
    );
    return _publicMemory(await _memory(id, includeDeleted: true));
  }

  Future<Map<String, Object?>> _updateMemory(Map<String, Object?> args) async {
    final id = '${args['id'] ?? ''}'.trim();
    final rows = await store.database.query(
      'memories',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw const FormatException('没有找到这条可用记忆');
    final row = rows.first;
    await content.saveMemory(
      id: id,
      content: args['content'] == null
          ? row['content']! as String
          : '${args['content']}'.trim().isEmpty
          ? row['content']! as String
          : '${args['content']}'.trim(),
      level: _memoryLevels.contains('${args['level']}')
          ? '${args['level']}'
          : row['level']! as String,
      tags: args['tags'] == null
          ? ((jsonDecode(row['tags_json']! as String)) as List).cast<String>()
          : _normalizeTags(args['tags']),
    );
    return _publicMemory(await _memory(id, includeDeleted: true));
  }

  Future<Map<String, Object?>> _deleteMemory(Map<String, Object?> args) async {
    final id = '${args['id'] ?? ''}'.trim();
    if (id.isEmpty) throw const FormatException('请提供记忆UUID');
    final reason = '${args['reason'] ?? ''}'.trim();
    if (reason.isEmpty) throw const FormatException('删除记忆必须提供删除原因');
    final rows = await store.database.query(
      'memories',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw const FormatException('没有找到这条可用记忆');
    await store.database.update(
      'memories',
      <String, Object?>{'delete_reason': reason},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    await store.softDelete('memories', id);
    return _publicMemory(await _memory(id, includeDeleted: true));
  }

  Future<MemoryEntry> _memory(String id, {bool includeDeleted = false}) async {
    final rows = await store.database.query(
      'memories',
      where: includeDeleted ? 'id = ?' : 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw const FormatException('没有找到这条可用记忆');
    return MemoryEntry.fromMap(rows.first);
  }

  Map<String, Object?> _publicMemory(MemoryEntry item) => <String, Object?>{
    'id': item.id,
    'content': item.content,
    'level': item.level,
    'tags': item.tags,
    'source': item.source,
    'sourceConversationId': item.sourceConversationId ?? '',
    'createdAt': item.createdAt.toUtc().toIso8601String(),
    'updatedAt': item.updatedAt.toUtc().toIso8601String(),
    'last_accessed': item.lastAccessedAt?.toUtc().toIso8601String() ?? '',
    'use_frequency': item.useFrequency,
    'deletedAt': item.deletedAt?.toUtc().toIso8601String() ?? '',
    'deleteReason': item.deleteReason ?? '',
  };

  Future<Map<String, Object?>> _requestDeleteDiary(
    Map<String, Object?> args,
  ) async {
    final id = '${args['id'] ?? ''}'.trim();
    final reason = '${args['reason'] ?? ''}'.trim().isEmpty
        ? 'AI 请求删除'
        : '${args['reason']}'.trim();
    final rows = await store.database.query(
      'diary_entries',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw const FormatException('没有找到这篇日记');
    final current = DiaryEntry.fromMap(rows.first);
    if (current.status == 'deleted' || current.deletedAt != null) {
      return _publicDiary(current);
    }
    final latest = await content.diaryLatest(id);
    final now = DateTime.now().toUtc();
    final versionId = _uuid.v4();
    await store.database.insert(
      'diary_versions',
      DiaryVersion(
        id: versionId,
        diaryId: id,
        title: current.title,
        content: latest?.content ?? '',
        operation: 'delete',
        reason: reason,
        mood: current.mood,
        tags: current.tags,
        sourceConversationId: activeConversationId,
        createdAt: now,
        originDeviceId: store.deviceId,
      ).toMap(),
    );
    await store.database.update(
      'diary_entries',
      <String, Object?>{
        'status': 'deleted',
        'latest_version_id': versionId,
        'delete_reason': reason,
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    await store.softDelete('diary_entries', id);
    final updated = await store.database.query(
      'diary_entries',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return _publicDiary(DiaryEntry.fromMap(updated.first));
  }

  Future<Map<String, Object?>> _publicDiary(DiaryEntry entry) async {
    final versions = await content.diaryVersions(entry.id);
    final latest =
        versions
            .where((item) => item.id == entry.latestVersionId)
            .firstOrNull ??
        versions.firstOrNull;
    final deleted = entry.status == 'deleted' || entry.deletedAt != null;
    return <String, Object?>{
      'id': entry.id,
      'title': entry.title,
      'status': entry.status,
      'mood': entry.mood ?? '',
      'tags': entry.tags,
      'createdAt': entry.createdAt.toUtc().toIso8601String(),
      'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
      'deletedAt': entry.deletedAt?.toUtc().toIso8601String() ?? '',
      'deleteReason': entry.deleteReason ?? '',
      'sourceConversationId': entry.sourceConversationId ?? '',
      'latestVersionId': entry.latestVersionId,
      'versionCount': versions.length,
      'latestContentPreview': deleted && (entry.deleteReason ?? '').isNotEmpty
          ? '已删除，原因为：${entry.deleteReason}'
          : (latest?.content ?? '').substring(
              0,
              (latest?.content.length ?? 0).clamp(0, 240),
            ),
    };
  }

  Future<Map<String, Object?>> _createDiary(Map<String, Object?> args) async {
    final title = '${args['title'] ?? ''}'.trim();
    final body = '${args['content'] ?? ''}'.trim();
    if (title.isEmpty || body.trim().isEmpty)
      throw const FormatException('title 和 content 不能为空');
    final id = await content.saveDiary(
      title: title,
      content: body,
      mood: args['mood'] as String?,
      tags: _normalizeTags(args['tags']),
      reason: '创建日记',
      sourceConversationId: activeConversationId,
    );
    return _publicDiary(await _diary(id));
  }

  Future<Map<String, Object?>> _reviseDiary(Map<String, Object?> args) async {
    final id = '${args['id'] ?? ''}'.trim();
    final rows = await store.database.query(
      'diary_entries',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw const FormatException('没有找到这篇日记');
    final current = rows.first;
    if (current['status'] == 'deleted' || current['deleted_at'] != null) {
      throw const FormatException('已删除的日记不能继续修订');
    }
    final latest = await content.diaryLatest(id);
    final revisedContent = '${args['content'] ?? ''}'.trim().isEmpty
        ? (latest?.content ?? '')
        : '${args['content']}'.trim();
    if (revisedContent.isEmpty) throw const FormatException('修订后的正文不能为空');
    await content.saveDiary(
      id: id,
      title: '${args['title'] ?? ''}'.trim().isEmpty
          ? current['title']! as String
          : '${args['title']}'.trim(),
      content: revisedContent,
      mood: '${args['mood'] ?? ''}'.trim().isEmpty
          ? current['mood'] as String?
          : '${args['mood']}'.trim(),
      tags: args['tags'] == null
          ? ((jsonDecode(current['tags_json']! as String)) as List)
                .cast<String>()
          : _normalizeTags(args['tags']),
      reason: '${args['reason'] ?? ''}'.trim().isEmpty
          ? 'AI 修订了这篇日记'
          : '${args['reason']}'.trim(),
      sourceConversationId: current['source_conversation_id'] as String?,
      versionSourceConversationId: activeConversationId,
    );
    return _publicDiary(await _diary(id));
  }

  Future<DiaryEntry> _diary(String id) async {
    final rows = await store.database.query(
      'diary_entries',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw const FormatException('没有找到这篇日记');
    return DiaryEntry.fromMap(rows.first);
  }

  Future<Map<String, Object?>> _searchDiaries(Map<String, Object?> args) async {
    final query = '${args['query'] ?? ''}'.trim().toLowerCase();
    final status = <String>{'active', 'deleted', 'all'}.contains(args['status'])
        ? '${args['status']}'
        : 'all';
    final tags = _toolStringList(
      args['tags'],
    ).map((value) => value.toLowerCase()).toSet();
    final items = await content.diaries(includeDeleted: true);
    final scored = <({DiaryEntry item, int score})>[];
    for (final item in items) {
      final deleted = item.deletedAt != null || item.status == 'deleted';
      if (status == 'active' && deleted || status == 'deleted' && !deleted)
        continue;
      final lowerTags = item.tags.map((value) => value.toLowerCase()).toSet();
      if (tags.isNotEmpty && !tags.every(lowerTags.contains)) continue;
      final versions = await content.diaryVersions(item.id);
      final haystack = <String>[
        item.title,
        item.mood ?? '',
        item.deleteReason ?? '',
        item.tags.join(' '),
        ...versions.map(
          (value) => '${value.title} ${value.content} ${value.reason ?? ''}',
        ),
      ].join(' ').toLowerCase();
      final score = query.isEmpty && tags.isEmpty
          ? item.updatedAt.millisecondsSinceEpoch
          : _textScore(haystack, query) +
                tags.where(lowerTags.contains).length * 4;
      if (query.isEmpty || score > 0) {
        scored.add((item: item, score: score));
      }
    }
    scored.sort(
      (a, b) => b.score.compareTo(a.score) != 0
          ? b.score.compareTo(a.score)
          : b.item.updatedAt.compareTo(a.item.updatedAt),
    );
    final selected = scored.take(_limit(args['limit'])).toList();
    final matches = <Map<String, Object?>>[];
    for (final value in selected) {
      matches.add(await _publicDiary(value.item));
    }
    return <String, Object?>{'matches': matches, 'total': matches.length};
  }

  Future<Map<String, Object?>> _readDiary(Map<String, Object?> args) async {
    final id = '${args['id'] ?? ''}'.trim();
    final rows = await store.database.query(
      'diary_entries',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw const FormatException('没有找到这篇日记');
    final versions = await content.diaryVersions(id);
    final entry = DiaryEntry.fromMap(rows.first);
    final latest =
        versions
            .where((item) => item.id == entry.latestVersionId)
            .firstOrNull ??
        versions.firstOrNull;
    return <String, Object?>{
      ...await _publicDiary(entry),
      'content': latest?.content ?? '',
      'latestReason': latest?.reason ?? '',
      'versions': args['includeVersions'] == false
          ? const <Object?>[]
          : versions.map(_publicDiaryVersion).toList(),
    };
  }

  Map<String, Object?> _publicDiaryVersion(DiaryVersion item) =>
      <String, Object?>{
        'id': item.id,
        'diaryId': item.diaryId,
        'title': item.title,
        'content': item.content,
        'reason': item.reason ?? '',
        'mood': item.mood ?? '',
        'tags': item.tags,
        'createdAt': item.createdAt.toUtc().toIso8601String(),
        'operation': item.operation,
        'sourceConversationId': item.sourceConversationId ?? '',
      };

  Future<Map<String, Object?>> _searchFiles(Map<String, Object?> args) async {
    final value = '${args['query'] ?? ''}'.trim().toLowerCase();
    final items = await content.files();
    final matches = <Map<String, Object?>>[];
    final integrityErrors = <Map<String, Object?>>[];
    for (final item in items) {
      String body;
      try {
        body = await content.readFile(item.id);
      } on FileIntegrityException catch (error) {
        integrityErrors.add(<String, Object?>{
          'id': item.id,
          'name': item.name,
          'error': error.message,
        });
        continue;
      } on FileSystemException catch (error) {
        integrityErrors.add(<String, Object?>{
          'id': item.id,
          'name': item.name,
          'error': '文件无法读取：${error.message}',
        });
        continue;
      }
      if (value.isNotEmpty &&
          !item.name.toLowerCase().contains(value) &&
          !body
              .substring(0, body.length.clamp(0, 2000))
              .toLowerCase()
              .contains(value)) {
        continue;
      }
      matches.add(await _publicFile(item, body));
      if (matches.length >= _fileLimit(args['limit'])) break;
    }
    return <String, Object?>{
      'matches': matches,
      'total': matches.length,
      if (integrityErrors.isNotEmpty) 'integrityErrors': integrityErrors,
    };
  }

  Future<Map<String, Object?>> _readFile(Map<String, Object?> args) async {
    final item = await _resolveFileReference(args, includeDeleted: true);
    if (item.status == 'deleted' || item.deletedAt != null) {
      throw const FormatException('已删除的文件不能读取');
    }
    final body = await content.readFile(item.id);
    final public = await _publicFile(item, body);
    public.remove('preview');
    public.remove('deleteReason');
    return <String, Object?>{...public, 'content': body};
  }

  Future<Map<String, Object?>> _createFile(Map<String, Object?> args) async {
    final name = '${args['name'] ?? ''}'.trim();
    if (name.isEmpty) throw const FormatException('请提供文件名');
    final matches = await store.database.query(
      'user_files',
      where: 'name = ? AND status = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[name, 'active'],
      limit: 1,
    );
    final existingId = matches.isEmpty ? null : matches.first['id'] as String;
    final body = '${args['content'] ?? ''}';
    final type = '${args['type'] ?? _type(name)}'.trim().isEmpty
        ? 'text'
        : '${args['type'] ?? _type(name)}'.trim();
    final receipt = await content.saveTextFile(
      id: existingId,
      name: name,
      content: body,
      type: type,
      reason: existingId == null ? '创建文件' : '编辑前自动保存旧版本',
    );
    return _fileWriteReceipt(receipt);
  }

  Future<Map<String, Object?>> _editFile(Map<String, Object?> args) async {
    final item = await _resolveFileReference(args, includeDeleted: true);
    if (item.status == 'deleted' || item.deletedAt != null) {
      throw const FormatException('已删除的文件不能编辑');
    }
    final body = '${args['content'] ?? ''}';
    final requestedType = '${args['type'] ?? ''}'.trim();
    final type =
        (requestedType.isEmpty ? _type(item.name) : requestedType)
            .trim()
            .isEmpty
        ? 'text'
        : (requestedType.isEmpty
              ? _type(item.name)
              : requestedType);
    final receipt = await content.saveTextFile(
      id: item.id,
      name: item.name,
      content: body,
      type: type,
      reason: '${args['reason'] ?? ''}'.trim().isEmpty
          ? 'AI 编辑'
          : '${args['reason']}'.trim(),
    );
    return _fileWriteReceipt(receipt);
  }

  Future<Map<String, Object?>> _deleteFile(Map<String, Object?> args) async {
    final item = await _resolveFileReference(args, includeDeleted: true);
    final id = item.id;
    if (item.status == 'deleted' || item.deletedAt != null) {
      return <String, Object?>{
        'id': id,
        'name': item.name,
        'action': 'already_deleted',
      };
    }
    final reason = '${args['reason'] ?? ''}'.trim().isEmpty
        ? 'AI 请求删除'
        : '${args['reason']}'.trim();
    final body = await content.readFile(id);
    await content.saveTextFile(
      id: id,
      name: item.name,
      content: body,
      type: item.type,
      reason: '删除：$reason',
    );
    await store.database.update(
      'user_files',
      <String, Object?>{'status': 'deleted', 'delete_reason': reason},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    await store.softDelete('user_files', id);
    return <String, Object?>{
      'id': id,
      'name': item.name,
      'action': 'deleted',
      'reason': reason,
    };
  }

  Future<UserFileRecord> _file(String id, {bool includeDeleted = false}) async {
    final rows = await store.database.query(
      'user_files',
      where: includeDeleted ? 'id = ?' : 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const FormatException('没有找到该文件，请用 search_files 先获取id');
    }
    return UserFileRecord.fromMap(rows.first);
  }

  Future<UserFileRecord> _resolveFileReference(
    Map<String, Object?> args, {
    bool includeDeleted = false,
  }) async {
    final directId = <Object?>[
      args['id'],
      args['fileId'],
      args['file_id'],
    ]
        .map((value) => '${value ?? ''}'.trim())
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    if (directId != null) {
      final directRows = await store.database.query(
        'user_files',
        where: includeDeleted
            ? 'id = ?'
            : 'id = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[directId],
        limit: 1,
      );
      if (directRows.isNotEmpty) {
        return UserFileRecord.fromMap(directRows.single);
      }
      final versionRows = await store.database.query(
        'file_versions',
        columns: const <String>['file_id'],
        where: 'id = ?',
        whereArgs: <Object?>[directId],
        limit: 1,
      );
      if (versionRows.isNotEmpty) {
        return _file(
          '${versionRows.single['file_id']}',
          includeDeleted: includeDeleted,
        );
      }
    }

    // Some compatible providers echo the version receipt instead of the file
    // UUID. Resolve it safely through the local version table rather than
    // letting the model guess another identifier.
    final versionId = '${args['versionId'] ?? args['version_id'] ?? ''}'.trim();
    if (versionId.isNotEmpty) {
      final versions = await store.database.query(
        'file_versions',
        columns: const <String>['file_id'],
        where: 'id = ?',
        whereArgs: <Object?>[versionId],
        limit: 1,
      );
      if (versions.isNotEmpty) {
        return _file(
          '${versions.first['file_id']}',
          includeDeleted: includeDeleted,
        );
      }
    }

    // Keep the UUID contract as the advertised path, but tolerate an exact
    // active filename supplied by providers that dropped the prior receipt.
    final name = '${args['name'] ?? ''}'.trim();
    if (name.isNotEmpty) {
      final rows = await store.database.query(
        'user_files',
        where: includeDeleted
            ? 'name = ? COLLATE NOCASE'
            : 'name = ? COLLATE NOCASE AND status = ? AND deleted_at IS NULL',
        whereArgs: includeDeleted
            ? <Object?>[name]
            : <Object?>[name, 'active'],
        orderBy: 'updated_at DESC',
        limit: 2,
      );
      if (rows.length == 1) return UserFileRecord.fromMap(rows.single);
      if (rows.length > 1) {
        throw const FormatException('存在多个同名文件，请用 search_files 获取准确的文件UUID');
      }
    }
    throw const FormatException(
      '请提供文件UUID（id）。可直接复用 create_file 返回的 id，或先用 search_files 查询。',
    );
  }

  Map<String, Object?> _fileWriteReceipt(VerifiedFileWrite receipt) =>
      <String, Object?>{
        ...receipt.toMap(),
        'reference': <String, Object?>{
          'id': receipt.id,
          'fileId': receipt.id,
          'versionId': receipt.versionId,
        },
        'nextToolArguments': <String, Object?>{
          'read_file': <String, String>{'id': receipt.id},
          'edit_file': <String, String>{'id': receipt.id},
          'delete_file': <String, String>{'id': receipt.id},
        },
      };

  Future<Map<String, Object?>> _publicFile(
    UserFileRecord item,
    String body,
  ) async {
    final rows = await store.database.query(
      'user_files',
      columns: const <String>['created_at'],
      where: 'id = ?',
      whereArgs: <Object?>[item.id],
      limit: 1,
    );
    final versions = await content.fileVersions(item.id);
    return <String, Object?>{
      'id': item.id,
      'name': item.name,
      'type': item.type,
      'status': item.status,
      'size': body.length,
      'preview': body.substring(0, body.length.clamp(0, 200)),
      'createdAt': rows.firstOrNull?['created_at'],
      'updatedAt': item.updatedAt.toUtc().toIso8601String(),
      'deleteReason': item.deleteReason ?? '',
      'versionCount': versions.length,
    };
  }

  Future<Map<String, Object?>> _setGreeting(String value) async {
    final greeting = _normalizeDisplayLineBreaks(value).trim();
    if (greeting.isEmpty) throw const FormatException('请输入欢迎语');
    await settings.set('greeting', greeting);
    return <String, Object?>{'greeting': greeting};
  }

  Future<Map<String, Object?>> _setSplash(String value) async {
    final phrases = _normalizeDisplayLineBreaks(value).trim();
    if (phrases.isEmpty) throw const FormatException('请输入开屏语');
    await settings.set('splashPhrases', phrases);
    return <String, Object?>{'phrases': phrases};
  }

  String _normalizeDisplayLineBreaks(String value) => value
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll('/n', '\n');

  Future<Map<String, Object?>> _calendar(Map<String, Object?> args) async {
    final start = _futureDate(args['start'], '开始时间');
    final end = DateTime.tryParse('${args['end'] ?? ''}')?.toLocal();
    if (end == null || !end.isAfter(start))
      throw const FormatException('结束时间必须晚于开始时间');
    await platform.addCalendarEvent(
      title: _required(args['title'], '标题'),
      notes: '${args['notes'] ?? ''}',
      start: start,
      end: end,
    );
    return <String, Object?>{
      'created': true,
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
    };
  }

  Future<Map<String, Object?>> _notification(Map<String, Object?> args) async {
    final scheduled = _futureDate(args['scheduled_at'], '提醒时间');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now().toUtc().toIso8601String();
    final title = _required(args['title'], '标题');
    final userSettings = await settings.load();
    final soundUri = userSettings['notificationSoundUri'] as String?;
    await store.database.insert('reminders', <String, Object?>{
      'id': id,
      'title': title,
      'body': '${args['body'] ?? ''}',
      'scheduled_at': scheduled.toUtc().toIso8601String(),
      'timezone': scheduled.timeZoneName,
      'status': 'pending',
      'created_at': now,
      'updated_at': now,
      'revision': 1,
      'origin_device_id': store.deviceId,
    });
    try {
      await platform.scheduleNotification(
        id: id.hashCode & 0x7fffffff,
        title: title,
        body: '${args['body'] ?? ''}',
        at: scheduled,
        soundUri: soundUri,
      );
      await store.database.update(
        'reminders',
        <String, Object?>{
          'status': 'scheduled',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    } on Object catch (error) {
      await store.database.update(
        'reminders',
        <String, Object?>{
          'status': 'failed',
          'body': '${args['body'] ?? ''}\n[调度失败：$error]',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      rethrow;
    }
    return <String, Object?>{
      'created': true,
      'id': id,
      'scheduledAt': scheduled.toIso8601String(),
    };
  }

  Future<Map<String, Object?>> _systemReminder(
    Map<String, Object?> args,
  ) async {
    final due = _futureDate(args['due'], '到期时间');
    await platform.addSystemReminder(
      title: _required(args['title'], '标题'),
      notes: '${args['notes'] ?? ''}',
      due: due,
    );
    return <String, Object?>{'created': true, 'due': due.toIso8601String()};
  }

  Future<Map<String, Object?>> _widget(Map<String, Object?> args) async {
    final title = _required(args['title'], '标题');
    final body = _required(args['body'], '正文');
    await platform.updateWidget(title: title, body: body);
    return <String, Object?>{'updated': true};
  }

  DateTime _futureDate(Object? value, String label) {
    final date = DateTime.tryParse('${value ?? ''}')?.toLocal();
    if (date == null) throw FormatException('$label不是有效的 ISO 8601 时间');
    if (!date.isAfter(DateTime.now())) throw FormatException('$label必须晚于当前时间');
    return date;
  }

  String _required(Object? value, String label) {
    final output = '${value ?? ''}'.trim();
    if (output.isEmpty) throw FormatException('$label不能为空');
    return output;
  }

  int _memoryScore(MemoryEntry item, String query, Set<String> tags) {
    final lowerTags = item.tags.map((value) => value.toLowerCase()).toSet();
    final haystack = '${item.content} ${item.tags.join(' ')}'.toLowerCase();
    var score = _textScore(haystack, query);
    score += tags.where(lowerTags.contains).length * 4;
    if (item.level == 'critical') score += 3;
    if (item.level == 'important') score += 2;
    if (query.isEmpty && tags.isEmpty) {
      return item.updatedAt.millisecondsSinceEpoch;
    }
    return score;
  }

  int _textScore(String haystack, String query) {
    if (query.isEmpty) return 0;
    var score = haystack.contains(query) ? 10 : 0;
    for (final word
        in query.split(RegExp(r'\s+')).where((value) => value.isNotEmpty)) {
      if (haystack.contains(word)) score += 2;
    }
    return score;
  }

  int _limit(Object? value) => _number(value, 8).clamp(1, 20);
  int _fileLimit(Object? value) => _number(value, 8).clamp(1, 30);

  int _number(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return num.tryParse('${value ?? ''}')?.toInt() ?? fallback;
  }

  List<String> _toolStringList(Object? value) {
    if (value is List) {
      return value
          .map((item) => '$item'.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return _normalizeTags(value);
  }

  List<String> _normalizeTags(Object? value) {
    final values = value is List
        ? value.map((item) => '$item')
        : value is String
        ? value.split(RegExp(r'[,，#\s]+'))
        : const <String>[];
    return values
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .take(12)
        .toList();
  }

  Future<void> cleanStaleTrivialMemories() async {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 7));
    final rows = await store.database.query(
      'memories',
      columns: const <String>[
        'id',
        'created_at',
        'updated_at',
        'last_accessed_at',
        'use_frequency',
      ],
      where: 'level = ? AND deleted_at IS NULL AND use_frequency <= ?',
      whereArgs: const <Object?>['trivial', 1],
    );
    for (final row in rows) {
      final lastUsed = DateTime.tryParse(
        '${row['last_accessed_at'] ?? row['updated_at'] ?? row['created_at'] ?? ''}',
      )?.toUtc();
      if (lastUsed == null || !lastUsed.isBefore(cutoff)) continue;
      await store.database.update(
        'memories',
        const <String, Object?>{'delete_reason': '琐碎记忆已过期自动清理'},
        where: 'id = ?',
        whereArgs: <Object?>[row['id']],
      );
      await store.softDelete('memories', '${row['id']}');
    }
  }

  Future<Map<String, Object?>> _webSearch(Map<String, Object?> args) async {
    final query = '${args['query'] ?? ''}'.trim();
    if (query.isEmpty) throw const FormatException('请输入搜索关键词');
    try {
      return <String, Object?>{
        'query': query,
        'results': (await web.search(
          query,
          limit: 8,
        )).map((item) => item.toJson()).toList(),
      };
    } on Object catch (error) {
      final message = error is FormatException ? error.message : '$error';
      throw FormatException('网络搜索未成功：$message');
    }
  }

  Future<Map<String, Object?>> _fetchUrl(Map<String, Object?> args) async {
    final url = '${args['url'] ?? ''}'.trim();
    if (url.isEmpty) throw const FormatException('请提供要抓取的 URL');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw const FormatException('仅支持 http/https 链接');
    }
    try {
      return await web.fetch(url);
    } on Object catch (error) {
      final message = error is FormatException ? error.message : '$error';
      throw FormatException('网页抓取未成功：$message');
    }
  }

  String _type(String name) {
    final extension = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    return switch (extension) {
      'html' || 'htm' => 'html',
      'svg' => 'svg',
      'js' => 'js',
      'css' => 'css',
      'json' => 'json',
      'md' => 'md',
      _ => 'text',
    };
  }
}

const _memoryLevels = <String>{
  'critical',
  'important',
  'daily',
  'trivial',
  'archived',
};

const _weekdays = <String>['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
