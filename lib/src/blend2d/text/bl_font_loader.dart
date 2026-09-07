import 'dart:io';
import 'dart:typed_data';

import 'bl_font.dart';
import 'bl_font_collection.dart';

/// Loader inicial de fontes para o port Blend2D em Dart.
///
/// Nesta etapa, apenas encapsula bytes da fonte.
/// O parser OpenType completo entra nas proximas fases.
class BLFontLoader {
  const BLFontLoader();

  Future<BLFontFace> loadFile(
    String path, {
    String? familyName,
  }) async {
    final data = await File(path).readAsBytes();
    return loadBytes(data, familyName: familyName);
  }

  BLFontFace loadBytes(
    Uint8List data, {
    String? familyName,
  }) {
    return BLFontFace.parse(
      data,
      familyName: familyName,
    );
  }

  /// Diretórios usuais de fontes da plataforma atual.
  ///
  /// Android e iOS não garantem acesso ao catálogo completo. Neles esta lista
  /// representa apenas locais normalmente legíveis; fontes empacotadas pelo
  /// aplicativo devem ser registradas por bytes no [BLFontCollection].
  List<String> systemFontDirectories() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final windows = env['WINDIR'] ?? env['SystemRoot'];
      final local = env['LOCALAPPDATA'];
      return <String>[
        if (windows != null) '$windows${Platform.pathSeparator}Fonts',
        if (local != null)
          '$local${Platform.pathSeparator}Microsoft${Platform.pathSeparator}Windows${Platform.pathSeparator}Fonts',
      ];
    }
    if (Platform.isMacOS) {
      final home = env['HOME'];
      return <String>[
        '/System/Library/Fonts',
        '/Library/Fonts',
        if (home != null) '$home/Library/Fonts',
      ];
    }
    if (Platform.isAndroid) {
      return const <String>['/system/fonts', '/product/fonts', '/vendor/fonts'];
    }
    if (Platform.isIOS) {
      return const <String>['/System/Library/Fonts', '/Library/Fonts'];
    }
    final home = env['HOME'];
    return <String>[
      '/usr/share/fonts',
      '/usr/local/share/fonts',
      if (home != null) '$home/.fonts',
      if (home != null) '$home/.local/share/fonts',
    ];
  }

  /// Enumera arquivos OpenType acessíveis sem seguir links simbólicos.
  Future<List<String>> discoverSystemFontFiles({
    List<String>? directories,
  }) async {
    final result = <String>{};
    for (final path in directories ?? systemFontDirectories()) {
      final directory = Directory(path);
      if (!await directory.exists()) continue;
      try {
        await for (final entity
            in directory.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('.ttf') ||
              lower.endsWith('.otf') ||
              lower.endsWith('.ttc')) {
            result.add(entity.path);
          }
        }
      } on FileSystemException {
        // Catálogos do sistema podem conter subdiretórios sem permissão. Uma
        // falha local não deve esconder as fontes dos demais diretórios.
      }
    }
    final sorted = result.toList()..sort();
    return sorted;
  }
}
