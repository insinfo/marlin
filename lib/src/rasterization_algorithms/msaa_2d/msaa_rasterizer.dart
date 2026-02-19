/// ============================================================================
/// MSAA_2D — Rasterizacao com Multisampling de Cobertura
/// ============================================================================
///
/// Rasterizacao de poligonos via multisampling por pixel (2x2 ou 4x4).
/// Usa LUT de alpha e amostragem em grade rotacionada opcional.
/// ============================================================================

import 'dart:typed_data';
import 'dart:math' as math;

class MSAARasterizer {
  final int width;
  final int height;
  final int samplesPerAxis;
  final bool useRotatedGrid;
  final double rotationRadians;
  final double edgeEps;
  final int tileSize;
  final bool enableTileCulling;

  late final int _sampleCount;
  late final Float32List _sampleOffsets;
  late final Uint8List _alphaLut;

  final Uint32List _buffer;
  final Uint8List _coverage;
  late final int _tilesX;
  late final int _tilesY;
  late final Uint8List _tileOpaque;

  List<double>? _lastVerticesRef;
  List<int>? _lastContourCountsRef;
  int _lastVertexCount = 0;
  Float64List? _cacheXi;
  Float64List? _cacheYi;
  Float64List? _cacheXj;
  Float64List? _cacheYj;
  Float64List? _cacheDx;
  Float64List? _cacheDy;
  Float64List? _cacheInvLen2;
  Float64List? _cacheInvDy;
  Float64List? _cacheYMin;
  Float64List? _cacheYMax;
  Float64List? _cacheSlope;
  Float64List? _cacheXIntercept;
  Uint32List? _rowEdgeMask;
  int _rowEdgeMaskBlocks = 0;

  MSAARasterizer({
    required this.width,
    required this.height,
    this.samplesPerAxis = 4,
    this.useRotatedGrid = true,
    this.rotationRadians = 0.4636476090008061,
    this.edgeEps = 1e-6,
    this.tileSize = 8,
    // IMPORTANT:
    // Tile culling by "opaque tile" is not safe for painter's algorithm:
    // an early opaque polygon (e.g. background) would hide later polygons.
    // Keep disabled by default to preserve correct SVG layer compositing.
    this.enableTileCulling = false,
  })  : _buffer = Uint32List(width * height),
        _coverage = Uint8List(width * height) {
    _tilesX = (width + tileSize - 1) ~/ tileSize;
    _tilesY = (height + tileSize - 1) ~/ tileSize;
    _tileOpaque = Uint8List(_tilesX * _tilesY);
    _initSamples();
  }

  void _initSamples() {
    final n = samplesPerAxis.clamp(2, 4);
    _sampleCount = n * n;

    final offsets = Float32List(_sampleCount * 2);
    final inv = 1.0 / n;
    final cosA = useRotatedGrid ? math.cos(rotationRadians) : 1.0;
    final sinA = useRotatedGrid ? math.sin(rotationRadians) : 0.0;

    var idx = 0;
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        final ux = (x + 0.5) * inv - 0.5;
        final uy = (y + 0.5) * inv - 0.5;

        final rx = useRotatedGrid ? (ux * cosA - uy * sinA) : ux;
        final ry = useRotatedGrid ? (ux * sinA + uy * cosA) : uy;

        final ox = (rx + 0.5).clamp(0.0, 1.0);
        final oy = (ry + 0.5).clamp(0.0, 1.0);

        offsets[idx++] = ox;
        offsets[idx++] = oy;
      }
    }
    _sampleOffsets = offsets;

    final lut = Uint8List(_sampleCount + 1);
    for (int i = 0; i <= _sampleCount; i++) {
      lut[i] = ((i * 255 + (_sampleCount >> 1)) ~/ _sampleCount).clamp(0, 255);
    }
    _alphaLut = lut;
  }

  void clear([int color = 0xFFFFFFFF]) {
    _buffer.fillRange(0, _buffer.length, color);
    _coverage.fillRange(0, _coverage.length, 0);
    _tileOpaque.fillRange(0, _tileOpaque.length, 0);
  }

  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;

    final n = vertices.length ~/ 2;

    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (int i = 0; i < n; i++) {
      final x = vertices[i * 2];
      final y = vertices[i * 2 + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    int xStart = minX.floor();
    int xEnd = maxX.ceil() - 1;
    int yStart = minY.floor();
    int yEnd = maxY.ceil() - 1;

    if (xStart < 0) xStart = 0;
    if (yStart < 0) yStart = 0;
    if (xEnd >= width) xEnd = width - 1;
    if (yEnd >= height) yEnd = height - 1;

    if (xEnd < xStart || yEnd < yStart) return;

    final contours = _resolveContours(n, contourVertexCounts);
    int edgeCount = 0;
    for (final contour in contours) {
      if (contour.count >= 3) edgeCount += contour.count;
    }
    if (edgeCount == 0) return;
    Float64List xi;
    Float64List yi;
    Float64List xj;
    Float64List yj;
    Float64List dx;
    Float64List dy;
    Float64List invLen2;
    Float64List invDy;
    Float64List yMin;
    Float64List yMax;
    Float64List slope;
    Float64List xIntercept;

    if (identical(vertices, _lastVerticesRef) &&
        _lastVertexCount == n &&
        identical(contourVertexCounts, _lastContourCountsRef)) {
      xi = _cacheXi!;
      yi = _cacheYi!;
      xj = _cacheXj!;
      yj = _cacheYj!;
      dx = _cacheDx!;
      dy = _cacheDy!;
      invLen2 = _cacheInvLen2!;
      invDy = _cacheInvDy!;
      yMin = _cacheYMin!;
      yMax = _cacheYMax!;
      slope = _cacheSlope!;
      xIntercept = _cacheXIntercept!;
    } else {
      xi = Float64List(edgeCount);
      yi = Float64List(edgeCount);
      xj = Float64List(edgeCount);
      yj = Float64List(edgeCount);
      dx = Float64List(edgeCount);
      dy = Float64List(edgeCount);
      invLen2 = Float64List(edgeCount);
      invDy = Float64List(edgeCount);
      yMin = Float64List(edgeCount);
      yMax = Float64List(edgeCount);
      slope = Float64List(edgeCount);
      xIntercept = Float64List(edgeCount);

      int edgeIndex = 0;
      for (final contour in contours) {
        if (contour.count < 3) continue;
        for (int local = 0; local < contour.count; local++) {
          final i = contour.start + local;
          final j = contour.start + ((local + 1) % contour.count);
          final i2 = i * 2;
          final j2 = j * 2;

          final x0 = vertices[i2];
          final y0 = vertices[i2 + 1];
          final x1 = vertices[j2];
          final y1 = vertices[j2 + 1];

          xi[edgeIndex] = x0;
          yi[edgeIndex] = y0;
          xj[edgeIndex] = x1;
          yj[edgeIndex] = y1;

          final ex = x1 - x0;
          final ey = y1 - y0;
          dx[edgeIndex] = ex;
          dy[edgeIndex] = ey;

          final len2 = ex * ex + ey * ey;
          invLen2[edgeIndex] = len2 > 0 ? 1.0 / len2 : 0.0;
          invDy[edgeIndex] = ey != 0 ? 1.0 / ey : 0.0;
          if (y0 < y1) {
            yMin[edgeIndex] = y0;
            yMax[edgeIndex] = y1;
          } else {
            yMin[edgeIndex] = y1;
            yMax[edgeIndex] = y0;
          }
          final s = ey != 0 ? ex * invDy[edgeIndex] : 0.0;
          slope[edgeIndex] = s;
          xIntercept[edgeIndex] = x0 - s * y0;
          edgeIndex++;
        }
      }

      _lastVerticesRef = vertices;
      _lastContourCountsRef = contourVertexCounts;
      _lastVertexCount = n;
      _cacheXi = xi;
      _cacheYi = yi;
      _cacheXj = xj;
      _cacheYj = yj;
      _cacheDx = dx;
      _cacheDy = dy;
      _cacheInvLen2 = invLen2;
      _cacheInvDy = invDy;
      _cacheYMin = yMin;
      _cacheYMax = yMax;
      _cacheSlope = slope;
      _cacheXIntercept = xIntercept;
    }

    final offsets = _sampleOffsets;
    final samplesLen = offsets.length;
    final sampleCount = _sampleCount;
    final eps2 = edgeEps * edgeEps;

    final maskBlocks = (edgeCount + 31) >> 5;
    if (_rowEdgeMask == null || _rowEdgeMaskBlocks != maskBlocks) {
      _rowEdgeMask = Uint32List(_tilesY * maskBlocks);
      _rowEdgeMaskBlocks = maskBlocks;
    } else {
      _rowEdgeMask!.fillRange(0, _tilesY * maskBlocks, 0);
    }
    final rowMask = _rowEdgeMask!;

    for (int i = 0; i < edgeCount; i++) {
      final y0 = yMin[i];
      final y1 = yMax[i];
      int rowStart = (y0.floor()) ~/ tileSize;
      int rowEnd = (y1.ceil() - 1) ~/ tileSize;
      if (rowEnd < rowStart) continue;
      if (rowStart < 0) rowStart = 0;
      if (rowEnd >= _tilesY) rowEnd = _tilesY - 1;
      final block = i >> 5;
      final bit = 1 << (i & 31);
      for (int ty = rowStart; ty <= rowEnd; ty++) {
        rowMask[ty * maskBlocks + block] |= bit;
      }
    }

    final useEvenOdd = windingRule == 0;

    bool pointInPolygon(double x, double y, int rowMaskBase) {
      bool inside = false;
      int winding = 0;

      for (int b = 0; b < maskBlocks; b++) {
        int bits = rowMask[rowMaskBase + b];
        while (bits != 0) {
          final lsb = bits & -bits;
          final bitIndex = lsb.bitLength - 1;
          final i = (b << 5) + bitIndex;
          if (i >= edgeCount) {
            bits = 0;
            break;
          }
          bits &= bits - 1;

          if (y < yMin[i] || y >= yMax[i]) continue;
          final x0 = xi[i];
          final y0 = yi[i];
          final y1 = yj[i];

          final ex = dx[i];
          final ey = dy[i];
          final il2 = invLen2[i];

          if (il2 > 0) {
            var t = ((x - x0) * ex + (y - y0) * ey) * il2;
            if (t < 0) {
              t = 0;
            } else if (t > 1) {
              t = 1;
            }
            final cx = x0 + t * ex;
            final cy = y0 + t * ey;
            final dxp = x - cx;
            final dyp = y - cy;
            final dist2 = dxp * dxp + dyp * dyp;
            if (dist2 <= eps2) return true;
          }

          final intersects = x < (slope[i] * y + xIntercept[i]);
          if (intersects) {
            if (useEvenOdd) {
              inside = !inside;
            } else {
              winding += y1 > y0 ? 1 : -1;
            }
          }
        }
      }
      return useEvenOdd ? inside : winding != 0;
    }

    final tileMinX = xStart ~/ tileSize;
    final tileMaxX = xEnd ~/ tileSize;
    final tileMinY = yStart ~/ tileSize;
    final tileMaxY = yEnd ~/ tileSize;

    if (enableTileCulling) {
      bool allTilesOpaque = true;
      for (int ty = tileMinY; ty <= tileMaxY; ty++) {
        for (int tx = tileMinX; tx <= tileMaxX; tx++) {
          if (_tileOpaque[ty * _tilesX + tx] == 0) {
            allTilesOpaque = false;
            break;
          }
        }
        if (!allTilesOpaque) break;
      }
      if (allTilesOpaque) return;
    }

    for (int ty = tileMinY; ty <= tileMaxY; ty++) {
      final rowMaskBase = ty * maskBlocks;
      for (int tx = tileMinX; tx <= tileMaxX; tx++) {
        final tileIndex = ty * _tilesX + tx;
        if (enableTileCulling && _tileOpaque[tileIndex] != 0) continue;

        final startX = tx * tileSize;
        final startY = ty * tileSize;
        final endX = math.min(startX + tileSize, width);
        final endY = math.min(startY + tileSize, height);

        for (int y = startY; y < endY; y++) {
          for (int x = startX; x < endX; x++) {
            int insideCount = 0;

            for (int s = 0; s < samplesLen; s += 2) {
              final sx = x + offsets[s];
              final sy = y + offsets[s + 1];
              if (pointInPolygon(sx, sy, rowMaskBase)) {
                insideCount++;
                if (insideCount == sampleCount) break;
              }
            }

            if (insideCount == 0) continue;

            final alpha = _alphaLut[insideCount];
            if (alpha == 0) continue;
            _blendPixel(x, y, color, alpha);
          }
        }
      }
    }

    if (enableTileCulling) {
      _updateTileOpaque(tileMinX, tileMaxX, tileMinY, tileMaxY);
    }
  }

  void _blendPixel(int x, int y, int foreground, int alpha) {
    final idx = y * width + x;

    if (alpha >= 255) {
      _buffer[idx] = foreground;
      _coverage[idx] = 255;
      return;
    }

    final bg = _buffer[idx];
    final fgR = (foreground >> 16) & 0xFF;
    final fgG = (foreground >> 8) & 0xFF;
    final fgB = foreground & 0xFF;
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    final invA = 255 - alpha;
    final r = (fgR * alpha + bgR * invA) ~/ 255;
    final g = (fgG * alpha + bgG * invA) ~/ 255;
    final b = (fgB * alpha + bgB * invA) ~/ 255;

    _buffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
    if (alpha > _coverage[idx]) {
      _coverage[idx] = alpha;
    }
  }

  void _updateTileOpaque(
      int tileMinX, int tileMaxX, int tileMinY, int tileMaxY) {
    for (int ty = tileMinY; ty <= tileMaxY; ty++) {
      for (int tx = tileMinX; tx <= tileMaxX; tx++) {
        final tileIndex = ty * _tilesX + tx;
        if (_tileOpaque[tileIndex] != 0) continue;

        final startX = tx * tileSize;
        final startY = ty * tileSize;
        final endX = math.min(startX + tileSize, width);
        final endY = math.min(startY + tileSize, height);

        bool full = true;
        for (int y = startY; y < endY && full; y++) {
          int row = y * width + startX;
          for (int x = startX; x < endX; x++) {
            if (_coverage[row++] != 255) {
              full = false;
              break;
            }
          }
        }

        if (full) {
          _tileOpaque[tileIndex] = 1;
        }
      }
    }
  }

  Uint32List get buffer => _buffer;
  int get sampleCount => _sampleCount;
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

  final out = <_ContourSpan>[];
  int consumed = 0;
  for (final raw in counts) {
    if (raw < 3 || consumed + raw > totalPoints) {
      return <_ContourSpan>[_ContourSpan(0, totalPoints)];
    }
    out.add(_ContourSpan(consumed, raw));
    consumed += raw;
  }

  if (consumed != totalPoints) {
    return <_ContourSpan>[_ContourSpan(0, totalPoints)];
  }
  return out;
}
