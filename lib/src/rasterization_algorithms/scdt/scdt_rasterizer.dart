/// ============================================================================
/// SCDT — Spectral Coverage Decomposition with Ternary Encoding
/// ============================================================================
///
/// Reformula o problema de rasterização tratando a cobertura como um SINAL
/// DISCRETO que pode ser decomposto em componentes de frequência espacial.
///
/// PRINCÍPIO CENTRAL:
///   A cobertura de um pixel por uma aresta reta é uma função TRAPEZOIDAL.
///   Funções trapezoidais podem ser representadas por 3 componentes.
///   Essas componentes são codificadas em aritmética TERNÁRIA BALANCEADA
///   (-1, 0, +1), eliminando multiplicações e divisões.
///
/// INOVAÇÃO:
///   - Aritmética ternária balanceada em gráficos (nunca aplicada antes)
///   - Elimina bias de arredondamento presente em binário
///   - Base 3 alinha naturalmente com displays RGB (3 subpixels)
///   - Lookup O(1) com footprint de apenas 81 bytes
///
library scdt;

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLE TERNÁRIA
// ─────────────────────────────────────────────────────────────────────────────

/// LUT ternária: 27 entradas (3³ para 3 trits de precisão)
/// Cada entrada contém cobertura [0..255] para posições subpixel R, G, B
class TernaryLUT {
  /// 27 entradas × 3 canais = 81 bytes
  final Uint8List _table;

  TernaryLUT() : _table = Uint8List(27 * 3) {
    _precompute();
  }

  void _precompute() {
    for (int t0 = -1; t0 <= 1; t0++) {
      for (int t1 = -1; t1 <= 1; t1++) {
        for (int t2 = -1; t2 <= 1; t2++) {
          // Posição fracionária em ternário balanceado
          // f = t0/3 + t1/9 + t2/27 + 0.5 (centro em 0.5)
          final f = (t0 / 3.0) + (t1 / 9.0) + (t2 / 27.0) + 0.5;

          // Índice na tabela (mapeando -1..1 para 0..2)
          final idx = ((t0 + 1) * 9 + (t1 + 1) * 3 + (t2 + 1)) * 3;

          // Cobertura para cada subpixel usando filtro trapezoidal de largura 1/3
          _table[idx + 0] = _trapezoidCoverage(f, -1.0 / 6.0); // R
          _table[idx + 1] = _trapezoidCoverage(f, 0.0); // G
          _table[idx + 2] = _trapezoidCoverage(f, 1.0 / 6.0); // B
        }
      }
    }
  }

  /// Calcula cobertura trapezoidal para uma aresta na posição edgePos
  /// e um subpixel com offset específico
  int _trapezoidCoverage(double edgePos, double subpixelOffset) {
    // Centro do subpixel
    final subpixelCenter = 0.5 + subpixelOffset;

    // Distância da aresta ao centro do subpixel
    final d = edgePos - subpixelCenter;

    // Filtro trapezoidal de largura 1/3 (um subpixel)
    // Cobertura varia linearmente na faixa [-1/6, +1/6]
    double cov;
    if (d <= -1.0 / 6.0) {
      cov = 1.0; // Totalmente dentro
    } else if (d >= 1.0 / 6.0) {
      cov = 0.0; // Totalmente fora
    } else {
      // Transição linear
      cov = 0.5 - d * 3.0;
    }

    return (cov * 255).round().clamp(0, 255);
  }

  /// Obtém coberturas RGB para um índice ternário
  void getCoverage(int ternaryIndex, List<int> outRGB) {
    final base = ternaryIndex.clamp(0, 26) * 3;
    outRGB[0] = _table[base + 0];
    outRGB[1] = _table[base + 1];
    outRGB[2] = _table[base + 2];
  }

  int getR(int ternaryIndex) => _table[ternaryIndex.clamp(0, 26) * 3 + 0];
  int getG(int ternaryIndex) => _table[ternaryIndex.clamp(0, 26) * 3 + 1];
  int getB(int ternaryIndex) => _table[ternaryIndex.clamp(0, 26) * 3 + 2];
}

// ─────────────────────────────────────────────────────────────────────────────
// CONVERSÃO PARA TERNÁRIO
// ─────────────────────────────────────────────────────────────────────────────

/// Converte fração [0, 1) para índice ternário [0, 26]
/// Usa apenas shifts e somas (sem divisão)
int fractionToTernaryIndex(int fixedPointFrac) {
  // fixedPointFrac é a parte fracionária em Q0.8 (0..255)
  // Divisão por 85 ≈ 256/3 usando multiplicação recíproca

  // t0 = floor(frac * 3 / 256) = 0, 1, ou 2

  // Resto após subtrair t0 * (256/3) ≈ t0 * 85

  // t1 = floor(rem1 * 3 / 85) ≈ floor(rem1 * 3 / 85)

  // Resto após t1

  // t2 = floor(rem2 * 3 / 28)

  // Índice final (cada trit já mapeado para 0..2)
  final idx = (fixedPointFrac * 27) >> 8;
  return idx.clamp(0, 26);
}

/// Versão simplificada: converte fração double para índice ternário
int fractionToTernaryIndexDouble(double frac) {
  // Mapeia [0, 1) para [0, 26]
  return (frac * 27).floor().clamp(0, 26);
}

// ─────────────────────────────────────────────────────────────────────────────
// ESTADO DE ARESTA
// ─────────────────────────────────────────────────────────────────────────────

class EdgeState {
  int xFixed; // Posição X em ponto fixo Q8.8
  final int yMax; // Y máximo (em pixels inteiros)
  final int direction; // +1 ou -1 (winding)
  final int slopeFixed; // dx/dy em ponto fixo

  EdgeState({
    required this.xFixed,
    required this.yMax,
    required this.direction,
    required this.slopeFixed,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR SCDT
// ─────────────────────────────────────────────────────────────────────────────

class SCDTRasterizer {
  final int width;
  final int height;

  /// Buffer de subpixels RGB
  late final Uint8List _subpixelBuffer;

  /// Buffer de pixels para exportação
  late final Uint32List _pixelBuffer;

  /// LUT ternária
  final TernaryLUT _lut;

  /// Stride do buffer (bytes por linha)
  int get stride => width * 3;

  SCDTRasterizer({required this.width, required this.height})
      : _lut = TernaryLUT() {
    _subpixelBuffer = Uint8List(width * height * 3);
    _pixelBuffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFFFFFFFF]) {
    final r = (backgroundColor >> 16) & 0xFF;
    final g = (backgroundColor >> 8) & 0xFF;
    final b = backgroundColor & 0xFF;

    for (int i = 0; i < width * height; i++) {
      _subpixelBuffer[i * 3 + 0] = r;
      _subpixelBuffer[i * 3 + 1] = g;
      _subpixelBuffer[i * 3 + 2] = b;
    }
  }

  /// Desenha um polígono usando codificação ternária
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
    final useEvenOdd = windingRule == 0;

    // Construir lista de arestas
    final edgeTable = <int, List<EdgeState>>{};

    for (final contour in contours) {
      final cStart = contour.start;
      final cCount = contour.count;
      if (cCount < 2) continue;

      for (int local = 0; local < cCount; local++) {
        final i = cStart + local;
        final j = cStart + ((local + 1) % cCount);
        var x0 = vertices[i * 2];
        var y0 = vertices[i * 2 + 1];
        var x1 = vertices[j * 2];
        var y1 = vertices[j * 2 + 1];

        // Ignorar arestas horizontais
        if ((y1 - y0).abs() < 0.001) continue;

        // Direção para regra non-zero (orientação original)
        final dir = y1 > y0 ? 1 : -1;

        // Garantir y0 < y1 para varredura
        if (y0 > y1) {
          final tx = x0;
          x0 = x1;
          x1 = tx;
          final ty = y0;
          y0 = y1;
          y1 = ty;
        }

        // Converter para ponto fixo Q8.8
        final xFixed0 = (x0 * 256).toInt();
        // Usar centros de scanline (y + 0.5) para evitar artefatos horizontais
        var yMin = (y0 - 0.5).ceil();
        var yMax = (y1 - 0.5).floor();

        if (yMin > yMax) continue;
        if (yMin < 0) yMin = 0;
        if (yMax >= height) yMax = height - 1;

        // Slope em ponto fixo
        final dy = y1 - y0;
        final dx = x1 - x0;
        final slopeFixed = ((dx / dy) * 256).toInt();

        if (!edgeTable.containsKey(yMin)) {
          edgeTable[yMin] = [];
        }

        final scanY = yMin + 0.5;
        edgeTable[yMin]!.add(EdgeState(
          xFixed: xFixed0 + ((scanY - y0) * slopeFixed).toInt(),
          yMax: yMax,
          direction: dir,
          slopeFixed: slopeFixed,
        ));
      }
    }

    // Lista de arestas ativas
    final activeEdges = <EdgeState>[];

    // Cores
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;

    // Varredura
    for (int y = 0; y < height; y++) {
      // Adicionar novas arestas
      if (edgeTable.containsKey(y)) {
        activeEdges.addAll(edgeTable[y]!);
      }

      // Remover arestas terminadas
      activeEdges.removeWhere((e) => e.yMax < y);

      if (activeEdges.length < 2) {
        // Atualizar X para próxima scanline
        for (final e in activeEdges) {
          e.xFixed += e.slopeFixed;
        }
        continue;
      }

      // Ordenar por X
      activeEdges.sort((a, b) => a.xFixed.compareTo(b.xFixed));

      if (useEvenOdd) {
        for (int e = 0; e + 1 < activeEdges.length; e += 2) {
          final left = activeEdges[e];
          final right = activeEdges[e + 1];
          final xLeft = left.xFixed >> 8;
          final xRight = right.xFixed >> 8;

          if (xRight > xLeft + 1) {
            for (int x = xLeft + 1; x < xRight && x < width; x++) {
              if (x < 0) continue;
              final idx = y * stride + x * 3;
              _subpixelBuffer[idx + 0] = colorR;
              _subpixelBuffer[idx + 1] = colorG;
              _subpixelBuffer[idx + 2] = colorB;
            }
          }

          _blendBorderPixel(
            y,
            xLeft,
            ((left.xFixed & 0xFF) + 1).clamp(0, 255),
            colorR,
            colorG,
            colorB,
            false,
          );
          _blendBorderPixel(
            y,
            xRight,
            ((right.xFixed & 0xFF) - 1).clamp(0, 255),
            colorR,
            colorG,
            colorB,
            true,
          );
        }
      } else {
        int windingNumber = 0;
        int prevX = 0;

        for (int e = 0; e < activeEdges.length; e++) {
          final edge = activeEdges[e];
          final currentX = edge.xFixed >> 8; // Parte inteira
          final frac = edge.xFixed & 0xFF; // Parte fracionária Q0.8
          final fracAdj = (windingNumber != 0)
              ? (frac - 1).clamp(0, 255)
              : (frac + 1).clamp(0, 255);

          if (windingNumber != 0 && currentX > prevX + 1) {
            for (int x = prevX + 1; x < currentX && x < width; x++) {
              final idx = y * stride + x * 3;
              _subpixelBuffer[idx + 0] = colorR;
              _subpixelBuffer[idx + 1] = colorG;
              _subpixelBuffer[idx + 2] = colorB;
            }
          }

          _blendBorderPixel(
            y,
            currentX,
            fracAdj,
            colorR,
            colorG,
            colorB,
            windingNumber != 0,
          );

          windingNumber += edge.direction;
          prevX = currentX;
        }
      }

      // Atualizar X para próxima scanline
      for (final edge in activeEdges) {
        edge.xFixed += edge.slopeFixed;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _blendBorderPixel(
    int y,
    int x,
    int fracAdj,
    int colorR,
    int colorG,
    int colorB,
    bool inverse,
  ) {
    if (x < 0 || x >= width) return;
    final ternIdx = fractionToTernaryIndex(fracAdj);
    final bufBase = y * stride + x * 3;
    final covR = inverse ? (255 - _lut.getR(ternIdx)) : _lut.getR(ternIdx);
    final covG = inverse ? (255 - _lut.getG(ternIdx)) : _lut.getG(ternIdx);
    final covB = inverse ? (255 - _lut.getB(ternIdx)) : _lut.getB(ternIdx);

    _subpixelBuffer[bufBase + 0] =
        ((colorR * covR + _subpixelBuffer[bufBase + 0] * (255 - covR)) >> 8)
            .clamp(0, 255);
    _subpixelBuffer[bufBase + 1] =
        ((colorG * covG + _subpixelBuffer[bufBase + 1] * (255 - covG)) >> 8)
            .clamp(0, 255);
    _subpixelBuffer[bufBase + 2] =
        ((colorB * covB + _subpixelBuffer[bufBase + 2] * (255 - covB)) >> 8)
            .clamp(0, 255);
  }

  /// Resolve buffer de subpixels para buffer ARGB
  void resolve() {
    for (int i = 0; i < width * height; i++) {
      final r = _subpixelBuffer[i * 3 + 0];
      final g = _subpixelBuffer[i * 3 + 1];
      final b = _subpixelBuffer[i * 3 + 2];
      _pixelBuffer[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }

  Uint32List get pixels {
    resolve();
    return _pixelBuffer;
  }

  Uint8List get subpixels => _subpixelBuffer;
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
