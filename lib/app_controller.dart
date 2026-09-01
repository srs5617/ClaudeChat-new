import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:share_plus/share_plus.dart';

import 'core/app_paths.dart';
import 'data/app_database.dart';
import 'domain/entities.dart';
import 'services/api_client.dart';
import 'services/attachment_service.dart';
import 'services/backup_service.dart';
import 'services/brand_service.dart';
import 'services/content_repository.dart';
import 'services/context_budget.dart';
import 'services/diagnostics_service.dart';
import 'services/legacy_import_service.dart';
import 'services/platform_service.dart';
import 'services/portable_data_service.dart';
import 'services/secure_vault.dart';
import 'services/settings_service.dart';
import 'services/tool_service.dart';
import 'services/tool_preferences.dart';
import 'services/usage_formatter.dart';
import 'services/voice_service.dart';
import 'services/workspace_export_service.dart';
import 'services/workspace_project_service.dart';

enum AppSection { chat, memories, diary, files, voices, workspaces, settings }

enum AppNoticeType { info, notice, danger }

class AppNotice {
  const AppNotice({
    required this.id,
    required this.type,
    required this.text,
    required this.createdAt,
    this.target,
    this.entryId,
    this.approval,
  });

  final String id;
  final AppNoticeType type;
  final String text;
  final DateTime createdAt;
  final AppSection? target;
  final String? entryId;
  final ToolRequest? approval;

  bool get isApproval => approval != null;
}

class AppNoticeNavigation {
  const AppNoticeNavigation({
    required this.serial,
    required this.target,
    required this.entryId,
    this.returnConversationId,
    this.returnScrollOffset,
    this.returnScrollable,
  });

  final int serial;
  final AppSection target;
  final String entryId;
  final String? returnConversationId;
  final double? returnScrollOffset;
  final bool? returnScrollable;

  bool get canReturnToChat => returnConversationId != null;
}

enum ChatViewportDisposition { bottom, restore }

class ChatViewportRequest {
  const ChatViewportRequest({
    required this.serial,
    required this.conversationId,
    required this.disposition,
    this.offset,
    this.reserveLegacyScrollbar = false,
  });

  final int serial;
  final String conversationId;
  final ChatViewportDisposition disposition;
  final double? offset;
  final bool reserveLegacyScrollbar;
}

class WorkspaceTaskStep {
  const WorkspaceTaskStep({
    required this.key,
    required this.label,
    required this.state,
    required this.updatedAt,
    this.detail = '',
  });

  final String key;
  final String label;
  final String state;
  final String detail;
  final DateTime updatedAt;

  WorkspaceTaskStep copyWith({
    String? label,
    String? state,
    String? detail,
    DateTime? updatedAt,
  }) => WorkspaceTaskStep(
    key: key,
    label: label ?? this.label,
    state: state ?? this.state,
    detail: detail ?? this.detail,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class WorkspacePlanItem {
  const WorkspacePlanItem({
    required this.id,
    required this.title,
    required this.state,
  });

  final String id;
  final String title;
  final String state;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'title': title,
    'state': state,
  };

  static WorkspacePlanItem? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final title = '${raw['title'] ?? raw['label'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    final state = '${raw['state'] ?? raw['status'] ?? 'pending'}';
    return WorkspacePlanItem(
      id: id.isEmpty ? 'plan-${title.hashCode}' : id,
      title: title,
      state:
          const <String>{
            'pending',
            'running',
            'completed',
            'failed',
          }.contains(state)
          ? state
          : 'pending',
    );
  }
}

class WorkspaceTaskQueueEntry {
  const WorkspaceTaskQueueEntry({
    required this.workspace,
    required this.busy,
    required this.hasTask,
    required this.summary,
    required this.updatedAt,
  });

  final WorkspaceRecord workspace;
  final bool busy;
  final bool hasTask;
  final String summary;
  final DateTime updatedAt;
}

class WorkspaceLiveFileEdit {
  const WorkspaceLiveFileEdit({
    required this.name,
    required this.content,
    required this.status,
    required this.updatedAt,
  });

  final String name;
  final String content;
  final String status;
  final DateTime updatedAt;
}

class _WorkspaceRunState {
  _WorkspaceRunState(this.workspaceId);

  final String workspaceId;
  String? conversationId;
  bool busy = false;
  String streamingText = '';
  String streamingReasoning = '';
  List<ChatCompletionPart> streamingParts = <ChatCompletionPart>[];
  ChatCompletionPart? streamingToolProgress;
  List<WorkspaceTaskStep> taskSteps = <WorkspaceTaskStep>[];
  List<WorkspacePlanItem> planItems = <WorkspacePlanItem>[];
  String taskSummary = '任务尚未开始';
  String taskState = 'idle';
  Completer<void>? abort;
  Timer? timeout;
  bool timedOut = false;
  final Map<String, WorkspaceLiveFileEdit> liveFileEdits =
      <String, WorkspaceLiveFileEdit>{};
  DateTime updatedAt = DateTime.fromMillisecondsSinceEpoch(0);
}

class _PendingToolVoice {
  const _PendingToolVoice({
    required this.callId,
    required this.text,
    required this.profile,
    required this.generated,
  });

  final String callId;
  final String text;
  final VoiceProfile profile;
  final GeneratedVoice generated;
}

class AppController extends ChangeNotifier {
  AppController._({
    required this.paths,
    required this.database,
    required this.settingsService,
    required this.content,
    required this.backups,
    required this.legacy,
    required this.api,
    required this.platform,
    required this.attachments,
    required this.tools,
    required this.brand,
    required this.voice,
    required this.diagnostics,
    this.portableData,
  });

  final AppPaths paths;
  final AppDatabase database;
  final SettingsService settingsService;
  final ContentRepository content;
  final BackupService backups;
  final LegacyImportService legacy;
  final ApiClient api;
  final PlatformService platform;
  final AttachmentService attachments;
  final ToolService tools;
  final BrandService brand;
  final VoiceService voice;
  final DiagnosticsService diagnostics;
  final PortableDataService? portableData;

  Map<String, Object?> settings = <String, Object?>{};
  List<ApiProfile> profiles = <ApiProfile>[];
  List<Conversation> conversations = <Conversation>[];
  List<Conversation> archivedConversations = <Conversation>[];
  List<ChatMessage> messages = <ChatMessage>[];
  Map<String, List<MessagePart>> messagePartsByMessage =
      <String, List<MessagePart>>{};
  List<MemoryEntry> memories = <MemoryEntry>[];
  List<DiaryEntry> diaries = <DiaryEntry>[];
  List<DiaryVersion> visualAuditDiaryVersions = <DiaryVersion>[];
  Map<String, String> visualAuditFileContents = <String, String>{};
  List<UserFileRecord> files = <UserFileRecord>[];
  List<WorkspaceRecord> workspaces = <WorkspaceRecord>[];
  List<WorkspaceRecord> archivedWorkspaces = <WorkspaceRecord>[];
  List<WorkspaceFileRecord> workspaceFiles = <WorkspaceFileRecord>[];
  Map<String, int> workspaceFileCounts = <String, int>{};
  Map<String, String> workspaceFileContents = <String, String>{};
  List<WorkspaceMessageRecord> workspaceMessages = <WorkspaceMessageRecord>[];
  List<WorkspaceConversationRecord> workspaceConversations =
      <WorkspaceConversationRecord>[];
  WorkspaceConversationRecord? activeWorkspaceConversation;
  Map<String, List<MessagePart>> workspaceMessagePartsByMessage =
      <String, List<MessagePart>>{};
  List<WorkspaceCommitRecord> workspaceCommits = <WorkspaceCommitRecord>[];
  final Map<String, _WorkspaceRunState> _workspaceRuns =
      <String, _WorkspaceRunState>{};
  final Map<String, String> _selectedWorkspaceConversationIds =
      <String, String>{};
  List<VoiceProfile> voiceProfiles = <VoiceProfile>[];
  List<VoiceAsset> voiceAssets = <VoiceAsset>[];
  final Set<String> voiceBusyMessageIds = <String>{};
  final Map<String, String> voiceGenerationStatus = <String, String>{};
  final Map<String, Completer<void>> _voiceGenerationAborts =
      <String, Completer<void>>{};
  final List<_PendingToolVoice> _pendingToolVoices = <_PendingToolVoice>[];
  String? playingVoiceId;
  int audioPlaybackPositionMs = 0;
  int audioPlaybackDurationMs = 0;
  Timer? _audioPlaybackTimer;
  WorkspaceRecord? activeWorkspace;
  final ValueNotifier<int> workspaceActivity = ValueNotifier<int>(0);
  final ValueNotifier<int> chatActivity = ValueNotifier<int>(0);
  static const Duration _workspaceIdleLimit = Duration(minutes: 10);
  static const Set<String> _fileToolNames = <String>{
    'search_files',
    'read_file',
    'create_file',
    'edit_file',
    'delete_file',
    'list_workspace_files',
    'read_workspace_file',
    'list_workspace_file_versions',
    'read_workspace_file_version',
    'restore_workspace_file_version',
    'create_workspace_file',
    'edit_workspace_file',
  };

  static const _workspaceToolDefinitions = <ToolDefinition>[
    ToolDefinition(
      name: 'update_workspace_plan',
      description:
          '建立或更新本轮工作计划。计划只描述接下来要完成的目标步骤，不要写“正在分析/正在组织回复”等执行过程。任务开始时先提交完整计划，步骤开始和完成时更新 state。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['items'],
        'properties': <String, Object?>{
          'items': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'required': <String>['id', 'title', 'state'],
              'properties': <String, Object?>{
                'id': <String, String>{'type': 'string'},
                'title': <String, String>{'type': 'string'},
                'state': <String, Object?>{
                  'type': 'string',
                  'enum': <String>['pending', 'running', 'completed', 'failed'],
                },
              },
              'additionalProperties': false,
            },
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'list_workspace_files',
      description: '列出当前工作区中的文件名、类型和大小。',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'read_workspace_file',
      description: '读取当前工作区中一个文件的完整内容。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['name'],
        'properties': <String, Object?>{
          'name': <String, String>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'list_workspace_file_versions',
      description: '列出一个工作区文件的不可删除历史版本，返回可供读取或恢复的 versionId。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['name'],
        'properties': <String, Object?>{
          'name': <String, String>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'read_workspace_file_version',
      description: '按 versionId 校验并读取工作区文件的一个历史版本，不会修改当前文件。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['versionId'],
        'properties': <String, Object?>{
          'versionId': <String, String>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'restore_workspace_file_version',
      description: '按 versionId 恢复单个工作区文件；恢复前后都会保存不可删除检查点。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['versionId'],
        'properties': <String, Object?>{
          'versionId': <String, String>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'create_workspace_file',
      description:
          '在当前工作区创建一个新文件。成功时会返回经过落盘校验的文件 UUID、哈希和后续编辑参数；仅可依据 verified=true 判定创建成功。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['name', 'content'],
        'properties': <String, Object?>{
          'name': <String, String>{'type': 'string'},
          'content': <String, String>{'type': 'string'},
          'type': <String, String>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'edit_workspace_file',
      description: '编辑当前工作区中已存在的文件。必须使用精确文件名；成功时会返回经过落盘校验的文件 UUID、哈希和后续编辑参数。',
      parameters: <String, Object?>{
        'type': 'object',
        'required': <String>['name', 'content'],
        'properties': <String, Object?>{
          'name': <String, String>{'type': 'string'},
          'content': <String, String>{'type': 'string'},
          'type': <String, String>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
  ];
  Conversation? activeConversation;
  Conversation? _conversationBeforePrivate;
  List<ChatMessage> _messagesBeforePrivate = const <ChatMessage>[];
  Map<String, List<MessagePart>> _messagePartsBeforePrivate =
      const <String, List<MessagePart>>{};
  AppSection section = AppSection.chat;
  bool busy = false;
  static const Duration _generationIdleLimit = Duration(minutes: 10);
  Completer<void>? _generationAbort;
  Timer? _generationTimeout;
  bool _generationTimedOut = false;
  ChatMessage? editingUserMessage;
  bool editingUserMessageResend = false;
  int editRequestSerial = 0;
  bool privateMode = false;
  String streamingText = '';
  String streamingReasoning = '';
  List<ChatCompletionPart> streamingParts = <ChatCompletionPart>[];
  ChatCompletionPart? streamingToolProgress;
  String? notice;
  List<AppNotice> notifications = <AppNotice>[];
  bool notificationsOpen = false;
  AppNoticeNavigation? pendingNoticeNavigation;
  AppNoticeNavigation? activeNoticeNavigation;
  ChatViewportRequest? pendingChatViewportRequest;
  bool approvalDialogRequested = false;
  List<PendingAttachment> pendingAttachments = <PendingAttachment>[];
  ToolRequest? pendingToolApproval;
  final Map<String, ToolRequest> _pendingToolApprovals =
      <String, ToolRequest>{};
  final List<_ResolvedToolApproval> _resolvedToolApprovals =
      <_ResolvedToolApproval>[];
  List<String> _expandedNotificationIds = <String>[];
  int _noticeNavigationSerial = 0;
  int _chatViewportSerial = 0;
  int _noticeIdSerial = 0;
  final Map<String, double> _chatViewportOffsets = <String, double>{};
  final Map<String, bool> _chatViewportScrollable = <String, bool>{};
  final Set<String> _backgroundGenerationScopes = <String>{};

  Future<void> _beginBackgroundGeneration({
    required String scope,
    required String title,
    required bool workspace,
  }) async {
    final wasEmpty = _backgroundGenerationScopes.isEmpty;
    _backgroundGenerationScopes.add(scope);
    if (wasEmpty) {
      await platform.beginGenerationActivity(
        title: title,
        scopeId: scope,
        workspace: workspace,
      );
    } else {
      platform.updateGenerationActivity(
        status: '有 ${_backgroundGenerationScopes.length} 个任务正在运行',
      );
    }
  }

  Future<void> _endBackgroundGeneration({
    required String scope,
    required String status,
    required String preview,
    required bool success,
  }) async {
    _backgroundGenerationScopes.remove(scope);
    if (_backgroundGenerationScopes.isEmpty) {
      await platform.endGenerationActivity(
        status: status,
        preview: preview,
        success: success,
      );
    } else {
      platform.updateGenerationActivity(
        status: '还有 ${_backgroundGenerationScopes.length} 个任务正在运行',
        preview: preview,
      );
    }
  }

  static Future<AppController> bootstrap() async {
    final paths = await AppPaths.create();
    final database = await AppDatabase.open(paths);
    final vault = SecureVault();
    final settingsService = SettingsService(database, vault);
    final diagnostics = DiagnosticsService(paths.diagnostics);
    final brand = BrandService(paths, settingsService);
    await brand.loadSavedFont();
    final platform = PlatformService();
    await platform.initialize();
    final controller = AppController._(
      paths: paths,
      database: database,
      settingsService: settingsService,
      content: ContentRepository(database),
      backups: BackupService(database, vault),
      legacy: LegacyImportService(database, settingsService, brand),
      api: ApiClient(vault),
      platform: platform,
      attachments: AttachmentService(database),
      tools: ToolService(
        database,
        ContentRepository(database),
        settingsService,
        platform,
      ),
      brand: brand,
      voice: VoiceService(database, vault),
      diagnostics: diagnostics,
      portableData: PortableDataService(database),
    );
    platform.onNotificationPayload = controller._handleNotificationPayload;
    platform.onAudioPlaybackComplete = controller._audioPlaybackComplete;
    try {
      await controller.content.repairVersionHistories();
    } on Object catch (error) {
      // History repair is best effort and must never make the app unbootable.
      controller.notice = '部分历史版本暂时无法修复：$error';
    }
    await controller.reload();
    await controller.tools.cleanStaleTrivialMemories();
    await controller.legacy.repairLegacyToolParts();
    await controller.reload();
    final initialPayload = platform.initialNotificationPayload;
    if (initialPayload != null && initialPayload.isNotEmpty) {
      controller._handleNotificationPayload(initialPayload);
    }
    return controller;
  }

  /// Builds the real application controller with deterministic, inert state
  /// for browser screenshot and geometry comparison against the legacy web UI.
  /// The production bootstrap path remains unchanged.
  static AppController visualAudit({
    AppSection initialSection = AppSection.chat,
    String scenario = 'empty',
  }) {
    final paths = AppPaths.visualAudit();
    final database = AppDatabase.visualAudit(paths, 'visual-audit-device');
    final vault = SecureVault();
    final settingsService = SettingsService(database, vault);
    final diagnostics = DiagnosticsService(paths.diagnostics);
    final brand = BrandService(paths, settingsService);
    final platform = PlatformService();
    final content = ContentRepository(database);
    final controller = AppController._(
      paths: paths,
      database: database,
      settingsService: settingsService,
      content: content,
      backups: BackupService(database, vault),
      legacy: LegacyImportService(database, settingsService, brand),
      api: ApiClient(vault),
      platform: platform,
      attachments: AttachmentService(database),
      tools: ToolService(database, content, settingsService, platform),
      brand: brand,
      voice: VoiceService(database, vault),
      diagnostics: diagnostics,
    );
    controller
      ..settings = <String, Object?>{
        ...SettingsService.defaults,
        'appName': 'ClaudeChat',
        'profileName': '用户',
        'profileNote': '本地账号',
        'greeting': '晚上好',
        'themeMode': 'system',
        'fontFamily': 'claude',
        'fontSize': 'compact',
        'fontScale': 1.0,
        'splashRandom': true,
        'splashPhrases': '欢迎回来\n很高兴见到你\n我在这里\n今天想聊些什么？',
        'modelSlots': <Object?>[
          <String, Object?>{
            'id': 'sonnet',
            'label': 'Sonnet',
            'description': '日常聊天和创作',
            'apiName': '',
            'stream': true,
            'temperature': null,
            'topP': null,
            'frequencyPenalty': null,
            'presencePenalty': null,
            'maxTokens': null,
            'contextTokens': null,
          },
          <String, Object?>{
            'id': 'opus',
            'label': 'Opus',
            'description': '复杂任务和长对话',
            'apiName': '',
            'stream': true,
            'temperature': null,
            'topP': null,
            'frequencyPenalty': null,
            'presencePenalty': null,
            'maxTokens': null,
            'contextTokens': null,
          },
          <String, Object?>{
            'id': 'haiku',
            'label': 'Haiku',
            'description': '快速轻量回复',
            'apiName': '',
            'stream': true,
            'temperature': null,
            'topP': null,
            'frequencyPenalty': null,
            'presencePenalty': null,
            'maxTokens': null,
            'contextTokens': null,
          },
        ],
        'activeModelSlotId': 'sonnet',
        'activeModelId': '',
        'webSearchEnabled': false,
        'diaryViewMode': 'grid',
      }
      ..section = initialSection;
    if (scenario == 'chat-rich' || scenario == 'chat-markdown') {
      final markdown = scenario == 'chat-markdown';
      controller.settings['webSearchEnabled'] = true;
      final timestamp = DateTime.utc(2026, 8, 17, 12);
      const conversationId = 'visual-audit-conversation';
      const markdownPrompt =
          '# 标题\n'
          '正文包含 **粗体**、*斜体* 和 `inline_code`。\n\n'
          '- 第一项\n'
          '- 第二项\n\n'
          '```dart\n'
          '1\n2\n3\n4\n5\n6\n7\n'
          '```';
      final userContent = markdown ? markdownPrompt : '莫西莫西';
      final assistantContent = markdown
          ? '我现在跑在你的本地网页里。你刚刚说的是：“$markdownPrompt”。\n\n'
                '等你在设置里填好 OpenAI-compatible endpoint、API Key 和模型名后，我就会把这个界面切到真实流式回复。私密对话不会写进历史，普通对话会保存在这个浏览器本机。'
          : '我现在跑在你的本地网页里。你刚刚说的是：“莫西莫西”。\n\n'
                '等你在设置里填好 OpenAI-compatible endpoint、API Key 和模型名后，我就会把这个界面切到真实流式回复。私密对话不会写进历史，普通对话会保存在这个浏览器本机。';
      final conversation = Conversation(
        id: conversationId,
        title: markdown ? '# 标题 正文包含 **粗体**、*...' : '莫西莫西',
        modelId: 'sonnet',
        createdAt: timestamp,
        updatedAt: timestamp,
        originDeviceId: 'visual-audit-device',
      );
      final userMessage = ChatMessage(
        id: 'visual-audit-user',
        conversationId: conversationId,
        sequence: 1,
        role: 'user',
        content: userContent,
        metadataJson: jsonEncode(<String, Object?>{
          'estimatedTokens': markdown ? 26 : 3,
        }),
        createdAt: timestamp,
        originDeviceId: 'visual-audit-device',
      );
      final assistantMessage = ChatMessage(
        id: 'visual-audit-assistant',
        conversationId: conversationId,
        sequence: 2,
        role: 'assistant',
        content: assistantContent,
        metadataJson: jsonEncode(<String, Object?>{
          'estimatedTokens': markdown ? 107 : 83,
          'contextInputTokens': 2500,
        }),
        createdAt: timestamp.add(const Duration(seconds: 1)),
        originDeviceId: 'visual-audit-device',
      );
      controller
        ..conversations = <Conversation>[conversation]
        ..activeConversation = conversation
        ..messages = <ChatMessage>[userMessage, assistantMessage]
        ..messagePartsByMessage = <String, List<MessagePart>>{
          assistantMessage.id: <MessagePart>[
            MessagePart(
              id: 'visual-audit-sent',
              messageId: assistantMessage.id,
              sequence: 1,
              type: 'status',
              content: 'sent',
              metadataJson: jsonEncode(<String, Object?>{'status': 'sent'}),
              createdAt: timestamp,
            ),
            MessagePart(
              id: 'visual-audit-replying',
              messageId: assistantMessage.id,
              sequence: 2,
              type: 'status',
              content: 'replying',
              metadataJson: jsonEncode(<String, Object?>{'status': 'replying'}),
              createdAt: timestamp,
            ),
            MessagePart(
              id: 'visual-audit-thought-1',
              messageId: assistantMessage.id,
              sequence: 3,
              type: 'thought',
              content: '整理用户刚刚说的重点，确认要回复的方向。',
              createdAt: timestamp,
            ),
            MessagePart(
              id: 'visual-audit-thought-2',
              messageId: assistantMessage.id,
              sequence: 4,
              type: 'thought',
              content: '把回复拆成更容易阅读的几段，再开始输出。',
              createdAt: timestamp,
            ),
            MessagePart(
              id: 'visual-audit-content',
              messageId: assistantMessage.id,
              sequence: 5,
              type: 'content',
              content: assistantContent,
              createdAt: timestamp,
            ),
            MessagePart(
              id: 'visual-audit-success',
              messageId: assistantMessage.id,
              sequence: 6,
              type: 'status',
              content: 'success',
              metadataJson: jsonEncode(<String, Object?>{
                'status': 'success',
                'detail':
                    '消息返回成功，输出：~${markdown ? 107 : 83}(估算)，响应：0.5秒。\n'
                    '返回原文：usage 未返回 usage，已使用本地估算。',
              }),
              createdAt: timestamp,
            ),
          ],
        };
    }
    if (scenario == 'chat-notifications') {
      final timestamp = DateTime.utc(2026, 8, 17, 12, 1);
      controller.notifications = <AppNotice>[
        AppNotice(
          id: 'visual-audit-approval',
          type: AppNoticeType.danger,
          text: '小机子请求删除文件“旧草稿.md”',
          createdAt: timestamp.subtract(const Duration(seconds: 2)),
          approval: const ToolRequest(
            callId: 'visual-audit-approval',
            name: 'delete_file',
            arguments: <String, Object?>{
              'id': 'visual-audit-old-draft',
              'name': '旧草稿.md',
            },
          ),
        ),
        AppNotice(
          id: 'visual-audit-diary',
          type: AppNoticeType.notice,
          text: '小机子写了一篇日记“八月十七日”',
          createdAt: timestamp.subtract(const Duration(seconds: 1)),
          target: AppSection.diary,
          entryId: 'visual-audit-diary',
        ),
        AppNotice(
          id: 'visual-audit-file',
          type: AppNoticeType.info,
          text: '小机子创建了文件“旅行清单.md”',
          createdAt: timestamp,
          target: AppSection.files,
          entryId: 'visual-audit-file',
        ),
      ];
    }
    if (scenario == 'content-rich') {
      final timestamp = DateTime.utc(2026, 8, 17, 13, 30);
      controller.memories = <MemoryEntry>[
        MemoryEntry(
          id: 'visual-audit-memory',
          content: '用户喜欢在晚上安静地写日记。',
          level: 'important',
          tags: const <String>['偏好', '夜晚'],
          source: 'user',
          useFrequency: 0,
          createdAt: timestamp,
          updatedAt: timestamp,
          originDeviceId: 'visual-audit-device',
        ),
      ];
      controller
        ..diaries = <DiaryEntry>[
          DiaryEntry(
            id: 'audit-diary-20260817',
            title: '安静的夜晚',
            status: 'active',
            mood: '平静',
            tags: const <String>['夜晚', '日记'],
            latestVersionId: 'audit-diary-version-2',
            createdAt: timestamp.subtract(const Duration(days: 1)),
            updatedAt: timestamp,
            originDeviceId: 'visual-audit-device',
          ),
        ]
        ..visualAuditDiaryVersions = <DiaryVersion>[
          DiaryVersion(
            id: 'audit-diary-version-1',
            diaryId: 'audit-diary-20260817',
            title: '安静的夜晚',
            content: '夜深了，窗外很安静。今天把想做的事情一件件写下来，心也慢慢安定了。',
            operation: 'create',
            reason: '创建日记',
            mood: '平静',
            tags: const <String>['夜晚', '日记'],
            createdAt: timestamp.subtract(const Duration(days: 1)),
            originDeviceId: 'visual-audit-device',
          ),
          DiaryVersion(
            id: 'audit-diary-version-2',
            diaryId: 'audit-diary-20260817',
            title: '安静的夜晚',
            content: '夜深了，窗外很安静。今天把想做的事情一件件写下来，心也慢慢安定了。明天继续按照自己的节奏前进。',
            operation: 'revise',
            reason: '补充明天的计划',
            mood: '平静',
            tags: const <String>['夜晚', '日记'],
            createdAt: timestamp,
            originDeviceId: 'visual-audit-device',
          ),
        ]
        ..files = <UserFileRecord>[
          UserFileRecord(
            id: 'audit-file-active',
            name: '旅行清单.md',
            type: 'md',
            updatedAt: timestamp,
          ),
          UserFileRecord(
            id: 'audit-file-deleted',
            name: '旧草稿.txt',
            type: 'txt',
            status: 'deleted',
            updatedAt: timestamp.subtract(const Duration(hours: 1)),
            deletedAt: timestamp.subtract(const Duration(hours: 1)),
            deleteReason: '内容已过期',
          ),
        ]
        ..visualAuditFileContents = <String, String>{
          'audit-file-active': '行前准备\n- 身份证\n- 充电器\n- 雨伞',
          'audit-file-deleted': '这是一份需要保留历史的旧草稿。',
        }
        ..workspaces = <WorkspaceRecord>[
          WorkspaceRecord(
            id: 'audit-workspace-20260817',
            name: '旅行手册',
            updatedAt: timestamp,
          ),
        ]
        ..workspaceFileCounts = <String, int>{'audit-workspace-20260817': 2};
    }
    if (scenario == 'voices-rich') {
      final timestamp = DateTime.utc(2026, 8, 19, 12);
      controller
        ..voiceProfiles = <VoiceProfile>[
          const VoiceProfile(
            id: 'audit-voice-profile',
            provider: VoiceProvider.elevenLabs,
            name: 'ElevenLabs',
            endpoint: 'https://api.elevenlabs.io/v1/text-to-speech/{voice_id}',
            model: 'eleven_multilingual_v2',
            voiceId: 'audit-voice',
            outputFormat: 'mp3_44100_128',
            options: <String, Object?>{},
            customHeaders: <String, String>{},
            active: true,
          ),
        ]
        ..voiceAssets = <VoiceAsset>[
          VoiceAsset(
            id: 'audit-voice-asset',
            libraryNumber: 12,
            messageId: 'audit-message',
            conversationId: 'audit-conversation',
            profileId: 'audit-voice-profile',
            provider: 'elevenlabs',
            model: 'eleven_multilingual_v2',
            voiceId: 'audit-voice',
            relativePath: 'audit-conversation/audit-message/audit.mp3',
            mediaType: 'audio/mpeg',
            byteSize: 128,
            sha256: 'audit',
            favorite: true,
            bound: true,
            createdAt: timestamp,
            updatedAt: timestamp,
            sourceText: '今晚想听你把这段话温柔地读给我听。',
            messageRole: 'assistant',
            conversationRoleName: 'Sonnet',
          ),
        ];
    }
    return controller;
  }

  Map<String, Object?>? get activeModelConfig {
    final selected = settings['activeModelId'] as String?;
    final configs = settings['modelConfigs'];
    if (selected == null || configs is! Map || configs[selected] is! Map) {
      return null;
    }
    return (configs[selected] as Map).cast<String, Object?>();
  }

  ApiProfile? get activeProfile {
    final selected = settings['activeModelId'] as String?;
    final configuredProfileId =
        activeModelSlot?['apiProfileId'] as String? ??
        activeModelConfig?['apiProfileId'] as String?;
    return profiles
            .where((value) => value.id == configuredProfileId)
            .firstOrNull ??
        profiles
            .where(
              (value) => selected != null && value.models.contains(selected),
            )
            .firstOrNull ??
        profiles.where((value) => value.active).firstOrNull ??
        profiles.firstOrNull;
  }

  VoiceProfile? get activeVoiceProfile =>
      voiceProfiles.where((value) => value.active).firstOrNull ??
      voiceProfiles.firstOrNull;

  VoiceAsset? voiceForMessage(String messageId) => voiceAssets
      .where((value) => value.messageId == messageId && value.bound)
      .firstOrNull;

  String voiceProfileName(VoiceAsset asset) =>
      voiceProfiles
          .where((profile) => profile.id == asset.profileId)
          .map((profile) => profile.name.trim())
          .where((name) => name.isNotEmpty)
          .firstOrNull ??
      VoiceProviderInfo.fromKey(asset.provider).label;

  List<VoiceAsset> voicesForMessage(String messageId) => voiceAssets
      .where((value) => value.messageId == messageId)
      .toList(growable: false);

  String get activeModel =>
      (activeModelSlot?['apiName'] as String?) ??
      (settings['activeModelId'] as String?) ??
      activeProfile?.models.firstOrNull ??
      '';

  bool get localDemoMode {
    final profile = activeProfile;
    return profile == null ||
        profile.endpoint.trim().isEmpty ||
        activeModel.trim().isEmpty;
  }

  List<Map<String, Object?>> get modelSlots {
    final raw = settings['modelSlots'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return raw
        .whereType<Map>()
        .map((value) => value.cast<String, Object?>())
        .toList();
  }

  Map<String, Object?>? get activeModelSlot {
    final id = settings['activeModelSlotId'];
    if (id == null) return null;
    return modelSlots.where((slot) => slot['id'] == id).firstOrNull;
  }

  _WorkspaceRunState _workspaceRun(String workspaceId) => _workspaceRuns
      .putIfAbsent(workspaceId, () => _WorkspaceRunState(workspaceId));

  _WorkspaceRunState? get _activeWorkspaceRun {
    final id = activeWorkspace?.id;
    return id == null ? null : _workspaceRun(id);
  }

  _WorkspaceRunState? get _activeWorkspaceConversationRun {
    final run = _activeWorkspaceRun;
    final conversationId = activeWorkspaceConversation?.id;
    if (run == null || conversationId == null) return null;
    return run.conversationId == conversationId ? run : null;
  }

  _WorkspaceRunState? get _featuredWorkspaceRun {
    final active = _activeWorkspaceRun;
    if (active != null && (active.busy || active.taskSteps.isNotEmpty)) {
      return active;
    }
    final candidates =
        _workspaceRuns.values
            .where((run) => run.busy || run.taskSteps.isNotEmpty)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return candidates.firstOrNull;
  }

  _WorkspaceRunState? get _displayWorkspaceRun =>
      _activeWorkspaceRun ?? _featuredWorkspaceRun;

  bool get workspaceBusy => _displayWorkspaceRun?.busy ?? false;
  set workspaceBusy(bool value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.busy = value;
  }

  bool get anyWorkspaceBusy => _workspaceRuns.values.any((run) => run.busy);
  bool get workspaceConversationBusy =>
      _activeWorkspaceConversationRun?.busy == true;
  int get runningWorkspaceCount =>
      _workspaceRuns.values.where((run) => run.busy).length;

  bool isWorkspaceRunning(String workspaceId) =>
      _workspaceRuns[workspaceId]?.busy == true;

  List<WorkspaceTaskQueueEntry> get workspaceTaskQueue {
    final values = <WorkspaceTaskQueueEntry>[];
    for (final workspace in workspaces) {
      final run = _workspaceRuns[workspace.id];
      final persistent = workspace.settings['taskPersistent'] == true;
      final style = '${workspace.settings['taskDisplayStyle'] ?? 'top'}';
      if (style != 'ball' || (!persistent && run?.busy != true)) continue;
      values.add(
        WorkspaceTaskQueueEntry(
          workspace: workspace,
          busy: run?.busy == true,
          hasTask: run?.taskSteps.isNotEmpty == true,
          summary: _visibleWorkspaceTaskSummaryFor(run),
          updatedAt: run?.updatedAt ?? workspace.updatedAt,
        ),
      );
    }
    values.sort((left, right) {
      if (left.busy != right.busy) return left.busy ? -1 : 1;
      return right.updatedAt.compareTo(left.updatedAt);
    });
    return values;
  }

  List<WorkspaceTaskStep> workspaceTaskStepsFor(String workspaceId) =>
      _workspaceRuns[workspaceId]?.taskSteps ?? const <WorkspaceTaskStep>[];

  bool workspaceBusyFor(String workspaceId) =>
      _workspaceRuns[workspaceId]?.busy == true;

  String workspaceTaskSummaryFor(String workspaceId) =>
      _visibleWorkspaceTaskSummaryFor(_workspaceRuns[workspaceId]);

  List<WorkspaceLiveFileEdit> workspaceLiveFileEditsFor(String workspaceId) {
    final values =
        _workspaceRuns[workspaceId]?.liveFileEdits.values.toList() ??
        <WorkspaceLiveFileEdit>[];
    values.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return values;
  }

  String get workspaceStreamingText =>
      _activeWorkspaceConversationRun?.streamingText ?? '';
  set workspaceStreamingText(String value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.streamingText = value;
  }

  String get workspaceStreamingReasoning =>
      _activeWorkspaceConversationRun?.streamingReasoning ?? '';
  set workspaceStreamingReasoning(String value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.streamingReasoning = value;
  }

  List<ChatCompletionPart> get workspaceStreamingParts =>
      _activeWorkspaceConversationRun?.streamingParts ??
      const <ChatCompletionPart>[];
  set workspaceStreamingParts(List<ChatCompletionPart> value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.streamingParts = value;
  }

  ChatCompletionPart? get workspaceStreamingToolProgress =>
      _activeWorkspaceConversationRun?.streamingToolProgress;
  set workspaceStreamingToolProgress(ChatCompletionPart? value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.streamingToolProgress = value;
  }

  List<WorkspaceTaskStep> get workspaceTaskSteps =>
      _displayWorkspaceRun?.taskSteps ?? const <WorkspaceTaskStep>[];
  set workspaceTaskSteps(List<WorkspaceTaskStep> value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.taskSteps = value;
  }

  List<WorkspacePlanItem> get workspacePlanItems =>
      _displayWorkspaceRun?.planItems ?? const <WorkspacePlanItem>[];
  set workspacePlanItems(List<WorkspacePlanItem> value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.planItems = value;
  }

  String get workspaceTaskSummary =>
      _displayWorkspaceRun?.taskSummary ?? '任务尚未开始';
  set workspaceTaskSummary(String value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.taskSummary = value;
  }

  String get workspaceTaskState => _displayWorkspaceRun?.taskState ?? 'idle';
  set workspaceTaskState(String value) {
    final run = _activeWorkspaceRun;
    if (run != null) run.taskState = value;
  }

  void _notifyWorkspaceActivity(_WorkspaceRunState run) {
    run.updatedAt = DateTime.now();
    workspaceActivity.value++;
  }

  void _notifyChatActivity() => chatActivity.value++;

  Map<String, Object?>? get workspaceModelSlot {
    final id = activeWorkspace?.settings['modelSlotId'];
    if (id == null) return activeModelSlot;
    return modelSlots.where((slot) => slot['id'] == id).firstOrNull ??
        activeModelSlot;
  }

  ApiProfile? get workspaceProfile {
    final slot = workspaceModelSlot;
    final configuredProfileId = slot?['apiProfileId'] as String?;
    final apiName = slot?['apiName'] as String?;
    return profiles
            .where((value) => value.id == configuredProfileId)
            .firstOrNull ??
        profiles
            .where((value) => apiName != null && value.models.contains(apiName))
            .firstOrNull ??
        activeProfile;
  }

  String get workspaceModel =>
      (workspaceModelSlot?['apiName'] as String?) ?? activeModel;

  String get workspaceMode => '${activeWorkspace?.settings['mode'] ?? 'agent'}';

  WorkspaceProjectInspection get workspaceProjectInspection =>
      WorkspaceProjectService.inspect(<String, String>{
        for (final file in workspaceFiles)
          file.name: workspaceFileContents[file.id] ?? '',
      });

  String get effectiveWorkspaceProjectType {
    final configured = activeWorkspace?.projectType ?? 'auto';
    return configured == 'auto'
        ? workspaceProjectInspection.detectedType
        : configured;
  }

  int get workspaceMaxRounds {
    final raw = activeWorkspace?.settings['maxRounds'];
    return ((raw as num?)?.toInt() ?? 10).clamp(1, 20);
  }

  double get workspaceFontScale {
    final raw = activeWorkspace?.settings['fontScale'];
    return ((raw as num?)?.toDouble() ?? 1).clamp(.85, 1.25);
  }

  bool get workspaceTaskPersistent =>
      activeWorkspace?.settings['taskPersistent'] == true;

  bool get allowMultipleWorkspaceRuns =>
      activeWorkspace?.settings['allowMultipleWorkspaceRuns'] != false;

  String get workspaceTaskDisplayStyle =>
      '${activeWorkspace?.settings['taskDisplayStyle'] ?? 'top'}' == 'ball'
      ? 'ball'
      : 'top';

  bool get workspaceTaskVisible =>
      activeWorkspace != null &&
      (_activeWorkspaceRun?.busy == true || workspaceTaskPersistent);

  String get visibleWorkspaceTaskSummary =>
      _visibleWorkspaceTaskSummaryFor(_displayWorkspaceRun);

  String _visibleWorkspaceTaskSummaryFor(_WorkspaceRunState? run) {
    if (run == null) return '任务尚未开始';
    if (run.taskSteps.isNotEmpty) return run.taskSummary;
    final progress = run.streamingToolProgress;
    if (progress != null) {
      final name = '${progress.metadata['name'] ?? ''}';
      final status = '${progress.metadata['status'] ?? 'running'}';
      final arguments = progress.metadata['arguments'];
      final fileName = arguments is Map
          ? '${arguments['name'] ?? arguments['fileName'] ?? ''}'.trim()
          : '';
      return switch (name) {
        'list_workspace_files' => '正在整理文件树',
        'read_workspace_file' => fileName.isEmpty ? '正在读取文件' : '正在读取 $fileName',
        'list_workspace_file_versions' => '正在整理文件版本',
        'read_workspace_file_version' => '正在读取文件版本',
        'restore_workspace_file_version' => '正在恢复文件版本',
        'create_workspace_file' =>
          status == 'preparing'
              ? (fileName.isEmpty ? '准备创建文件' : '准备创建 $fileName')
              : (fileName.isEmpty ? '正在写入新文件' : '正在写入 $fileName'),
        'edit_workspace_file' =>
          status == 'preparing'
              ? (fileName.isEmpty ? '准备编辑文件' : '准备编辑 $fileName')
              : (fileName.isEmpty ? '正在保存修改' : '正在保存 $fileName'),
        _ => '任务正在运行',
      };
    }
    if (run.streamingReasoning.isNotEmpty) return '正在分析任务';
    if (run.streamingText.isNotEmpty) return '正在组织回复';
    return run.taskSummary;
  }

  List<ToolDefinition> get workspaceTools {
    return _workspaceToolsForMode(workspaceMode);
  }

  List<ToolDefinition> _workspaceToolsForMode(String mode) {
    if (mode == 'chat') return const <ToolDefinition>[];
    if (mode == 'plan') {
      return _workspaceToolDefinitions
          .where(
            (tool) => const <String>{
              'update_workspace_plan',
              'list_workspace_files',
              'read_workspace_file',
              'list_workspace_file_versions',
              'read_workspace_file_version',
            }.contains(tool.name),
          )
          .toList();
    }
    return _workspaceToolDefinitions;
  }

  String get activeModelLabel =>
      '${activeModelSlot?['label'] ?? activeModel}'.trim();

  Future<void> selectModelSlot(String id) async {
    await settingsService.set('activeModelSlotId', id);
    settings['activeModelSlotId'] = id;
    final slot = modelSlots.where((value) => value['id'] == id).firstOrNull;
    if (slot != null) {
      await settingsService.set('activeModelId', slot['apiName']);
      settings['activeModelId'] = slot['apiName'];
    }
    notifyListeners();
  }

  Future<void> saveModelSlot(Map<String, Object?> value) async {
    final slots = <Map<String, Object?>>[];
    var replaced = false;
    for (final slot in modelSlots) {
      if (slot['id'] == value['id']) {
        slots.add(value);
        replaced = true;
      } else {
        slots.add(slot);
      }
    }
    if (!replaced) {
      if (slots.length >= 5) {
        throw StateError('最多只能配置 5 个模型');
      }
      slots.add(value);
    }
    await settingsService.set('modelSlots', slots);
    settings['modelSlots'] = slots;
    if (settings['activeModelSlotId'] == null) {
      await settingsService.set('activeModelSlotId', value['id']);
      settings['activeModelSlotId'] = value['id'];
    }
    notifyListeners();
  }

  Future<void> deleteModelSlot(String id) async {
    if (const <String>{'sonnet', 'opus', 'haiku'}.contains(id)) return;
    final slots = modelSlots.where((slot) => slot['id'] != id).toList();
    await settingsService.set('modelSlots', slots);
    settings['modelSlots'] = slots;
    if (settings['activeModelSlotId'] == id) {
      final next = slots.firstOrNull;
      await settingsService.set('activeModelSlotId', next?['id']);
      settings['activeModelSlotId'] = next?['id'];
      if (next != null) {
        await settingsService.set('activeModelId', next['apiName']);
        settings['activeModelId'] = next['apiName'];
      }
    }
    notifyListeners();
  }

  List<String> get availableModels {
    final output = <String>[];
    for (final profile in profiles) {
      for (final model in profile.models) {
        if (!output.contains(model)) output.add(model);
      }
    }
    final configs = settings['modelConfigs'];
    if (configs is Map) {
      for (final model in configs.keys.map((value) => '$value')) {
        if (!output.contains(model)) output.add(model);
      }
    }
    return output;
  }

  List<ToolDefinition> get enabledToolDefinitions => ToolService
      .orderedDefinitions
      .where(
        (item) =>
            ToolPreferences.isEnabled(settings, item.name) &&
            (!privateMode || item.name == 'get_time'),
      )
      .toList();

  bool toolEnabled(String name) => ToolPreferences.isEnabled(settings, name);

  List<MessagePart> partsForMessage(String messageId) =>
      messagePartsByMessage[messageId] ?? const <MessagePart>[];

  Future<void> setToolEnabled(String name, bool enabled) => saveSetting(
    'toolOverrides',
    ToolPreferences.withEnabled(settings['toolOverrides'], name, enabled),
  );

  Future<void> reload() async {
    settings = await settingsService.load();
    profiles = await settingsService.profiles();
    voiceProfiles = await voice.profiles();
    voiceAssets = await voice.assets();
    conversations = await database.conversations();
    archivedConversations = await database.archivedConversations();
    memories = await content.memories(includeDeleted: true);
    diaries = await content.diaries(includeDeleted: true);
    files = await content.files(includeDeleted: true);
    workspaces = await content.workspaces();
    archivedWorkspaces = await content.workspaces(archived: true);
    workspaceFileCounts = <String, int>{};
    for (final workspace in workspaces) {
      workspaceFileCounts[workspace.id] = (await content.workspaceFiles(
        workspace.id,
      )).length;
    }
    if (activeWorkspace != null) {
      activeWorkspace = workspaces
          .where((item) => item.id == activeWorkspace!.id)
          .firstOrNull;
      if (activeWorkspace != null) {
        workspaceFiles = await content.workspaceFiles(activeWorkspace!.id);
        workspaceFileContents = <String, String>{
          for (final file in workspaceFiles)
            file.id: await content.readWorkspaceFile(file),
        };
        await _loadWorkspaceConversations(activeWorkspace!.id);
        workspaceCommits = await content.workspaceCommits(activeWorkspace!.id);
      }
    }
    if (activeConversation != null) {
      activeConversation = conversations
          .where((item) => item.id == activeConversation!.id)
          .firstOrNull;
    }
    if (activeConversation != null) {
      messages = await database.messages(activeConversation!.id);
      await _loadMessageParts(activeConversation!.id);
    }
    await portableData?.rebuild();
    notifyListeners();
  }

  Future<void> _loadMessageParts(String conversationId) async {
    final parts = await database.messageParts(conversationId);
    messagePartsByMessage = <String, List<MessagePart>>{};
    for (final part in parts) {
      (messagePartsByMessage[part.messageId] ??= <MessagePart>[]).add(part);
    }
  }

  void open(AppSection value) {
    activeNoticeNavigation = null;
    pendingNoticeNavigation = null;
    if (value == AppSection.workspaces) {
      // Opening the studio from another surface must always show the workspace
      // chooser. Running workspaces remain alive in [_workspaceRuns], but no
      // single running workspace is allowed to hijack navigation.
      _clearActiveWorkspaceView();
    }
    section = value;
    if (value == AppSection.chat) {
      _requestChatBottom(activeConversation?.id);
    }
    notifyListeners();
  }

  bool get canReturnFromNotice =>
      activeNoticeNavigation?.canReturnToChat == true;

  void recordChatViewport(
    String conversationId,
    double offset, {
    required bool scrollable,
  }) {
    if (conversationId.isEmpty || !offset.isFinite) return;
    _chatViewportOffsets[conversationId] = offset < 0 ? 0 : offset;
    _chatViewportScrollable[conversationId] = scrollable;
  }

  ChatViewportRequest? takeChatViewportRequest(String conversationId) {
    final request = pendingChatViewportRequest;
    if (request == null || request.conversationId != conversationId)
      return null;
    pendingChatViewportRequest = null;
    return request;
  }

  void _requestChatBottom(String? conversationId) {
    if (conversationId == null || conversationId.isEmpty) return;
    pendingChatViewportRequest = ChatViewportRequest(
      serial: ++_chatViewportSerial,
      conversationId: conversationId,
      disposition: ChatViewportDisposition.bottom,
    );
  }

  void returnFromNoticeNavigation([int? serial]) {
    final navigation = activeNoticeNavigation;
    if (navigation == null || serial != null && navigation.serial != serial) {
      return;
    }
    final conversationId = navigation.returnConversationId;
    activeNoticeNavigation = null;
    if (conversationId == null || activeConversation?.id != conversationId) {
      return;
    }
    section = AppSection.chat;
    pendingChatViewportRequest = ChatViewportRequest(
      serial: ++_chatViewportSerial,
      conversationId: conversationId,
      disposition: ChatViewportDisposition.restore,
      offset:
          navigation.returnScrollOffset ??
          _chatViewportOffsets[conversationId] ??
          0,
      reserveLegacyScrollbar:
          navigation.returnScrollable ??
          _chatViewportScrollable[conversationId] ??
          false,
    );
    notifyListeners();
  }

  Future<VoiceAsset?> generateVoice(
    ChatMessage message, {
    VoiceProfile? profile,
    bool bind = true,
  }) async {
    if (privateMode || message.id.startsWith('private-')) {
      notice = '私密对话不会生成或缓存语音';
      notifyListeners();
      return null;
    }
    if (voiceBusyMessageIds.contains(message.id)) return null;
    final abort = Completer<void>();
    _voiceGenerationAborts[message.id] = abort;
    voiceBusyMessageIds.add(message.id);
    voiceGenerationStatus[message.id] = '准备生成语音…';
    notifyListeners();
    try {
      final asset = await voice.generate(
        messageId: message.id,
        conversationId: message.conversationId,
        text: message.content,
        profile: profile,
        bind: bind,
        abortTrigger: abort.future,
        onProgress: (status) {
          voiceGenerationStatus[message.id] = status;
          notifyListeners();
        },
      );
      voiceAssets = await voice.assets();
      notifyListeners();
      return asset;
    } on Object catch (error) {
      if (abort.isCompleted) {
        notice = '已停止生成语音';
      } else {
        notice = '$error';
      }
      notifyListeners();
      return null;
    } finally {
      if (identical(_voiceGenerationAborts[message.id], abort)) {
        _voiceGenerationAborts.remove(message.id);
      }
      voiceBusyMessageIds.remove(message.id);
      voiceGenerationStatus.remove(message.id);
      notifyListeners();
    }
  }

  void stopVoiceGeneration(String messageId) {
    final abort = _voiceGenerationAborts[messageId];
    if (abort == null || abort.isCompleted) return;
    voiceGenerationStatus[messageId] = '正在停止语音生成…';
    abort.complete();
    notifyListeners();
  }

  Future<void> playMessageVoice(ChatMessage message) async {
    var asset = voiceForMessage(message.id);
    asset ??= await generateVoice(message);
    if (asset != null) await playVoice(asset);
  }

  Future<void> playVoice(VoiceAsset asset) async {
    try {
      if (playingVoiceId == asset.id) {
        await platform.stopAudio();
        playingVoiceId = null;
        _stopAudioProgress();
      } else {
        if (playingVoiceId != null) await platform.stopAudio();
        await platform.playAudio(
          voice.absolutePath(asset),
          backgroundPlayback: settings['voiceBackgroundPlayback'] == true,
          title: asset.numberLabel,
          subtitle: voiceProfileName(asset),
          preview: asset.sourceText,
        );
        playingVoiceId = asset.id;
        _startAudioProgress();
      }
      notifyListeners();
    } on Object catch (error) {
      playingVoiceId = null;
      notice = '播放失败：$error';
      notifyListeners();
    }
  }

  void _audioPlaybackComplete() {
    if (playingVoiceId == null) return;
    playingVoiceId = null;
    _stopAudioProgress();
    notifyListeners();
  }

  void _startAudioProgress() {
    _audioPlaybackTimer?.cancel();
    audioPlaybackPositionMs = 0;
    audioPlaybackDurationMs = 0;
    _audioPlaybackTimer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) => unawaited(_refreshAudioProgress()),
    );
    unawaited(_refreshAudioProgress());
  }

  void _stopAudioProgress() {
    _audioPlaybackTimer?.cancel();
    _audioPlaybackTimer = null;
    audioPlaybackPositionMs = 0;
    audioPlaybackDurationMs = 0;
  }

  Future<void> _refreshAudioProgress() async {
    if (playingVoiceId == null) return;
    try {
      final state = await platform.audioPlaybackState();
      audioPlaybackPositionMs = state.positionMs;
      audioPlaybackDurationMs = state.durationMs;
      if (!state.playing &&
          state.durationMs > 0 &&
          state.positionMs >= state.durationMs) {
        playingVoiceId = null;
        _stopAudioProgress();
      }
      notifyListeners();
    } on Object {
      // Older native shells keep basic playback working without seek state.
    }
  }

  Future<void> seekVoice(VoiceAsset asset, double progress) async {
    final value = progress.clamp(0.0, 1.0);
    if (playingVoiceId != asset.id) {
      await playVoice(asset);
      if (playingVoiceId != asset.id) return;
    }
    final duration = audioPlaybackDurationMs > 0
        ? audioPlaybackDurationMs
        : (asset.durationMs ?? 0);
    if (duration <= 0) return;
    final position = (duration * value).round();
    await platform.seekAudio(position);
    audioPlaybackPositionMs = position;
    notifyListeners();
  }

  Future<void> bindVoice(VoiceAsset asset) async {
    await voice.bind(asset);
    voiceAssets = await voice.assets();
    notifyListeners();
  }

  Future<void> toggleVoiceFavorite(ChatMessage message) async {
    var asset = voiceForMessage(message.id);
    asset ??= await generateVoice(message);
    if (asset == null) return;
    await voice.setFavorite(asset, !asset.favorite);
    voiceAssets = await voice.assets();
    notifyListeners();
  }

  Future<void> refreshVoices() async {
    voiceProfiles = await voice.profiles();
    voiceAssets = await voice.assets();
    notifyListeners();
  }

  void setPrivateMode(bool value) {
    if (privateMode == value) return;
    privateMode = value;
    pendingAttachments = <PendingAttachment>[];
    if (value) {
      _conversationBeforePrivate = activeConversation;
      _messagesBeforePrivate = List<ChatMessage>.of(messages);
      _messagePartsBeforePrivate = <String, List<MessagePart>>{
        for (final entry in messagePartsByMessage.entries)
          entry.key: List<MessagePart>.of(entry.value),
      };
      final now = DateTime.now().toUtc();
      activeConversation = Conversation(
        id: 'private-${now.microsecondsSinceEpoch}',
        title: '私密对话',
        modelId: activeModel,
        createdAt: now,
        updatedAt: now,
        originDeviceId: database.deviceId,
      );
      messages = <ChatMessage>[];
      messagePartsByMessage = <String, List<MessagePart>>{};
      section = AppSection.chat;
      notifyListeners();
    } else {
      activeConversation = _conversationBeforePrivate;
      _conversationBeforePrivate = null;
      messages = _messagesBeforePrivate;
      messagePartsByMessage = _messagePartsBeforePrivate;
      _messagesBeforePrivate = const <ChatMessage>[];
      _messagePartsBeforePrivate = const <String, List<MessagePart>>{};
      notifyListeners();
    }
  }

  Future<void> newConversation() async {
    activeNoticeNavigation = null;
    pendingNoticeNavigation = null;
    if (privateMode) {
      final now = DateTime.now().toUtc();
      activeConversation = Conversation(
        id: 'private-${now.microsecondsSinceEpoch}',
        title: '私密对话',
        modelId: activeModel,
        createdAt: now,
        updatedAt: now,
        originDeviceId: database.deviceId,
      );
      messages = <ChatMessage>[];
      messagePartsByMessage = <String, List<MessagePart>>{};
      section = AppSection.chat;
      _requestChatBottom(activeConversation?.id);
      notifyListeners();
      return;
    }
    activeConversation = await database.createConversation(
      modelId: activeModel.isEmpty ? null : activeModel,
    );
    messages = <ChatMessage>[];
    messagePartsByMessage = <String, List<MessagePart>>{};
    conversations = await database.conversations();
    section = AppSection.chat;
    _requestChatBottom(activeConversation?.id);
    notifyListeners();
  }

  Future<void> selectConversation(Conversation value) async {
    activeNoticeNavigation = null;
    pendingNoticeNavigation = null;
    privateMode = false;
    activeConversation = value;
    messages = await database.messages(value.id);
    await _loadMessageParts(value.id);
    section = AppSection.chat;
    _requestChatBottom(value.id);
    notifyListeners();
  }

  Future<void> send(String text) async {
    if (busy || (text.trim().isEmpty && pendingAttachments.isEmpty)) return;
    busy = true;
    String? diagnosticRequestId;
    var generationActivityStarted = false;
    String? backgroundScope;
    var generationActivityStatus = '回复已中断';
    var generationActivityPreview = '';
    _generationAbort = Completer<void>();
    _generationTimedOut = false;
    notice = null;
    _pendingToolVoices.clear();
    try {
      final selectedAttachments = <PendingAttachment>[...pendingAttachments];
      pendingAttachments = <PendingAttachment>[];
      if (activeConversation == null) {
        if (privateMode) {
          final now = DateTime.now().toUtc();
          activeConversation = Conversation(
            id: 'private-${now.microsecondsSinceEpoch}',
            title: '私密对话',
            modelId: activeModel,
            createdAt: now,
            updatedAt: now,
            originDeviceId: database.deviceId,
          );
        } else {
          activeConversation = await database.createConversation(
            modelId: activeModel.isEmpty ? null : activeModel,
          );
        }
      }
      final userMessage = ChatMessage(
        id: 'private-${DateTime.now().microsecondsSinceEpoch}',
        conversationId: activeConversation!.id,
        sequence: messages.length + 1,
        role: 'user',
        content: text.trim(),
        createdAt: DateTime.now().toUtc(),
      );
      if (privateMode) {
        messages = <ChatMessage>[...messages, userMessage];
        messagePartsByMessage[userMessage.id] = <MessagePart>[];
      } else {
        final saved = await database.appendMessage(
          conversationId: activeConversation!.id,
          role: 'user',
          content: text.trim(),
          metadataJson: attachments.metadata(selectedAttachments),
          parts: <MessagePartInput>[
            const MessagePartInput(
              type: 'status',
              metadata: <String, Object?>{'status': 'sent'},
            ),
            MessagePartInput(type: 'content', content: text.trim()),
          ],
        );
        await attachments.linkToMessage(saved.id, selectedAttachments);
        if (messages.isEmpty ||
            (messages.length == 1 && messages.first.role == 'user')) {
          await database.renameConversation(
            activeConversation!.id,
            _titleFrom(text),
          );
          activeConversation = (await database.conversations())
              .where((item) => item.id == activeConversation!.id)
              .firstOrNull;
        }
        messages = await database.messages(activeConversation!.id);
        await _loadMessageParts(activeConversation!.id);
      }
      notifyListeners();
      final profile = activeProfile;
      streamingText = '';
      streamingReasoning = '';
      streamingToolProgress = null;
      streamingParts = <ChatCompletionPart>[];
      notifyListeners();
      backgroundScope = 'chat:${activeConversation!.id}';
      await _beginBackgroundGeneration(
        scope: backgroundScope,
        title: activeConversation?.title ?? 'ClaudeChat',
        workspace: false,
      );
      generationActivityStarted = true;
      final ChatCompletionResult result;
      if (localDemoMode) {
        result = await _localDemoReply(text.trim());
      } else {
        final requestContext = await _prepareConversationContext(profile!);
        diagnosticRequestId =
            'chat-${DateTime.now().toUtc().microsecondsSinceEpoch}';
        final diagnosticSink = _diagnosticSink(
          requestId: diagnosticRequestId,
          conversationId: activeConversation!.id,
        );
        diagnosticSink?.call(<String, Object?>{
          'event': 'context_prepared',
          'totalStoredMessages': messages.length,
          'sentStoredMessages': requestContext.messages.length,
          'summarizedMessages': requestContext.summarizedMessages,
          'hardDroppedMessages': requestContext.droppedMessages,
          'estimatedInputTokens': estimatedInputTokens,
          'historicalToolParts': requestContext.messages.fold<int>(
            0,
            (total, message) =>
                total +
                (messagePartsByMessage[message.id] ?? const <MessagePart>[])
                    .where((part) => part.type == 'tool')
                    .length,
          ),
        });
        _touchGenerationActivity();
        result = await api.chatWithTools(
          profile: profile,
          model: activeModel,
          messages: requestContext.messages,
          messagePartsByMessage: messagePartsByMessage,
          lastUserContent: <String, Object?>{
            'content': await attachments.apiContent(
              text.trim(),
              selectedAttachments,
            ),
          },
          systemPrompt: requestContext.systemPrompt,
          systemPromptWithoutTools: requestContext.systemPromptWithoutTools,
          temperature: _modelDouble('temperature', 0.7),
          topP: _modelDouble('topP', 1),
          frequencyPenalty: _modelDouble('frequencyPenalty', 0),
          presencePenalty: _modelDouble('presencePenalty', 0),
          maxTokens: _modelInt('maxTokens', 4096),
          stream: _modelBool('stream', settings['stream'] != false),
          thinkingEnabled: settings['thinking'] != false,
          reasoningEffort: 'max',
          // Ordinary chats start a fresh reasoning phase for each user turn.
          // This keeps legacy tool-heavy histories from requiring old local
          // reasoning to be resent. Workspace requests remain independent.
          clearHistoricalReasoning: true,
          abortTrigger: _generationAbort!.future,
          tools: settings['toolboxEnabled'] == false
              ? const <Map<String, Object?>>[]
              : enabledToolDefinitions.map((item) => item.toApi()).toList(),
          onText: (chunk) {
            _touchGenerationActivity();
            streamingText += chunk;
            generationActivityPreview = streamingText;
            platform.updateGenerationActivity(
              status: '小机子正在回复',
              preview: streamingText,
            );
            _notifyChatActivity();
          },
          // Reasoning is response data, not a request-side display option.
          // The legacy web client always captured it when the provider sent
          // it. Gating this callback behind the imported `thinking` setting
          // made ordinary chats silently discard their live reasoning while
          // workspace chats kept working.
          onReasoning: (chunk) {
            _touchGenerationActivity();
            streamingReasoning += chunk;
            platform.updateGenerationActivity(status: '小机子正在思考');
            _notifyChatActivity();
          },
          onToolEvent: (part) {
            _touchGenerationActivity();
            streamingParts = <ChatCompletionPart>[...streamingParts, part];
            if (part.type == 'tool') {
              platform.updateGenerationActivity(
                status: _toolActivityLabel(part, completed: true),
              );
            }
            _notifyChatActivity();
          },
          onToolProgress: (part) {
            _touchGenerationActivity();
            streamingToolProgress = part;
            if (part != null) {
              platform.updateGenerationActivity(
                status: _toolActivityLabel(part),
              );
            }
            _notifyChatActivity();
          },
          onActivity: _touchGenerationActivity,
          diagnosticContext: <String, Object?>{
            'requestId': diagnosticRequestId,
            'conversationId': activeConversation!.id,
          },
          onDiagnostic: diagnosticSink,
          executeTool: (callId, name, arguments) async {
            final request = ToolRequest(
              callId: callId,
              name: name,
              arguments: arguments,
            );
            if (privateMode && name != 'get_time') {
              return jsonEncode(<String, Object?>{
                'ok': false,
                'tool': name,
                'error': '私密对话只允许使用 get_time',
              });
            }
            return _executeChatTool(request);
          },
        );
      }
      streamingText = result.text;
      final completedParts = _completionParts(result);
      if (privateMode) {
        final privateMessage = ChatMessage(
          id: 'private-${DateTime.now().microsecondsSinceEpoch}',
          conversationId: activeConversation!.id,
          sequence: messages.length + 1,
          role: 'assistant',
          content: streamingText,
          metadataJson: jsonEncode(_completionMetadata(result)),
          createdAt: DateTime.now().toUtc(),
        );
        messages = <ChatMessage>[...messages, privateMessage];
        messagePartsByMessage[privateMessage.id] = _ephemeralParts(
          privateMessage.id,
          completedParts,
        );
      } else {
        final savedAssistant = await database.appendMessage(
          conversationId: activeConversation!.id,
          role: 'assistant',
          content: streamingText,
          metadataJson: jsonEncode(_completionMetadata(result)),
          parts: completedParts,
        );
        await _persistPendingToolVoices(savedAssistant);
        messages = await database.messages(activeConversation!.id);
        await _loadMessageParts(activeConversation!.id);
        conversations = await database.conversations();
      }
      await _notifyReplyIfBackground(result.text);
      generationActivityStatus = '回复已完成';
      generationActivityPreview = result.text;
      _diagnosticSink(
        requestId: diagnosticRequestId,
        conversationId: activeConversation?.id,
      )?.call(<String, Object?>{
        'event': 'chat_response_persisted',
        'assistantCharacters': result.text.length,
        'partCount': completedParts.length,
      });
    } on Object catch (error) {
      generationActivityStatus = _generationAbort?.isCompleted == true
          ? (_generationTimedOut ? '回复等待超时' : '回复已停止')
          : '回复出现错误';
      _diagnosticSink(
        requestId: diagnosticRequestId,
        conversationId: activeConversation?.id,
      )?.call(<String, Object?>{
        'event': 'chat_request_failed',
        'error': '$error',
        'partialTextCharacters': streamingText.length,
        'partialReasoningCharacters': streamingReasoning.length,
        'persistedToolPartCount': streamingParts
            .where((part) => part.type == 'tool')
            .length,
      });
      if (_generationAbort?.isCompleted == true) {
        final detail = _generationTimedOut
            ? '请求超时：API 在等待时间内没有返回完整消息。可能原因是模型服务繁忙、网络延迟高、请求体过大，或模型正在生成较长内容。'
            : '用户手动停止了消息生成。';
        notice = _generationTimedOut ? '请求超时' : '已停止生成';
        await _recordAssistantFailure(
          detail,
          statusType: 'return_failed',
          fallbackText: _generationTimedOut ? '请求超时' : '已停止',
        );
        return;
      }
      final message = '$error'
          .replaceFirst('FormatException: ', '')
          .replaceFirst('HttpException: ', '');
      notice = message;
      await _recordAssistantFailure(message);
    } finally {
      if (generationActivityStarted) {
        await _endBackgroundGeneration(
          scope: backgroundScope!,
          status: generationActivityStatus,
          preview: generationActivityPreview,
          success: generationActivityStatus == '回复已完成',
        );
      }
      streamingText = '';
      streamingReasoning = '';
      streamingParts = <ChatCompletionPart>[];
      streamingToolProgress = null;
      busy = false;
      _generationTimeout?.cancel();
      _generationTimeout = null;
      _generationAbort = null;
      _generationTimedOut = false;
      _pendingToolVoices.clear();
      notifyListeners();
    }
  }

  String _toolActivityLabel(ChatCompletionPart part, {bool completed = false}) {
    final name = '${part.metadata['name'] ?? 'tool'}';
    final status = '${part.metadata['status'] ?? ''}';
    final action = switch (name) {
      'create_file' => '创建文件',
      'edit_file' => '编辑文件',
      'delete_file' => '删除文件',
      'read_file' => '读取文件',
      'search_files' => '搜索文件',
      'create_memory' => '创建记忆',
      'update_memory' => '更新记忆',
      'search_memory' => '搜索记忆',
      'create_diary_entry' => '写日记',
      'revise_diary_entry' => '修订日记',
      'search_diary_entries' => '搜索日记',
      'web_search' => '搜索网络',
      'fetch_url' => '读取网页',
      'generate_voice' => '说话',
      'list_workspace_files' => '检查工作区文件',
      'read_workspace_file' => '读取工作区文件',
      'list_workspace_file_versions' => '检查工作区文件版本',
      'read_workspace_file_version' => '读取工作区文件版本',
      'restore_workspace_file_version' => '恢复工作区文件版本',
      'create_workspace_file' => '创建工作区文件',
      'edit_workspace_file' => '编辑工作区文件',
      _ => '执行工具',
    };
    if (completed) {
      return status == 'success' ? '小机子已完成$action' : '小机子$action失败';
    }
    return status == 'preparing' ? '小机子准备$action' : '小机子正在$action';
  }

  Future<ChatCompletionResult> _localDemoReply(String userText) async {
    final stopwatch = Stopwatch()..start();
    const thoughts = <String>['整理用户刚刚说的重点，确认要回复的方向。', '把回复拆成更容易阅读的几段，再开始输出。'];
    for (final thought in thoughts) {
      streamingParts = <ChatCompletionPart>[
        ...streamingParts,
        ChatCompletionPart(type: 'thought', content: thought),
      ];
      _notifyChatActivity();
    }
    final excerpt = userText.length <= 80
        ? userText
        : userText.substring(0, 80);
    final sample =
        '我现在跑在你的本地应用里。你刚刚说的是：“$excerpt”。\n\n'
        '等你在设置里填好 OpenAI-compatible endpoint、API Key，并把真实模型映射到模型槽位后，我就会切换到真实流式回复。私密对话不会写进历史，普通对话只保存在本机。';
    final chunks = RegExp(
      r'[\s\S]{1,8}',
    ).allMatches(sample).map((match) => match.group(0)!).toList();
    for (final chunk in chunks) {
      if (_generationAbort?.isCompleted == true) {
        throw const HttpException('本地演示已停止');
      }
      streamingText += chunk;
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 28));
    }
    stopwatch.stop();
    return ChatCompletionResult(
      text: sample,
      parts: <ChatCompletionPart>[
        for (final thought in thoughts)
          ChatCompletionPart(type: 'thought', content: thought),
        ChatCompletionPart(type: 'content', content: sample),
      ],
      usage: const <String, Object?>{},
      elapsed: stopwatch.elapsed,
    );
  }

  void stopGeneration() {
    if (!busy || _generationAbort?.isCompleted == true) return;
    _generationAbort?.complete();
    _cancelPendingToolApprovals();
    notifyListeners();
  }

  void _touchGenerationActivity() {
    if (!busy || _generationAbort?.isCompleted != false) return;
    _generationTimeout?.cancel();
    _generationTimeout = Timer(_generationIdleLimit, () {
      if (_isActiveFileToolProgress(streamingToolProgress)) {
        _touchGenerationActivity();
        return;
      }
      _generationTimedOut = true;
      if (_generationAbort?.isCompleted == false) _generationAbort?.complete();
    });
  }

  bool _isActiveFileToolProgress(ChatCompletionPart? part) {
    if (part == null || part.type != 'tool') return false;
    final status = '${part.metadata['status'] ?? ''}';
    if (status != 'preparing' && status != 'running') return false;
    return _fileToolNames.contains('${part.metadata['name'] ?? ''}'.trim());
  }

  Future<void> _recordAssistantFailure(
    String detail, {
    String statusType = 'receive_failed',
    String? fallbackText,
  }) async {
    final conversation = activeConversation;
    if (conversation == null) return;
    final content = streamingText.isEmpty
        ? (fallbackText ?? 'API 请求失败：$detail')
        : streamingText;
    final parts = <MessagePartInput>[
      ..._interruptedParts(content),
      MessagePartInput(
        type: 'status',
        metadata: <String, Object?>{'status': statusType, 'detail': detail},
      ),
    ];
    try {
      if (privateMode) {
        final failed = ChatMessage(
          id: 'private-${DateTime.now().microsecondsSinceEpoch}',
          conversationId: conversation.id,
          sequence: messages.length + 1,
          role: 'assistant',
          content: content,
          status: 'error',
          error: detail,
          createdAt: DateTime.now().toUtc(),
        );
        messages = <ChatMessage>[...messages, failed];
        messagePartsByMessage[failed.id] = _ephemeralParts(failed.id, parts);
      } else {
        await database.appendMessage(
          conversationId: conversation.id,
          role: 'assistant',
          content: content,
          status: 'error',
          error: detail,
          metadataJson: jsonEncode(<String, Object?>{
            if (streamingReasoning.isNotEmpty) 'reasoning': streamingReasoning,
          }),
          parts: parts,
        );
        messages = await database.messages(conversation.id);
        await _loadMessageParts(conversation.id);
      }
    } on Object {
      // The original failure remains visible through [notice] if local
      // persistence itself is unavailable.
    }
  }

  List<MessagePartInput> _interruptedParts(String content) {
    final result = streamingParts.map((part) => part.toInput()).toList();
    final committedReasoning = streamingParts
        .where((part) => part.type == 'thought')
        .map((part) => part.content ?? '')
        .join();
    final pendingReasoning = streamingReasoning.startsWith(committedReasoning)
        ? streamingReasoning.substring(committedReasoning.length)
        : streamingReasoning;
    if (pendingReasoning.isNotEmpty) {
      result.add(MessagePartInput(type: 'thought', content: pendingReasoning));
    }
    final committedText = streamingParts
        .where((part) => part.type == 'content')
        .map((part) => part.content ?? '')
        .join();
    final pendingText = content.startsWith(committedText)
        ? content.substring(committedText.length)
        : content;
    if (pendingText.isNotEmpty) {
      result.add(MessagePartInput(type: 'content', content: pendingText));
    }
    final progress = streamingToolProgress;
    if (progress != null) result.add(progress.toInput());
    return result;
  }

  Future<void> renameActiveConversation(String title) async {
    final conversation = activeConversation;
    if (conversation == null || privateMode) return;
    await database.renameConversation(conversation.id, title);
    await reload();
  }

  Future<void> toggleConversationStar(Conversation value) async {
    if (privateMode || value.id.startsWith('private-')) return;
    await database.setConversationStarred(value.id, starred: !value.starred);
    await reload();
  }

  Future<void> archiveConversation(Conversation value) async {
    if (privateMode || value.id.startsWith('private-')) return;
    await database.setConversationArchived(value.id, archived: true);
    if (activeConversation?.id == value.id) {
      activeConversation = null;
      messages = <ChatMessage>[];
      messagePartsByMessage = <String, List<MessagePart>>{};
    }
    await reload();
  }

  Future<void> unarchiveConversation(Conversation value) async {
    if (value.id.startsWith('private-')) return;
    await database.setConversationArchived(value.id, archived: false);
    await reload();
  }

  Future<List<ChatMessage>> messagesForConversation(Conversation value) async {
    if (value.id.startsWith('private-')) return const <ChatMessage>[];
    return database.messages(value.id);
  }

  Future<void> deleteConversation(Conversation value) async {
    if (value.id.startsWith('private-')) {
      activeConversation = null;
      messages = <ChatMessage>[];
      notifyListeners();
      return;
    }
    await database.softDelete('conversations', value.id);
    if (activeConversation?.id == value.id) {
      activeConversation = null;
      messages = <ChatMessage>[];
    }
    await reload();
  }

  Future<void> clearConversationHistory() async {
    for (final conversation in await database.conversations()) {
      await database.softDelete('conversations', conversation.id);
    }
    activeConversation = null;
    messages = <ChatMessage>[];
    messagePartsByMessage = <String, List<MessagePart>>{};
    await reload();
  }

  Future<void> restoreEntity(String table, String id) async {
    final rows = await database.database.query(
      table,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final update = <String, Object?>{
      'deleted_at': null,
      if (table == 'memories' ||
          table == 'diary_entries' ||
          table == 'user_files')
        'delete_reason': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'revision': ((rows.first['revision'] as num?)?.toInt() ?? 0) + 1,
      'origin_device_id': database.deviceId,
      if (table == 'diary_entries' || table == 'user_files') 'status': 'active',
    };
    await database.database.transaction((transaction) async {
      await transaction.update(
        table,
        update,
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      await transaction.delete(
        'tombstones',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: <Object?>[table, id],
      );
    });
    await reload();
  }

  Future<void> deleteMemoryFromUi(String id) async {
    final rows = await database.database.query(
      'memories',
      columns: const <String>['id'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await database.database.update(
      'memories',
      const <String, Object?>{'delete_reason': '用户在记忆管理界面删除'},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    await database.softDelete('memories', id);
    await reload();
  }

  Future<void> deleteFileFromUi(String id) async {
    final rows = await database.database.query(
      'user_files',
      where: 'id = ? AND deleted_at IS NULL AND status != ?',
      whereArgs: <Object?>[id, 'deleted'],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final file = UserFileRecord.fromMap(rows.first);
    final body = await content.readFile(id);
    await content.saveTextFile(
      id: id,
      name: file.name,
      content: body,
      type: file.type,
      reason: '用户手动删除',
    );
    final now = DateTime.now().toUtc().toIso8601String();
    await database.database.update(
      'user_files',
      <String, Object?>{
        'status': 'deleted',
        'delete_reason': '用户手动删除',
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    await database.softDelete('user_files', id);
    await reload();
  }

  Future<String> exportConversation(Conversation value) async {
    final items = value.id.startsWith('private-')
        ? messages
        : await database.messages(value.id);
    final safeTitle = value.title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    final path =
        '${paths.temp.path}${Platform.pathSeparator}${safeTitle.isEmpty ? 'ClaudeChat' : safeTitle}.md';
    final output = StringBuffer('# ${value.title}\n\n');
    for (final item in items) {
      output
        ..writeln(item.role == 'user' ? '## 用户' : '## Claude')
        ..writeln()
        ..writeln(item.content)
        ..writeln();
    }
    await File(path).writeAsString(output.toString(), flush: true);
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(path)], title: value.title),
    );
    return path;
  }

  Future<String> exportMessage(ChatMessage value) async {
    final safeRole = value.role == 'user' ? 'User' : 'Claude';
    final path =
        '${paths.temp.path}${Platform.pathSeparator}${safeRole}_${DateTime.now().millisecondsSinceEpoch}.txt';
    await File(path).writeAsString(value.content, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(path)], title: 'ClaudeChat 单条消息'),
    );
    return path;
  }

  Future<String> shareTextContent({
    required String name,
    required String content,
  }) async {
    final safeName = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    final path =
        '${paths.temp.path}${Platform.pathSeparator}${safeName.isEmpty ? 'ClaudeChat.txt' : safeName}';
    await File(path).writeAsString(content, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(path)], title: name),
    );
    return path;
  }

  Future<void> branchFromMessage(ChatMessage value) async {
    final source = activeConversation;
    if (source == null || privateMode) return;
    final selected = messages
        .where((message) => message.sequence <= value.sequence)
        .toList();
    final branch = await database.branchConversation(
      source: source,
      messages: selected,
    );
    activeConversation = branch;
    messages = await database.messages(branch.id);
    conversations = await database.conversations();
    notifyListeners();
  }

  Future<void> rateMessage(ChatMessage value, String rating) async {
    if (value.role != 'assistant') return;
    Map<String, Object?> metadata;
    try {
      metadata = (jsonDecode(value.metadataJson) as Map)
          .cast<String, Object?>();
    } on Object {
      metadata = <String, Object?>{};
    }
    metadata['feedback'] = metadata['feedback'] == rating ? null : rating;
    if (privateMode) {
      final index = messages.indexWhere((message) => message.id == value.id);
      if (index < 0) return;
      final updated = ChatMessage(
        id: value.id,
        conversationId: value.conversationId,
        sequence: value.sequence,
        role: value.role,
        content: value.content,
        status: value.status,
        error: value.error,
        metadataJson: jsonEncode(metadata),
        createdAt: value.createdAt,
        updatedAt: DateTime.now().toUtc(),
        deletedAt: value.deletedAt,
        revision: value.revision + 1,
        originDeviceId: value.originDeviceId,
      );
      messages = <ChatMessage>[
        ...messages.take(index),
        updated,
        ...messages.skip(index + 1),
      ];
      notifyListeners();
      return;
    }
    await database.updateMessage(
      ChatMessage(
        id: value.id,
        conversationId: value.conversationId,
        sequence: value.sequence,
        role: value.role,
        content: value.content,
        status: value.status,
        error: value.error,
        metadataJson: jsonEncode(metadata),
        createdAt: value.createdAt,
        updatedAt: DateTime.now().toUtc(),
        deletedAt: value.deletedAt,
        revision: value.revision + 1,
        originDeviceId: database.deviceId,
      ),
    );
    messages = await database.messages(value.conversationId);
    notifyListeners();
  }

  Future<void> editUserMessage(
    ChatMessage message,
    String content, {
    required bool resend,
  }) async {
    if (privateMode) {
      final index = messages.indexWhere((item) => item.id == message.id);
      if (index < 0) return;
      final replacement = ChatMessage(
        id: message.id,
        conversationId: message.conversationId,
        sequence: message.sequence,
        role: message.role,
        content: content,
        status: message.status,
        error: message.error,
        metadataJson: message.metadataJson,
        createdAt: message.createdAt,
        updatedAt: DateTime.now().toUtc(),
        deletedAt: message.deletedAt,
        revision: message.revision + 1,
        originDeviceId: message.originDeviceId,
      );
      messages = <ChatMessage>[
        ...messages.take(index),
        replacement,
        if (!resend) ...messages.skip(index + 1),
      ];
      notifyListeners();
      if (resend) await _continueAfterEditedUser();
      return;
    }
    await database.replaceMessageContent(message.id, content);
    if (resend)
      await database.deleteMessagesAfter(
        message.conversationId,
        message.sequence,
      );
    messages = await database.messages(message.conversationId);
    notifyListeners();
    if (resend) await _continueAfterEditedUser();
  }

  void beginUserMessageEdit(ChatMessage message, {required bool resend}) {
    if (busy || message.role != 'user') return;
    pendingAttachments = <PendingAttachment>[];
    editingUserMessage = message;
    editingUserMessageResend = resend;
    editRequestSerial++;
    notifyListeners();
  }

  void cancelUserMessageEdit() {
    if (editingUserMessage == null) return;
    editingUserMessage = null;
    editingUserMessageResend = false;
    editRequestSerial++;
    notifyListeners();
  }

  Future<void> submitUserMessageEdit(String content) async {
    final message = editingUserMessage;
    if (message == null || content.trim().isEmpty || busy) return;
    final resend = editingUserMessageResend;
    editingUserMessage = null;
    editingUserMessageResend = false;
    editRequestSerial++;
    notifyListeners();
    await editUserMessage(message, content.trim(), resend: resend);
  }

  Future<void> retryAssistantMessage(ChatMessage message) async {
    final previousUsers = messages
        .where(
          (item) => item.sequence < message.sequence && item.role == 'user',
        )
        .toList();
    if (previousUsers.isEmpty) return;
    if (!privateMode) {
      await database.softDelete('messages', message.id);
      messages = await database.messages(message.conversationId);
    } else {
      messages = messages.where((item) => item.id != message.id).toList();
    }
    await _continueAfterEditedUser();
  }

  Future<void> deleteMessage(ChatMessage message) async {
    if (privateMode) {
      messages = messages.where((item) => item.id != message.id).toList();
    } else {
      await database.softDelete('messages', message.id);
      messages = await database.messages(message.conversationId);
    }
    notifyListeners();
  }

  Future<void> openWorkspace(WorkspaceRecord value) async {
    final existingRun = _workspaceRuns[value.id];
    final preserveTask =
        existingRun != null &&
        (existingRun.busy || existingRun.taskSteps.isNotEmpty);
    activeWorkspace = value;
    final run = _workspaceRun(value.id);
    if (run.planItems.isEmpty) {
      run.planItems = _workspacePlanItemsFromSettings(value.settings);
    }
    if (!preserveTask) {
      workspaceTaskSteps = <WorkspaceTaskStep>[];
      workspaceTaskSummary = '任务尚未开始';
      workspaceTaskState = 'idle';
    }
    section = AppSection.workspaces;
    notifyListeners();
    final loadedFiles = await content.workspaceFiles(value.id);
    final loadedContents = <String, String>{
      for (final file in loadedFiles)
        file.id: await content.readWorkspaceFile(file),
    };
    final loadedConversations = await content.workspaceConversations(value.id);
    final selectedId = _selectedWorkspaceConversationIds[value.id];
    var loadedConversation =
        loadedConversations
            .where((item) => item.id == selectedId)
            .firstOrNull ??
        loadedConversations.firstOrNull;
    var loadedMessages = loadedConversation == null
        ? <WorkspaceMessageRecord>[]
        : await content.workspaceMessages(
            value.id,
            conversationId: loadedConversation.id,
          );
    if (loadedConversation != null && loadedMessages.isEmpty) {
      final fallback = await content.latestNonEmptyWorkspaceConversation(
        value.id,
        excludingConversationId: loadedConversation.id,
      );
      if (fallback != null) {
        loadedConversation = fallback;
        loadedMessages = await content.workspaceMessages(
          value.id,
          conversationId: fallback.id,
        );
      }
    }
    final loadedParts = loadedConversation == null
        ? <String, List<MessagePart>>{}
        : await content.workspaceMessageParts(
            value.id,
            conversationId: loadedConversation.id,
          );
    final loadedCommits = await content.workspaceCommits(value.id);
    if (activeWorkspace?.id != value.id) return;
    workspaceFiles = loadedFiles;
    workspaceFileContents = loadedContents;
    workspaceFileCounts[value.id] = loadedFiles.length;
    workspaceConversations = loadedConversations;
    activeWorkspaceConversation = loadedConversation;
    if (loadedConversation != null) {
      _selectedWorkspaceConversationIds[value.id] = loadedConversation.id;
    }
    workspaceMessages = loadedMessages;
    workspaceMessagePartsByMessage = loadedParts;
    workspaceCommits = loadedCommits;
    section = AppSection.workspaces;
    notifyListeners();
  }

  void closeWorkspace() {
    // Leaving a workspace is navigation only.  A running task may continue in
    // the background; it must never force the user into ordinary chat or keep
    // the workspace detail page pinned open.
    _clearActiveWorkspaceView();
    notifyListeners();
  }

  void _clearActiveWorkspaceView() {
    activeWorkspace = null;
    workspaceFiles = <WorkspaceFileRecord>[];
    workspaceFileContents = <String, String>{};
    workspaceMessages = <WorkspaceMessageRecord>[];
    workspaceConversations = <WorkspaceConversationRecord>[];
    activeWorkspaceConversation = null;
    workspaceMessagePartsByMessage = <String, List<MessagePart>>{};
    workspaceCommits = <WorkspaceCommitRecord>[];
  }

  Future<void> _loadWorkspaceConversations(String workspaceId) async {
    workspaceConversations = await content.workspaceConversations(workspaceId);
    final selectedId = _selectedWorkspaceConversationIds[workspaceId];
    var selected =
        workspaceConversations
            .where((item) => item.id == selectedId)
            .firstOrNull ??
        workspaceConversations.firstOrNull;
    var conversationId = selected?.id;
    if (conversationId == null) {
      activeWorkspaceConversation = null;
      workspaceMessages = <WorkspaceMessageRecord>[];
      workspaceMessagePartsByMessage = <String, List<MessagePart>>{};
      return;
    }
    workspaceMessages = await content.workspaceMessages(
      workspaceId,
      conversationId: conversationId,
    );
    if (workspaceMessages.isEmpty) {
      final fallback = await content.latestNonEmptyWorkspaceConversation(
        workspaceId,
        excludingConversationId: conversationId,
      );
      if (fallback != null) {
        selected = fallback;
        conversationId = fallback.id;
        workspaceMessages = await content.workspaceMessages(
          workspaceId,
          conversationId: conversationId,
        );
      }
    }
    activeWorkspaceConversation = selected;
    _selectedWorkspaceConversationIds[workspaceId] = conversationId;
    workspaceMessagePartsByMessage = await content.workspaceMessageParts(
      workspaceId,
      conversationId: conversationId,
    );
  }

  Future<void> createWorkspaceConversation() async {
    final workspace = activeWorkspace;
    if (workspace == null) return;
    final created = await content.createWorkspaceConversation(
      workspace.id,
      title: '新对话 ${workspaceConversations.length + 1}',
    );
    if (activeWorkspace?.id != workspace.id) return;
    workspaceConversations = await content.workspaceConversations(workspace.id);
    if (activeWorkspace?.id != workspace.id) return;
    await openWorkspaceConversation(created);
  }

  Future<void> openWorkspaceConversation(
    WorkspaceConversationRecord conversation,
  ) async {
    final workspace = activeWorkspace;
    if (workspace == null || conversation.workspaceId != workspace.id) return;
    activeWorkspaceConversation = conversation;
    _selectedWorkspaceConversationIds[workspace.id] = conversation.id;
    final loadedMessages = await content.workspaceMessages(
      workspace.id,
      conversationId: conversation.id,
    );
    final loadedParts = await content.workspaceMessageParts(
      workspace.id,
      conversationId: conversation.id,
    );
    if (activeWorkspace?.id != workspace.id ||
        activeWorkspaceConversation?.id != conversation.id) {
      return;
    }
    workspaceMessages = loadedMessages;
    workspaceMessagePartsByMessage = loadedParts;
    notifyListeners();
  }

  /// Rebuilds a preview from fresh, workspace-scoped storage. Native preview
  /// pages call this on refresh instead of reloading the static HTML snapshot
  /// that was passed when the page first opened.
  Future<Map<String, String>?> workspacePreviewPayload(
    String workspaceId, {
    required String fallbackTitle,
    String? fileId,
  }) async {
    final files = await content.workspaceFiles(workspaceId);
    if (fileId != null) {
      final file = files.where((item) => item.id == fileId).firstOrNull;
      if (file == null) return null;
      return <String, String>{
        'html': await content.readWorkspaceFile(file),
        'title': file.name,
      };
    }
    final sources = <String, String>{
      for (final file in files)
        file.name: await content.readWorkspaceFile(file),
    };
    final document = WorkspaceProjectService.build(
      sources,
      fallbackTitle: fallbackTitle,
    );
    if (document == null) return null;
    return <String, String>{'html': document.html, 'title': document.title};
  }

  Future<void> deleteWorkspace(WorkspaceRecord value) async {
    await database.softDelete('workspaces', value.id);
    closeWorkspace();
    await reload();
  }

  Future<void> archiveWorkspace(WorkspaceRecord value) async {
    await content.archiveWorkspace(value.id);
    closeWorkspace();
    await reload();
  }

  Future<void> restoreArchivedWorkspace(WorkspaceRecord value) async {
    await content.unarchiveWorkspace(value.id);
    await reload();
  }

  Future<void> saveWorkspaceConfiguration({
    String? name,
    String? description,
    String? projectType,
    String? modelSlotId,
    String? mode,
    int? maxRounds,
    double? fontScale,
    bool? showThinking,
    bool? taskPersistent,
    String? taskDisplayStyle,
    bool? allowMultipleWorkspaceRuns,
  }) async {
    final workspace = activeWorkspace;
    if (workspace == null) return;
    final nextSettings = <String, Object?>{
      ...workspace.settings,
      'modelSlotId': ?modelSlotId,
      'mode': ?mode,
      'maxRounds': ?maxRounds?.clamp(1, 20),
      'fontScale': ?fontScale?.clamp(.85, 1.25),
      'showThinking': ?showThinking,
      'taskPersistent': ?taskPersistent,
      'taskDisplayStyle': ?taskDisplayStyle,
      'allowMultipleWorkspaceRuns': ?allowMultipleWorkspaceRuns,
    };
    final optimistic = WorkspaceRecord(
      id: workspace.id,
      name: name == null
          ? workspace.name
          : (name.trim().isEmpty ? '我的工作区' : name.trim()),
      description: description?.trim() ?? workspace.description,
      projectType: projectType ?? workspace.projectType,
      settings: nextSettings,
      updatedAt: DateTime.now().toUtc(),
      archivedAt: workspace.archivedAt,
    );
    workspaces = workspaces
        .map((item) => item.id == workspace.id ? optimistic : item)
        .toList();
    activeWorkspace = optimistic;
    // Task-ball presentation is a front-end preference. Reflect it before the
    // SQLite round trip so enabling persistent/ball mode shows the ball on the
    // settings screen itself, not only after navigating back.
    notifyListeners();
    try {
      await content.updateWorkspace(
        id: workspace.id,
        name: name,
        description: description,
        projectType: projectType,
        settings: nextSettings,
      );
      final rows = await content.workspaces();
      if (rows.isNotEmpty) workspaces = rows;
      if (activeWorkspace?.id == workspace.id) {
        activeWorkspace =
            rows.where((item) => item.id == workspace.id).firstOrNull ??
            optimistic;
      }
    } on Object catch (error) {
      workspaces = workspaces
          .map((item) => item.id == workspace.id ? workspace : item)
          .toList();
      if (activeWorkspace?.id == workspace.id) activeWorkspace = workspace;
      notice = '工作区设置保存失败：$error';
    }
    notifyListeners();
  }

  Future<void> createWorkspaceCheckpoint({String message = '手动保存'}) async {
    final workspace = activeWorkspace;
    if (workspace == null) return;
    await content.createWorkspaceCheckpoint(
      workspace.id,
      message: message,
      trigger: 'manual',
      force: true,
    );
    workspaceCommits = await content.workspaceCommits(workspace.id);
    notifyListeners();
  }

  Future<void> shareWorkspaceFile(WorkspaceFileRecord value) async {
    final path =
        '${paths.files.path}${Platform.pathSeparator}${value.relativePath.replaceAll('/', Platform.pathSeparator)}';
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(path)], title: value.name),
    );
  }

  Future<void> restoreWorkspaceCheckpoint(WorkspaceCommitRecord commit) async {
    final workspace = activeWorkspace;
    if (workspace == null || workspace.id != commit.workspaceId) return;
    workspaceBusy = true;
    notifyListeners();
    try {
      await content.restoreWorkspaceCheckpoint(commit);
      workspaceFiles = await content.workspaceFiles(workspace.id);
      workspaceFileContents = <String, String>{
        for (final file in workspaceFiles)
          file.id: await content.readWorkspaceFile(file),
      };
      workspaceFileCounts[workspace.id] = workspaceFiles.length;
      workspaceCommits = await content.workspaceCommits(workspace.id);
      notice = '已恢复到检查点 #${commit.sequence}';
    } on Object catch (error) {
      notice = '恢复失败：$error';
    } finally {
      workspaceBusy = false;
      notifyListeners();
    }
  }

  Future<List<WorkspaceFileVersionRecord>> workspaceFileVersions(
    WorkspaceFileRecord file,
  ) => content.workspaceFileVersions(
    workspaceId: file.workspaceId,
    fileId: file.id,
  );

  Future<VerifiedWorkspaceFileVersion> readWorkspaceFileVersion(
    WorkspaceFileVersionRecord version,
  ) => content.readWorkspaceFileVersion(
    version.id,
    workspaceId: version.workspaceId,
  );

  Future<void> restoreWorkspaceFileVersion(
    WorkspaceFileVersionRecord version,
  ) async {
    final workspace = activeWorkspace;
    if (workspace == null || workspace.id != version.workspaceId) return;
    workspaceBusy = true;
    notifyListeners();
    try {
      await content.restoreWorkspaceFileVersion(
        version.id,
        workspaceId: workspace.id,
      );
      workspaceFiles = await content.workspaceFiles(workspace.id);
      workspaceFileContents = <String, String>{
        for (final file in workspaceFiles)
          file.id: await content.readWorkspaceFile(file),
      };
      workspaceCommits = await content.workspaceCommits(workspace.id);
      notice = '已恢复 ${version.name} 的版本 #${version.sequence}';
    } on Object catch (error) {
      notice = '文件版本恢复失败：$error';
    } finally {
      workspaceBusy = false;
      notifyListeners();
    }
  }

  void _beginWorkspaceTask(String request, {_WorkspaceRunState? target}) {
    final run = target ?? _activeWorkspaceRun;
    if (run == null) return;
    run.taskSteps = <WorkspaceTaskStep>[];
    run.planItems = <WorkspacePlanItem>[];
    run.taskState = 'running';
    run.taskSummary = '任务正在启动';
    _setWorkspaceTaskStep(
      'request',
      label: '收到任务',
      state: 'completed',
      detail: _titleFrom(request),
      target: run,
    );
    _setWorkspaceTaskStep(
      'model',
      label: '等待模型响应',
      state: 'running',
      target: run,
    );
  }

  List<WorkspacePlanItem> _workspacePlanItemsFromSettings(
    Map<String, Object?> settings,
  ) {
    final raw = settings['planItems'];
    if (raw is! List) return <WorkspacePlanItem>[];
    return raw
        .map(WorkspacePlanItem.fromMap)
        .whereType<WorkspacePlanItem>()
        .toList(growable: false);
  }

  Future<String> _updateWorkspacePlan(
    WorkspaceRecord workspace,
    Map<String, Object?> arguments,
    _WorkspaceRunState run,
  ) async {
    final raw = arguments['items'];
    if (raw is! List) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'error': '计划 items 必须是数组',
      });
    }
    final next = raw
        .map(WorkspacePlanItem.fromMap)
        .whereType<WorkspacePlanItem>()
        .toList(growable: false);
    if (next.isEmpty) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'error': '计划至少需要一个有效步骤',
      });
    }
    run.planItems = next;
    final nextSettings = <String, Object?>{
      ...workspace.settings,
      'planItems': next.map((item) => item.toMap()).toList(),
    };
    await content.updateWorkspace(id: workspace.id, settings: nextSettings);
    if (activeWorkspace?.id == workspace.id) {
      final refreshed = (await content.workspaces())
          .where((item) => item.id == workspace.id)
          .firstOrNull;
      if (refreshed != null) activeWorkspace = refreshed;
    }
    _notifyWorkspaceActivity(run);
    return jsonEncode(<String, Object?>{
      'ok': true,
      'updated': next.length,
      'items': next.map((item) => item.toMap()).toList(),
    });
  }

  void _setWorkspaceTaskStep(
    String key, {
    required String label,
    required String state,
    String detail = '',
    _WorkspaceRunState? target,
  }) {
    final run = target ?? _activeWorkspaceRun;
    if (run == null) return;
    final now = DateTime.now();
    final index = run.taskSteps.indexWhere((item) => item.key == key);
    final step = WorkspaceTaskStep(
      key: key,
      label: label,
      state: state,
      detail: detail,
      updatedAt: now,
    );
    if (index < 0) {
      run.taskSteps = <WorkspaceTaskStep>[...run.taskSteps, step];
    } else {
      final next = <WorkspaceTaskStep>[...run.taskSteps];
      next[index] = step;
      run.taskSteps = next;
    }
    run.taskSummary = label;
    run.taskState = state;
    _notifyWorkspaceActivity(run);
  }

  void _updateWorkspaceToolTask(
    ChatCompletionPart? part, {
    _WorkspaceRunState? target,
  }) {
    if (part == null) return;
    final metadata = part.metadata;
    final name = '${metadata['name'] ?? 'tool'}';
    final callId = '${metadata['callId'] ?? name}';
    final status = '${metadata['status'] ?? 'running'}';
    final arguments = metadata['arguments'];
    final fileName = arguments is Map
        ? '${arguments['name'] ?? arguments['fileName'] ?? ''}'.trim()
        : '';
    if ((name == 'create_workspace_file' || name == 'edit_workspace_file') &&
        fileName.isNotEmpty &&
        arguments is Map) {
      final source = arguments['content'];
      if (source is String) {
        final run = target ?? _activeWorkspaceRun;
        run?.liveFileEdits[fileName] = WorkspaceLiveFileEdit(
          name: fileName,
          content: source,
          status: status,
          updatedAt: DateTime.now(),
        );
      }
    }
    final noun = switch (name) {
      'list_workspace_files' => '整理文件树',
      'read_workspace_file' => fileName.isEmpty ? '读取文件' : '读取 $fileName',
      'list_workspace_file_versions' => '整理文件版本',
      'read_workspace_file_version' => '读取文件版本',
      'restore_workspace_file_version' => '恢复文件版本',
      'create_workspace_file' => fileName.isEmpty ? '创建文件' : '创建 $fileName',
      'edit_workspace_file' => fileName.isEmpty ? '编辑文件' : '编辑 $fileName',
      _ => '执行 ${name.replaceAll('_', ' ')}',
    };
    final stepState = switch (status) {
      'success' => 'completed',
      'error' || 'denied' => 'failed',
      _ => 'running',
    };
    final label = switch (status) {
      'preparing' => '准备$noun',
      'running' => '正在$noun',
      'success' => '已完成$noun',
      _ => '$noun失败',
    };
    _setWorkspaceTaskStep(
      'tool-$callId',
      label: label,
      state: stepState,
      detail: fileName.isEmpty ? name : '$name · $fileName',
      target: target,
    );
  }

  void _settleWorkspaceTaskSteps({
    required String state,
    String detail = '',
    _WorkspaceRunState? target,
  }) {
    final run = target ?? _activeWorkspaceRun;
    if (run == null) return;
    final now = DateTime.now();
    run.taskSteps = run.taskSteps.map((step) {
      if (step.state != 'running') return step;
      return step.copyWith(
        state: state,
        detail: detail.isEmpty ? step.detail : detail,
        updatedAt: now,
      );
    }).toList();
    _notifyWorkspaceActivity(run);
  }

  String _workspaceTaskPreview(String value) {
    final sample = value.length <= 180
        ? value
        : value.substring(value.length - 180);
    final normalized = sample.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 80
        ? normalized
        : '…${normalized.substring(normalized.length - 80)}';
  }

  Future<void> sendWorkspaceMessage(String text) async {
    final workspace = activeWorkspace;
    final conversation = activeWorkspaceConversation;
    if (workspace == null || conversation == null || text.trim().isEmpty) {
      return;
    }
    final run = _workspaceRun(workspace.id);
    if (run.busy) return;
    if (!allowMultipleWorkspaceRuns &&
        _workspaceRuns.values.any(
          (candidate) =>
              candidate.workspaceId != workspace.id && candidate.busy,
        )) {
      notice = '已有另一个工作区正在运行；请先停止它，或开启“允许多个工作区同时运行”。';
      notifyListeners();
      return;
    }
    var generationActivityStarted = false;
    final backgroundScope = 'workspace:${workspace.id}';
    var generationActivityStatus = '工作区任务已中断';
    var generationActivityPreview = '';
    final requestedMode = '${workspace.settings['mode'] ?? 'agent'}';
    final profile = workspaceProfile;
    final model = workspaceModel;
    final capturedAppSettings = <String, Object?>{...settings};
    final capturedModelSlot = workspaceModelSlot == null
        ? null
        : <String, Object?>{...workspaceModelSlot!};
    Object? capturedModelValue(String key, Object? fallback) =>
        capturedModelSlot != null && capturedModelSlot.containsKey(key)
        ? capturedModelSlot[key]
        : fallback;
    final capturedTemperature =
        (capturedModelValue(
                  'temperature',
                  capturedAppSettings['temperature'] ?? 0.7,
                )
                as num?)
            ?.toDouble();
    final capturedTopP =
        (capturedModelValue('topP', capturedAppSettings['topP'] ?? 1) as num?)
            ?.toDouble();
    final capturedFrequencyPenalty =
        (capturedModelValue(
                  'frequencyPenalty',
                  capturedAppSettings['frequencyPenalty'] ?? 0,
                )
                as num?)
            ?.toDouble();
    final capturedPresencePenalty =
        (capturedModelValue(
                  'presencePenalty',
                  capturedAppSettings['presencePenalty'] ?? 0,
                )
                as num?)
            ?.toDouble();
    final capturedMaxTokens =
        (capturedModelValue(
                  'maxTokens',
                  capturedAppSettings['maxTokens'] ?? 4096,
                )
                as num?)
            ?.toInt();
    final capturedStream =
        capturedModelValue('stream', capturedAppSettings['stream'] != false) !=
        false;
    final capturedContextBudget = ContextBudget.normalizeBudget(
      capturedModelValue('contextTokens', capturedAppSettings['contextTokens']),
    );
    final capturedMaxRounds =
        ((workspace.settings['maxRounds'] as num?)?.toInt() ?? 10).clamp(1, 20);
    if (profile == null || model.isEmpty) {
      notice = '请先在设置中配置 API 和模型';
      notifyListeners();
      return;
    }
    run.busy = true;
    run.conversationId = conversation.id;
    _beginWorkspaceTask(text.trim(), target: run);
    run.abort = Completer<void>();
    run.timedOut = false;
    _touchWorkspaceActivity(run);
    // A plan belongs to exactly one task run. Persist the reset before the
    // request starts so a cancelled/crashed run cannot resurrect stale steps
    // from the previous task the next time this workspace is opened.
    await content.updateWorkspace(
      id: workspace.id,
      settings: <String, Object?>{...workspace.settings, 'planItems': const []},
    );
    await content.appendWorkspaceMessage(
      workspaceId: workspace.id,
      conversationId: conversation.id,
      role: 'user',
      content: text.trim(),
      parts: <MessagePartInput>[
        const MessagePartInput(
          type: 'status',
          metadata: <String, Object?>{'status': 'sent'},
        ),
        MessagePartInput(type: 'content', content: text.trim()),
      ],
    );
    final capturedMessages = await content.workspaceMessages(
      workspace.id,
      conversationId: conversation.id,
    );
    final capturedMessageParts = await content.workspaceMessageParts(
      workspace.id,
      conversationId: conversation.id,
    );
    final capturedConversations = await content.workspaceConversations(
      workspace.id,
    );
    if (activeWorkspace?.id == workspace.id &&
        activeWorkspaceConversation?.id == conversation.id) {
      workspaceConversations = capturedConversations;
      activeWorkspaceConversation =
          capturedConversations
              .where((item) => item.id == conversation.id)
              .firstOrNull ??
          conversation;
      workspaceMessages = capturedMessages;
      workspaceMessagePartsByMessage = capturedMessageParts;
    }
    run.streamingText = '';
    run.streamingReasoning = '';
    run.streamingToolProgress = null;
    run.streamingParts = <ChatCompletionPart>[];
    run.liveFileEdits.clear();
    run.planItems = <WorkspacePlanItem>[];
    notifyListeners();
    final synthetic = capturedMessages
        .map(
          (item) => ChatMessage(
            id: item.id,
            conversationId: conversation.id,
            sequence: item.sequence,
            role: item.role,
            content: item.content,
            createdAt: item.createdAt,
          ),
        )
        .toList();
    final diagnosticRequestId =
        'workspace-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final diagnosticSink = _diagnosticSink(
      requestId: diagnosticRequestId,
      conversationId: conversation.id,
    );
    try {
      await _beginBackgroundGeneration(
        scope: backgroundScope,
        title: workspace.name,
        workspace: true,
      );
      generationActivityStarted = true;
      if (requestedMode == 'agent') {
        await content.createWorkspaceCheckpoint(
          workspace.id,
          message: 'Agent 任务前：${_titleFrom(text.trim())}',
          author: 'assistant',
          trigger: 'before_agent',
          force: true,
        );
      }
      final capturedFiles = await content.workspaceFiles(workspace.id);
      final capturedFileContents = <String, String>{
        for (final file in capturedFiles)
          file.name: await content.readWorkspaceFile(file),
      };
      final inspection = WorkspaceProjectService.inspect(capturedFileContents);
      final detectedType = inspection.detectedType;
      final effectiveType = workspace.projectType == 'auto'
          ? detectedType
          : workspace.projectType;
      final fileContext = capturedFiles.isEmpty
          ? '当前工作区还没有文件。'
          : '当前工作区已有文件：\n${capturedFiles.map((item) => '- ${item.name} (${item.type})').join('\n')}';
      final runtimeContext = inspection.runnable
          ? '当前项目可由移动端 ${inspection.runtime} 运行器执行，入口为 ${inspection.entryFile}。${inspection.runtime == 'python-wasm' ? '若用户需要小游戏、工具或可视化界面，请在 Python 中使用 from claudechat_ui import render_html，并调用 render_html(自包含的 HTML/CSS/JavaScript 字符串)，运行时会像普通 HTML 项目一样全屏显示；不要只用 print 输出模拟界面。' : ''}'
          : '当前项目不能在手机本机直接构建或运行：${inspection.diagnostics.join('；')}';
      final modePrompt = switch (requestedMode) {
        'chat' => '当前为 Chat 模式：只讨论和解释，不修改文件。',
        'plan' => '当前为 Plan 模式：可以读取文件来制定方案，但不能修改文件。',
        _ => '当前为 Agent 模式：可以读取、创建和编辑工作区文件。',
      };
      final systemPrompt =
          '${capturedAppSettings['systemPrompt'] ?? ''}\n\n你正在名为“${workspace.name}”的 $effectiveType 项目工作区中。'
          '${workspace.projectType == 'auto' ? '项目类型由当前文件自动识别为 $detectedType。' : ''}'
          '\n$modePrompt\n$fileContext\n$runtimeContext\n开始处理一个包含多个步骤的任务时，先调用 update_workspace_plan 提交目标计划；开始某一步时把它改为 running，完成后改为 completed。计划不得混入“正在分析任务、正在组织回复”等实时过程。\n工具返回 ok=false、error 或缺少 verified=true 时必须向用户说明失败，不得声称操作成功。创建或编辑成功后，请继续使用回执中的精确文件名。';
      final budget = capturedContextBudget;
      final trimmedWorkspace = budget == null
          ? ContextTrim(messages: synthetic, dropped: 0)
          : ContextBudget.trim(
              synthetic,
              budget: budget,
              reservedTokens:
                  ContextBudget.estimateText(systemPrompt) +
                  (capturedMaxTokens ?? 4096).clamp(256, budget ~/ 2),
              extraTokens: _workspaceHistoricalToolExtraTokens,
            );
      final buffer = StringBuffer();
      final result = await api.chatWithTools(
        profile: profile,
        model: model,
        messages: trimmedWorkspace.messages,
        messagePartsByMessage: capturedMessageParts,
        systemPrompt:
            '$systemPrompt${trimmedWorkspace.dropped == 0 ? '' : '\n\n为遵守当前模型的上下文预算，较早的 ${trimmedWorkspace.dropped} 条工作区消息未随本次请求发送。'}',
        tools: _workspaceToolsForMode(
          requestedMode,
        ).map((item) => item.toApi()).toList(),
        executeTool: (callId, name, arguments) async {
          final toolResult = await _executeWorkspaceTool(
            workspace,
            requestedMode,
            name,
            arguments,
            run,
          );
          _touchWorkspaceActivity(run);
          return toolResult;
        },
        temperature: capturedTemperature,
        topP: capturedTopP,
        frequencyPenalty: capturedFrequencyPenalty,
        presencePenalty: capturedPresencePenalty,
        maxTokens: capturedMaxTokens,
        stream: capturedStream,
        maxRounds: capturedMaxRounds,
        abortTrigger: run.abort!.future,
        onReasoning: (chunk) {
          _touchWorkspaceActivity(run);
          _setWorkspaceTaskStep(
            'model',
            label: '正在分析任务',
            state: 'running',
            detail: '正在理解需求并检查工作区上下文',
            target: run,
          );
          platform.updateGenerationActivity(status: '正在分析工作区任务');
          if (workspace.settings['showThinking'] == false) {
            _notifyWorkspaceActivity(run);
            return;
          }
          run.streamingReasoning += chunk;
          _notifyWorkspaceActivity(run);
        },
        onToolEvent: (part) {
          _touchWorkspaceActivity(run);
          run.streamingParts = <ChatCompletionPart>[
            ...run.streamingParts,
            part,
          ];
          if (part.type == 'tool') {
            _updateWorkspaceToolTask(part, target: run);
            platform.updateGenerationActivity(
              status: _toolActivityLabel(part, completed: true),
            );
          }
          _notifyWorkspaceActivity(run);
        },
        onToolProgress: (part) {
          _touchWorkspaceActivity(run);
          run.streamingToolProgress = part;
          _updateWorkspaceToolTask(part, target: run);
          if (part != null) {
            platform.updateGenerationActivity(status: _toolActivityLabel(part));
          }
          _notifyWorkspaceActivity(run);
        },
        onText: (chunk) {
          _touchWorkspaceActivity(run);
          buffer.write(chunk);
          run.streamingText = buffer.toString();
          generationActivityPreview = run.streamingText;
          final preview = _workspaceTaskPreview(run.streamingText);
          _setWorkspaceTaskStep(
            'response',
            label: '正在组织回复',
            state: 'running',
            detail: preview,
            target: run,
          );
          platform.updateGenerationActivity(
            status: '正在更新工作区',
            preview: run.streamingText,
          );
          _notifyWorkspaceActivity(run);
        },
        onActivity: () => _touchWorkspaceActivity(run),
        diagnosticContext: <String, Object?>{
          'requestId': diagnosticRequestId,
          'conversationId': conversation.id,
          'requestKind': 'workspace',
          'workspaceMode': requestedMode,
          'hardDroppedMessages': trimmedWorkspace.dropped,
        },
        onDiagnostic: diagnosticSink,
      );
      await content.appendWorkspaceMessage(
        workspaceId: workspace.id,
        conversationId: conversation.id,
        role: 'assistant',
        content: result.text,
        parts: _completionParts(result),
      );
      final refreshedFiles = await content.workspaceFiles(workspace.id);
      workspaceFileCounts[workspace.id] = refreshedFiles.length;
      if (activeWorkspace?.id == workspace.id &&
          activeWorkspaceConversation?.id == conversation.id) {
        workspaceConversations = await content.workspaceConversations(
          workspace.id,
        );
        activeWorkspaceConversation =
            workspaceConversations
                .where((item) => item.id == conversation.id)
                .firstOrNull ??
            conversation;
        workspaceFiles = refreshedFiles;
        workspaceFileContents = <String, String>{
          for (final file in workspaceFiles)
            file.id: await content.readWorkspaceFile(file),
        };
        workspaceMessages = await content.workspaceMessages(
          workspace.id,
          conversationId: conversation.id,
        );
        workspaceMessagePartsByMessage = await content.workspaceMessageParts(
          workspace.id,
          conversationId: conversation.id,
        );
      }
      if (requestedMode == 'agent') {
        await content.createWorkspaceCheckpoint(
          workspace.id,
          message: 'Agent 完成：${_titleFrom(text.trim())}',
          author: 'assistant',
          trigger: 'after_agent',
        );
        if (activeWorkspace?.id == workspace.id) {
          workspaceCommits = await content.workspaceCommits(workspace.id);
        }
      }
      _settleWorkspaceTaskSteps(state: 'completed', target: run);
      _setWorkspaceTaskStep(
        'model',
        label: '模型响应已完成',
        state: 'completed',
        target: run,
      );
      if (run.taskSteps.any((step) => step.key == 'response')) {
        _setWorkspaceTaskStep(
          'response',
          label: '回复已完成',
          state: 'completed',
          detail: _workspaceTaskPreview(result.text),
          target: run,
        );
      }
      _setWorkspaceTaskStep(
        'finish',
        label: '任务已完成',
        state: 'completed',
        target: run,
      );
      generationActivityStatus = '工作区任务已完成';
      generationActivityPreview = result.text;
    } on Object catch (error) {
      generationActivityStatus = run.abort?.isCompleted == true
          ? (run.timedOut ? '工作区任务等待超时' : '工作区任务已停止')
          : '工作区任务失败';
      _settleWorkspaceTaskSteps(
        state: 'failed',
        detail: generationActivityStatus,
        target: run,
      );
      _setWorkspaceTaskStep(
        'finish',
        label: generationActivityStatus,
        state: 'failed',
        detail: '$error',
        target: run,
      );
      diagnosticSink?.call(<String, Object?>{
        'event': 'chat_request_failed',
        'requestKind': 'workspace',
        'error': '$error',
        'partialTextCharacters': run.streamingText.length,
        'partialReasoningCharacters': run.streamingReasoning.length,
      });
      final detail = run.abort?.isCompleted == true
          ? (run.timedOut ? '长时间没有收到新数据，已停止等待' : '已停止生成')
          : '$error';
      notice = detail;
      await _recordWorkspaceAssistantFailure(workspace, detail, run);
    } finally {
      if (generationActivityStarted) {
        await _endBackgroundGeneration(
          scope: backgroundScope,
          status: generationActivityStatus,
          preview: generationActivityPreview,
          success: generationActivityStatus == '工作区任务已完成',
        );
      }
      run.busy = false;
      run.streamingText = '';
      run.streamingReasoning = '';
      run.streamingParts = <ChatCompletionPart>[];
      run.streamingToolProgress = null;
      run.timeout?.cancel();
      run.timeout = null;
      run.abort = null;
      run.timedOut = false;
      _notifyWorkspaceActivity(run);
      notifyListeners();
    }
  }

  void stopWorkspaceGeneration() {
    final run = _displayWorkspaceRun;
    if (run == null || !run.busy || run.abort?.isCompleted == true) return;
    run.abort?.complete();
    _cancelPendingToolApprovals();
    _notifyWorkspaceActivity(run);
    notifyListeners();
  }

  void _touchWorkspaceActivity(_WorkspaceRunState run) {
    if (!run.busy || run.abort?.isCompleted != false) return;
    run.timeout?.cancel();
    run.timeout = Timer(_workspaceIdleLimit, () {
      if (_isActiveFileToolProgress(run.streamingToolProgress)) {
        _touchWorkspaceActivity(run);
        return;
      }
      run.timedOut = true;
      if (run.abort?.isCompleted == false) run.abort?.complete();
    });
  }

  Future<String?> exportActiveWorkspacePackage() async {
    final workspace = activeWorkspace;
    if (workspace == null) {
      throw StateError('请先打开一个工作区');
    }
    final files = await content.workspaceFiles(workspace.id);
    final sources = <String, String>{
      for (final file in files)
        file.name: await content.readWorkspaceFile(file),
    };
    final bytes = WorkspaceExportService.buildZip(sources);
    final safeName = workspace.name.trim().replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '_',
    );
    final fileName = '${safeName.isEmpty ? 'workspace' : safeName}.zip';
    if (Platform.isIOS || Platform.isAndroid) {
      await paths.temp.create(recursive: true);
      final output = File(
        '${paths.temp.path}${Platform.pathSeparator}$fileName',
      );
      await output.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(output.path, mimeType: 'application/zip')],
          fileNameOverrides: <String>[fileName],
          title: '导出 ${workspace.name}',
        ),
      );
      return output.path;
    }
    final destination = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'ZIP 文件包',
          extensions: <String>['zip'],
          mimeTypes: <String>['application/zip'],
          uniformTypeIdentifiers: <String>['public.zip-archive'],
        ),
      ],
    );
    if (destination == null) return null;
    final package = XFile.fromData(
      bytes,
      mimeType: 'application/zip',
      name: fileName,
    );
    await package.saveTo(destination.path);
    return destination.path;
  }

  Future<int> importFilesToActiveWorkspace() async {
    final workspace = activeWorkspace;
    if (workspace == null) throw StateError('请先打开一个工作区');
    final selected = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '工作区文件或 ZIP 文件包',
          extensions: <String>[
            'zip',
            'html',
            'htm',
            'css',
            'js',
            'jsx',
            'ts',
            'tsx',
            'json',
            'md',
            'txt',
            'py',
            'yaml',
            'yml',
            'xml',
            'csv',
          ],
        ),
      ],
      confirmButtonText: '导入',
    );
    if (selected.isEmpty) return 0;
    final sources = <String, String>{};
    for (final item in selected) {
      final bytes = await item.readAsBytes();
      if (item.name.toLowerCase().endsWith('.zip')) {
        sources.addAll(WorkspaceExportService.readZip(bytes));
      } else {
        sources[WorkspaceExportService.normalizeEntryPath(item.name)] = utf8
            .decode(bytes, allowMalformed: false);
      }
    }
    if (sources.isEmpty) return 0;
    final existing = await content.workspaceFiles(workspace.id);
    for (final entry in sources.entries) {
      final current = existing
          .where((file) => file.name == entry.key)
          .firstOrNull;
      final extension = entry.key.contains('.')
          ? entry.key.split('.').last.toLowerCase()
          : 'text';
      await content.saveWorkspaceFile(
        workspaceId: workspace.id,
        id: current?.id,
        name: entry.key,
        type: extension,
        content: entry.value,
      );
    }
    await content.createWorkspaceCheckpoint(
      workspace.id,
      message: '导入 ${sources.length} 个工作区文件',
      trigger: 'file_import',
      force: true,
    );
    workspaceFiles = await content.workspaceFiles(workspace.id);
    workspaceFileContents = <String, String>{
      for (final file in workspaceFiles)
        file.id: await content.readWorkspaceFile(file),
    };
    workspaceFileCounts[workspace.id] = workspaceFiles.length;
    workspaceCommits = await content.workspaceCommits(workspace.id);
    notifyListeners();
    return sources.length;
  }

  Future<void> _recordWorkspaceAssistantFailure(
    WorkspaceRecord workspace,
    String detail,
    _WorkspaceRunState run,
  ) async {
    final messageContent = run.streamingText.isEmpty
        ? '工作区任务未完成：$detail'
        : run.streamingText;
    final parts = run.streamingParts.map((part) => part.toInput()).toList();
    final committedReasoning = run.streamingParts
        .where((part) => part.type == 'thought')
        .map((part) => part.content ?? '')
        .join();
    final pendingReasoning =
        run.streamingReasoning.startsWith(committedReasoning)
        ? run.streamingReasoning.substring(committedReasoning.length)
        : run.streamingReasoning;
    if (pendingReasoning.isNotEmpty) {
      parts.add(MessagePartInput(type: 'thought', content: pendingReasoning));
    }
    final committedText = run.streamingParts
        .where((part) => part.type == 'content')
        .map((part) => part.content ?? '')
        .join();
    final pendingText = messageContent.startsWith(committedText)
        ? messageContent.substring(committedText.length)
        : messageContent;
    if (pendingText.isNotEmpty) {
      parts.add(MessagePartInput(type: 'content', content: pendingText));
    }
    final progress = run.streamingToolProgress;
    if (progress != null) {
      parts.add(
        MessagePartInput(
          type: progress.type,
          content: progress.content,
          metadata: <String, Object?>{
            ...progress.metadata,
            'status': 'error',
            'error': detail,
          },
        ),
      );
    }
    parts.add(
      MessagePartInput(
        type: 'status',
        metadata: <String, Object?>{
          'status': 'receive_failed',
          'detail': detail,
        },
      ),
    );
    final conversationId = run.conversationId;
    if (conversationId == null || conversationId.isEmpty) return;
    try {
      await content.appendWorkspaceMessage(
        workspaceId: workspace.id,
        conversationId: conversationId,
        role: 'assistant',
        content: messageContent,
        parts: parts,
      );
      if (activeWorkspace?.id == workspace.id &&
          activeWorkspaceConversation?.id == conversationId) {
        workspaceMessages = await content.workspaceMessages(
          workspace.id,
          conversationId: conversationId,
        );
        workspaceMessagePartsByMessage = await content.workspaceMessageParts(
          workspace.id,
          conversationId: conversationId,
        );
      }
    } on Object {
      // The original transport/tool failure remains visible through [notice].
    }
  }

  Future<String> _executeWorkspaceTool(
    WorkspaceRecord workspace,
    String mode,
    String name,
    Map<String, Object?> arguments,
    _WorkspaceRunState run,
  ) async {
    if (!_workspaceToolsForMode(mode).any((tool) => tool.name == name)) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'error': '当前 ${mode.toUpperCase()} 模式不允许调用工具：$name',
      });
    }
    if (name == 'update_workspace_plan') {
      return _updateWorkspacePlan(workspace, arguments, run);
    }
    final current = await content.workspaceFiles(workspace.id);
    if (name == 'list_workspace_files') {
      final values = <Map<String, Object?>>[];
      for (final file in current) {
        final value = await content.readWorkspaceFile(file);
        values.add(<String, Object?>{
          'id': file.id,
          'fileId': file.id,
          'name': file.name,
          'type': file.type,
          'bytes': utf8.encode(value).length,
          'sha256': file.sha256,
          'updatedAt': file.updatedAt.toUtc().toIso8601String(),
        });
      }
      return jsonEncode(<String, Object?>{'ok': true, 'files': values});
    }
    if (name == 'list_workspace_file_versions') {
      final requestedName = '${arguments['name'] ?? ''}'.trim();
      final versions = await content.workspaceFileVersions(
        workspaceId: workspace.id,
        name: requestedName,
      );
      return jsonEncode(<String, Object?>{
        'ok': true,
        'name': requestedName,
        'versions': versions.map((value) => value.toMap()).toList(),
      });
    }
    if (name == 'read_workspace_file_version') {
      final versionId = '${arguments['versionId'] ?? ''}'.trim();
      final snapshot = await content.readWorkspaceFileVersion(
        versionId,
        workspaceId: workspace.id,
      );
      return jsonEncode(<String, Object?>{
        'ok': true,
        'version': snapshot.version.toMap(),
        'content': snapshot.content,
        'verified': true,
      });
    }
    if (name == 'restore_workspace_file_version') {
      final versionId = '${arguments['versionId'] ?? ''}'.trim();
      final receipt = await content.restoreWorkspaceFileVersion(
        versionId,
        workspaceId: workspace.id,
      );
      final refreshed = await content.workspaceFiles(workspace.id);
      workspaceFileCounts[workspace.id] = refreshed.length;
      if (activeWorkspace?.id == workspace.id) {
        workspaceFiles = refreshed;
        workspaceFileContents = <String, String>{
          for (final file in workspaceFiles)
            file.id: await content.readWorkspaceFile(file),
        };
        workspaceCommits = await content.workspaceCommits(workspace.id);
        _notifyWorkspaceActivity(run);
      }
      return jsonEncode(<String, Object?>{
        'ok': true,
        'result': receipt.toMap(),
        'restoredVersionId': versionId,
      });
    }
    if (name != 'read_workspace_file' &&
        name != 'create_workspace_file' &&
        name != 'edit_workspace_file') {
      return jsonEncode(<String, String>{'error': '未知工作区工具：$name'});
    }
    final requestedId = '${arguments['id'] ?? arguments['fileId'] ?? ''}'
        .trim();
    final fileName =
        '${arguments['name'] ?? arguments['fileName'] ?? arguments['path'] ?? ''}'
            .trim()
            .replaceAll('\\', '/');
    if (fileName.isEmpty && requestedId.isEmpty) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'error': '文件名或文件 UUID 不能为空',
      });
    }
    final normalizedName = fileName.startsWith('./')
        ? fileName.substring(2)
        : fileName;
    final existing = current
        .where(
          (item) =>
              (requestedId.isNotEmpty && item.id == requestedId) ||
              (normalizedName.isNotEmpty &&
                  item.name.replaceAll('\\', '/') == normalizedName),
        )
        .firstOrNull;
    if (name == 'read_workspace_file') {
      if (existing == null) {
        return jsonEncode(<String, Object?>{
          'ok': false,
          'error': '没有找到“$fileName”',
        });
      }
      return jsonEncode(<String, Object?>{
        'ok': true,
        'id': existing.id,
        'fileId': existing.id,
        'name': existing.name,
        'type': existing.type,
        'sha256': existing.sha256,
        'verified': true,
        'content': await content.readWorkspaceFile(existing),
      });
    }
    if (name == 'create_workspace_file' && existing != null) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'error': '文件“$fileName”已存在；如需修改请使用 edit_workspace_file',
      });
    }
    if (name == 'edit_workspace_file' && existing == null) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'error': '没有找到“$fileName”',
      });
    }
    final fileType = '${arguments['type'] ?? ''}'.trim();
    final fileContent = '${arguments['content'] ?? ''}';
    final receipt = await content.saveWorkspaceFile(
      workspaceId: workspace.id,
      id: existing?.id,
      name: existing?.name ?? normalizedName,
      content: fileContent,
      type: fileType.isEmpty ? 'text' : fileType,
    );
    await content.createWorkspaceCheckpoint(
      workspace.id,
      message: name == 'create_workspace_file'
          ? '模型创建文件：${receipt.name}'
          : '模型编辑文件：${receipt.name}',
      author: 'assistant',
      trigger: name == 'create_workspace_file' ? 'file_create' : 'file_edit',
    );
    final refreshed = await content.workspaceFiles(workspace.id);
    workspaceFileCounts[workspace.id] = refreshed.length;
    if (activeWorkspace?.id == workspace.id) {
      workspaceFiles = refreshed;
      workspaceFileContents = <String, String>{
        for (final file in workspaceFiles)
          file.id: await content.readWorkspaceFile(file),
      };
      workspaceCommits = await content.workspaceCommits(workspace.id);
      _notifyWorkspaceActivity(run);
    }
    return jsonEncode(<String, Object?>{'ok': true, 'result': receipt.toMap()});
  }

  Future<void> _continueAfterEditedUser() async {
    if (busy || messages.isEmpty) return;
    final profile = activeProfile;
    busy = true;
    _generationAbort = Completer<void>();
    _generationTimedOut = false;
    _pendingToolVoices.clear();
    streamingText = '';
    streamingReasoning = '';
    streamingToolProgress = null;
    streamingParts = <ChatCompletionPart>[];
    notifyListeners();
    String? diagnosticRequestId;
    try {
      final ChatCompletionResult result;
      if (localDemoMode) {
        final lastUser = messages.where((item) => item.role == 'user').last;
        result = await _localDemoReply(lastUser.content);
      } else {
        final requestContext = await _prepareConversationContext(profile!);
        diagnosticRequestId =
            'resend-${DateTime.now().toUtc().microsecondsSinceEpoch}';
        final diagnosticSink = _diagnosticSink(
          requestId: diagnosticRequestId,
          conversationId: activeConversation!.id,
        );
        _touchGenerationActivity();
        result = await api.chatWithTools(
          profile: profile,
          model: activeModel,
          messages: requestContext.messages,
          messagePartsByMessage: messagePartsByMessage,
          systemPrompt: requestContext.systemPrompt,
          systemPromptWithoutTools: requestContext.systemPromptWithoutTools,
          tools: settings['toolboxEnabled'] == false
              ? const <Map<String, Object?>>[]
              : enabledToolDefinitions.map((item) => item.toApi()).toList(),
          executeTool: (callId, name, arguments) async {
            final request = ToolRequest(
              callId: callId,
              name: name,
              arguments: arguments,
            );
            if (privateMode && name != 'get_time') {
              return jsonEncode(<String, Object?>{
                'ok': false,
                'tool': name,
                'error': '私密对话只允许使用 get_time',
              });
            }
            return _executeChatTool(request);
          },
          onText: (chunk) {
            _touchGenerationActivity();
            streamingText += chunk;
            _notifyChatActivity();
          },
          // Edited-and-resent messages must preserve the same reasoning
          // stream as a newly sent ordinary chat.
          onReasoning: (chunk) {
            _touchGenerationActivity();
            streamingReasoning += chunk;
            _notifyChatActivity();
          },
          onToolEvent: (part) {
            _touchGenerationActivity();
            streamingParts = <ChatCompletionPart>[...streamingParts, part];
            _notifyChatActivity();
          },
          onToolProgress: (part) {
            _touchGenerationActivity();
            streamingToolProgress = part;
            _notifyChatActivity();
          },
          onActivity: _touchGenerationActivity,
          diagnosticContext: <String, Object?>{
            'requestId': diagnosticRequestId,
            'conversationId': activeConversation!.id,
            'requestKind': 'edited_resend',
          },
          onDiagnostic: diagnosticSink,
          temperature: _modelDouble('temperature', 0.7),
          topP: _modelDouble('topP', 1),
          frequencyPenalty: _modelDouble('frequencyPenalty', 0),
          presencePenalty: _modelDouble('presencePenalty', 0),
          maxTokens: _modelInt('maxTokens', 4096),
          stream: _modelBool('stream', settings['stream'] != false),
          thinkingEnabled: settings['thinking'] != false,
          reasoningEffort: 'max',
          clearHistoricalReasoning: true,
          abortTrigger: _generationAbort!.future,
        );
      }
      final completedParts = _completionParts(result);
      if (privateMode) {
        final privateMessage = ChatMessage(
          id: 'private-${DateTime.now().microsecondsSinceEpoch}',
          conversationId: activeConversation!.id,
          sequence: messages.length + 1,
          role: 'assistant',
          content: result.text,
          metadataJson: jsonEncode(_completionMetadata(result)),
          createdAt: DateTime.now().toUtc(),
        );
        messages = <ChatMessage>[...messages, privateMessage];
        messagePartsByMessage[privateMessage.id] = _ephemeralParts(
          privateMessage.id,
          completedParts,
        );
      } else {
        final savedAssistant = await database.appendMessage(
          conversationId: activeConversation!.id,
          role: 'assistant',
          content: result.text,
          metadataJson: jsonEncode(_completionMetadata(result)),
          parts: completedParts,
        );
        await _persistPendingToolVoices(savedAssistant);
        messages = await database.messages(activeConversation!.id);
        await _loadMessageParts(activeConversation!.id);
      }
      await _notifyReplyIfBackground(result.text);
    } on Object catch (error) {
      _diagnosticSink(
        requestId: diagnosticRequestId,
        conversationId: activeConversation?.id,
      )?.call(<String, Object?>{
        'event': 'chat_request_failed',
        'requestKind': 'edited_resend',
        'error': '$error',
        'partialTextCharacters': streamingText.length,
        'partialReasoningCharacters': streamingReasoning.length,
      });
      if (_generationAbort?.isCompleted == true) {
        final detail = _generationTimedOut
            ? '请求超时：API 在等待时间内没有返回完整消息。'
            : '用户手动停止了消息生成。';
        notice = _generationTimedOut ? '请求超时' : '已停止生成';
        await _recordAssistantFailure(
          detail,
          statusType: 'return_failed',
          fallbackText: _generationTimedOut ? '请求超时' : '已停止',
        );
      } else {
        notice = '$error';
        await _recordAssistantFailure('$error');
      }
    } finally {
      busy = false;
      _generationTimeout?.cancel();
      _generationTimeout = null;
      _generationAbort = null;
      _generationTimedOut = false;
      streamingText = '';
      streamingReasoning = '';
      streamingParts = <ChatCompletionPart>[];
      streamingToolProgress = null;
      _pendingToolVoices.clear();
      notifyListeners();
    }
  }

  List<MessagePartInput> _completionParts(ChatCompletionResult result) =>
      <MessagePartInput>[
        ...result.parts
            .where(
              (part) =>
                  part.type != 'status' ||
                  !'${part.metadata['status'] ?? ''}'.startsWith('tool_'),
            )
            .map((part) => part.toInput()),
        MessagePartInput(
          type: 'status',
          metadata: <String, Object?>{
            'status': 'success',
            'detail': _successDetail(result),
            'usage': result.usage,
            'elapsedMs': result.elapsed.inMilliseconds,
          },
        ),
      ];

  Map<String, Object?> _completionMetadata(ChatCompletionResult result) =>
      <String, Object?>{
        'reasoning': result.parts
            .where((part) => part.type == 'thought')
            .map((part) => part.content ?? '')
            .where((value) => value.isNotEmpty)
            .join('\n\n'),
        'usage': result.usage,
        'elapsedMs': result.elapsed.inMilliseconds,
      };

  List<MessagePart> _ephemeralParts(
    String messageId,
    List<MessagePartInput> inputs,
  ) {
    final now = DateTime.now().toUtc();
    return inputs.indexed
        .map(
          (entry) => MessagePart(
            id: '$messageId-part-${entry.$1 + 1}',
            messageId: messageId,
            sequence: entry.$1 + 1,
            type: entry.$2.type,
            content: entry.$2.content,
            metadataJson: canonicalJson(entry.$2.metadata),
            createdAt: now,
          ),
        )
        .toList();
  }

  String _successDetail(ChatCompletionResult result) {
    final usage = result.usage;
    final values = formatCompletionUsage(usage);
    final seconds = (result.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    final summary = values.isEmpty ? 'API 未返回 usage' : values;
    final toolNames = result.parts
        .where((part) => part.type == 'tool')
        .map((part) => '${part.metadata['name'] ?? 'tool'}')
        .toList();
    final tools = toolNames.isEmpty ? '' : '\n工具：${toolNames.join(' → ')}';
    return '消息返回成功，$summary，响应：$seconds秒。$tools\n返回原文：usage ${jsonEncode(usage)}';
  }

  String _titleFrom(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return '新的对话';
    return compact.length <= 24 ? compact : '${compact.substring(0, 24)}…';
  }

  String _chatSystemPrompt({bool includeTools = true}) {
    final base = '${settings['systemPrompt'] ?? ''}'.trim();
    final toolboxPrompt = includeTools && settings['toolboxEnabled'] != false
        ? _toolboxSystemPrompt()
        : '';
    final unavailableToolPrompt =
        !includeTools && settings['toolboxEnabled'] != false
        ? _toolUnavailableSystemPrompt()
        : '';
    if (privateMode) {
      return <String>[
        if (base.isNotEmpty) base,
        if (toolboxPrompt.isNotEmpty) toolboxPrompt,
        if (unavailableToolPrompt.isNotEmpty) unavailableToolPrompt,
      ].join('\n\n');
    }
    final critical = memories
        .where((item) => item.level == 'critical' && item.deletedAt == null)
        .take(24)
        .toList();
    final prefix = <String>[
      if (base.isNotEmpty) base,
      if (toolboxPrompt.isNotEmpty) toolboxPrompt,
      if (unavailableToolPrompt.isNotEmpty) unavailableToolPrompt,
    ].join('\n\n');
    if (critical.isEmpty) return prefix;
    final memoryPrompt = <String>[
      '以下是用户标记为“关键”的本地记忆，会默认参与上下文。请自然使用，不要逐条复述：',
      ...critical.indexed.map(
        (entry) =>
            '${entry.$1 + 1}. [${entry.$2.id}] ${entry.$2.content}${entry.$2.tags.isEmpty ? '' : ' #${entry.$2.tags.join(' #')}'}',
      ),
    ].join('\n');
    return prefix.isEmpty ? memoryPrompt : '$prefix\n\n$memoryPrompt';
  }

  String _toolboxSystemPrompt() {
    if (privateMode) return '当前是私密对话。你只能使用 get_time 获取当前时间。';
    final availableVoices = voiceProfiles.isEmpty
        ? '当前没有已配置的语音接口；不要调用 generate_voice。'
        : '可用语音接口：${voiceProfiles.map((item) => '${item.name}（profileId=${item.id}）').join('、')}。';
    return <String>[
      '你可以按需使用内部工具箱。不要为了展示工具而调用工具；只有当工具能明显帮助回答或维护长期上下文时再用。',
      '关键记忆会自动出现在系统上下文中；important、daily、trivial、archived 等其它记忆默认不注入，需要你主动用 search_memory 搜索。',
      '记忆的ID是UUID（形如 a1b2c3d4-... 的长字符串），不是搜索结果列表中的数字序号。对记忆做 update_memory 或 delete_memory 之前，必须先用 search_memory 查出目标记忆的确切UUID，确认内容无误后再操作。绝对不要凭空构造ID。',
      '只有具有长期价值、用户明确表达的偏好、稳定事实或重要关系信息才适合 create_memory / update_memory。不要把每轮普通聊天都写成记忆。',
      'AI 日记是你自己的日记区：你可以 create_diary_entry 或 revise_diary_entry；需要回看时用 search_diary_entries / read_diary_entry。用户不能编辑正文。删除日记使用 request_delete_diary_entry 并提供删除原因。',
      '编辑文件请用 search_files 获取文件UUID；需要查看完整内容时用 read_file；然后用 edit_file 编辑、delete_file 删除（需提供UUID和删除原因）。',
      '本轮只有收到工具返回的 ok=true 及 result 回执，才算实际执行成功。历史消息里的文件ID、模型自己写出的ID或口头描述都不能证明本轮执行过工具。',
      '用户要求创建、编辑、删除或读取本地数据时，必须真实发起对应工具调用；没有收到本轮工具回执时，禁止声称操作成功。',
      'generate_voice 会把你要说的内容真正生成语音条并保存进 Ta的声音。仅在用户明确要听语音或语音表达明显更自然时使用，不要每轮都生成。$availableVoices',
    ].join('\n');
  }

  String _toolUnavailableSystemPrompt() =>
      '当前接口在本轮未提供可执行工具。你只能进行普通文本回复；不得声称已经创建、编辑、删除、读取或搜索任何本地数据，也不得编造文件ID、版本ID或工具执行结果。若用户要求操作数据，请明确说明本轮没有执行。';

  Future<_PreparedContext> _prepareConversationContext(
    ApiProfile profile,
  ) async {
    final budget = contextTokenBudget;
    final conversation = activeConversation;
    var systemPrompt = _chatSystemPrompt();
    var systemPromptWithoutTools = _chatSystemPrompt(includeTools: false);
    await _recordInjectedCriticalMemoryAccess();
    final approvalContext = _consumeResolvedApprovals();
    List<ChatMessage> appendApproval(List<ChatMessage> source) =>
        approvalContext.isEmpty
        ? source
        : <ChatMessage>[
            ...source,
            ChatMessage(
              id: 'approval-context-${DateTime.now().microsecondsSinceEpoch}',
              conversationId: conversation?.id ?? 'approval-context',
              sequence: source.length + 1,
              role: 'user',
              content: approvalContext,
              createdAt: DateTime.now().toUtc(),
            ),
          ];
    if (budget == null || conversation == null || privateMode) {
      return _PreparedContext(
        messages: appendApproval(messages),
        systemPrompt: systemPrompt,
        systemPromptWithoutTools: systemPromptWithoutTools,
        summarizedMessages: 0,
        droppedMessages: 0,
      );
    }

    var summary = conversation.accumulatedSummary?.trim() ?? '';
    var summarizedCount = conversation.summarizedMessageCount.clamp(
      0,
      messages.length,
    );
    final visible = messages.skip(summarizedCount).toList();
    final reserved =
        ContextBudget.estimateText(systemPrompt) +
        ContextBudget.estimateText(summary) +
        (_modelInt('maxTokens', 4096) ?? 4096).clamp(256, budget ~/ 2);
    final estimate =
        ContextBudget.estimateMessages(
          visible,
          extraTokens: _historicalToolExtraTokens,
        ) +
        reserved;
    if (estimate >= budget * .78) {
      final end = ContextBudget.summaryEndIndex(
        messages,
        summarizedCount: summarizedCount,
        budget: budget,
        extraTokens: _historicalToolExtraTokens,
      );
      if (end > summarizedCount) {
        final chunk = messages.sublist(summarizedCount, end);
        final generated = await _summarizeHistory(
          profile: profile,
          previousSummary: summary,
          chunk: chunk,
        );
        if (generated.isNotEmpty) {
          summary = generated;
          summarizedCount = end;
          await database.updateConversationSummary(
            conversation.id,
            summary: summary,
            summarizedMessageCount: summarizedCount,
            summaryFoldCount: conversation.summaryFoldCount + 1,
          );
          activeConversation = (await database.conversations())
              .where((item) => item.id == conversation.id)
              .firstOrNull;
        }
      }
    }

    final remaining = messages.skip(summarizedCount).toList();
    final trim = ContextBudget.trim(
      remaining,
      budget: budget,
      reservedTokens:
          ContextBudget.estimateText(systemPrompt) +
          ContextBudget.estimateText(summary) +
          (_modelInt('maxTokens', 4096) ?? 4096).clamp(256, budget ~/ 2),
      extraTokens: _historicalToolExtraTokens,
    );
    if (summary.isNotEmpty) {
      systemPrompt =
          '$systemPrompt\n\n以下是较早对话的累计摘要，请把它视为连续上下文，不要复述摘要本身：\n$summary';
      systemPromptWithoutTools =
          '$systemPromptWithoutTools\n\n以下是较早对话的累计摘要，请把它视为连续上下文，不要复述摘要本身：\n$summary';
    }
    if (trim.dropped > 0) {
      systemPrompt =
          '$systemPrompt\n\n由于上下文预算限制，本次又省略了 ${trim.dropped} 条较早消息。保留的最近消息优先。';
      systemPromptWithoutTools =
          '$systemPromptWithoutTools\n\n由于上下文预算限制，本次又省略了 ${trim.dropped} 条较早消息。保留的最近消息优先。';
    }
    return _PreparedContext(
      messages: appendApproval(trim.messages),
      systemPrompt: systemPrompt,
      systemPromptWithoutTools: systemPromptWithoutTools,
      summarizedMessages: summarizedCount,
      droppedMessages: trim.dropped,
    );
  }

  Future<void> _recordInjectedCriticalMemoryAccess() async {
    if (privateMode) return;
    final ids = memories
        .where((item) => item.level == 'critical' && item.deletedAt == null)
        .take(24)
        .map((item) => item.id)
        .toList(growable: false);
    if (ids.isEmpty) return;
    await content.recordMemoryAccesses(ids);
    memories = await content.memories(includeDeleted: true);
    notifyListeners();
  }

  int _historicalToolExtraTokens(ChatMessage message) {
    return _toolPartsExtraTokens(message, messagePartsByMessage);
  }

  int _workspaceHistoricalToolExtraTokens(ChatMessage message) {
    return _toolPartsExtraTokens(message, workspaceMessagePartsByMessage);
  }

  int _toolPartsExtraTokens(
    ChatMessage message,
    Map<String, List<MessagePart>> source,
  ) {
    final parts = source[message.id] ?? const <MessagePart>[];
    var total = 0;
    for (final part in parts.where((part) => part.type == 'tool')) {
      final arguments = part.metadata['arguments'];
      total +=
          16 +
          ContextBudget.estimateText(part.content ?? '') +
          ContextBudget.estimateText(
            arguments is String ? arguments : jsonEncode(arguments ?? const {}),
          );
    }
    return total;
  }

  String _summaryTranscriptMessage(ChatMessage message) {
    final role = message.role == 'user' ? '用户' : '助手';
    final tools = (messagePartsByMessage[message.id] ?? const <MessagePart>[])
        .where((part) => part.type == 'tool')
        .map((part) {
          final name = '${part.metadata['name'] ?? 'unknown_tool'}';
          final status = '${part.metadata['status'] ?? 'unknown'}';
          final compact = (part.content ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          final receipt = compact.length <= 600
              ? compact
              : '${compact.substring(0, 600)}…';
          return '工具 $name（$status）回执：$receipt';
        })
        .join('\n');
    return '$role：${message.content}${tools.isEmpty ? '' : '\n$tools'}';
  }

  Future<String> _summarizeHistory({
    required ApiProfile profile,
    required String previousSummary,
    required List<ChatMessage> chunk,
  }) async {
    final transcript = chunk.map(_summaryTranscriptMessage).join('\n\n');
    final prompt = <String>[
      '请把以下较早对话压缩成可供后续继续交流的中文事实摘要。',
      '必须保留：用户偏好、承诺、计划、未完成事项、关键事实、名字、日期和分歧。',
      '不要添加原文没有的信息，不要写寒暄，只返回摘要正文。',
      if (previousSummary.isNotEmpty) '已有累计摘要：\n$previousSummary',
      '本次新增对话：\n$transcript',
    ].join('\n\n');
    final buffer = StringBuffer();
    await for (final value in api.chat(
      profile: profile,
      model: activeModel,
      messages: <ChatMessage>[
        ChatMessage(
          id: 'summary-${DateTime.now().microsecondsSinceEpoch}',
          conversationId: activeConversation!.id,
          sequence: 1,
          role: 'user',
          content: prompt,
          createdAt: DateTime.now().toUtc(),
        ),
      ],
      systemPrompt: '你是严格的对话上下文压缩器。',
      temperature: .1,
      maxTokens: (_modelInt('maxTokens', 4096) ?? 4096).clamp(512, 4096),
      stream: false,
    )) {
      buffer.write(value);
    }
    return buffer.toString().trim();
  }

  Object? _modelValue(String key, Object? fallback) {
    final slot = activeModelSlot;
    if (slot != null && slot.containsKey(key)) return slot[key];
    final config = activeModelConfig;
    return config != null && config.containsKey(key) ? config[key] : fallback;
  }

  double? _modelDouble(String key, double fallback) {
    final value = _modelValue(key, settings[key] ?? fallback);
    return value == null ? null : (value as num).toDouble();
  }

  int? _modelInt(String key, int fallback) {
    final value = _modelValue(key, settings[key] ?? fallback);
    return value == null ? null : (value as num).toInt();
  }

  bool _modelBool(String key, bool fallback) =>
      _modelValue(key, fallback) != false;

  int? get contextTokenBudget => ContextBudget.normalizeBudget(
    _modelValue('contextTokens', settings['contextTokens']),
  );

  int get estimatedInputTokens {
    for (final message in messages.reversed) {
      final persisted = _messageMetadataInt(message, 'contextInputTokens');
      if (persisted != null) return persisted;
    }
    final conversation = activeConversation;
    final start =
        conversation?.summarizedMessageCount.clamp(0, messages.length) ?? 0;
    return ContextBudget.estimateMessages(messages.skip(start)) +
        messages
            .skip(start)
            .fold<int>(
              0,
              (total, message) => total + _historicalToolExtraTokens(message),
            ) +
        ContextBudget.estimateText(conversation?.accumulatedSummary ?? '') +
        ContextBudget.estimateText(_chatSystemPrompt());
  }

  int get estimatedOutputTokens => messages
      .where((message) => message.role == 'assistant')
      .fold<int>(0, (total, message) {
        final persisted = _messageMetadataInt(message, 'estimatedTokens');
        return total +
            (persisted ?? ContextBudget.estimateText(message.content));
      });

  int? _messageMetadataInt(ChatMessage message, String key) {
    try {
      final metadata = jsonDecode(message.metadataJson);
      final value = metadata is Map ? metadata[key] : null;
      return value is num ? value.round() : null;
    } on FormatException {
      return null;
    }
  }

  void _handleNotificationPayload(String payload) {
    const prefix = 'conversation:';
    if (!payload.startsWith(prefix)) return;
    final id = payload.substring(prefix.length);
    final conversation = conversations
        .where((item) => item.id == id)
        .firstOrNull;
    if (conversation != null) unawaited(selectConversation(conversation));
  }

  Future<void> _notifyReplyIfBackground(String reply) async {
    if (privateMode || settings['replyNotifications'] == false) return;
    final lifecycle = SchedulerBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) return;
    final conversation = activeConversation;
    if (conversation == null || reply.trim().isEmpty) return;
    final compact = reply.replaceAll(RegExp(r'\s+'), ' ').trim();
    final body = compact.length <= 120
        ? compact
        : '${compact.substring(0, 120)}…';
    try {
      await platform.showChatReplyNotification(
        id: conversation.id.hashCode & 0x7fffffff,
        title: conversation.title,
        body: body,
        conversationId: conversation.id,
      );
    } on Object {
      // A denied permission or unavailable platform notification service must
      // never turn a successfully completed chat response into a failed one.
    }
  }

  Future<String> _executeChatTool(ToolRequest request) async {
    // Preserve the legacy private-chat boundary even if a provider returns a
    // tool call that was not present in the advertised tool list.
    if (privateMode && request.name != 'get_time') {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'tool': request.name,
        'error': '私密对话只允许使用 get_time',
      });
    }
    if (request.name == 'generate_voice') {
      return _generateToolVoice(request);
    }
    final definition = tools.definition(request.name);
    if (definition?.requiresApproval == true) {
      requestToolApproval(request);
      return jsonEncode(<String, Object?>{
        'ok': true,
        'pendingApproval': request.callId,
        'label': definition?.label ?? request.name,
      });
    }
    final raw = await tools.execute(
      request,
      approved: true,
      conversationId: activeConversation?.id,
    );
    final decoded = _decodeToolOutput(raw);
    if (decoded is Map && decoded['error'] != null) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'tool': request.name,
        'error': '${decoded['error']}',
      });
    }
    final validationError = _toolResultValidationError(request.name, decoded);
    if (validationError != null) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'tool': request.name,
        'error': validationError,
      });
    }
    Object? confirmedResult = decoded;
    if (request.name == 'create_file' || request.name == 'edit_file') {
      if (decoded is! Map ||
          decoded['verified'] != true ||
          '${decoded['id'] ?? ''}'.trim().isEmpty ||
          '${decoded['versionId'] ?? ''}'.trim().isEmpty) {
        return jsonEncode(<String, Object?>{
          'ok': false,
          'tool': request.name,
          'error': '文件写入回执不完整：缺少文件ID、版本ID或完整性证明',
        });
      }
      final fileId = '${decoded['id']}'.trim();
      confirmedResult = <String, Object?>{
        ...decoded.cast<String, Object?>(),
        'fileId': fileId,
        'confirmedByRepository': true,
      };
      await _refreshAfterVerifiedFileWrite(fileId);
    } else {
      await reload();
    }
    _captureToolNotification(request, jsonEncode(confirmedResult));
    return jsonEncode(<String, Object?>{
      'ok': true,
      'tool': request.name,
      'result': confirmedResult,
    });
  }

  Future<String> _generateToolVoice(ToolRequest request) async {
    final text = '${request.arguments['text'] ?? ''}'.trim();
    if (text.isEmpty) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'tool': request.name,
        'error': '语音内容不能为空',
      });
    }
    final requestedId = '${request.arguments['profileId'] ?? ''}'.trim();
    final profile = requestedId.isEmpty
        ? activeVoiceProfile
        : voiceProfiles.where((item) => item.id == requestedId).firstOrNull;
    if (profile == null) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'tool': request.name,
        'error': requestedId.isEmpty ? '请先配置语音接口' : '指定的语音接口不存在',
      });
    }
    try {
      final generated = await voice.synthesize(
        profile: profile,
        apiKey: await voice.vault.readVoiceApiKey(profile.id) ?? '',
        text: text,
        abortTrigger: _generationAbort?.future,
      );
      _pendingToolVoices.add(
        _PendingToolVoice(
          callId: request.callId,
          text: text,
          profile: profile,
          generated: generated,
        ),
      );
      return jsonEncode(<String, Object?>{
        'generated': true,
        'profileId': profile.id,
        'profileName': profile.name,
        'text': text,
      });
    } on Object catch (error) {
      return jsonEncode(<String, Object?>{
        'ok': false,
        'tool': request.name,
        'error': '$error',
      });
    }
  }

  Future<void> _persistPendingToolVoices(ChatMessage message) async {
    if (_pendingToolVoices.isEmpty) return;
    try {
      for (var index = 0; index < _pendingToolVoices.length; index++) {
        final pending = _pendingToolVoices[index];
        await voice.persistGenerated(
          messageId: message.id,
          conversationId: message.conversationId,
          text: pending.text,
          profile: pending.profile,
          generated: pending.generated,
          bind: index == _pendingToolVoices.length - 1,
        );
      }
      voiceAssets = await voice.assets();
      notifyListeners();
    } on Object catch (error) {
      notice = '语音已经生成，但保存语音条失败：$error';
      notifyListeners();
    }
  }

  Future<void> _refreshAfterVerifiedFileWrite(String fileId) async {
    try {
      files = await content.files(includeDeleted: true);
      notifyListeners();
    } on Object catch (error, stackTrace) {
      debugPrint('Verified file saved but file list refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    final mirror = portableData;
    if (mirror == null) return;
    unawaited(
      mirror.syncUserFile(fileId).catchError((Object error, StackTrace stack) {
        debugPrint(
          'Verified file saved but portable mirror sync failed: $error',
        );
        debugPrintStack(stackTrace: stack);
      }),
    );
  }

  Object? _decodeToolOutput(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  String? _toolResultValidationError(String name, Object? decoded) {
    if (decoded is! Map) return '工具没有返回可验证的结构化结果';
    bool hasText(String key) => '${decoded[key] ?? ''}'.trim().isNotEmpty;
    bool hasList(String key) => decoded[key] is List;
    final valid = switch (name) {
      'get_time' => hasText('iso') && hasText('local'),
      'search_memory' => hasList('matches'),
      'create_memory' || 'update_memory' => hasText('id'),
      'delete_memory' => hasText('id') && hasText('deletedAt'),
      'create_diary_entry' ||
      'revise_diary_entry' => hasText('id') && hasText('latestVersionId'),
      'request_delete_diary_entry' ||
      'delete_diary_entry' => hasText('id') && decoded['status'] == 'deleted',
      'search_diary_entries' => hasList('matches'),
      'read_diary_entry' => hasText('id') && hasList('versions'),
      'search_files' => hasList('matches'),
      'read_file' => hasText('id') && decoded.containsKey('content'),
      'create_file' || 'edit_file' =>
        decoded['verified'] == true &&
            hasText('id') &&
            hasText('versionId') &&
            hasText('sha256'),
      'delete_file' => hasText('id') && hasText('action'),
      'web_search' => hasText('query') && hasList('results'),
      'fetch_url' => hasText('url') && decoded.containsKey('content'),
      'set_greeting' => hasText('greeting'),
      'set_splash_phrases' => hasText('phrases'),
      'generate_voice' => decoded['generated'] == true && hasText('profileId'),
      'create_calendar_event' ||
      'schedule_notification' ||
      'create_system_reminder' => decoded['created'] == true,
      'update_home_widget' => decoded['updated'] == true,
      _ => false,
    };
    return valid ? null : '工具返回结果未通过完成性校验，操作不能判定为成功';
  }

  void requestToolApproval(ToolRequest request) {
    _pendingToolApprovals[request.callId] = request;
    pendingToolApproval = null;
    approvalDialogRequested = false;
    final itemName = _notificationLabel(
      request.arguments['name'] ??
          request.arguments['title'] ??
          (request.name == 'delete_memory'
              ? memories
                    .where((item) => item.id == request.arguments['id'])
                    .firstOrNull
                    ?.content
              : request.arguments['content']),
    );
    final noun = switch (request.name) {
      'delete_memory' => '记忆',
      'delete_file' => '文件',
      'request_delete_diary_entry' || 'delete_diary_entry' => '日记',
      _ => '一条内容',
    };
    _pushNotification(
      type: AppNoticeType.danger,
      text:
          '小机子请求${request.name.startsWith('delete_') ? '删除$noun' : '执行${_toolNoticeVerb(request.name)}'}${itemName.isEmpty ? '' : '“$itemName”'}',
      approval: request,
    );
    notifyListeners();
  }

  void toggleNotifications() {
    if (actionableNotifications.isEmpty) return;
    notificationsOpen = !notificationsOpen;
    _expandedNotificationIds = notificationsOpen
        ? actionableNotifications.map((item) => item.id).toList()
        : <String>[];
    notifyListeners();
  }

  List<AppNotice> get actionableNotifications {
    final items = notifications
        .where((item) => item.approval != null || item.target != null)
        .toList();
    items.sort((left, right) {
      if (left.isApproval != right.isApproval) {
        return left.isApproval ? -1 : 1;
      }
      return right.createdAt.compareTo(left.createdAt);
    });
    return List<AppNotice>.unmodifiable(items);
  }

  List<AppNotice> get expandedActionableNotifications {
    if (!notificationsOpen) return const <AppNotice>[];
    final byId = <String, AppNotice>{
      for (final item in actionableNotifications) item.id: item,
    };
    return _expandedNotificationIds
        .map((id) => byId[id])
        .whereType<AppNotice>()
        .toList(growable: false);
  }

  void activateNotification(AppNotice item) {
    notificationsOpen = false;
    _expandedNotificationIds = <String>[];
    if (item.approval != null) {
      final pending = _pendingToolApprovals[item.approval!.callId];
      if (pending == null) {
        notifications = notifications
            .where((notice) => notice.id != item.id)
            .toList();
        notice = '这条审批已经处理或失效';
      } else {
        pendingToolApproval = pending;
        approvalDialogRequested = true;
      }
      notifyListeners();
      return;
    }
    if (item.target != null) {
      final returnConversationId = section == AppSection.chat
          ? activeConversation?.id
          : null;
      final returnScrollOffset = returnConversationId == null
          ? null
          : _chatViewportOffsets[returnConversationId];
      final returnScrollable = returnConversationId == null
          ? null
          : _chatViewportScrollable[returnConversationId];
      notifications = notifications
          .where((notice) => notice.target != item.target)
          .toList();
      section = item.target!;
      final entryId = item.entryId?.trim() ?? '';
      final navigation = entryId.isEmpty
          ? null
          : AppNoticeNavigation(
              serial: ++_noticeNavigationSerial,
              target: item.target!,
              entryId: entryId,
              returnConversationId: returnConversationId,
              returnScrollOffset: returnScrollOffset,
              returnScrollable: returnScrollable,
            );
      pendingNoticeNavigation = navigation;
      activeNoticeNavigation = navigation?.canReturnToChat == true
          ? navigation
          : null;
    } else {
      notifications = notifications
          .where((notice) => notice.id != item.id)
          .toList();
    }
    notifyListeners();
  }

  void completeNoticeNavigation(int serial) {
    if (pendingNoticeNavigation?.serial == serial) {
      pendingNoticeNavigation = null;
    }
  }

  Future<void> resolveToolApproval(bool approved) async {
    final request = pendingToolApproval;
    final callId = pendingToolApproval?.callId;
    pendingToolApproval = null;
    approvalDialogRequested = false;
    if (callId != null) {
      notifications = notifications
          .where((notice) => notice.approval?.callId != callId)
          .toList();
    }
    if (request != null) {
      _pendingToolApprovals.remove(request.callId);
      final resolved = _ResolvedToolApproval(
        request: request,
        approved: approved,
        resolvedAt: DateTime.now().toUtc(),
      );
      _resolvedToolApprovals.add(resolved);
      if (approved) {
        final raw = await tools.execute(
          request,
          approved: true,
          conversationId: activeConversation?.id,
        );
        resolved.executedResult = _decodeToolOutput(raw);
        _captureToolNotification(request, raw);
        await reload();
      }
    }
    notifyListeners();
  }

  void _cancelPendingToolApprovals() {
    for (final request in _pendingToolApprovals.values) {
      _resolvedToolApprovals.add(
        _ResolvedToolApproval(
          request: request,
          approved: false,
          resolvedAt: DateTime.now().toUtc(),
        ),
      );
    }
    _pendingToolApprovals.clear();
    pendingToolApproval = null;
    approvalDialogRequested = false;
    notifications = notifications
        .where((item) => item.approval == null)
        .toList();
  }

  String _consumeResolvedApprovals() {
    if (_resolvedToolApprovals.isEmpty) return '';
    final items = <_ResolvedToolApproval>[..._resolvedToolApprovals];
    _resolvedToolApprovals.clear();
    return items
        .map((item) {
          final definition = tools.definition(item.request.name);
          final name = definition?.label ?? item.request.name;
          if (item.approved) {
            final result = item.executedResult == null
                ? '已执行'
                : jsonEncode(item.executedResult);
            return '系统通知：你之前请求的"$name"操作已被用户批准（审批ID: ${item.request.callId}）。执行结果：$result';
          }
          return '系统通知：你之前请求的"$name"操作已被用户拒绝（审批ID: ${item.request.callId}），请不要再重复此操作。';
        })
        .join('\n');
  }

  void _captureToolNotification(ToolRequest request, String rawResult) {
    Object? decoded;
    try {
      decoded = jsonDecode(rawResult);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map && decoded['error'] != null) return;
    final result = decoded is Map ? decoded.cast<Object?, Object?>() : const {};
    final value = _notificationLabel(
      result['name'] ??
          result['title'] ??
          result['content'] ??
          request.arguments['name'] ??
          request.arguments['title'] ??
          request.arguments['content'],
    );
    final id = '${result['id'] ?? request.arguments['id'] ?? ''}';
    final mapping = switch (request.name) {
      'create_memory' => (AppNoticeType.info, '创建了 ', AppSection.memories),
      'update_memory' => (AppNoticeType.info, '编辑了 ', AppSection.memories),
      'create_diary_entry' => (
        AppNoticeType.notice,
        '写了一篇日记',
        AppSection.diary,
      ),
      'revise_diary_entry' => (AppNoticeType.notice, '修订了日记', AppSection.diary),
      'request_delete_diary_entry' ||
      'delete_diary_entry' => (AppNoticeType.notice, '删除了日记', AppSection.diary),
      'create_file' => (AppNoticeType.info, '创建了文件', AppSection.files),
      'read_file' => (AppNoticeType.info, '读取了文件', AppSection.files),
      'edit_file' => (AppNoticeType.info, '编辑了文件', AppSection.files),
      'delete_file' => (AppNoticeType.info, '删除了文件', AppSection.files),
      _ => null,
    };
    if (mapping == null) return;
    _pushNotification(
      type: mapping.$1,
      text: '小机子${mapping.$2}${value.isEmpty ? '' : '“$value”'}',
      target: mapping.$3,
      entryId: id,
    );
  }

  void _pushNotification({
    required AppNoticeType type,
    required String text,
    AppSection? target,
    String? entryId,
    ToolRequest? approval,
  }) {
    final createdAt = DateTime.now();
    final item = AppNotice(
      id: 'notice-${createdAt.microsecondsSinceEpoch}-${_noticeIdSerial++}',
      type: type,
      text: text,
      createdAt: createdAt,
      target: target,
      entryId: entryId,
      approval: approval,
    );
    notifications =
        <AppNotice>[
          item,
          ...notifications.where((notice) => notice.id != item.id),
        ].take(20).toList()..sort((left, right) {
          final leftAction = left.approval != null ? 0 : 1;
          final rightAction = right.approval != null ? 0 : 1;
          if (leftAction != rightAction) return leftAction - rightAction;
          return right.createdAt.compareTo(left.createdAt);
        });
  }

  String _notificationLabel(Object? value) {
    final text = '$value'.trim();
    if (text.isEmpty || text == 'null') return '';
    return text.length <= 30 ? text : text.substring(0, 30);
  }

  String _toolNoticeVerb(String name) => switch (name) {
    'create_calendar_event' => '创建系统日程',
    'schedule_notification' => '创建本地通知',
    'create_system_reminder' => '创建系统提醒事项',
    'update_home_widget' => '更新桌面小组件',
    _ => name,
  };

  Future<void> pickAttachments({
    ConfirmLargeAttachmentSelection? confirmLargeSelection,
  }) async {
    await _pickAttachments(
      () => attachments.pickAndStore(
        confirmLargeSelection: confirmLargeSelection,
      ),
    );
  }

  Future<void> captureAttachment({
    ConfirmLargeAttachmentSelection? confirmLargeSelection,
  }) async {
    await _pickAttachments(
      () => attachments.captureImageAndStore(
        confirmLargeSelection: confirmLargeSelection,
      ),
    );
  }

  Future<void> pickPhotoAttachments({
    ConfirmLargeAttachmentSelection? confirmLargeSelection,
  }) async {
    await _pickAttachments(
      () => attachments.pickImagesAndStore(
        confirmLargeSelection: confirmLargeSelection,
      ),
    );
  }

  Future<void> _pickAttachments(
    Future<List<PendingAttachment>> Function() picker,
  ) async {
    if (privateMode) {
      notice = '私密对话不会写入磁盘，因此不能添加本机附件';
      notifyListeners();
      return;
    }
    try {
      pendingAttachments = <PendingAttachment>[
        ...pendingAttachments,
        ...await picker(),
      ];
      notifyListeners();
    } on Object catch (error) {
      notice = '$error';
      notifyListeners();
    }
  }

  void removeAttachment(PendingAttachment value) {
    pendingAttachments = pendingAttachments
        .where((item) => item.id != value.id)
        .toList();
    notifyListeners();
  }

  Future<String> exportBackup({
    required String password,
    required bool includeSecrets,
  }) async {
    final bytes = await backups.export(
      password: password.isEmpty ? null : password,
      includeSecrets: includeSecrets,
    );
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.-]'), '')
        .substring(0, 15);
    final path =
        '${paths.temp.path}${Platform.pathSeparator}ClaudeChat_$stamp.claudechat';
    await File(path).writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(path)], title: 'ClaudeChat 数据备份'),
    );
    return path;
  }

  Future<ImportReport?> pickAndImport({String? password}) async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'Claude Chat 备份',
          extensions: <String>['claudechat', 'json'],
          mimeTypes: <String>['application/octet-stream', 'application/json'],
          uniformTypeIdentifiers: <String>['public.data', 'public.json'],
        ),
      ],
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    final report = legacy.recognizes(bytes)
        ? await legacy.import(bytes)
        : await backups.import(bytes, password: password);
    await legacy.repairLegacyToolParts();
    await brand.loadSavedFont();
    await reload();
    return report;
  }

  Future<void> saveSetting(String key, Object? value) async {
    await settingsService.set(key, value);
    settings[key] = value;
    // Dialogs, dropdowns and text fields leave the overlay tree at the end of
    // a frame. Rebuilding MaterialApp during that teardown can trip Flutter's
    // InheritedElement `_dependents.isEmpty` assertion. Commit first, then
    // notify after the route/input teardown frame has completed.
    await SchedulerBinding.instance.endOfFrame;
    notifyListeners();
  }

  Future<void> persistSetting(String key, Object? value) =>
      settingsService.set(key, value);

  DiagnosticSink? _diagnosticSink({
    required String? requestId,
    required String? conversationId,
  }) {
    if (settings['diagnosticsEnabled'] == false) return null;
    return (event) {
      unawaited(
        diagnostics
            .record(<String, Object?>{
              'requestId': ?requestId,
              'conversationId': ?conversationId,
              ...event,
            })
            .catchError((Object _) {}),
      );
    };
  }

  Future<List<Map<String, Object?>>> diagnosticEntries({int limit = 300}) =>
      diagnostics.entries(limit: limit);

  Future<String> diagnosticText({int limit = 300}) async {
    final values = await diagnosticEntries(limit: limit);
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(values.reversed.toList(growable: false));
  }

  Future<String> shareDiagnostics() async {
    final path = await diagnostics.export(destination: paths.temp);
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(path)], title: 'ClaudeChat 脱敏诊断日志'),
    );
    return path;
  }

  Future<void> clearDiagnostics() => diagnostics.clear();

  Future<List<String>> fetchModels(ApiProfile profile) => api.models(profile);

  Future<void> deleteProfile(ApiProfile profile) async {
    await settingsService.deleteProfile(profile.id);
    final activeWasRemoved = activeProfile?.id == profile.id;
    await reload();
    if (activeWasRemoved) {
      await saveSetting('activeModelId', activeProfile?.models.firstOrNull);
    }
  }

  Future<void> installCustomFont() async {
    try {
      await brand.pickAndInstallFont();
      await reload();
    } on Object catch (error) {
      notice = '$error';
      notifyListeners();
    }
  }

  Future<void> resetCustomFont() async {
    try {
      await brand.resetFont();
      await reload();
    } on Object catch (error) {
      notice = '$error';
      notifyListeners();
    }
  }

  Future<void> installCustomIcon() async {
    try {
      await brand.pickAndInstallIcon();
      await reload();
    } on Object catch (error) {
      notice = '$error';
      notifyListeners();
    }
  }

  Future<void> disposeResources() => database.close();
}

class _PreparedContext {
  const _PreparedContext({
    required this.messages,
    required this.systemPrompt,
    required this.systemPromptWithoutTools,
    required this.summarizedMessages,
    required this.droppedMessages,
  });

  final List<ChatMessage> messages;
  final String systemPrompt;
  final String systemPromptWithoutTools;
  final int summarizedMessages;
  final int droppedMessages;
}

class _ResolvedToolApproval {
  _ResolvedToolApproval({
    required this.request,
    required this.approved,
    required this.resolvedAt,
  });

  final ToolRequest request;
  final bool approved;
  final DateTime resolvedAt;
  Object? executedResult;
}
