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
  if (x >= 0.5) return x + 0.5 - 1.0/12.0; // Integral acumulada
  final t = x + 0.5;
  return math.pow(t, 3) - 0.5 * math.pow(t, 4);
}

/// g(d): cobertura de um subpixel de largura 1/3 centrado na distância d
/// g(d) = S(d + 1/6) - S(d - 1/6)
double coverageG(double d) {
  return smoothstepIntegral(d + 1.0/6.0) - smoothstepIntegral(d - 1.0/6.0);
}

/// g'(d): derivada de g(d) = s(d + 1/6) - s(d - 1/6)
double coverageGPrime(double d) {
  return smoothstep(d + 1.0/6.0) - smoothstep(d - 1.0/6.0);
}

// ─────────────────────────────────────────────────────────────────────────────
// LOOK-UP TABLES
// ─────────────────────────────────────────────────────────────────────────────

class CoverageTables {
  static const int tableSize = 256;

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

  /// Obtém valores de g e g' para uma distância d
  List<double> lookup(double d) {
    final dClamped = d.clamp(-1.0, 1.0);
    final index = (((dClamped + 1.0) / 2.0) * (tableSize - 1)).round().clamp(0, tableSize - 1);
    return [gTable[index], gPrimeTable[index]];
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
  static const List<double> subpixelOffsetsX = [-1.0/3.0, 0.0, 1.0/3.0];

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

        // Pixel de borda esquerda
        if (xStart > 0 && xStart - 1 < width) {
          _processLeftBorderPixel(
            xStart - 1, y, leftEdge, colorR, colorG, colorB);
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
        if (xEnd >= 0 && xEnd < width && xEnd != xStart - 1) {
          _processRightBorderPixel(
            xEnd, y, rightEdge, colorR, colorG, colorB);
        }
      }

      // Atualizar posições X para próxima scanline
      for (final edge in activeEdges) {
        edge.x += edge.slopeInverse;
      }
    }
  }

  /// Processa pixel de borda esquerda
  void _processLeftBorderPixel(
    int px, int py,
    SweepActiveEdge edge,
    int colorR, int colorG, int colorB,
  ) {
    final pixelCenterX = px + 0.5;

    // Distância do centro do pixel à aresta (ao longo da normal)
    final dPixel = edge.nx * (pixelCenterX - edge.x);

    // Lookup de g e g'
    final gValues = _tables.lookup(dPixel);
    final g = gValues[0];
    final gPrime = gValues[1];

    // Calcular cobertura para cada subpixel
    final idx = (py * width + px) * 3;

    for (int s = 0; s < 3; s++) {
      // Distância do subpixel à aresta
      final dSub = dPixel + edge.nx * subpixelOffsetsX[s];

      // Aproximação linear: g(dSub) ≈ g(dPixel) + g'(dPixel) * (dSub - dPixel)
      var coverage = g + gPrime * (dSub - dPixel);

      // Para borda esquerda, queremos a área à direita da aresta
      coverage = (1.0 - coverage).clamp(0.0, 1.0);

      final intensity = (coverage * 255).round().clamp(0, 255);
      final existing = _subpixelBuffer[idx + s];

      // Blend
      final colors = [colorR, colorG, colorB];
      _subpixelBuffer[idx + s] =
          ((colors[s] * intensity + existing * (255 - intensity)) ~/ 255)
              .clamp(0, 255);
    }
  }

  /// Processa pixel de borda direita
  void _processRightBorderPixel(
    int px, int py,
    SweepActiveEdge edge,
    int colorR, int colorG, int colorB,
  ) {
    final pixelCenterX = px + 0.5;

    // Distância do centro do pixel à aresta
    final dPixel = edge.nx * (pixelCenterX - edge.x);

    // Lookup de g e g'
    final gValues = _tables.lookup(dPixel);
    final g = gValues[0];
    final gPrime = gValues[1];

    // Calcular cobertura para cada subpixel
    final idx = (py * width + px) * 3;

    for (int s = 0; s < 3; s++) {
      final dSub = dPixel + edge.nx * subpixelOffsetsX[s];

      // Aproximação linear
      var coverage = g + gPrime * (dSub - dPixel);

      // Para borda direita, queremos a área à esquerda da aresta
      coverage = coverage.clamp(0.0, 1.0);

      final intensity = (coverage * 255).round().clamp(0, 255);
      final existing = _subpixelBuffer[idx + s];

      final colors = [colorR, colorG, colorB];
      _subpixelBuffer[idx + s] =
          ((colors[s] * intensity + existing * (255 - intensity)) ~/ 255)
              .clamp(0, 255);
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
