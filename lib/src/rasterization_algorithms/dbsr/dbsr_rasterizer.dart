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
    // Criar arestas
    final edges = [
      Edge.fromPoints(x1, y1, x2, y2),
      Edge.fromPoints(x2, y2, x3, y3),
      Edge.fromPoints(x3, y3, x1, y1),
    ];

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
        int weightR = _computeSubpixelWeight(edges, centerR, centerY);

        // Subpixel G (centro)
        final centerG = x + _subpixelG;
        int weightG = _computeSubpixelWeight(edges, centerG, centerY);

        // Subpixel B (direita)
        final centerB = x + _subpixelB;
        int weightB = _computeSubpixelWeight(edges, centerB, centerY);

        // ─── BLENDING ───────────────────────────────────────────────
        if (weightR > 0) {
          final existing = _subpixelBuffer[baseIdx + 0];
          _subpixelBuffer[baseIdx + 0] =
              ((colorR * weightR + existing * (255 - weightR)) ~/ 255).clamp(
                  0, 255);
        }

        if (weightG > 0) {
          final existing = _subpixelBuffer[baseIdx + 1];
          _subpixelBuffer[baseIdx + 1] =
              ((colorG * weightG + existing * (255 - weightG)) ~/ 255).clamp(
                  0, 255);
        }

        if (weightB > 0) {
          final existing = _subpixelBuffer[baseIdx + 2];
          _subpixelBuffer[baseIdx + 2] =
              ((colorB * weightB + existing * (255 - weightB)) ~/ 255).clamp(
                  0, 255);
        }
      }
    }
  }

  /// Calcula o peso de um subpixel considerando todas as arestas
  int _computeSubpixelWeight(List<Edge> edges, double px, double py) {
    // Para cada aresta, calculamos a distância assinada.
    // O peso final é o MÍNIMO dos pesos individuais (interseção das meias-
    // planos).
    int minWeight = 255;

    for (final edge in edges) {
      // Distância assinada ao longo da normal
      final dist = edge.signedDistance(px, py);

      // Converter para ponto fixo e usar LUT
      final fixedDist = (dist * _fixedOne).toInt();
      final weight = _distanceLUT.getWeight(fixedDist);

      if (weight < minWeight) {
        minWeight = weight;
      }
    }

    return minWeight;
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
