/// ============================================================================
/// DBSR — Distance-Based Subpixel Rasterization
/// ============================================================================
///
/// Cada subpixel (R, G, B de um LCD) contribui para a cobertura proporcional
/// a um modelo de distância. A inovação é usar distância Manhattan
/// (não Euclidiana) como proxy rápido, combinado com um decaimento
/// proporcional ao inverso da distância.
///
/// PRINCÍPIO CENTRAL:
///   - Divide cada pixel em 3 subpixels (R, G, B no layout horizontal)
///   - Calcula a distância de cada subpixel à aresta mais próxima
///   - Usa uma LUT pré-computada para mapear distância → peso de cobertura
///   - Suporta loop unrolling para processar subpixels em paralelo
///
/// INOVAÇÃO:
///   - Distância Manhattan como proxy O(1) vs Euclidiana O(sqrt)
///   - LUT de pesos baseada em distância, não área
///   - Posições subpixel codificadas como offsets fracionários fixos
///   - Otimizado para Dart: usa int, minimiza branches e objetos
///
library dbsr;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DE SUBPIXEL
// ─────────────────────────────────────────────────────────────────────────────

/// Offsets subpixel horizontais em fração do pixel (0.0 = borda esquerda)
/// Layout LCD RGB padrão: R à esquerda, G no centro, B à direita
const double _subpixelR = 1.0 / 6.0; // Centro do subpixel R
const double _subpixelG = 3.0 / 6.0; // Centro do subpixel G
const double _subpixelB = 5.0 / 6.0; // Centro do subpixel B

/// Ponto fixo para precisão subpixel
const int _fixedShift = 8;
const int _fixedOne = 1 << _fixedShift;

// ─────────────────────────────────────────────────────────────────────────────
// LUT DE PESOS DE DISTÂNCIA
// ─────────────────────────────────────────────────────────────────────────────

/// Look-Up Table que mapeia distância para peso de cobertura.
///
/// A ideia é que pixels próximos da aresta têm cobertura parcial,
/// enquanto pixels longe têm cobertura 0 ou 1.
class DistanceWeightLUT {
  static const int lutSize = 256;
  static const int lutHalf = lutSize ~/ 2;

  final Uint8List _weights;

  DistanceWeightLUT() : _weights = Uint8List(lutSize) {
    _precompute();
  }

  void _precompute() {
    // Função de peso: baseada em smoothstep com largura de transição = 1 pixel
    for (int i = 0; i < lutSize; i++) {
      // Mapear índice para distância normalizada [-1, 1]
      final d = (i - lutHalf) / lutHalf;

      // Peso: smoothstep invertido
      // d = -1 → peso = 1 (completamente dentro)
      // d =  0 → peso = 0.5 (na borda)
      // d = +1 → peso = 0 (completamente fora)
      double weight;
      if (d <= -1.0) {
        weight = 1.0;
      } else if (d >= 1.0) {
        weight = 0.0;
      } else {
        final t = (1.0 - d) * 0.5; // Mapeia [-1,1] para [0,1]
        weight = t * t * (3.0 - 2.0 * t);
      }

      _weights[i] = (weight * 255).round().clamp(0, 255);
    }
  }

  /// Obtém peso para distância assinada em ponto fixo
  int getWeight(int signedDistance) {
    // Normaliza distância para índice
    final normalized = (signedDistance >> 1) + lutHalf;
    final index = normalized.clamp(0, lutSize - 1);
    return _weights[index];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DADOS DE ARESTA
// ─────────────────────────────────────────────────────────────────────────────

class Edge {
  final double x1, y1, x2, y2;

  /// Normal unitária (apontando para fora)
  final double nx, ny;

  /// Distância do ponto de referência (para cálculo incremental)
  final double d;

  Edge({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.nx,
    required this.ny,
    required this.d,
  });

  /// Cria aresta a partir de dois pontos
  factory Edge.fromPoints(double x1, double y1, double x2, double y2) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    final len = math.sqrt(dx * dx + dy * dy);

    // Normal perpendicular (rotação 90°)
    // Direção: apontando para a "direita" do vetor (sentido horário)
    final nx = dy / len;
    final ny = -dx / len;

    // Distância da origem ao longo da normal
    final d = nx * x1 + ny * y1;

    return Edge(x1: x1, y1: y1, x2: x2, y2: y2, nx: nx, ny: ny, d: d);
  }

  /// Calcula distância assinada de um ponto à linha da aresta
  double signedDistance(double px, double py) {
    return nx * px + ny * py - d;
  }

  /// Calcula distância assinada usando aproximação Manhattan (mais rápida)
  /// |d| ≈ |Δx·nx| + |Δy·ny| (dentro de √2 do valor real)
  double manhattanDistance(double px, double py) {
    // Diferença para um ponto na aresta
    final cx = (x1 + x2) * 0.5;
    final cy = (y1 + y2) * 0.5;
    return (px - cx).abs() * nx.abs() + (py - cy).abs() * ny.abs();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR DBSR
// ─────────────────────────────────────────────────────────────────────────────

/// Rasterizador Distance-Based Subpixel Rasterization
///
/// Otimizado para displays LCD com layout RGB horizontal.
class DBSRRasterizer {
  final int width;
  final int height;

  /// Buffer de subpixels: 3 bytes por pixel (R, G, B)
  late final Uint8List _subpixelBuffer;

  /// Buffer de pixels finais (para exportação)
  late final Uint32List _pixelBuffer;

  /// LUT de pesos de distância
  final DistanceWeightLUT _distanceLUT;

  DBSRRasterizer({required this.width, required this.height})
      : _distanceLUT = DistanceWeightLUT() {
    _subpixelBuffer = Uint8List(width * height * 3);
    _pixelBuffer = Uint32List(width * height);
  }

  /// Limpa os buffers
  void clear([int backgroundColor = 0xFF000000]) {
    _subpixelBuffer.fillRange(0, _subpixelBuffer.length, 0);

    // Preencher buffer de pixels com cor de fundo
    final r = (backgroundColor >> 16) & 0xFF;
    final g = (backgroundColor >> 8) & 0xFF;
    final b = backgroundColor & 0xFF;

    for (int i = 0; i < width * height; i++) {
      _subpixelBuffer[i * 3 + 0] = r;
      _subpixelBuffer[i * 3 + 1] = g;
      _subpixelBuffer[i * 3 + 2] = b;
    }
  }

  /// Desenha um triângulo com anti-aliasing subpixel
  void drawTriangle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int color,
  ) {
    // Garantir orientação CCW (normais apontam para fora)
    final area = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
    if (area == 0) return; // Degenerado
    if (area < 0) {
      final tx = x2;
      final ty = y2;
      x2 = x3;
      y2 = y3;
      x3 = tx;
      y3 = ty;
    }

    // Pré-calcular arestas (normais e d) — evita alocações
    final dx1 = x2 - x1;
    final dy1 = y2 - y1;
    final len1 = math.sqrt(dx1 * dx1 + dy1 * dy1);
    if (len1 == 0) return;
    final nx1 = dy1 / len1;
    final ny1 = -dx1 / len1;
    final d1 = nx1 * x1 + ny1 * y1;

    final dx2 = x3 - x2;
    final dy2 = y3 - y2;
    final len2 = math.sqrt(dx2 * dx2 + dy2 * dy2);
    if (len2 == 0) return;
    final nx2 = dy2 / len2;
    final ny2 = -dx2 / len2;
    final d2 = nx2 * x2 + ny2 * y2;

    final dx3 = x1 - x3;
    final dy3 = y1 - y3;
    final len3 = math.sqrt(dx3 * dx3 + dy3 * dy3);
    if (len3 == 0) return;
    final nx3 = dy3 / len3;
    final ny3 = -dx3 / len3;
    final d3 = nx3 * x3 + ny3 * y3;

    // Bounding box
    final minX = math.min(x1, math.min(x2, x3)).floor().clamp(0, width - 1);
    final maxX = math.max(x1, math.max(x2, x3)).ceil().clamp(0, width - 1);
    final minY = math.min(y1, math.min(y2, y3)).floor().clamp(0, height - 1);
    final maxY = math.max(y1, math.max(y2, y3)).ceil().clamp(0, height - 1);

    // Extrair canais de cor
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;

    // Rasterização por pixel
    for (int y = minY; y <= maxY; y++) {
      final centerY = y + 0.5; // Centro do pixel

      for (int x = minX; x <= maxX; x++) {
        final baseIdx = (y * width + x) * 3;

        // ─── LOOP UNROLLING: Processa os 3 subpixels em paralelo ───

        // Subpixel R (esquerda)
        final centerR = x + _subpixelR;
        int weightR = _computeSubpixelWeight3(
          centerR,
          centerY,
          nx1,
          ny1,
          d1,
          nx2,
          ny2,
          d2,
          nx3,
          ny3,
          d3,
        );

        // Subpixel G (centro)
        final centerG = x + _subpixelG;
        int weightG = _computeSubpixelWeight3(
          centerG,
          centerY,
          nx1,
          ny1,
          d1,
          nx2,
          ny2,
          d2,
          nx3,
          ny3,
          d3,
        );

        // Subpixel B (direita)
        final centerB = x + _subpixelB;
        int weightB = _computeSubpixelWeight3(
          centerB,
          centerY,
          nx1,
          ny1,
          d1,
          nx2,
          ny2,
          d2,
          nx3,
          ny3,
          d3,
        );

        // ─── BLENDING ───────────────────────────────────────────────
        if (weightR > 0) {
          final existing = _subpixelBuffer[baseIdx + 0];
          _subpixelBuffer[baseIdx + 0] =
              ((colorR * weightR + existing * (255 - weightR)) ~/ 255)
                  .clamp(0, 255);
        }

        if (weightG > 0) {
          final existing = _subpixelBuffer[baseIdx + 1];
          _subpixelBuffer[baseIdx + 1] =
              ((colorG * weightG + existing * (255 - weightG)) ~/ 255)
                  .clamp(0, 255);
        }

        if (weightB > 0) {
          final existing = _subpixelBuffer[baseIdx + 2];
          _subpixelBuffer[baseIdx + 2] =
              ((colorB * weightB + existing * (255 - weightB)) ~/ 255)
                  .clamp(0, 255);
        }
      }
    }
  }

  /// Desenha um polígono (concavo/convexo) com AA subpixel
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return; // Mínimo 3 vértices

    final n = vertices.length ~/ 2;

    // Bounding box
    var minX = vertices[0];
    var maxX = vertices[0];
    var minY = vertices[1];
    var maxY = vertices[1];
    for (int i = 1; i < n; i++) {
      final x = vertices[i * 2];
      final y = vertices[i * 2 + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    final minXi = minX.floor().clamp(0, width - 1);
    final maxXi = maxX.ceil().clamp(0, width - 1);
    final minYi = minY.floor().clamp(0, height - 1);
    final maxYi = maxY.ceil().clamp(0, height - 1);

    // Pré-calcular arestas sem alocação de objetos
    final edgeCount = n;
    final edgeX1 = List<double>.filled(edgeCount, 0.0);
    final edgeY1 = List<double>.filled(edgeCount, 0.0);
    final edgeX2 = List<double>.filled(edgeCount, 0.0);
    final edgeY2 = List<double>.filled(edgeCount, 0.0);

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
    }

    // Extrair canais de cor
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;

    for (int y = minYi; y <= maxYi; y++) {
      final centerY = y + 0.5;

      for (int x = minXi; x <= maxXi; x++) {
        final baseIdx = (y * width + x) * 3;

        // Subpixel R (esquerda)
        final centerR = x + _subpixelR;
        final weightR = _computeSubpixelWeightPolygon(
          centerR,
          centerY,
          edgeCount,
          edgeX1,
          edgeY1,
          edgeX2,
          edgeY2,
        );

        // Subpixel G (centro)
        final centerG = x + _subpixelG;
        final weightG = _computeSubpixelWeightPolygon(
          centerG,
          centerY,
          edgeCount,
          edgeX1,
          edgeY1,
          edgeX2,
          edgeY2,
        );

        // Subpixel B (direita)
        final centerB = x + _subpixelB;
        final weightB = _computeSubpixelWeightPolygon(
          centerB,
          centerY,
          edgeCount,
          edgeX1,
          edgeY1,
          edgeX2,
          edgeY2,
        );

        if (weightR > 0) {
          final existing = _subpixelBuffer[baseIdx + 0];
          _subpixelBuffer[baseIdx + 0] =
              ((colorR * weightR + existing * (255 - weightR)) ~/ 255)
                  .clamp(0, 255);
        }

        if (weightG > 0) {
          final existing = _subpixelBuffer[baseIdx + 1];
          _subpixelBuffer[baseIdx + 1] =
              ((colorG * weightG + existing * (255 - weightG)) ~/ 255)
                  .clamp(0, 255);
        }

        if (weightB > 0) {
          final existing = _subpixelBuffer[baseIdx + 2];
          _subpixelBuffer[baseIdx + 2] =
              ((colorB * weightB + existing * (255 - weightB)) ~/ 255)
                  .clamp(0, 255);
        }
      }
    }
  }

  /// Desenha um retângulo
  void drawRect(double x, double y, double w, double h, int color) {
    final vertices = <double>[x, y, x + w, y, x + w, y + h, x, y + h];
    drawPolygon(vertices, color);
  }

  /// Calcula o peso de um subpixel considerando três arestas
  @pragma('vm:prefer-inline')
  int _computeSubpixelWeight3(
    double px,
    double py,
    double nx1,
    double ny1,
    double d1,
    double nx2,
    double ny2,
    double d2,
    double nx3,
    double ny3,
    double d3,
  ) {
    // Para cada aresta, calculamos a distância assinada.
    // O peso final é o MÍNIMO dos pesos individuais (interseção das meias-
    // planos).
    final dist1 = nx1 * px + ny1 * py - d1;
    int minWeight = _distanceLUT.getWeight((dist1 * _fixedOne).toInt());

    final dist2 = nx2 * px + ny2 * py - d2;
    final weight2 = _distanceLUT.getWeight((dist2 * _fixedOne).toInt());
    if (weight2 < minWeight) minWeight = weight2;

    final dist3 = nx3 * px + ny3 * py - d3;
    final weight3 = _distanceLUT.getWeight((dist3 * _fixedOne).toInt());
    if (weight3 < minWeight) minWeight = weight3;

    return minWeight;
  }

  /// Peso por subpixel para polígonos arbitrários (winding + distância mínima)
  @pragma('vm:prefer-inline')
  int _computeSubpixelWeightPolygon(
    double px,
    double py,
    int edgeCount,
    List<double> edgeX1,
    List<double> edgeY1,
    List<double> edgeX2,
    List<double> edgeY2,
  ) {
    int winding = 0;
    double minDistSq = double.infinity;

    for (int i = 0; i < edgeCount; i++) {
      final x1 = edgeX1[i];
      final y1 = edgeY1[i];
      final x2 = edgeX2[i];
      final y2 = edgeY2[i];

      // Winding (Non-Zero Rule)
      if (y1 <= py) {
        if (y2 > py && _isLeft(x1, y1, x2, y2, px, py) > 0) {
          winding++;
        }
      } else {
        if (y2 <= py && _isLeft(x1, y1, x2, y2, px, py) < 0) {
          winding--;
        }
      }

      // Distância à aresta como SEGMENTO (evita "linhas fantasmas" fora do polígono)
      final vx = x2 - x1;
      final vy = y2 - y1;
      final vv = vx * vx + vy * vy;

      double t;
      if (vv <= 1e-12) {
        t = 0.0;
      } else {
        t = ((px - x1) * vx + (py - y1) * vy) / vv;
        if (t < 0.0) {
          t = 0.0;
        } else if (t > 1.0) {
          t = 1.0;
        }
      }

      final cx = x1 + vx * t;
      final cy = y1 + vy * t;
      final dx = px - cx;
      final dy = py - cy;
      final distSq = dx * dx + dy * dy;

      if (distSq < minDistSq) minDistSq = distSq;
    }

    final inside = winding != 0;
    final minAbs = minDistSq.isFinite ? math.sqrt(minDistSq) : 0.0;
    final signedDist = inside ? -minAbs : minAbs;
    return _distanceLUT.getWeight((signedDist * _fixedOne).toInt());
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

  /// Converte buffer de subpixels para buffer de pixels ARGB
  void resolve() {
    for (int i = 0; i < width * height; i++) {
      final r = _subpixelBuffer[i * 3 + 0];
      final g = _subpixelBuffer[i * 3 + 1];
      final b = _subpixelBuffer[i * 3 + 2];
      _pixelBuffer[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }

  /// Retorna o buffer de pixels
  Uint32List get pixels {
    resolve();
    return _pixelBuffer;
  }

  /// Retorna o buffer de subpixels (para debug)
  Uint8List get subpixels => _subpixelBuffer;
}
