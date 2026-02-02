/// ============================================================================
/// QCS — Quantized Coverage Signature Rasterization
/// ============================================================================
///
/// A filosofia central é converter o problema geométrico complexo de cálculo
/// de área (que usa muito ponto flutuante e é lento) em um problema de BUSCA
/// EM TABELAS e OPERAÇÕES DE BITS.
///
/// PRINCÍPIO CENTRAL:
///   Em vez de calcular a área exata, QUANTIZAMOS a cobertura. Imagine que
///   cada pixel é dividido em uma micro-grade de pontos de amostragem.
///   Para rasterização de subpixel em layout RGB horizontal, usamos uma
///   grade de 3×2 (6 pontos) dentro de cada pixel.
///
///   Para cada ponto de amostragem, perguntamos: "está dentro ou fora?"
///   A resposta é uma sequência de 6 bits (a "Assinatura de Cobertura")
///   que indexa diretamente uma LUT pré-computada.
///
/// INOVAÇÃO:
///   - Elimina ponto flutuante no loop interno: tudo é int + bitwise
///   - Conversão de Geometria em Busca O(1)
///   - Minimal footprint por pixel: algumas somas e uma indexação
///   - Adaptável: grade 3×1 (mais rápida), 3×3 (mais qualidade)
///
library qcs;

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DE AMOSTRAGEM
// ─────────────────────────────────────────────────────────────────────────────

/// Layout de amostragem 3×2:
/// | R | G | B | <- subpixels
/// | • | • | • | <- pontos superiores (s0, s1, s2)
/// | • | • | • | <- pontos inferiores (s3, s4, s5)
///
/// Total: 6 pontos = 6 bits = 64 assinaturas possíveis

/// Offsets horizontais dos pontos de amostragem (em fração do pixel)
const List<double> _sampleOffsetsX = [
  1.0 / 6.0,
  3.0 / 6.0,
  5.0 / 6.0, // Linha superior (R, G, B)
  1.0 / 6.0,
  3.0 / 6.0,
  5.0 / 6.0, // Linha inferior
];


// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLE DE SUBPIXEL
// ─────────────────────────────────────────────────────────────────────────────

/// LUT que mapeia assinatura de 6 bits para intensidades RGB
class SubpixelLUT {
  /// 64 entradas, cada uma com 3 valores (R, G, B)
  final Uint8List _table;

  SubpixelLUT() : _table = Uint8List(64 * 3) {
    _precompute();
  }

  void _precompute() {
    for (int signature = 0; signature < 64; signature++) {
      // Bits: s0 s1 s2 s3 s4 s5
      // s0, s3 → Red   (2 amostras)
      // s1, s4 → Green (2 amostras)
      // s2, s5 → Blue  (2 amostras)

      final s0 = (signature >> 0) & 1; // Red superior
      final s1 = (signature >> 1) & 1; // Green superior
      final s2 = (signature >> 2) & 1; // Blue superior
      final s3 = (signature >> 3) & 1; // Red inferior
      final s4 = (signature >> 4) & 1; // Green inferior
      final s5 = (signature >> 5) & 1; // Blue inferior

      // Cobertura de cada canal (0, 0.5, ou 1.0 → 0, 127, 255)
      final coverageR = ((s0 + s3) * 255) ~/ 2;
      final coverageG = ((s1 + s4) * 255) ~/ 2;
      final coverageB = ((s2 + s5) * 255) ~/ 2;

      _table[signature * 3 + 0] = coverageR;
      _table[signature * 3 + 1] = coverageG;
      _table[signature * 3 + 2] = coverageB;
    }
  }

  /// Obtém as intensidades RGB para uma assinatura
  void getIntensities(int signature, List<int> outRGB) {
    outRGB[0] = _table[signature * 3 + 0];
    outRGB[1] = _table[signature * 3 + 1];
    outRGB[2] = _table[signature * 3 + 2];
  }

  int getR(int signature) => _table[signature * 3 + 0];
  int getG(int signature) => _table[signature * 3 + 1];
  int getB(int signature) => _table[signature * 3 + 2];
}

// Scanline-based approach for non-convex support

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR QCS
// ─────────────────────────────────────────────────────────────────────────────

class QCSRasterizer {
  final int width;
  final int height;

  /// Buffer de subpixels RGB
  late final Uint8List _subpixelBuffer;

  /// Buffer de pixels para exportação
  late final Uint32List _pixelBuffer;

  /// LUT de subpixel
  final SubpixelLUT _lut;

  /// Buffer de assinaturas por scanline (auxiliar de integração)
  late final Uint8List _signatureScanline;

  QCSRasterizer({required this.width, required this.height})
      : _lut = SubpixelLUT() {
    _subpixelBuffer = Uint8List(width * height * 3);
    _pixelBuffer = Uint32List(width * height);
    _signatureScanline = Uint8List(width + 1);
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

  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;
    final n = vertices.length ~/ 2;

    // 1. Pré-processamento de Arestas
    final edges = <_QcsEdge>[];
    double minY = double.infinity, maxY = double.negativeInfinity;

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = vertices[i * 2], y0 = vertices[i * 2 + 1];
      final x1 = vertices[j * 2], y1 = vertices[j * 2 + 1];

      if (y0 < minY) minY = y0; if (y0 > maxY) maxY = y0;
      if (y1 < minY) minY = y1; if (y1 > maxY) maxY = y1;
      if (y0 == y1) continue;
      
      edges.add(_QcsEdge(x0, y0, x1, y1));
    }

    final pxMinY = minY.floor().clamp(0, height - 1);
    final pxMaxY = maxY.ceil().clamp(0, height - 1);

    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;

    // 2. Loop de Scanlines
    for (int py = pxMinY; py <= pxMaxY; py++) {
      _signatureScanline.fillRange(0, _signatureScanline.length, 0);

      // Y dos centros das duas sub-scanlines QCS
      final yTop = py + 0.25;
      final yBot = py + 0.75;

      // 3. Fase de Toggle (Marcar Bordas de Transição de Bit)
      for (final edge in edges) {
        // Interseção na sub-scanline Superior
        if ((edge.y0 <= yTop && edge.y1 > yTop) || (edge.y1 <= yTop && edge.y0 > yTop)) {
          final x = edge.x0 + (yTop - edge.y0) * (edge.x1 - edge.x0) / (edge.y1 - edge.y0);
          // Toggle bits 0, 1, 2 baseados nos offsets de subpixel
          // Convention: toggle na posição do subpixel
          for (int s = 0; s < 3; s++) {
            final ix = (x - _sampleOffsetsX[s]).floor();
            if (ix >= -1 && ix < width) {
              _signatureScanline[ix + 1] ^= (1 << s);
            }
          }
        }
        // Interseção na sub-scanline Inferior
        if ((edge.y0 <= yBot && edge.y1 > yBot) || (edge.y1 <= yBot && edge.y0 > yBot)) {
          final x = edge.x0 + (yBot - edge.y0) * (edge.x1 - edge.x0) / (edge.y1 - edge.y0);
          for (int s = 3; s < 6; s++) {
            final ix = (x - _sampleOffsetsX[s]).floor();
            if (ix >= -1 && ix < width) {
              _signatureScanline[ix + 1] ^= (1 << s);
            }
          }
        }
      }

      // 4. Integração de Bits (Prefix XOR horizontal) + Blit
      int runningSignature = 0;
      final rowOffset = py * width * 3;

      for (int px = 0; px < width; px++) {
        // Atualiza assinatura acumulada para este pixel
        runningSignature ^= _signatureScanline[px];

        if (runningSignature == 0) continue;

        // Recupera intensidade da LUT O(1)
        final intensityR = _lut.getR(runningSignature);
        final intensityG = _lut.getG(runningSignature);
        final intensityB = _lut.getB(runningSignature);

        final idx = rowOffset + px * 3;

        if (runningSignature == 63) { // 100% Cobertura
          _subpixelBuffer[idx + 0] = colorR;
          _subpixelBuffer[idx + 1] = colorG;
          _subpixelBuffer[idx + 2] = colorB;
        } else {
          // Blend Subpixel Oritentado
          final bgR = _subpixelBuffer[idx + 0];
          final bgG = _subpixelBuffer[idx + 1];
          final bgB = _subpixelBuffer[idx + 2];

          _subpixelBuffer[idx + 0] = ((colorR * intensityR + bgR * (255 - intensityR)) >> 8).clamp(0, 255);
          _subpixelBuffer[idx + 1] = ((colorG * intensityG + bgG * (255 - intensityG)) >> 8).clamp(0, 255);
          _subpixelBuffer[idx + 2] = ((colorB * intensityB + bgB * (255 - intensityB)) >> 8).clamp(0, 255);
        }
      }
    }
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

class _QcsEdge {
  final double x0, y0, x1, y1;
  _QcsEdge(this.x0, this.y0, this.x1, this.y1);
}
