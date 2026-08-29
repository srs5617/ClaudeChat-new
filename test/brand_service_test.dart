import 'dart:typed_data';

import 'package:claudechat/services/brand_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('custom font picker accepts TTF and OTF across mobile platforms', () {
    expect(
      BrandService.supportedFontTypes.extensions,
      containsAll(<String>['ttf', 'otf']),
    );
    expect(
      BrandService.supportedFontTypes.uniformTypeIdentifiers,
      contains('public.font'),
    );
  });

  test('font validation has no legacy 2.5 MB file-size ceiling', () {
    final largeTtf = Uint8List(2_500_001)
      ..[0] = 0
      ..[1] = 1
      ..[2] = 0
      ..[3] = 0;
    final otf = Uint8List.fromList(<int>[
      ...'SOTTO'.codeUnits.skip(1),
      ...List<int>.filled(8, 0),
    ]);

    expect(BrandService.isSupportedFontData(largeTtf), isTrue);
    expect(BrandService.isSupportedFontData(otf), isTrue);
    expect(BrandService.isSupportedFontData('WOFF'.codeUnits), isFalse);
  });
}
