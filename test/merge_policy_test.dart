import 'package:claudechat/services/merge_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = MergePolicy();
  Map<String, Object?> row({
    int revision = 1,
    String updated = '2026-01-01T00:00:00Z',
    String content = 'a',
    String? deleted,
  }) => <String, Object?>{
    'id': 'same-id',
    'revision': revision,
    'updated_at': updated,
    'content': content,
    'deleted_at': deleted,
  };

  test('adds unknown entities', () {
    expect(
      policy.decide(table: 'memories', local: null, incoming: row()).action,
      MergeAction.add,
    );
  });

  test('skips byte-equivalent entities', () {
    expect(
      policy.decide(table: 'memories', local: row(), incoming: row()).action,
      MergeAction.skip,
    );
  });

  test('higher revision replaces local entity', () {
    expect(
      policy
          .decide(
            table: 'memories',
            local: row(revision: 1),
            incoming: row(revision: 2, content: 'b'),
          )
          .action,
      MergeAction.replaceLocal,
    );
  });

  test('lower imported revision does not overwrite local changes', () {
    expect(
      policy
          .decide(
            table: 'memories',
            local: row(revision: 3),
            incoming: row(revision: 2, content: 'b'),
          )
          .action,
      MergeAction.skip,
    );
  });

  test('active import restores a locally deleted entity', () {
    expect(
      policy
          .decide(
            table: 'conversations',
            local: row(revision: 4, deleted: '2026-04-01T00:00:00Z'),
            incoming: row(revision: 1),
          )
          .action,
      MergeAction.replaceLocal,
    );
  });

  test('changed conversation content at equal version updates local row', () {
    expect(
      policy
          .decide(
            table: 'messages',
            local: row(content: 'old content'),
            incoming: row(content: 'updated content'),
          )
          .action,
      MergeAction.replaceLocal,
    );
  });

  test('newer tombstone wins without physically deleting history', () {
    expect(
      policy
          .decide(
            table: 'memories',
            local: row(),
            incoming: row(revision: 2, deleted: '2026-02-01T00:00:00Z'),
          )
          .action,
      MergeAction.applyTombstone,
    );
  });

  test('concurrent immutable revisions are preserved as conflict history', () {
    expect(
      policy
          .decide(
            table: 'diary_versions',
            local: row(content: 'local'),
            incoming: row(content: 'remote'),
          )
          .action,
      MergeAction.preserveBoth,
    );
  });
}
