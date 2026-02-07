/// ============================================================================
/// DAA — Delta-Analytic Approximation Rasterizer
/// ============================================================================
///
/// Uma abordagem que trata a borda como um sinal elétrico, modelando a variação
/// da cobertura através da scanline como uma onda.
///
/// PRINCÍPIO CENTRAL:
///   Em vez de calcular a área de cobertura do polígono dentro do pixel
///   (geometria) ou amostrar pontos (estatística), tratamos a borda como
///   um Sinal Elétrico.
///
///   A chave é perceber que, ao movermos de um pixel para o próximo na
///   horizontal, a mudança na distância para a borda é CONSTANTE (é a
///   derivada da linha, ou seja, o slope).
///
/// INOVAÇÃO:
///   - Elimina multiplicação e divisão no loop interno
///   - Substitui matemática complexa por Soma Inteira e Lookup Tables
///   - Usa aritmética de ponto fixo 16.16 para precisão subpixel
///
library daa;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DE PONTO FIXO
// ─────────────────────────────────────────────────────────────────────────────

/// Ponto fixo 16.16: 1 pixel = 65536 unidades
const int _fixedShift = 16;
const int _fixedOne = 1 << _fixedShift;
const int _fixedHalf = 1 << (_fixedShift - 1);

/// Converte double para ponto fixo
int _toFixed(double value) => (value * _fixedOne).toInt();

// ignore: unused_element (mantido para referência/futura utilização)
double _fromFixed(int value) => value / _fixedOne;

// ─────────────────────────────────────────────────────────────────────────────
// TABELA DE COBERTURA (LOOKUP TABLE)
// ─────────────────────────────────────────────────────────────────────────────

/// A Coverage LUT mapeia distância não normalizada da aresta para opacidade
class CoverageLUT {
  static const int lutSize = 128;
  static const int lutHalf = lutSize ~/ 2;

  /// Tabela pré-computada: distância → opacidade (0-255)
  final Uint8List _table;

  CoverageLUT() : _table = Uint8List(lutSize) {
    _precompute();
  }

  void _precompute() {
    // Função de transição suave (smoothstep)
    for (int i = 0; i < lutSize; i++) {
      // Mapeia índice para distância normalizada [-1, 1]
      final d = (i - lutHalf) / lutHalf;

      // Smoothstep: transição suave na região da borda
      double coverage;
      if (d <= -1.0) {
        coverage = 1.0; // Totalmente dentro
      } else if (d >= 1.0) {
        coverage = 0.0; // Totalmente fora
      } else {
        // Smoothstep: 3x² - 2x³ para x em [0,1]
        final t = (1.0 - d) * 0.5; // Mapeia [-1,1] para [0,1]
        coverage = t * t * (3.0 - 2.0 * t);
      }

      _table[i] = (coverage * 255).round().clamp(0, 255);
    }
  }

  /// Obtém opacidade para uma distância em ponto fixo
  int getAlpha(int distance) {
    // Normaliza distância para índice da tabela
    // A faixa de transição é de [-_fixedOne, +_fixedOne]
    final normalizedDist = (distance >> (_fixedShift - 6)) + lutHalf;
    final index = normalizedDist.clamp(0, lutSize - 1);
    return _table[index];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DADOS DE ARESTA
// ─────────────────────────────────────────────────────────────────────────────

/// Representa os coeficientes da equação de aresta F(x,y) = Ax + By + C
class EdgeData {
  /// Coeficiente A = (y1 - y2) - delta Y
  final int a;

  /// Coeficiente B = (x2 - x1) - delta X negativo
  final int b;

  /// Coeficiente C = x1*y2 - x2*y1
  final int c;

  EdgeData(this.a, this.b, this.c);

  /// Avalia a função de aresta em um ponto (x, y) em ponto fixo
  int evaluate(int x, int y) {
    // F(x,y) = A*x + B*y + C
    // Usando ponto fixo, precisamos ajustar a escala
    return ((a * x) >> _fixedShift) + ((b * y) >> _fixedShift) + c;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR DAA
// ─────────────────────────────────────────────────────────────────────────────

/// Rasterizador Delta-Analytic Approximation
///
/// Uso:
/// ```dart
/// final rasterizer = DAARasterizer(width: 512, height: 512);
/// rasterizer.drawTriangle(x1, y1, x2, y2, x3, y3, 0xFFFF0000);
/// final pixels = rasterizer.framebuffer;
/// ```
class DAARasterizer {
  final int width;
  final int height;

  /// Framebuffer ARGB de 32 bits
  late final Uint32List framebuffer;

  /// Tabela de cobertura pré-computada
  final CoverageLUT _coverageLUT;

  DAARasterizer({required this.width, required this.height})
      : _coverageLUT = CoverageLUT() {
    framebuffer = Uint32List(width * height);
  }

  /// Limpa o framebuffer com uma cor de fundo
  void clear([int backgroundColor = 0xFF000000]) {
    framebuffer.fillRange(0, framebuffer.length, backgroundColor);
  }

  /// Desenha um triângulo com anti-aliasing
  void drawTriangle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int color,
  ) {
    // Normaliza winding para manter sinal consistente na função de aresta.
    final area2 = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
    if (area2 == 0.0) return;
    if (area2 > 0.0) {
      final tx = x2;
      final ty = y2;
      x2 = x3;
      y2 = y3;
      x3 = tx;
      y3 = ty;
    }

    // Converter para ponto fixo
    final fx1 = _toFixed(x1);
    final fy1 = _toFixed(y1);
    final fx2 = _toFixed(x2);
    final fy2 = _toFixed(y2);
    final fx3 = _toFixed(x3);
    final fy3 = _toFixed(y3);

    // Criar arestas
    final edges = [
      _createEdge(fx1, fy1, fx2, fy2),
      _createEdge(fx2, fy2, fx3, fy3),
      _createEdge(fx3, fy3, fx1, fy1),
    ];

    // Calcular bounding box em coordenadas inteiras
    final minX = math.min(x1, math.min(x2, x3)).floor().clamp(0, width - 1);
    final maxX = math.max(x1, math.max(x2, x3)).ceil().clamp(0, width - 1);
    final minY = math.min(y1, math.min(y2, y3)).floor().clamp(0, height - 1);
    final maxY = math.max(y1, math.max(y2, y3)).ceil().clamp(0, height - 1);

    // Rasterizar linha por linha
    for (int y = minY; y <= maxY; y++) {
      final fixedY = (y << _fixedShift) + _fixedHalf; // Centro do pixel

      // Calcular o "Delta Inicial" (valor da função de aresta no início da linha)
      final currentDeltas = <int>[
        edges[0].evaluate(minX << _fixedShift, fixedY),
        edges[1].evaluate(minX << _fixedShift, fixedY),
        edges[2].evaluate(minX << _fixedShift, fixedY),
      ];

      // Loop de Pixels (O Inner Loop)
      final rowOffset = y * width;
      for (int x = minX; x <= maxX; x++) {
        // Otimização Crítica: Usar o mínimo da cobertura das 3 arestas
        int minCoverage = 255;

        for (int e = 0; e < 3; e++) {
          // Passa a distância para a LUT obter a opacidade parcial desta aresta
          final alphaEdge = _coverageLUT.getAlpha(currentDeltas[e]);

          // A cobertura total é o mínimo das coberturas individuais
          if (alphaEdge < minCoverage) minCoverage = alphaEdge;

          // Prepara para o próximo pixel (somente adição!)
          // F(x+1) = F(x) + A
          currentDeltas[e] += edges[e].a;
        }

        // Mistura (Blending) otimizado
        if (minCoverage > 0) {
          if (minCoverage == 255) {
            framebuffer[rowOffset + x] = color; // Opaco puro
          } else {
            // Alpha Blending
            _blendPixel(rowOffset + x, color, minCoverage);
          }
        }
      }
    }
  }

  /// Cria dados de aresta a partir de dois vértices em ponto fixo
  EdgeData _createEdge(int x1, int y1, int x2, int y2) {
    // F(x,y) = (y1 - y2)x + (x2 - x1)y + (x1y2 - x2y1)
    // a = dy, b = -dx
    final a = y1 - y2;
    final b = x2 - x1;
    final c = ((x1 * y2) >> _fixedShift) - ((x2 * y1) >> _fixedShift);
    return EdgeData(a, b, c);
  }

  /// Aplica alpha blending em um pixel
  void _blendPixel(int index, int foreground, int alpha) {
    final bg = framebuffer[index];

    // Desempacota cores de fundo
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    // Desempacota cores de primeiro plano
    final fgR = (foreground >> 16) & 0xFF;
    final fgG = (foreground >> 8) & 0xFF;
    final fgB = foreground & 0xFF;

    // Blending
    final invA = 255 - alpha;
    final r = (fgR * alpha + bgR * invA) ~/ 255;
    final g = (fgG * alpha + bgG * invA) ~/ 255;
    final b = (fgB * alpha + bgB * invA) ~/ 255;

    framebuffer[index] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  /// Desenha um polígono convexo (decomposição em triângulos)
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return; // Mínimo 3 vértices (6 coordenadas)

    final n = vertices.length ~/ 2;
    final edgeX1 = List<double>.filled(n, 0.0);
    final edgeY1 = List<double>.filled(n, 0.0);
    final edgeX2 = List<double>.filled(n, 0.0);
    final edgeY2 = List<double>.filled(n, 0.0);

    var minX = vertices[0];
    var maxX = vertices[0];
    var minY = vertices[1];
    var maxY = vertices[1];

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

    for (int y = minYi; y <= maxYi; y++) {
      final py = y + 0.5;
      final rowOffset = y * width;

      for (int x = minXi; x <= maxXi; x++) {
        final px = x + 0.5;
        final alpha = _computePolygonAlpha(
          edgeCount: n,
          edgeX1: edgeX1,
          edgeY1: edgeY1,
          edgeX2: edgeX2,
          edgeY2: edgeY2,
          px: px,
          py: py,
        );

        if (alpha == 255) {
          framebuffer[rowOffset + x] = color;
        } else if (alpha > 0) {
          _blendPixel(rowOffset + x, color, alpha);
        }
      }
    }
  }

  @pragma('vm:prefer-inline')
  int _computePolygonAlpha({
    required int edgeCount,
    required List<double> edgeX1,
    required List<double> edgeY1,
    required List<double> edgeX2,
    required List<double> edgeY2,
    required double px,
    required double py,
  }) {
    int winding = 0;
    double minDistSq = double.infinity;

    for (int i = 0; i < edgeCount; i++) {
      final x1 = edgeX1[i];
      final y1 = edgeY1[i];
      final x2 = edgeX2[i];
      final y2 = edgeY2[i];

      if (y1 <= py) {
        if (y2 > py && _isLeft(x1, y1, x2, y2, px, py) > 0) winding++;
      } else {
        if (y2 <= py && _isLeft(x1, y1, x2, y2, px, py) < 0) winding--;
      }

      final distSq = _distanceToSegmentSq(x1, y1, x2, y2, px, py);
      if (distSq < minDistSq) minDistSq = distSq;
    }

    final inside = winding != 0;
    final minDist = minDistSq.isFinite ? math.sqrt(minDistSq) : 0.0;
    final signedDist = inside ? -minDist : minDist;
    return _coverageLUT.getAlpha((signedDist * _fixedOne).toInt());
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

    if (vv <= 1e-12) return wx * wx + wy * wy;

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
}
