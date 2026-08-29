import 'package:claudechat/services/attachment_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mib = 1024 * 1024;

  test('50 MB is a confirmation threshold rather than a fixed limit', () {
    expect(requiresLargeAttachmentConfirmation(<int>[50 * mib]), isFalse);
    expect(requiresLargeAttachmentConfirmation(<int>[51 * mib]), isTrue);
    expect(
      requiresLargeAttachmentConfirmation(<int>[30 * mib, 21 * mib]),
      isTrue,
    );
  });
}
