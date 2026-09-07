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
    if (!_hasRecognizedHeader(data)) {
      throw const FormatException('Cabeçalho de fonte OpenType/CFF inválido.');
    }
    return BLFontFace.parse(
      data,
      familyName: familyName,
    );
  }

  static bool _hasRecognizedHeader(Uint8List data) {
    if (data.length < 4) return false;
    final signature = String.fromCharCodes(data.take(4));
    if (signature == 'OTTO' ||
        signature == 'true' ||
        signature == 'typ1' ||
        signature == 'ttcf') {
      return true;
    }
    if (data[0] == 0 && data[1] == 1 && data[2] == 0 && data[3] == 0) {
      return true;
    }
    // CFF puro: major 1/2, minor, hdrSize e offSize válidos.
    return (data[0] == 1 || data[0] == 2) &&
        data[2] >= 4 &&
        data[2] <= data.length &&
        data[3] >= 1 &&
        data[3] <= 4;
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

  /// Descobre, valida e adiciona fontes nativas a [collection].
  ///
  /// Arquivos ilegíveis ou formatos ainda não suportados são ignorados para
  /// que uma fonte defeituosa do sistema não invalide o catálogo inteiro.
  /// [onError] permite registrar esses casos. [maxFonts] limita o consumo de
  /// memória em dispositivos móveis; `null` tenta carregar todas as faces.
  Future<int> loadSystemFonts(
    BLFontCollection collection, {
    List<String>? directories,
    int? maxFonts,
    void Function(String path, Object error)? onError,
  }) async {
    if (maxFonts != null && maxFonts < 0) {
      throw ArgumentError.value(maxFonts, 'maxFonts', 'deve ser nulo ou >= 0');
    }
    if (maxFonts == 0) return 0;
    final files = await discoverSystemFontFiles(directories: directories);
    var loaded = 0;
    for (final path in files) {
      if (maxFonts != null && loaded >= maxFonts) break;
      try {
        collection.addFace(await loadFile(path));
        loaded++;
      } on Object catch (error) {
        onError?.call(path, error);
      }
    }
    return loaded;
  }
}
