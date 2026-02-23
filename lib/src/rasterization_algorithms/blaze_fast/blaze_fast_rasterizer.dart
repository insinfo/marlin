/// ============================================================================
/// SCANLINE_EO — Scanline fill sem anti-aliasing (AA)
/// ============================================================================
///
/// Rasterização rápida baseada em varredura por scanlines.
/// Sem AA: escreve pixels sólidos (even-odd) para polígonos simples.
/// ============================================================================

import 'dart:typed_data';

class ScanlineRasterizer {
  final int width;
  final int height;

  final Uint32List _buffer;

  ScanlineRasterizer({required this.width, required this.height})
      : _buffer = Uint32List(width * height);

  void clear([int color = 0xFFFFFFFF]) {
    _buffer.fillRange(0, _buffer.length, color);
  }

  /// Preenche polígono (even-odd), sem AA
  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;

    final n = vertices.length ~/ 2;
    final contours = _resolveContours(n, contourVertexCounts);
    if (contours.isEmpty) return;

    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (final contour in contours) {
      for (int local = 0; local < contour.count; local++) {
        final i = contour.start + local;
        final y = vertices[i * 2 + 1];
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }

    int yStart = minY.floor();
    int yEnd = maxY.ceil() - 1;

    if (yStart < 0) yStart = 0;
    if (yEnd >= height) yEnd = height - 1;

    if (yEnd < yStart) return;

    final crossings = <_Crossing>[];
    final useEvenOdd = windingRule == 0;

    for (int y = yStart; y <= yEnd; y++) {
      crossings.clear();

      final scanY = y + 0.5;

      for (final contour in contours) {
        final cStart = contour.start;
        final cCount = contour.count;
        if (cCount < 2) continue;

        for (int local = 0; local < cCount; local++) {
          final i = cStart + local;
          final j = cStart + ((local + 1) % cCount);
          final xi = vertices[i * 2];
          final yi = vertices[i * 2 + 1];
          final xj = vertices[j * 2];
          final yj = vertices[j * 2 + 1];

          final intersects = ((yi > scanY) != (yj > scanY));
          if (intersects) {
            final t = (scanY - yi) / (yj - yi);
            final x = xi + t * (xj - xi);
            final dir = yj > yi ? 1 : -1;
            crossings.add(_Crossing(x, dir));
          }
        }
      }

      if (crossings.length < 2) continue;
      crossings.sort((a, b) => a.x.compareTo(b.x));

      final rowIndex = y * width;
      if (useEvenOdd) {
        for (int k = 0; k + 1 < crossings.length; k += 2) {
          int xStart = crossings[k].x.ceil();
          int xEnd = crossings[k + 1].x.floor();

          if (xStart < 0) xStart = 0;
          if (xEnd >= width) xEnd = width - 1;
          if (xEnd < xStart) continue;

          for (int x = xStart; x <= xEnd; x++) {
            _buffer[rowIndex + x] = color;
          }
        }
      } else {
        int winding = 0;
        double? spanStart;
        for (int k = 0; k < crossings.length; k++) {
          final c = crossings[k];
          final wasInside = winding != 0;
          winding += c.direction;
          final isInside = winding != 0;

          if (!wasInside && isInside) {
            spanStart = c.x;
            continue;
          }
          if (wasInside && !isInside && spanStart != null) {
            int xStart = spanStart.ceil();
            int xEnd = c.x.floor();
            if (xStart < 0) xStart = 0;
            if (xEnd >= width) xEnd = width - 1;
            if (xEnd >= xStart) {
              for (int x = xStart; x <= xEnd; x++) {
                _buffer[rowIndex + x] = color;
              }
            }
            spanStart = null;
          }
        }
      }
    }
  }

  Uint32List get buffer => _buffer;
}

class _Crossing {
  final double x;
  final int direction;
  const _Crossing(this.x, this.direction);
}

class _ContourSpan {
  final int start;
  final int count;
  const _ContourSpan(this.start, this.count);
}

List<_ContourSpan> _resolveContours(int totalPoints, List<int>? counts) {
  if (counts == null || counts.isEmpty) {
    return <_ContourSpan>[_ContourSpan(0, totalPoints)];
  }
  int consumed = 0;
  final out = <_ContourSpan>[];
  for (final raw in counts) {
    if (raw <= 0) continue;
    if (consumed + raw > totalPoints) {
      return <_ContourSpan>[_ContourSpan(0, totalPoints)];
    }
    out.add(_ContourSpan(consumed, raw));
    consumed += raw;
  }
  if (out.isEmpty || consumed != totalPoints) {
    return <_ContourSpan>[_ContourSpan(0, totalPoints)];
  }
  return out;
}
