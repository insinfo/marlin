/// Dedicated glyph rasterizer that produces A8 coverage bitmaps.
///
/// Uses the existing analytic rasterizer pipeline to render glyph outlines
/// into single-channel (A8) coverage masks suitable for caching in
/// [BLGlyphCache].
///
/// Inspired by: Blend2D's glyph AA rasterization pipeline.

import 'dart:typed_data';

import '../raster/bl_analytic_rasterizer.dart';
import 'bl_font.dart';
import 'bl_glyph_cache.dart';

/// Rasterizes glyph outlines into A8 coverage bitmaps.
///
/// This rasterizer:
/// 1. Gets the glyph outline from the font at the given size
/// 2. Computes the bounding box of the outline
/// 3. Renders it using the analytic rasterizer pipeline
/// 4. Extracts the alpha channel as an A8 bitmap
///
/// Usage:
/// ```dart
/// final rasterizer = BLGlyphRasterizer();
/// final entry = rasterizer.rasterize(font, glyphId);
/// if (entry != null) {
///   cache.put(fontFaceId, glyphId, font.size, entry);
/// }
/// ```
class BLGlyphRasterizer {
  /// Padding around the glyph bitmap to avoid clipping.
  final int padding;

  const BLGlyphRasterizer({this.padding = 1});

  /// Rasterizes [glyphId] from [font] into an A8 coverage bitmap.
  ///
  /// Returns a [BLGlyphCacheEntry] or null if the glyph has no outline.
  Future<BLGlyphCacheEntry?> rasterize(BLFont font, int glyphId) async {
    final outline = font.glyphOutline(glyphId);
    if (outline == null) return null;

    final verts = outline.vertices;
    if (verts.length < 6) return null; // Need at least 3 points

    // Compute bounding box of the scaled glyph outline
    double minX = double.maxFinite, minY = double.maxFinite;
    double maxX = -double.maxFinite, maxY = -double.maxFinite;
    for (int i = 0; i < verts.length; i += 2) {
      final x = verts[i];
      final y = verts[i + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    // Add padding and compute integer bounds
    final bx = (minX - padding).floor();
    final by = (minY - padding).floor();
    final bw = (maxX + padding).ceil() - bx;
    final bh = (maxY + padding).ceil() - by;

    if (bw <= 0 || bh <= 0 || bw > 4096 || bh > 4096) return null;

    // Translate outline to bitmap space (offset so bbox starts at 0,0)
    final translated = List<double>.filled(verts.length, 0.0);
    for (int i = 0; i < verts.length; i += 2) {
      translated[i] = verts[i] - bx;
      translated[i + 1] = verts[i + 1] - by;
    }

    // Rasterize using analytic rasterizer
    // Use transparent black as clear color, draw white glyph
    final rasterizer = BLAnalyticRasterizer(bw, bh);
    rasterizer.clear(0x00000000); // transparent background

    await rasterizer.drawPolygon(
      translated,
      0xFFFFFFFF, // white fill — alpha = coverage
      contourVertexCounts: outline.contourVertexCounts,
    );

    // Read back the buffer and extract alpha channel
    final buffer = rasterizer.pixelBuffer;
    final a8 = Uint8List(bw * bh);
    for (int i = 0; i < buffer.length; i++) {
      a8[i] = (buffer[i] >> 24) & 0xFF;
    }

    rasterizer.dispose();

    return BLGlyphCacheEntry(
      glyphId: glyphId,
      fontSize: font.size,
      width: bw,
      height: bh,
      bearingX: bx,
      bearingY: by,
      bitmap: a8,
    );
  }

  /// Rasterizes a glyph and stores it in the cache.
  /// Returns the cached entry, fetching from cache if already present.
  Future<BLGlyphCacheEntry?> rasterizeAndCache(
    BLFont font,
    int glyphId,
    int fontFaceId,
    BLGlyphCache cache,
  ) async {
    final existing = cache.get(fontFaceId, glyphId, font.size);
    if (existing != null) return existing;

    final entry = await rasterize(font, glyphId);
    if (entry != null) {
      cache.put(fontFaceId, glyphId, font.size, entry);
    }
    return entry;
  }
}
