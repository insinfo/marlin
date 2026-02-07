/// ============================================================================
/// RHBD — Rasterização Híbrida em Blocos para Dart
/// ============================================================================
///
/// Combina ideias de rasterização por varredura e buffer de acumulação,
/// junto com divisão espacial (tiling).
///
/// PRINCÍPIO CENTRAL:
///   1. Divide a imagem em BLOCOS menores (tiles), ex: 32×32 pixels
///   2. Cada bloco é processado quase independentemente
///   3. Dentro de cada bloco, aplica rasterização tipo ACUMULAÇÃO DE ARESTAS
///   4. Sparse global, denso local
///
/// BENEFÍCIOS:
///   - Localidade de memória: cada bloco cabe no cache L1
///   - Facilita paralelismo: blocos diferentes em isolates diferentes
///   - Evita tocar pixel a pixel regiões vazias da imagem
///   - Loop interno extremamente enxuto
///
library rhbd;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES
// ─────────────────────────────────────────────────────────────────────────────

/// Tamanho do bloco/tile em pixels
const int kTileSize = 32;

/// Ponto fixo 24.8 para precisão subpixel
const int kFracBits = 8;
const int kFracOne = 1 << kFracBits;
const int kFracHalf = 1 << (kFracBits - 1);

// ─────────────────────────────────────────────────────────────────────────────
// ARESTA EM PONTO FIXO
// ─────────────────────────────────────────────────────────────────────────────

class FixedEdge {
  /// Coordenadas em ponto fixo 24.8
  final int x0, y0, x1, y1;

  /// Direção: +1 se descendo, -1 se subindo
  final int dir;

  /// Slope dx/dy em ponto fixo (para cálculo de interseção)
  final int slopeDxDy;

  FixedEdge({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.dir,
    required this.slopeDxDy,
  });

  factory FixedEdge.fromDouble(double x0, double y0, double x1, double y1) {
    // Garantir que y0 <= y1 (aresta sempre vai de cima para baixo)
    int dir = 1;
    if (y0 > y1) {
      final tx = x0;
      x0 = x1;
      x1 = tx;
      final ty = y0;
      y0 = y1;
      y1 = ty;
      dir = -1;
    }

    final fx0 = (x0 * kFracOne).toInt();
    final fy0 = (y0 * kFracOne).toInt();
    final fx1 = (x1 * kFracOne).toInt();
    final fy1 = (y1 * kFracOne).toInt();

    final dy = fy1 - fy0;
    final dx = fx1 - fx0;

    // Slope em ponto fixo: (dx / dy) << kFracBits
    final slope = dy != 0 ? ((dx << kFracBits) ~/ dy) : 0;

    return FixedEdge(
      x0: fx0,
      y0: fy0,
      x1: fx1,
      y1: fy1,
      dir: dir,
      slopeDxDy: slope,
    );
  }

  /// Calcula X na scanline Y (em ponto fixo)
  int xAtY(int y) {
    if (y <= y0) return x0;
    if (y >= y1) return x1;
    final dy = y - y0;
    return x0 + ((dy * slopeDxDy) >> kFracBits);
  }

  /// Verifica se a aresta cruza um tile
  bool intersectsTile(int tileX, int tileY, int tileSize) {
    final tileLeft = tileX * tileSize * kFracOne;
    final tileRight = (tileX + 1) * tileSize * kFracOne;
    final tileTop = tileY * tileSize * kFracOne;
    final tileBottom = (tileY + 1) * tileSize * kFracOne;

    // Verificar overlap de bounding boxes
    final edgeLeft = math.min(x0, x1);
    final edgeRight = math.max(x0, x1);
    final edgeTop = y0;
    final edgeBottom = y1;

    return edgeRight >= tileLeft &&
        edgeLeft <= tileRight &&
        edgeBottom >= tileTop &&
        edgeTop <= tileBottom;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TILE/BLOCO
// ─────────────────────────────────────────────────────────────────────────────

/// Representa um tile com seu buffer de acumulação
class Tile {
  final int x, y; // Posição do tile em coordenadas de tile

  Tile(this.x, this.y);

  void clear() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR RHBD
// ─────────────────────────────────────────────────────────────────────────────

class RHBDRasterizer {
  final int width;
  final int height;

  /// Número de tiles em cada direção
  final int tilesX;
  final int tilesY;

  /// Framebuffer final
  late final Uint32List _framebuffer;

  /// Pool de tiles (reutilizáveis)
  late final List<List<Tile>> _tiles;

  RHBDRasterizer({required this.width, required this.height})
      : tilesX = (width + kTileSize - 1) ~/ kTileSize,
        tilesY = (height + kTileSize - 1) ~/ kTileSize {
    _framebuffer = Uint32List(width * height);

    // Inicializar grid de tiles
    _tiles = List.generate(
        tilesY, (ty) => List.generate(tilesX, (tx) => Tile(tx, ty)));
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
    for (final row in _tiles) {
      for (final tile in row) {
        tile.clear();
      }
    }
  }

  /// Desenha um polígono usando o algoritmo híbrido
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;

    final n = vertices.length ~/ 2;
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    final edgeX1 = List<double>.filled(n, 0.0);
    final edgeY1 = List<double>.filled(n, 0.0);
    final edgeX2 = List<double>.filled(n, 0.0);
    final edgeY2 = List<double>.filled(n, 0.0);

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x1 = vertices[i * 2];
      final y1 = vertices[i * 2 + 1];
      final x2 = vertices[j * 2];
      final y2 = vertices[j * 2 + 1];

      edgeX1[i] = x1;
      edgeY1[i] = y1;
      edgeX2[i] = x2;
      edgeY2[i] = y2;

      if (x1 < minX) minX = x1;
      if (x1 > maxX) maxX = x1;
      if (y1 < minY) minY = y1;
      if (y1 > maxY) maxY = y1;
    }

    final minXi = minX.floor().clamp(0, width - 1);
    final maxXi = maxX.ceil().clamp(0, width - 1);
    final minYi = minY.floor().clamp(0, height - 1);
    final maxYi = maxY.ceil().clamp(0, height - 1);

    final minTileX = (minXi ~/ kTileSize).clamp(0, tilesX - 1);
    final maxTileX = (maxXi ~/ kTileSize).clamp(0, tilesX - 1);
    final minTileY = (minYi ~/ kTileSize).clamp(0, tilesY - 1);
    final maxTileY = (maxYi ~/ kTileSize).clamp(0, tilesY - 1);

    // Processar por tiles dentro da bbox do polígono.
    for (int ty = minTileY; ty <= maxTileY; ty++) {
      final tileY0 = ty * kTileSize;
      final tileY1 = math.min(tileY0 + kTileSize - 1, height - 1);
      final yStart = math.max(tileY0, minYi);
      final yEnd = math.min(tileY1, maxYi);

      for (int tx = minTileX; tx <= maxTileX; tx++) {
        final tileX0 = tx * kTileSize;
        final tileX1 = math.min(tileX0 + kTileSize - 1, width - 1);
        final xStart = math.max(tileX0, minXi);
        final xEnd = math.min(tileX1, maxXi);

        for (int y = yStart; y <= yEnd; y++) {
          final cy = y + 0.5;

          for (int x = xStart; x <= xEnd; x++) {
            final cx = x + 0.5;
            final alpha = _computePixelAlpha(
              n,
              edgeX1,
              edgeY1,
              edgeX2,
              edgeY2,
              cx,
              cy,
            );

            if (alpha > 0) {
              _blendPixel(x, y, color, alpha);
            }
          }
        }
      }
    }
  }

  @pragma('vm:prefer-inline')
  int _computePixelAlpha(
    int edgeCount,
    List<double> edgeX1,
    List<double> edgeY1,
    List<double> edgeX2,
    List<double> edgeY2,
    double px,
    double py,
  ) {
    int winding = 0;
    double minDistSq = double.infinity;

    for (int i = 0; i < edgeCount; i++) {
      final x1 = edgeX1[i];
      final y1 = edgeY1[i];
      final x2 = edgeX2[i];
      final y2 = edgeY2[i];

      if (y1 <= py) {
        if (y2 > py && _isLeft(x1, y1, x2, y2, px, py) > 0) {
          winding++;
        }
      } else {
        if (y2 <= py && _isLeft(x1, y1, x2, y2, px, py) < 0) {
          winding--;
        }
      }

      final distSq = _distanceToSegmentSq(x1, y1, x2, y2, px, py);
      if (distSq < minDistSq) minDistSq = distSq;
    }

    final inside = winding != 0;
    final minDist = minDistSq.isFinite ? math.sqrt(minDistSq) : 0.0;
    final signedDist = inside ? -minDist : minDist;

    if (signedDist <= -0.5) return 255;
    if (signedDist >= 0.5) return 0;

    final t = (0.5 - signedDist).clamp(0.0, 1.0);
    final coverage = t * t * (3.0 - 2.0 * t);
    return (coverage * 255).round().clamp(0, 255);
  }

  @pragma('vm:prefer-inline')
  double _distanceToSegmentSq(
    double x1,
    double y1,
    double x2,
    double y2,
    double px,
    double py,
  ) {
    final vx = x2 - x1;
    final vy = y2 - y1;
    final wx = px - x1;
    final wy = py - y1;
    final vv = vx * vx + vy * vy;

    if (vv <= 1e-12) {
      return wx * wx + wy * wy;
    }

    var t = (wx * vx + wy * vy) / vv;
    if (t < 0.0) {
      t = 0.0;
    } else if (t > 1.0) {
      t = 1.0;
    }

    final cx = x1 + vx * t;
    final cy = y1 + vy * t;
    final dx = px - cx;
    final dy = py - cy;
    return dx * dx + dy * dy;
  }

  @pragma('vm:prefer-inline')
  double _isLeft(
    double x1,
    double y1,
    double x2,
    double y2,
    double px,
    double py,
  ) {
    return (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1);
  }

  @pragma('vm:prefer-inline')
  void _blendPixel(int x, int y, int color, int alpha) {
    if (alpha <= 0) return;

    final idx = y * width + x;
    if (alpha >= 255) {
      _framebuffer[idx] = color;
      return;
    }

    final bg = _framebuffer[idx];
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    final invA = 255 - alpha;
    final r = (colorR * alpha + bgR * invA) ~/ 255;
    final g = (colorG * alpha + bgG * invA) ~/ 255;
    final b = (colorB * alpha + bgB * invA) ~/ 255;

    _framebuffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  Uint32List get buffer => _framebuffer;
}
