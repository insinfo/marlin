import 'dart:io';
import 'dart:typed_data';

import 'bl_font.dart';

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
}
