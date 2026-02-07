/// ============================================================================
/// EPL_AA — EdgePlane Lookup Anti-Aliasing
/// ============================================================================
///
/// Uma ideia bem diferente do "4×4 subpixel" e do "cell accumulation":
/// em vez de amostrar subpixels, calcula-se diretamente a FRAÇÃO DE ÁREA
/// que um semi-plano (definido pela aresta mais relevante) ocupa dentro
/// do quadrado do pixel.
///
/// PRINCÍPIO CENTRAL:
///   A cobertura do quadrado do pixel por um semi-plano depende APENAS de:
///   1. Orientação da reta (ângulo θ da normal/tangente)
///   2. Distância assinada (s) da reta ao centro do pixel
///
///   Ou seja: α ≈ C(θ, s)
///
///   Onde s é a distância em "unidades de pixel" e θ é a orientação.
///
/// TÉCNICA:
///   1. Pré-computa uma LUT 2D com coberturas para todas as combinações (θ, s)
///   2. Em runtime, apenas indexa a LUT e retorna o alpha
///   3. Fallback para 4×4 apenas em casos patológicos (vértices, interseções)
///
/// PERFORMANCE:
///   - Evita loops internos de 16 amostras
///   - Reduz branch misprediction
///   - Usa Uint8List e soma incremental
///   - A parte "pesada" fica confinada a poucos pixels
///
library epl_aa;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLE DE COBERTURA
// ─────────────────────────────────────────────────────────────────────────────

/// LUT 2D para cobertura de semi-plano.
///
/// Armazena, para cada combinação de (ângulo, distância), a porcentagem
/// de área do pixel coberta pelo semi-plano.
class CoverageLUT2D {
  /// Número de bins para o ângulo θ (0..π/2, explorando simetria)
  static const int thetaBins = 256;

  /// Número de bins para a distância s (tipicamente -1.0..+1.0 como folga)
  static const int distBins = 256;

  /// Tabela de coberturas (0..255)
  final Uint8List _table;

  CoverageLUT2D() : _table = Uint8List(thetaBins * distBins) {
    _precompute();
  }

  void _precompute() {
    // Para cada combinação (θ, s), calcula a área do quadrado [-0.5,0.5]²
    // que satisfaz n·p + s <= 0, onde n é o vetor normal unitário.
    for (int t = 0; t < thetaBins; t++) {
      // Ângulo no range [0, π/2] (simetria permite reduzir)
      final theta = (t / thetaBins) * (math.pi / 2);
      final nx = math.cos(theta);
      final ny = math.sin(theta);

      for (int d = 0; d < distBins; d++) {
        // Distância signada no range [-1.25, +1.25]
        final s = ((d / distBins) * 2.5) - 1.25;

        // Calcular área de cobertura usando clipping de polígono
        final coverage = _computeCoverage(nx, ny, s);
        _table[t * distBins + d] = (coverage * 255).round().clamp(0, 255);
      }
    }
  }

  /// Calcula a área de cobertura exata usando Sutherland-Hodgman clipping
  double _computeCoverage(double nx, double ny, double s) {
    // Quadrado do pixel: vértices em coordenadas locais [-0.5, 0.5]²
    // O semi-plano é n·p + s <= 0
    List<List<double>> polygon = [
      [-0.5, -0.5],
      [0.5, -0.5],
      [0.5, 0.5],
      [-0.5, 0.5]
    ];

    // Clip do polígono pelo semi-plano
    final clipped = _clipPolygon(polygon, nx, ny, s);

    // Calcular área do polígono resultante
    return _polygonArea(clipped);
  }

  /// Sutherland-Hodgman clipping de polígono por semi-plano
  List<List<double>> _clipPolygon(
      List<List<double>> poly, double nx, double ny, double s) {
    if (poly.isEmpty) return [];

    final result = <List<double>>[];

    for (int i = 0; i < poly.length; i++) {
      final current = poly[i];
      final next = poly[(i + 1) % poly.length];

      // Distância assinada de cada vértice
      final currentDist = nx * current[0] + ny * current[1] + s;
      final nextDist = nx * next[0] + ny * next[1] + s;

      if (currentDist <= 0) {
        // Vértice atual está dentro
        result.add(current);

        if (nextDist > 0) {
          // Próximo está fora: adicionar interseção
          final t = currentDist / (currentDist - nextDist);
          result.add([
            current[0] + t * (next[0] - current[0]),
            current[1] + t * (next[1] - current[1])
          ]);
        }
      } else {
        // Vértice atual está fora
        if (nextDist <= 0) {
          // Próximo está dentro: adicionar interseção
          final t = currentDist / (currentDist - nextDist);
          result.add([
            current[0] + t * (next[0] - current[0]),
            current[1] + t * (next[1] - current[1])
          ]);
        }
      }
    }

    return result;
  }

  /// Calcula área de um polígono usando fórmula do shoelace
  double _polygonArea(List<List<double>> poly) {
    if (poly.length < 3) return 0.0;

    double area = 0.0;
    for (int i = 0; i < poly.length; i++) {
      final j = (i + 1) % poly.length;
      area += poly[i][0] * poly[j][1];
      area -= poly[j][0] * poly[i][1];
    }

    return area.abs() / 2.0;
  }

  /// Obtém cobertura para um ângulo e distância
  int getCoverage(double theta, double signedDist) {
    // Normalizar ângulo para [0, π/2]
    var normalizedTheta = theta.abs();
    while (normalizedTheta > math.pi / 2) {
      normalizedTheta = math.pi - normalizedTheta;
    }

    // Índices na tabela
    final thetaIdx = ((normalizedTheta / (math.pi / 2)) * (thetaBins - 1))
        .round()
        .clamp(0, thetaBins - 1);
    final distIdx = (((signedDist + 1.25) / 2.5) * (distBins - 1))
        .round()
        .clamp(0, distBins - 1);

    return _table[thetaIdx * distBins + distIdx];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ARESTA PROCESSADA
// ─────────────────────────────────────────────────────────────────────────────

class EplProcessedEdge {
  final double x1, y1, x2, y2;

  /// Normal unitária
  final double nx, ny;

  /// Ângulo da normal
  final double theta;

  /// Comprimento da aresta
  final double length;

  /// Inverse length para normalização
  final double invLength;

  EplProcessedEdge({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.nx,
    required this.ny,
    required this.theta,
    required this.length,
    required this.invLength,
  });

  factory EplProcessedEdge.fromPoints(
      double x1, double y1, double x2, double y2) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    final len = math.sqrt(dx * dx + dy * dy);
    final invLen = len > 0 ? 1.0 / len : 0.0;

    // Normal apontando para a direita do vetor (sentido horário)
    final nx = dy * invLen;
    final ny = -dx * invLen;

    // Ângulo da normal
    final theta = math.atan2(ny, nx);

    return EplProcessedEdge(
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      nx: nx,
      ny: ny,
      theta: theta,
      length: len,
      invLength: invLen,
    );
  }

  /// Calcula distância assinada de um ponto ao plano da aresta
  double signedDistance(double px, double py) {
    return nx * (px - x1) + ny * (py - y1);
  }

  /// Verifica se o ponto está próximo de um endpoint (caso patológico)
  bool isNearEndpoint(double px, double py, double threshold) {
    final d1 = (px - x1).abs() + (py - y1).abs(); // Manhattan
    final d2 = (px - x2).abs() + (py - y2).abs();
    return d1 < threshold || d2 < threshold;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR EPL_AA
// ─────────────────────────────────────────────────────────────────────────────

class EPLRasterizer {
  final int width;
  final int height;

  /// Buffer de pixels
  late final Uint32List _buffer;

  /// LUT de cobertura
  final CoverageLUT2D _coverageLUT;

  /// Tamanho do tile para processamento
  static const int tileSize = 32;

  EPLRasterizer({required this.width, required this.height})
      : _coverageLUT = CoverageLUT2D() {
    _buffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _buffer.fillRange(0, _buffer.length, backgroundColor);
  }

  /// Desenha um polígono usando o método de semi-plano com LUT
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;

    // Converter para arestas processadas
    final n = vertices.length ~/ 2;
    final edges = <EplProcessedEdge>[];

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      edges.add(EplProcessedEdge.fromPoints(
        vertices[i * 2],
        vertices[i * 2 + 1],
        vertices[j * 2],
        vertices[j * 2 + 1],
      ));
    }

    // Bounding box
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;

    for (int i = 0; i < n; i++) {
      final x = vertices[i * 2];
      final y = vertices[i * 2 + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    final pxMinX = minX.floor().clamp(0, width - 1);
    final pxMaxX = maxX.ceil().clamp(0, width - 1);
    final pxMinY = minY.floor().clamp(0, height - 1);
    final pxMaxY = maxY.ceil().clamp(0, height - 1);

    // Rasterizar por pixel
    for (int py = pxMinY; py <= pxMaxY; py++) {
      final centerY = py + 0.5;

      for (int px = pxMinX; px <= pxMaxX; px++) {
        final centerX = px + 0.5;

        // Verificar se está dentro do polígono
        final coverage = _computePixelCoverage(edges, centerX, centerY);

        if (coverage > 0) {
          _blendPixel(px, py, color, coverage);
        }
      }
    }
  }

  /// Computa a cobertura de um pixel usando a aresta dominante
  int _computePixelCoverage(
      List<EplProcessedEdge> edges, double centerX, double centerY) {
    final centerInside = _isPointInsideWinding(edges, centerX, centerY);

    // Encontrar a aresta dominante pela menor distância ao SEGMENTO
    // (não à linha infinita), para evitar artefatos longe da borda real.
    EplProcessedEdge? dominantEdge;
    double minDistSq = double.infinity;
    double secondMinDistSq = double.infinity;

    for (final edge in edges) {
      final distSq = _distanceToSegmentSq(edge, centerX, centerY);

      if (distSq < minDistSq) {
        secondMinDistSq = minDistSq;
        minDistSq = distSq;
        dominantEdge = edge;
      } else if (distSq < secondMinDistSq) {
        secondMinDistSq = distSq;
      }
    }

    if (dominantEdge == null) return 0;

    // Pixel longe da borda: classificação binária robusta.
    if (minDistSq > 0.55 * 0.55) {
      return centerInside ? 255 : 0;
    }

    // Verificar casos patológicos
    final secondMinDist =
        secondMinDistSq.isFinite ? math.sqrt(secondMinDistSq) : double.infinity;
    final isPathological = secondMinDist < 0.6 ||
        dominantEdge.isNearEndpoint(centerX, centerY, 1.0);

    if (isPathological) {
      // Fallback para supersampling 4×4
      return _supersample4x4(edges, centerX - 0.5, centerY - 0.5);
    }

    // Caso normal: usar LUT
    final signedDist = dominantEdge.signedDistance(centerX, centerY);
    var coverage = _coverageLUT.getCoverage(dominantEdge.theta, signedDist);

    // Alinhar o lado "inside" da LUT com a classificação global do polígono.
    final lineInside = signedDist <= 0.0;
    if (lineInside != centerInside) {
      coverage = 255 - coverage;
    }

    return coverage.clamp(0, 255);
  }

  /// Fallback: supersampling 4×4 para pixels problemáticos
  int _supersample4x4(
      List<EplProcessedEdge> edges, double pixelX, double pixelY) {
    int count = 0;

    for (int sy = 0; sy < 4; sy++) {
      final y = pixelY + (sy + 0.5) / 4;

      for (int sx = 0; sx < 4; sx++) {
        final x = pixelX + (sx + 0.5) / 4;

        if (_isPointInsideWinding(edges, x, y)) count++;
      }
    }

    return (count * 255) ~/ 16;
  }

  @pragma('vm:prefer-inline')
  bool _isPointInsideWinding(
      List<EplProcessedEdge> edges, double px, double py) {
    int winding = 0;

    for (final edge in edges) {
      final x1 = edge.x1;
      final y1 = edge.y1;
      final x2 = edge.x2;
      final y2 = edge.y2;

      if (y1 <= py) {
        if (y2 > py && _isLeft(x1, y1, x2, y2, px, py) > 0) {
          winding++;
        }
      } else {
        if (y2 <= py && _isLeft(x1, y1, x2, y2, px, py) < 0) {
          winding--;
        }
      }
    }

    return winding != 0;
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
  double _distanceToSegmentSq(EplProcessedEdge edge, double px, double py) {
    final vx = edge.x2 - edge.x1;
    final vy = edge.y2 - edge.y1;
    final wx = px - edge.x1;
    final wy = py - edge.y1;

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

    final cx = edge.x1 + vx * t;
    final cy = edge.y1 + vy * t;
    final dx = px - cx;
    final dy = py - cy;
    return dx * dx + dy * dy;
  }

  /// Aplica blending de um pixel
  void _blendPixel(int x, int y, int foreground, int alpha) {
    final idx = y * width + x;
    final bg = _buffer[idx];

    if (alpha >= 255) {
      _buffer[idx] = foreground;
      return;
    }

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
  }

  Uint32List get buffer => _buffer;
}
