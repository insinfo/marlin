/// ============================================================================
/// SWEEP_SDF — Rasterização por Varredura com SDF Analítico para Subpixel
/// ============================================================================
///
/// Combina conceitos de Signed Distance Fields (SDF), pré-computação de
/// funções de cobertura e adaptação do clássico algoritmo de varredura.
///
/// PRINCÍPIO CENTRAL:
///   1. Pré-computa funções de cobertura analíticas para subpixel baseadas
///      na integral de smoothstep sobre intervalos de pixel e subpixel
///   2. Usa distâncias assinadas (SDF) perpendiculares calculadas
///      incrementalmente durante a varredura
///   3. Aproveita aproximação linear da cobertura a partir do SDF do pixel
///
/// INOVAÇÃO:
///   - Função g(d): cobertura de um subpixel centrado na distância d
///   - Derivada g'(d) para interpolação rápida entre subpixels
///   - Separação inteligente: pixels inteiros, bordas e subpixels
///   - Lookup tables de 256 entradas para g e g'
///
library sweep_sdf;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// FUNÇÕES DE COBERTURA ANALÍTICAS
// ─────────────────────────────────────────────────────────────────────────────

/// Função smoothstep: transição suave de 0 a 1
double smoothstep(double x) {
  if (x <= -0.5) return 0.0;
  if (x >= 0.5) return 1.0;
  final t = x + 0.5; // Mapeia [-0.5, 0.5] para [0, 1]
  return t * t * (3.0 - 2.0 * t);
}

/// Integral indefinida de smoothstep: S(x) = ∫s(x)dx
/// Para s(x) = 3(x+0.5)² - 2(x+0.5)³
/// S(x) = (x+0.5)³ - 0.5(x+0.5)⁴
double smoothstepIntegral(double x) {
  if (x <= -0.5) return 0.0;
  if (x >= 0.5) return x + 0.5 - 1.0 / 12.0; // Integral acumulada
  final t = x + 0.5;
  return math.pow(t, 3) - 0.5 * math.pow(t, 4);
}

/// g(d): cobertura de um subpixel de largura 1/3 centrado na distância d
/// g(d) = S(d + 1/6) - S(d - 1/6)
double coverageG(double d) {
  return smoothstepIntegral(d + 1.0 / 6.0) - smoothstepIntegral(d - 1.0 / 6.0);
}

/// g'(d): derivada de g(d) = s(d + 1/6) - s(d - 1/6)
double coverageGPrime(double d) {
  return smoothstep(d + 1.0 / 6.0) - smoothstep(d - 1.0 / 6.0);
}

// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLES
// ─────────────────────────────────────────────────────────────────────────────

class CoverageTables {
  static const int tableSize = 1024;

  final Float64List gTable;
  final Float64List gPrimeTable;

  CoverageTables()
      : gTable = Float64List(tableSize),
        gPrimeTable = Float64List(tableSize) {
    _precompute();
  }

  void _precompute() {
    for (int i = 0; i < tableSize; i++) {
      // d varia de -1.0 a +1.0
      final d = -1.0 + (i / (tableSize - 1)) * 2.0;
      gTable[i] = coverageG(d);
      gPrimeTable[i] = coverageGPrime(d);
    }
  }

  @pragma('vm:prefer-inline')
  double _lookupInterpolated(Float64List table, double d) {
    if (d <= -1.0) return table[0];
    if (d >= 1.0) return table[tableSize - 1];

    final pos = ((d + 1.0) * 0.5) * (tableSize - 1);
    int i = pos.floor();
    if (i >= tableSize - 1) i = tableSize - 2;
    final t = pos - i;
    final a = table[i];
    final b = table[i + 1];
    return a + (b - a) * t;
  }

  @pragma('vm:prefer-inline')
  double lookupG(double d) => _lookupInterpolated(gTable, d);

  @pragma('vm:prefer-inline')
  double lookupGPrime(double d) => _lookupInterpolated(gPrimeTable, d);
}

@pragma('vm:prefer-inline')
double _clamp01(double v) {
  if (v <= 0.0) return 0.0;
  if (v >= 1.0) return 1.0;
  return v;
}

@pragma('vm:prefer-inline')
int _blendChannel(int existing, int color, double coverage) {
  final intensity = (_clamp01(coverage) * 255.0).round().clamp(0, 255);
  return ((color * intensity + existing * (255 - intensity)) ~/ 255)
      .clamp(0, 255);
}

extension on SweepSDFRasterizer {
  @pragma('vm:prefer-inline')
  void _paintBorderPixel(
    int px,
    int py,
    SweepActiveEdge edge,
    double edgeXAtScanline,
    bool invertCoverage,
    int colorR,
    int colorG,
    int colorB,
  ) {
    final pixelCenterX = px + 0.5;
    final dPixel = edge.nx * (pixelCenterX - edgeXAtScanline);

    final g = _tables.lookupG(dPixel);
    final gPrime = _tables.lookupGPrime(dPixel);

    final idx = (py * width + px) * 3;

    final dR = dPixel + edge.nx * SweepSDFRasterizer.subpixelOffsetsX[0];
    final dG = dPixel + edge.nx * SweepSDFRasterizer.subpixelOffsetsX[1];
    final dB = dPixel + edge.nx * SweepSDFRasterizer.subpixelOffsetsX[2];

    double cR = g + gPrime * (dR - dPixel);
    double cG = g + gPrime * (dG - dPixel);
    double cB = g + gPrime * (dB - dPixel);

    if (invertCoverage) {
      cR = 1.0 - cR;
      cG = 1.0 - cG;
      cB = 1.0 - cB;
    }

    _subpixelBuffer[idx + 0] =
        _blendChannel(_subpixelBuffer[idx + 0], colorR, cR);
    _subpixelBuffer[idx + 1] =
        _blendChannel(_subpixelBuffer[idx + 1], colorG, cG);
    _subpixelBuffer[idx + 2] =
        _blendChannel(_subpixelBuffer[idx + 2], colorB, cB);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ARESTA ATIVA
// ─────────────────────────────────────────────────────────────────────────────

class SweepActiveEdge {
  double x; // Posição X atual (interseção com scanline)
  final double yMax; // Y máximo da aresta
  final double slopeInverse; // dx/dy
  final double nx, ny; // Normal unitária

  SweepActiveEdge({
    required this.x,
    required this.yMax,
    required this.slopeInverse,
    required this.nx,
    required this.ny,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR SWEEP_SDF
// ─────────────────────────────────────────────────────────────────────────────

class SweepSDFRasterizer {
  final int width;
  final int height;

  /// Buffer de subpixels RGB
  late final Uint8List _subpixelBuffer;

  /// Buffer de pixels para exportação
  late final Uint32List _pixelBuffer;

  /// Tabelas de cobertura
  final CoverageTables _tables;

  /// Offsets subpixel (layout LCD RGB horizontal)
  static const List<double> subpixelOffsetsX = [-1.0 / 3.0, 0.0, 1.0 / 3.0];

  SweepSDFRasterizer({required this.width, required this.height})
      : _tables = CoverageTables() {
    _subpixelBuffer = Uint8List(width * height * 3);
    _pixelBuffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    final r = (backgroundColor >> 16) & 0xFF;
    final g = (backgroundColor >> 8) & 0xFF;
    final b = backgroundColor & 0xFF;

    for (int i = 0; i < width * height; i++) {
      _subpixelBuffer[i * 3 + 0] = r;
      _subpixelBuffer[i * 3 + 1] = g;
      _subpixelBuffer[i * 3 + 2] = b;
    }
  }

  /// Desenha um polígono usando varredura com SDF
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;

    final n = vertices.length ~/ 2;

    // Construir tabela de arestas
    final edgeTable = <int, List<SweepActiveEdge>>{};

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = vertices[i * 2];
      final y0 = vertices[i * 2 + 1];
      final x1 = vertices[j * 2];
      final y1 = vertices[j * 2 + 1];

      // Ignorar arestas horizontais
      if ((y1 - y0).abs() < 0.001) continue;

      // Garantir que y0 < y1
      double px0 = x0, py0 = y0, px1 = x1, py1 = y1;
      if (py0 > py1) {
        px0 = x1;
        py0 = y1;
        px1 = x0;
        py1 = y0;
      }

      // Calcular normal
      final dx = px1 - px0;
      final dy = py1 - py0;
      final len = math.sqrt(dx * dx + dy * dy);
      final nx = dy / len;
      final ny = -dx / len;

      // Slope inverso (dx/dy)
      final slopeInv = dx / dy;

      // Adicionar à tabela de arestas
      final yStart = py0.ceil();
      if (!edgeTable.containsKey(yStart)) {
        edgeTable[yStart] = [];
      }

      edgeTable[yStart]!.add(SweepActiveEdge(
        x: px0 + slopeInv * (yStart - py0),
        yMax: py1,
        slopeInverse: slopeInv,
        nx: nx,
        ny: ny,
      ));
    }

    // Lista de arestas ativas (AET)
    final activeEdges = <SweepActiveEdge>[];

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
      activeEdges.removeWhere((e) => e.yMax <= y);

      if (activeEdges.length < 2) continue;

      // Ordenar por X
      activeEdges.sort((a, b) => a.x.compareTo(b.x));

      // Processar pares de arestas
      for (int i = 0; i + 1 < activeEdges.length; i += 2) {
        final leftEdge = activeEdges[i];
        final rightEdge = activeEdges[i + 1];
        final xLeft = leftEdge.x;
        final xRight = rightEdge.x;

        final xStart = xLeft.ceil().clamp(0, width);
        final xEnd = xRight.floor().clamp(0, width);
        const eps = 1e-9;
        final hasLeftFraction = (xStart - xLeft) > eps;
        final hasRightFraction = (xRight - xEnd) > eps;

        // Pixel de borda esquerda
        if (hasLeftFraction && xStart > 0 && xStart - 1 < width) {
          _paintBorderPixel(
            xStart - 1,
            y,
            leftEdge,
            xLeft,
            true,
            colorR,
            colorG,
            colorB,
          );
        }

        // Pixels interiores (cobertura total)
        for (int x = xStart; x < xEnd; x++) {
          if (x >= 0 && x < width) {
            final idx = (y * width + x) * 3;
            _subpixelBuffer[idx + 0] = colorR;
            _subpixelBuffer[idx + 1] = colorG;
            _subpixelBuffer[idx + 2] = colorB;
          }
        }

        // Pixel de borda direita
        if (hasRightFraction &&
            xEnd >= 0 &&
            xEnd < width &&
            xEnd != xStart - 1) {
          _paintBorderPixel(
            xEnd,
            y,
            rightEdge,
            xRight,
            false,
            colorR,
            colorG,
            colorB,
          );
        }
      }

      // Atualizar posições X para próxima scanline
      for (final edge in activeEdges) {
        edge.x += edge.slopeInverse;
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
