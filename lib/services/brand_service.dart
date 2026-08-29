import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import '../core/app_paths.dart';
import 'settings_service.dart';

class BrandService {
  BrandService(this.paths, this.settings);

  static const supportedFontTypes = XTypeGroup(
    label: '字体（TTF / OTF）',
    extensions: <String>['ttf', 'otf'],
    mimeTypes: <String>[
      'font/ttf',
      'font/otf',
      'application/x-font-ttf',
      'application/x-font-opentype',
    ],
    uniformTypeIdentifiers: <String>['public.font'],
  );

  final AppPaths paths;
  final SettingsService settings;

  Future<String?> loadSavedFont() async {
    final values = await settings.load();
    final relative = values['customFontPath'] as String?;
    final family = values['customFontFamily'] as String?;
    if (relative == null ||
        relative.isEmpty ||
        family == null ||
        family.isEmpty ||
        relative.contains('..')) {
      return null;
    }
    final file = File(
      '${paths.fonts.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    if (!file.existsSync()) return null;
    await _loadFont(family, await file.readAsBytes());
    return family;
  }

  Future<String?> pickAndInstallFont() async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[supportedFontTypes],
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    if (bytes.length < 12) throw const FormatException('无法读取字体文件');
    if (!isSupportedFontData(bytes)) {
      throw const FormatException('所选文件不是可识别的 TTF 或 OTF 字体');
    }
    final safeName = _safeName(picked.name);
    final output = File(
      '${paths.fonts.path}${Platform.pathSeparator}$safeName',
    );
    await output.writeAsBytes(bytes, flush: true);
    final family = 'ClaudeChatCustom_${DateTime.now().microsecondsSinceEpoch}';
    await _loadFont(family, bytes);
    await settings.set('customFontPath', safeName);
    await settings.set('customFontFamily', family);
    await settings.set(
      'customFontName',
      picked.name.replaceFirst(
        RegExp(r'\.(?:ttf|otf)$', caseSensitive: false),
        '',
      ),
    );
    await settings.set('fontFamily', family);
    return family;
  }

  Future<void> resetFont() async {
    final values = await settings.load();
    final relative = values['customFontPath'] as String?;
    if (relative != null && relative.isNotEmpty && !relative.contains('..')) {
      final file = File(
        '${paths.fonts.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      if (file.existsSync()) await file.delete();
    }
    await settings.set('customFontName', '');
    await settings.set('customFontPath', '');
    await settings.set('customFontFamily', '');
    await settings.set('fontFamily', 'system');
  }

  Future<String?> pickAndInstallIcon() async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '图片',
          extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp'],
          uniformTypeIdentifiers: <String>[
            'public.png',
            'public.jpeg',
            'org.webmproject.webp',
          ],
        ),
      ],
    );
    if (picked == null) return null;
    if (await picked.length() > 8 * 1024 * 1024)
      throw const FormatException('图标文件不能超过 8 MB');
    final bytes = await picked.readAsBytes();
    if (bytes.length < 16) throw const FormatException('无法读取图标文件');
    final supported = _isPng(bytes) || _isJpeg(bytes) || _isWebp(bytes);
    if (!supported) throw const FormatException('自定义图标仅支持 PNG、JPEG 或 WebP');
    final extension = _isPng(bytes)
        ? 'png'
        : _isJpeg(bytes)
        ? 'jpg'
        : 'webp';
    final name =
        'custom-icon-${DateTime.now().microsecondsSinceEpoch}.$extension';
    await File(
      '${paths.icons.path}${Platform.pathSeparator}$name',
    ).writeAsBytes(bytes, flush: true);
    await settings.set('customIconPath', name);
    return name;
  }

  Future<void> importLegacyAssets(Map<String, Object?> source) async {
    final icon = source['customIcon'];
    if (icon is String && icon.startsWith('data:image/')) {
      final comma = icon.indexOf(',');
      if (comma > 0) {
        try {
          final bytes = base64Decode(icon.substring(comma + 1));
          if (bytes.length <= 8 * 1024 * 1024) {
            const name = 'legacy-custom-icon.png';
            await File(
              '${paths.icons.path}${Platform.pathSeparator}$name',
            ).writeAsBytes(bytes, flush: true);
            await settings.set('customIconPath', name);
          }
        } on FormatException {
          // Malformed optional legacy asset is ignored without blocking data import.
        }
      }
    }
    final font = source['customFontSrc'];
    if (font is String &&
        (font.startsWith('data:font/') ||
            font.startsWith('data:application/x-font-ttf') ||
            font.startsWith('data:application/octet-stream'))) {
      final comma = font.indexOf(',');
      if (comma > 0) {
        try {
          final bytes = base64Decode(font.substring(comma + 1));
          if (isSupportedFontData(bytes)) {
            final name = _fontExtension(bytes) == 'otf'
                ? 'legacy-custom-font.otf'
                : 'legacy-custom-font.ttf';
            await File(
              '${paths.fonts.path}${Platform.pathSeparator}$name',
            ).writeAsBytes(bytes, flush: true);
            const family = 'ClaudeChatLegacyCustom';
            await _loadFont(family, bytes);
            await settings.set('customFontPath', name);
            await settings.set('customFontFamily', family);
            await settings.set(
              'customFontName',
              '${source['customFontName'] ?? '自定义字体'}',
            );
            await settings.set('fontFamily', family);
          }
        } on FormatException {
          // Keep all other imported data if the optional font is malformed.
        }
      }
    }
  }

  Future<void> _loadFont(String family, List<int> bytes) async {
    final loader = FontLoader(family)
      ..addFont(
        Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))),
      );
    await loader.load();
  }

  static bool isSupportedFontData(List<int> bytes) {
    if (bytes.length < 4) return false;
    final signature = String.fromCharCodes(bytes.take(4));
    return signature == 'OTTO' ||
        signature == 'true' ||
        signature == 'typ1' ||
        (bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0);
  }

  static String _fontExtension(List<int> bytes) =>
      bytes.length >= 4 && String.fromCharCodes(bytes.take(4)) == 'OTTO'
      ? 'otf'
      : 'ttf';

  String _safeName(String value) {
    final clean = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    return clean.isEmpty
        ? 'custom-font.ttf'
        : clean.substring(0, clean.length.clamp(0, 100));
  }

  bool _isPng(List<int> bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47;
  bool _isJpeg(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff;
  bool _isWebp(List<int> bytes) =>
      bytes.length >= 12 &&
      String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP';
}
