import 'dart:convert';

import '../domain/entities.dart';

enum MergeAction { add, skip, replaceLocal, preserveBoth, applyTombstone }

class MergeDecision {
  const MergeDecision(this.action, {this.reason = ''});

  final MergeAction action;
  final String reason;
}

class MergePolicy {
  const MergePolicy();

  static const immutableTables = <String>{
    'message_parts',
    'workspace_message_parts',
    'workspace_commits',
    'workspace_commit_files',
    'diary_versions',
    'file_versions',
    'attachment_references',
    'entity_revisions',
  };

  MergeDecision decide({
    required String table,
    required Map<String, Object?>? local,
    required Map<String, Object?> incoming,
  }) {
    if (local == null) return const MergeDecision(MergeAction.add);
    if (_same(local, incoming))
      return const MergeDecision(MergeAction.skip, reason: 'identical');
    if (local['deleted_at'] != null && incoming['deleted_at'] == null) {
      return const MergeDecision(
        MergeAction.replaceLocal,
        reason: 'explicit re-import restores locally deleted record',
      );
    }
    if (immutableTables.contains(table)) {
      return const MergeDecision(
        MergeAction.preserveBoth,
        reason: 'immutable revision conflict',
      );
    }
    final localRevision = _integer(local['revision']);
    final incomingRevision = _integer(incoming['revision']);
    if (incoming['deleted_at'] != null && incomingRevision >= localRevision) {
      return const MergeDecision(
        MergeAction.applyTombstone,
        reason: 'newer deletion',
      );
    }
    if (incomingRevision > localRevision) {
      return const MergeDecision(
        MergeAction.replaceLocal,
        reason: 'higher revision',
      );
    }
    if (incomingRevision < localRevision) {
      return const MergeDecision(
        MergeAction.skip,
        reason: 'local revision is newer',
      );
    }
    final localTime = _date(
      local['updated_at'] ?? local['created_at'] ?? local['deleted_at'],
    );
    final incomingTime = _date(
      incoming['updated_at'] ??
          incoming['created_at'] ??
          incoming['deleted_at'],
    );
    if (incomingTime.isAfter(localTime)) {
      return const MergeDecision(
        MergeAction.replaceLocal,
        reason: 'same revision, imported record is newer',
      );
    }
    if (incomingTime.isBefore(localTime)) {
      return const MergeDecision(
        MergeAction.skip,
        reason: 'same revision, local record is newer',
      );
    }
    if (table == 'conversations' || table == 'messages') {
      return const MergeDecision(
        MergeAction.replaceLocal,
        reason: 'imported conversation content differs',
      );
    }
    return const MergeDecision(
      MergeAction.preserveBoth,
      reason: 'concurrent edits',
    );
  }

  bool _same(Map<String, Object?> a, Map<String, Object?> b) {
    const ignored = <String>{'last_seen_at'};
    final left = <String, Object?>{
      for (final entry in a.entries)
        if (!ignored.contains(entry.key)) entry.key: entry.value,
    };
    final right = <String, Object?>{
      for (final entry in b.entries)
        if (!ignored.contains(entry.key)) entry.key: entry.value,
    };
    return canonicalJson(left) == canonicalJson(right);
  }

  int _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 1;

  DateTime _date(Object? value) =>
      DateTime.tryParse('${value ?? ''}')?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

String jsonLine(Map<String, Object?> value) => jsonEncode(canonicalize(value));
