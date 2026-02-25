import 'bl_font.dart';
import 'bl_glyph_run.dart';

/// Layout de texto em linha unica com suporte a GSUB/GPOS.
///
/// Pipeline:
///   1. Mapeia codepoints → glyph IDs via cmap
///   2. Aplica GSUB (ligaduras, substituições) se disponível
///   3. Posiciona glifos com advance + kerning (legacy + GPOS)
class BLTextLayout {
  const BLTextLayout();

  /// Executa shaping simplificado com GSUB/GPOS quando disponível.
  ///
  /// [features] permite selecionar features GSUB específicas
  /// (default: `{'liga', 'clig', 'rlig'}`).
  BLGlyphRun shapeSimple(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
    Set<String>? gsubFeatures,
    Set<String>? gposFeatures,
  }) {
    if (text.isEmpty) return const BLGlyphRun(<BLGlyphPlacement>[]);

    final runes = text.runes.toList(growable: false);
    final face = font.face;

    // Step 1: cmap mapping (codepoints → glyph IDs)
    var glyphIds = <int>[for (final cp in runes) face.mapCodePoint(cp)];

    // Step 2: Apply GSUB (ligatures, substitutions)
    final engine = face.layoutEngine;
    if (engine != null && engine.hasGSUB) {
      glyphIds = engine.applyGSUB(glyphIds, features: gsubFeatures);
    }

    // Step 3: Get GPOS adjustments
    List<int>? gposAdj;
    if (engine != null && engine.hasGPOS) {
      gposAdj = engine.applyGPOS(glyphIds, features: gposFeatures);
    }

    // Step 4: Position glyphs with advance + kerning
    final glyphs = <BLGlyphPlacement>[];
    double penX = x;
    for (int i = 0; i < glyphIds.length; i++) {
      final gid = glyphIds[i];

      // Apply legacy kerning if no GPOS
      if (gposAdj == null && i > 0) {
        penX += font.kerning(glyphIds[i - 1], gid);
      }

      final adv = font.glyphAdvance(gid);
      glyphs.add(BLGlyphPlacement(
        glyphId: gid,
        x: penX,
        y: y,
        advanceX: adv,
      ));

      penX += adv;

      // Apply GPOS x-advance adjustment
      if (gposAdj != null && i < gposAdj.length) {
        penX += font.scaleValue(gposAdj[i]);
      }
    }
    return BLGlyphRun(glyphs);
  }
}
