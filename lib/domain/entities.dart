import 'dart:convert';

Map<String, Object?> canonicalize(Map<String, Object?> source) {
  final keys = source.keys.toList()..sort();
  return <String, Object?>{
    for (final key in keys)
      key: switch (source[key]) {
        Map value => canonicalize(value.cast<String, Object?>()),
        List value =>
          value
              .map(
                (item) => item is Map
                    ? canonicalize(item.cast<String, Object?>())
                    : item,
              )
              .toList(),
        final value => value,
      },
  };
}

String canonicalJson(Map<String, Object?> source) =>
    jsonEncode(canonicalize(source));

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.modelId,
    this.starred = false,
    this.accumulatedSummary,
    this.summarizedMessageCount = 0,
    this.summaryFoldCount = 0,
    this.archivedAt,
    this.deletedAt,
    this.revision = 1,
    this.originDeviceId = '',
  });

  final String id;
  final String title;
  final String? modelId;
  final bool starred;
  final String? accumulatedSummary;
  final int summarizedMessageCount;
  final int summaryFoldCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? archivedAt;
  final DateTime? deletedAt;
  final int revision;
  final String originDeviceId;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'title': title,
    'model_id': modelId,
    'is_starred': starred ? 1 : 0,
    'accumulated_summary': accumulatedSummary,
    'summarized_message_count': summarizedMessageCount,
    'summary_fold_count': summaryFoldCount,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'archived_at': archivedAt?.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'revision': revision,
    'origin_device_id': originDeviceId,
  };

  factory Conversation.fromMap(Map<String, Object?> map) => Conversation(
    id: map['id']! as String,
    title: (map['title'] as String?) ?? '新的对话',
    modelId: map['model_id'] as String?,
    starred: map['is_starred'] == 1 || map['is_starred'] == true,
    accumulatedSummary: map['accumulated_summary'] as String?,
    summarizedMessageCount:
        (map['summarized_message_count'] as num?)?.toInt() ?? 0,
    summaryFoldCount: (map['summary_fold_count'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
    archivedAt: map['archived_at'] == null
        ? null
        : DateTime.parse(map['archived_at']! as String),
    deletedAt: map['deleted_at'] == null
        ? null
        : DateTime.parse(map['deleted_at']! as String),
    revision: (map['revision'] as num?)?.toInt() ?? 1,
    originDeviceId: (map['origin_device_id'] as String?) ?? '',
  );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.sequence,
    required this.role,
    required this.content,
    required this.createdAt,
    this.status = 'complete',
    this.error,
    this.metadataJson = '{}',
    this.updatedAt,
    this.deletedAt,
    this.revision = 1,
    this.originDeviceId = '',
  });

  final String id;
  final String conversationId;
  final int sequence;
  final String role;
  final String content;
  final String status;
  final String? error;
  final String metadataJson;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  final int revision;
  final String originDeviceId;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'conversation_id': conversationId,
    'sequence': sequence,
    'role': role,
    'content': content,
    'status': status,
    'error': error,
    'metadata_json': metadataJson,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'revision': revision,
    'origin_device_id': originDeviceId,
  };

  factory ChatMessage.fromMap(Map<String, Object?> map) => ChatMessage(
    id: map['id']! as String,
    conversationId: map['conversation_id']! as String,
    sequence: (map['sequence'] as num).toInt(),
    role: map['role']! as String,
    content: (map['content'] as String?) ?? '',
    status: (map['status'] as String?) ?? 'complete',
    error: map['error'] as String?,
    metadataJson: (map['metadata_json'] as String?) ?? '{}',
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: map['updated_at'] == null
        ? null
        : DateTime.parse(map['updated_at']! as String),
    deletedAt: map['deleted_at'] == null
        ? null
        : DateTime.parse(map['deleted_at']! as String),
    revision: (map['revision'] as num?)?.toInt() ?? 1,
    originDeviceId: (map['origin_device_id'] as String?) ?? '',
  );
}

/// One ordered, durable fragment of a chat message.
///
/// The web application can interleave reasoning, tool calls, delivery states,
/// and visible content. Keeping those fragments as rows (rather than flattening
/// everything into [ChatMessage.content]) lets the mobile UI reproduce that
/// order and keeps export/import lossless.
class MessagePart {
  const MessagePart({
    required this.id,
    required this.messageId,
    required this.sequence,
    required this.type,
    required this.createdAt,
    this.content,
    this.metadataJson = '{}',
  });

  final String id;
  final String messageId;
  final int sequence;
  final String type;
  final String? content;
  final String metadataJson;
  final DateTime createdAt;

  Map<String, Object?> get metadata {
    try {
      final value = jsonDecode(metadataJson);
      return value is Map
          ? value.cast<String, Object?>()
          : const <String, Object?>{};
    } on Object {
      return const <String, Object?>{};
    }
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'message_id': messageId,
    'sequence': sequence,
    'type': type,
    'content': content,
    'metadata_json': metadataJson,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory MessagePart.fromMap(Map<String, Object?> map) => MessagePart(
    id: map['id']! as String,
    messageId: map['message_id']! as String,
    sequence: (map['sequence'] as num).toInt(),
    type: map['type']! as String,
    content: map['content'] as String?,
    metadataJson: (map['metadata_json'] as String?) ?? '{}',
    createdAt: DateTime.parse(map['created_at']! as String),
  );
}

class MessagePartInput {
  const MessagePartInput({
    required this.type,
    this.content,
    this.metadata = const <String, Object?>{},
  });

  final String type;
  final String? content;
  final Map<String, Object?> metadata;
}

class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.content,
    required this.level,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
    this.source = 'user',
    this.sourceConversationId,
    this.lastAccessedAt,
    this.useFrequency = 0,
    this.deletedAt,
    this.deleteReason,
    this.revision = 1,
    this.originDeviceId = '',
  });

  final String id;
  final String content;
  final String level;
  final List<String> tags;
  final String source;
  final String? sourceConversationId;
  final DateTime? lastAccessedAt;
  final int useFrequency;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final String? deleteReason;
  final int revision;
  final String originDeviceId;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'content': content,
    'level': level,
    'tags_json': jsonEncode(tags),
    'source': source,
    'source_conversation_id': sourceConversationId,
    'last_accessed_at': lastAccessedAt?.toUtc().toIso8601String(),
    'use_frequency': useFrequency,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'delete_reason': deleteReason,
    'revision': revision,
    'origin_device_id': originDeviceId,
  };

  factory MemoryEntry.fromMap(Map<String, Object?> map) => MemoryEntry(
    id: map['id']! as String,
    content: (map['content'] as String?) ?? '',
    level: (map['level'] as String?) ?? 'daily',
    tags: ((jsonDecode((map['tags_json'] as String?) ?? '[]')) as List)
        .cast<String>(),
    source: (map['source'] as String?) ?? 'user',
    sourceConversationId: map['source_conversation_id'] as String?,
    lastAccessedAt: map['last_accessed_at'] == null
        ? null
        : DateTime.parse(map['last_accessed_at']! as String),
    useFrequency: (map['use_frequency'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
    deletedAt: map['deleted_at'] == null
        ? null
        : DateTime.parse(map['deleted_at']! as String),
    deleteReason: map['delete_reason'] as String?,
    revision: (map['revision'] as num?)?.toInt() ?? 1,
    originDeviceId: (map['origin_device_id'] as String?) ?? '',
  );
}

class DiaryEntry {
  const DiaryEntry({
    required this.id,
    required this.title,
    required this.status,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
    this.mood,
    this.latestVersionId,
    this.sourceConversationId,
    this.deletedAt,
    this.deleteReason,
    this.revision = 1,
    this.originDeviceId = '',
  });

  final String id;
  final String title;
  final String status;
  final String? mood;
  final List<String> tags;
  final String? latestVersionId;
  final String? sourceConversationId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final String? deleteReason;
  final int revision;
  final String originDeviceId;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'title': title,
    'status': status,
    'mood': mood,
    'tags_json': jsonEncode(tags),
    'latest_version_id': latestVersionId,
    'source_conversation_id': sourceConversationId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'delete_reason': deleteReason,
    'revision': revision,
    'origin_device_id': originDeviceId,
  };

  factory DiaryEntry.fromMap(Map<String, Object?> map) => DiaryEntry(
    id: map['id']! as String,
    title: (map['title'] as String?) ?? '未命名日记',
    status: (map['status'] as String?) ?? 'active',
    mood: map['mood'] as String?,
    tags: ((jsonDecode((map['tags_json'] as String?) ?? '[]')) as List)
        .cast<String>(),
    latestVersionId: map['latest_version_id'] as String?,
    sourceConversationId: map['source_conversation_id'] as String?,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
    deletedAt: map['deleted_at'] == null
        ? null
        : DateTime.parse(map['deleted_at']! as String),
    deleteReason: map['delete_reason'] as String?,
    revision: (map['revision'] as num?)?.toInt() ?? 1,
    originDeviceId: (map['origin_device_id'] as String?) ?? '',
  );
}

class DiaryVersion {
  const DiaryVersion({
    required this.id,
    required this.diaryId,
    required this.title,
    required this.content,
    required this.operation,
    required this.tags,
    required this.createdAt,
    this.reason,
    this.mood,
    this.sourceConversationId,
    this.originDeviceId = '',
  });

  final String id;
  final String diaryId;
  final String title;
  final String content;
  final String operation;
  final String? reason;
  final String? mood;
  final List<String> tags;
  final String? sourceConversationId;
  final DateTime createdAt;
  final String originDeviceId;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'diary_id': diaryId,
    'title': title,
    'content': content,
    'operation': operation,
    'reason': reason,
    'mood': mood,
    'tags_json': jsonEncode(tags),
    'source_conversation_id': sourceConversationId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'origin_device_id': originDeviceId,
  };
}

class ImportReport {
  ImportReport({
    this.added = 0,
    this.skipped = 0,
    this.updated = 0,
    this.conflicts = 0,
    this.failed = 0,
  });

  int added;
  int skipped;
  int updated;
  int conflicts;
  int failed;

  Map<String, Object?> toJson() => <String, Object?>{
    'added': added,
    'skipped': skipped,
    'updated': updated,
    'conflicts': conflicts,
    'failed': failed,
  };
}
