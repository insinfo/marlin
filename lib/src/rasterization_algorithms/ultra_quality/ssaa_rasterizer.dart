/// ============================================================================
/// SSAA — Supersampling de alta densidade
/// ============================================================================
///
/// Rasterização por cobertura via supersampling (SSAA 8x8 = 64 amostras).
/// Prioriza qualidade visual máxima, com custo computacional elevado.
/// ============================================================================

import 'dart:typed_data';
import 'dart:math' as math;

class SSAARasterizer {
  final int width;
  final int height;
  final int samplesPerAxis;
  final bool useRotatedGrid;
  final double rotationRadians;
  final double edgeEps;
  final bool enableTileCulling;
  final int tileSize;
  late final int _sampleCount;
  late final Float32List _sampleOffsets;
  late final Uint8List _alphaLut;

  final Uint32List _buffer;
  final Uint8List _coverage;
  late final int _tilesX;
  late final int _tilesY;
  late final Uint8List _tileOpaque;

  List<double>? _lastVerticesRef;
  int _lastVertexCount = 0;
  Float64List? _cacheXi;
  Float64List? _cacheYi;
  Float64List? _cacheXj;
  Float64List? _cacheYj;
  Float64List? _cacheDx;
  Float64List? _cacheDy;
  Float64List? _cacheInvLen2;
  Float64List? _cacheInvDy;

  SSAARasterizer({
    required this.width,
    required this.height,
    this.samplesPerAxis = 8,
    this.useRotatedGrid = true,
    this.rotationRadians = 0.4636476090008061,
    this.edgeEps = 1e-6,
    this.enableTileCulling = true,
    this.tileSize = 8,
  })  : _buffer = Uint32List(width * height),
        _coverage = Uint8List(width * height) {
    _tilesX = (width + tileSize - 1) ~/ tileSize;
    _tilesY = (height + tileSize - 1) ~/ tileSize;
    _tileOpaque = Uint8List(_tilesX * _tilesY);
    _initSamples();
  }

  void _initSamples() {
    final n = samplesPerAxis.clamp(2, 16);
    _sampleCount = n * n;

    // Grid regular de alta densidade (centros de subpixels)
    // com opção de Rotated Grid (RGSS) para reduzir aliasing direcional.
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

    final edgeCount = n;
    Float64List xi;
    Float64List yi;
    Float64List xj;
    Float64List yj;
    Float64List dx;
    Float64List dy;
    Float64List invLen2;
    Float64List invDy;

    if (identical(vertices, _lastVerticesRef) && _lastVertexCount == n) {
      xi = _cacheXi!;
      yi = _cacheYi!;
      xj = _cacheXj!;
      yj = _cacheYj!;
      dx = _cacheDx!;
      dy = _cacheDy!;
      invLen2 = _cacheInvLen2!;
      invDy = _cacheInvDy!;
    } else {
      xi = Float64List(edgeCount);
      yi = Float64List(edgeCount);
      xj = Float64List(edgeCount);
      yj = Float64List(edgeCount);
      dx = Float64List(edgeCount);
      dy = Float64List(edgeCount);
      invLen2 = Float64List(edgeCount);
      invDy = Float64List(edgeCount);

      for (int i = 0; i < edgeCount; i++) {
        final i2 = i * 2;
        final j = (i + 1) % edgeCount;
        final j2 = j * 2;

        final x0 = vertices[i2];
        final y0 = vertices[i2 + 1];
        final x1 = vertices[j2];
        final y1 = vertices[j2 + 1];

        xi[i] = x0;
        yi[i] = y0;
        xj[i] = x1;
        yj[i] = y1;

        final ex = x1 - x0;
        final ey = y1 - y0;
        dx[i] = ex;
        dy[i] = ey;

        final len2 = ex * ex + ey * ey;
        invLen2[i] = len2 > 0 ? 1.0 / len2 : 0.0;
        invDy[i] = ey != 0 ? 1.0 / ey : 0.0;
      }

      _lastVerticesRef = vertices;
      _lastVertexCount = n;
      _cacheXi = xi;
      _cacheYi = yi;
      _cacheXj = xj;
      _cacheYj = yj;
      _cacheDx = dx;
      _cacheDy = dy;
      _cacheInvLen2 = invLen2;
      _cacheInvDy = invDy;
    }

    final offsets = _sampleOffsets;
    final samplesLen = offsets.length;
    final sampleCount = _sampleCount;
    final eps2 = edgeEps * edgeEps;

    bool pointInPolygon(double x, double y) {
      bool inside = false;

      for (int i = 0; i < edgeCount; i++) {
        final x0 = xi[i];
        final y0 = yi[i];
        final y1 = yj[i];

        final ex = dx[i];
        final ey = dy[i];
        final il2 = invLen2[i];

        if (il2 > 0) {
          var t = ((x - x0) * ex + (y - y0) * ey) * il2;
          if (t < 0)
            t = 0;
          else if (t > 1) t = 1;
          final cx = x0 + t * ex;
          final cy = y0 + t * ey;
          final dxp = x - cx;
          final dyp = y - cy;
          final dist2 = dxp * dxp + dyp * dyp;
          if (dist2 <= eps2) return true;
        }

        final intersects =
            ((y0 > y) != (y1 > y)) && (x < (ex * (y - y0) * invDy[i]) + x0);
        if (intersects) inside = !inside;
      }

      return inside;
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

    for (int y = yStart; y <= yEnd; y++) {
      for (int x = xStart; x <= xEnd; x++) {
        int insideCount = 0;

        for (int s = 0; s < samplesLen; s += 2) {
          final sx = x + offsets[s];
          final sy = y + offsets[s + 1];
          if (pointInPolygon(sx, sy)) {
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
