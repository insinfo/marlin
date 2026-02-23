import 'bl_font.dart';
import 'bl_glyph_run.dart';

/// Layout simplificado de texto em linha unica (bootstrap).
///
/// Usa mapeamento `cmap` e metrica horizontal da fonte para avancos.
/// Nao executa shaping GSUB/GPOS nem bidi ainda.
class BLTextLayout {
  const BLTextLayout();

  BLGlyphRun shapeSimple(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
  }) {
    if (text.isEmpty) return const BLGlyphRun(<BLGlyphPlacement>[]);

    final glyphs = <BLGlyphPlacement>[];
    double penX = x;
    final runes = text.runes.toList(growable: false);
    int prevGid = -1;
    for (final cp in runes) {
      final gid = font.face.mapCodePoint(cp);
      if (prevGid >= 0 && gid != 0) {
        penX += font.kerning(prevGid, gid);
      }
      final adv = font.glyphAdvance(gid);
      glyphs.add(BLGlyphPlacement(
        glyphId: gid,
        x: penX,
        y: y,
        advanceX: adv,
      ));
      penX += adv;
      prevGid = gid;
    }
    return BLGlyphRun(glyphs);
  }
}
