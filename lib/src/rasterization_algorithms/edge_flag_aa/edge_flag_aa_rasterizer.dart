/// ============================================================================
/// EDGE_FLAG_AA — Scanline Edge-Flag Antialiasing (Otimizado)
/// ============================================================================
/// 
/// Implementação baseada no artigo "Scanline edge-flag algorithm for antialiasing"
/// de Kiia Kallio.
/// 
/// CARACTERÍSTICAS:
///   - Abordagem Orientada a Scanline (Cache-friendly)
///   - Aritmética de Ponto Fixo (16.16)
///   - Padrão N-Rooks (8 amostras)
///   - Regra Non-Zero Winding por padrão
///
library edge_flag_aa;

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES E PADRÕES
// ─────────────────────────────────────────────────────────────────────────────

const int kSubpixelShift = 3; // 8 amostras
const int kSubpixelCount = 1 << kSubpixelShift;

const int kFixedShift = 16;
const int kFixedOne = 1 << kFixedShift;

/// Padrão N-Rooks (8 amostras)
/// Centros das sub-scanlines com offsets horizontais
const List<double> kRooks8X = [0.25, 0.875, 0.5, 0.125, 0.75, 0.375, 0.0, 0.625];
final Int32List kRooks8XFixed = Int32List.fromList(
    kRooks8X.map((x) => (x * kFixedOne).toInt()).toList());

// ─────────────────────────────────────────────────────────────────────────────
// ESTRUTURAS DE ARESTA
// ─────────────────────────────────────────────────────────────────────────────

class ScanEdge {
  int x;          // Posição X no início da scanline atual (sub-scanline y << 3)
  int slope;      // dx por sub-scanline (Fixed 16.16)
  int firstLine;  // Primeira sub-scanline (global index)
  int lastLine;   // Última sub-scanline (global index)
  int winding;    // +1 ou -1
  ScanEdge? next;

  ScanEdge({
    required this.x,
    required this.slope,
    required this.firstLine,
    required this.lastLine,
    required this.winding,
  }) : super();
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR
// ─────────────────────────────────────────────────────────────────────────────

class EdgeFlagAARasterizer {
  final int width;
  final int height;

  /// Tabela de Arestas (ET) por scanline inteiro
  late final List<ScanEdge?> _edgeTable;
  
  /// Arestas Ativas (AET)
  ScanEdge? _activeEdges;

  /// Buffer de Scanline (Temporary Canvas)
  /// Non-Zero: 1 byte por sample (Int8List)
  late final Int8List _nzScanline;

  /// Framebuffer de saída (ARGB)
  late final Uint32List _framebuffer;

  /// Popcount LUT para 8 bits (escala 0..255)
  late final Uint8List _popCountAlpha;

  EdgeFlagAARasterizer({required this.width, required this.height}) {
    _edgeTable = List<ScanEdge?>.filled(height, null);
    _nzScanline = Int8List((width + 1) * kSubpixelCount);
    _framebuffer = Uint32List(width * height);
    
    _popCountAlpha = Uint8List(256);
    for (int i = 0; i < 256; i++) {
        int count = 0;
        int v = i;
        while (v > 0) { if (v & 1 == 1) count++; v >>= 1; }
        _popCountAlpha[i] = (count * 255 ~/ 8);
    }
  }

  void clear([int backgroundColor = 0xFFFFFFFF]) {
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
    _edgeTable.fillRange(0, _edgeTable.length, null);
    _activeEdges = null;
  }

  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;
    
    final n = vertices.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      _addEdge(vertices[i * 2], vertices[i * 2 + 1],
               vertices[j * 2], vertices[j * 2 + 1]);
    }

    _render(color);
  }

  void _addEdge(double x0, double y0, double x1, double y1) {
    int winding = 1;
    if (y0 > y1) {
        var t = y0; y0 = y1; y1 = t;
        t = x0; x0 = x1; x1 = t;
        winding = -1;
    }

    double dy = y1 - y0;
    if (dy < 1e-9) return;

    // Regra de amostragem: o centro da sub-scanline k está em (k + 0.5) / 8
    // Uma aresta cobre a sub-scanline k se y0 <= (k + 0.5) / 8 < y1
    // => 8*y0 - 0.5 <= k < 8*y1 - 0.5
    final double fy0 = y0 * kSubpixelCount - 0.5;
    final double fy1 = y1 * kSubpixelCount - 0.5;

    int firstLine = fy0.ceil();
    int lastLine = fy1.ceil() - 1;
    if (firstLine > lastLine) return;

    double dx = x1 - x0;
    double slope = dx / (dy * kSubpixelCount);

    // X no centro da primeira sub-scanline (firstLine + 0.5) / 8
    double firstCenterY = (firstLine + 0.5) / kSubpixelCount;
    double xAtFirst = x0 + (firstCenterY - y0) * (dx / dy);
    
    if (xAtFirst.isInfinite || xAtFirst.isNaN || slope.isInfinite || slope.isNaN) return;

    // Ajustar X para o início da scanline inteira (sub-scanline: firstLine & ~7)
    // Isso facilita o loop principal pois ScanEdge.x será sempre o valor em s=0.
    int lineStartSub = (firstLine >> kSubpixelShift) << kSubpixelShift;
    double xAtLineStart = xAtFirst - (firstLine - lineStartSub) * slope;

    final edge = ScanEdge(
        x: (xAtLineStart * kFixedOne).toInt(),
        slope: (slope * kFixedOne).toInt(),
        firstLine: firstLine,
        lastLine: lastLine,
        winding: winding,
    );

    int scanlineIdx = firstLine >> kSubpixelShift;
    if (scanlineIdx >= 0 && scanlineIdx < height) {
        edge.next = _edgeTable[scanlineIdx];
        _edgeTable[scanlineIdx] = edge;
    }
  }

  void _render(int color) {
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;
    final colorA = (color >> 24) & 0xFF;

    final acc = Int32List(kSubpixelCount);

    for (int y = 0; y < height; y++) {
      // 1. Ativar novas arestas
      ScanEdge? e = _edgeTable[y];
      while (e != null) {
        ScanEdge? next = e.next;
        e.next = _activeEdges;
        _activeEdges = e;
        e = next;
      }
      _edgeTable[y] = null;

      if (_activeEdges == null) continue;

      // 2. Plotar flags Non-Zero
      _nzScanline.fillRange(0, _nzScanline.length, 0);
      
      ScanEdge? prev;
      ScanEdge? curr = _activeEdges;
      while (curr != null) {
        final isLastScanline = (curr.lastLine >> kSubpixelShift) == y;
        int x = curr.x;
        final slope = curr.slope;
        final winding = curr.winding;
        final first = curr.firstLine;
        final last = curr.lastLine;
        final baseSub = y << kSubpixelShift;

        for (int s = 0; s < kSubpixelCount; s++) {
          final curSub = baseSub + s;
          if (curSub >= first && curSub <= last) {
             final ix = (x + kRooks8XFixed[s]) >> kFixedShift;
             if (ix >= 0 && ix < width) {
                _nzScanline[ix * kSubpixelCount + s] += winding;
             } else if (ix < 0) {
                _nzScanline[0] += winding; // Toggle no início da linha (acumulador virtual)
             }
          }
          x += slope;
        }

        if (isLastScanline) {
          if (prev == null) _activeEdges = curr.next;
          else prev.next = curr.next;
          curr = curr.next;
        } else {
          curr.x = x;
          prev = curr;
          curr = curr.next;
        }
      }

      // 3. Sweep horizontal (Blit)
      final rowOffset = y * width;
      acc.fillRange(0, kSubpixelCount, 0);
      
      for (int x = 0; x < width; x++) {
        int mask = 0;
        final base = x * kSubpixelCount;
        for (int s = 0; s < kSubpixelCount; s++) {
            final f = _nzScanline[base + s];
            if (f != 0) acc[s] += f;
            if (acc[s] != 0) mask |= (1 << s);
        }

        if (mask != 0) {
          final alpha = (_popCountAlpha[mask] * colorA) >> 8;
          if (alpha >= 255) {
             _framebuffer[rowOffset + x] = color;
          } else {
             _blendPixel(rowOffset + x, colorR, colorG, colorB, alpha);
          }
        }
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _blendPixel(int idx, int r, int g, int b, int alpha) {
    if (alpha <= 0) return;
    final bg = _framebuffer[idx];
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    final invA = 255 - alpha;
    final outR = (r * alpha + bgR * invA) >> 8;
    final outG = (g * alpha + bgG * invA) >> 8;
    final outB = (b * alpha + bgB * invA) >> 8;

    _framebuffer[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
  }

  Uint32List get buffer => _framebuffer;
}
