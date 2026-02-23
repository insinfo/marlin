/// Posicionamento de um glifo em um run.
class BLGlyphPlacement {
  final int glyphId;
  final double x;
  final double y;
  final double advanceX;

  const BLGlyphPlacement({
    required this.glyphId,
    required this.x,
    required this.y,
    required this.advanceX,
  });
}

/// Saida de shaping/layout (bootstrap).
class BLGlyphRun {
  final List<BLGlyphPlacement> glyphs;

  const BLGlyphRun(this.glyphs);

  bool get isEmpty => glyphs.isEmpty;
}
