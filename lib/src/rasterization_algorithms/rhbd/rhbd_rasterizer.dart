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

  /// Buffer A: acumulação de área local (soma em cada pixel)
  final Float32List areaBuffer;

  /// Buffer X: acumulação de cobertura infinita à direita
  final Float32List coverBuffer;

  /// Lista de arestas que afetam este tile
  final List<FixedEdge> edges = [];

  Tile(this.x, this.y)
      : areaBuffer = Float32List(kTileSize * kTileSize),
        coverBuffer = Float32List(kTileSize);

  void clear() {
    areaBuffer.fillRange(0, areaBuffer.length, 0.0);
    coverBuffer.fillRange(0, coverBuffer.length, 0.0);
    edges.clear();
  }
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

    // 1. Criar arestas em ponto fixo
    final edges = <FixedEdge>[];
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = vertices[i * 2];
      final y0 = vertices[i * 2 + 1];
      final x1 = vertices[j * 2];
      final y1 = vertices[j * 2 + 1];

      // Ignorar arestas horizontais
      if ((y1 - y0).abs() < 0.001) continue;

      edges.add(FixedEdge.fromDouble(x0, y0, x1, y1));
    }

    // 2. Binning: distribuir arestas para tiles
    for (final edge in edges) {
      for (int ty = 0; ty < tilesY; ty++) {
        for (int tx = 0; tx < tilesX; tx++) {
          if (edge.intersectsTile(tx, ty, kTileSize)) {
            _tiles[ty][tx].edges.add(edge);
          }
        }
      }
    }

    // 3. Processar cada tile que tem arestas
    for (int ty = 0; ty < tilesY; ty++) {
      for (int tx = 0; tx < tilesX; tx++) {
        final tile = _tiles[ty][tx];
        if (tile.edges.isNotEmpty) {
          _processTile(tile, color);
        }
      }
    }
  }

  /// Processa um tile usando acumulação de arestas
  void _processTile(Tile tile, int color) {
    final tilePixelX = tile.x * kTileSize;
    final tilePixelY = tile.y * kTileSize;

    // Para cada aresta que afeta o tile
    for (final edge in tile.edges) {
      _rasterizeEdgeInTile(tile, edge, tilePixelX, tilePixelY);
    }

    // Integrar e aplicar cor
    _integrateTile(tile, tilePixelX, tilePixelY, color);
  }

  /// Rasteriza uma aresta dentro de um tile, acumulando no buffer
  void _rasterizeEdgeInTile(
      Tile tile, FixedEdge edge, int tilePixelX, int tilePixelY) {
    // Range de scanlines dentro do tile
    final tileTop = tilePixelY * kFracOne;
    final tileBottom = (tilePixelY + kTileSize) * kFracOne;

    final yStart = math.max(edge.y0, tileTop);
    final yEnd = math.min(edge.y1, tileBottom);

    if (yStart >= yEnd) return;

    // Iterar por linhas fracionárias
    // Convertemos para linhas de pixel inteiras
    final pixelYStart = (yStart ~/ kFracOne) - tilePixelY;
    final pixelYEnd = ((yEnd + kFracOne - 1) ~/ kFracOne) - tilePixelY;

    for (int localY = math.max(0, pixelYStart);
        localY < math.min(kTileSize, pixelYEnd);
        localY++) {
      final scanY = (tilePixelY + localY) * kFracOne + kFracHalf;

      // Skip se fora da aresta
      if (scanY < edge.y0 || scanY >= edge.y1) continue;

      // Calcular X na intersecção
      final xFixed = edge.xAtY(scanY);
      final xPixel = xFixed ~/ kFracOne;
      final xFrac = xFixed & (kFracOne - 1);

      final localX = xPixel - tilePixelX;

      if (localX >= 0 && localX < kTileSize) {
        // Contribuição fracionária no pixel da interseção
        final coverage = (kFracOne - xFrac).toDouble() / kFracOne;
        tile.areaBuffer[localY * kTileSize + localX] += coverage * edge.dir;

        // Contribuição de cobertura infinita para pixels à direita
        if (localX + 1 < kTileSize) {
          tile.coverBuffer[localY] += edge.dir.toDouble();
        }
      } else if (localX < 0) {
        // Aresta está à esquerda do tile: afeta toda a linha
        tile.coverBuffer[localY] += edge.dir.toDouble();
      }
    }
  }

  /// Integra o buffer de acumulação e aplica cor ao framebuffer
  void _integrateTile(Tile tile, int tilePixelX, int tilePixelY, int color) {
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;

    for (int localY = 0; localY < kTileSize; localY++) {
      final globalY = tilePixelY + localY;
      if (globalY >= height) break;

      // Soma prefixo horizontal
      double accumulator = 0.0;

      for (int localX = 0; localX < kTileSize; localX++) {
        final globalX = tilePixelX + localX;
        if (globalX >= width) break;

        // Somar área local
        accumulator += tile.areaBuffer[localY * kTileSize + localX];

        // Adicionar cobertura de colunas anteriores
        if (localX == 0) {
          accumulator += tile.coverBuffer[localY];
        }

        // Cobertura final (clamp 0..1, winding rule)
        var coverage = accumulator.abs().clamp(0.0, 1.0);

        if (coverage > 0.001) {
          final idx = globalY * width + globalX;
          final alpha = (coverage * 255).toInt();

          if (alpha >= 255) {
            _framebuffer[idx] = 0xFF000000 | (colorR << 16) | (colorG << 8) | colorB;
          } else {
            // Blend
            final bg = _framebuffer[idx];
            final bgR = (bg >> 16) & 0xFF;
            final bgG = (bg >> 8) & 0xFF;
            final bgB = bg & 0xFF;

            final invA = 255 - alpha;
            final r = (colorR * alpha + bgR * invA) ~/ 255;
            final g = (colorG * alpha + bgG * invA) ~/ 255;
            final b = (colorB * alpha + bgB * invA) ~/ 255;

            _framebuffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
          }
        }
      }
    }
  }

  Uint32List get buffer => _framebuffer;
}
