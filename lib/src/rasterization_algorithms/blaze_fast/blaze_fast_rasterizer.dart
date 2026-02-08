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

    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (int i = 0; i < n; i++) {
      final y = vertices[i * 2 + 1];
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    int yStart = minY.floor();
    int yEnd = maxY.ceil() - 1;

    if (yStart < 0) yStart = 0;
    if (yEnd >= height) yEnd = height - 1;

    if (yEnd < yStart) return;

    final intersections = <double>[];

    for (int y = yStart; y <= yEnd; y++) {
      intersections.clear();

      final scanY = y + 0.5;

      int j = n - 1;
      double xj = vertices[j * 2];
      double yj = vertices[j * 2 + 1];

      for (int i = 0; i < n; i++) {
        final xi = vertices[i * 2];
        final yi = vertices[i * 2 + 1];

        final intersects = ((yi > scanY) != (yj > scanY));
        if (intersects) {
          final t = (scanY - yi) / (yj - yi);
          final x = xi + t * (xj - xi);
          intersections.add(x);
        }

        j = i;
        xj = xi;
        yj = yi;
      }

      if (intersections.length < 2) continue;

      intersections.sort();

      for (int k = 0; k + 1 < intersections.length; k += 2) {
        int xStart = intersections[k].ceil();
        int xEnd = intersections[k + 1].floor();

        if (xStart < 0) xStart = 0;
        if (xEnd >= width) xEnd = width - 1;
        if (xEnd < xStart) continue;

        final rowIndex = y * width;
        for (int x = xStart; x <= xEnd; x++) {
          _buffer[rowIndex + x] = color;
        }
      }
    }
  }

  Uint32List get buffer => _buffer;
}
