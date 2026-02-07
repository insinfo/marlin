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
import 'edge_flag_aa_tables.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES E PADRÕES
// ─────────────────────────────────────────────────────────────────────────────

const int kSubpixelShift = 3; // 8 amostras
const int kSubpixelCount = 1 << kSubpixelShift;

const int kFixedShift = 16;
const int kFixedOne = 1 << kFixedShift;

// ─────────────────────────────────────────────────────────────────────────────
// ESTRUTURAS DE ARESTA
// ─────────────────────────────────────────────────────────────────────────────

class ScanEdge {
  int x; // Posição X no início da scanline atual (sub-scanline y << 3)
  int slope; // dx por sub-scanline (Fixed 16.16)
  int firstLine; // Primeira sub-scanline (global index)
  int lastLine; // Última sub-scanline (global index)
  int winding; // +1 ou -1
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
  ScanEdge? _freeEdges;

  /// Buffer de Scanline (Temporary Canvas)
  /// Non-Zero: 1 byte por sample (Int8List)
  late final Int8List _nzScanline;

  /// Framebuffer de saída (ARGB)
  late final Uint32List _framebuffer;

  int _prevDirtyMinX = 1;
  int _prevDirtyMaxX = 0;
  int _pendingMinY = 1;
  int _pendingMaxY = 0;

  EdgeFlagAARasterizer({required this.width, required this.height}) {
    _edgeTable = List<ScanEdge?>.filled(height, null);
    _nzScanline = Int8List((width + 1) * kSubpixelCount);
    _framebuffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFFFFFFFF]) {
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
    _nzScanline.fillRange(0, _nzScanline.length, 0);
    for (int i = 0; i < _edgeTable.length; i++) {
      final head = _edgeTable[i];
      if (head != null) {
        _recycleChain(head);
        _edgeTable[i] = null;
      }
    }
    if (_activeEdges != null) {
      _recycleChain(_activeEdges!);
      _activeEdges = null;
    }
    _activeEdges = null;
    _prevDirtyMinX = 1;
    _prevDirtyMaxX = 0;
    _pendingMinY = 1;
    _pendingMaxY = 0;
  }

  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6 || (color >> 24) == 0) return;

    _pendingMinY = height;
    _pendingMaxY = -1;

    final n = vertices.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      _addEdge(vertices[i * 2], vertices[i * 2 + 1], vertices[j * 2],
          vertices[j * 2 + 1]);
    }

    if (_pendingMinY <= _pendingMaxY) {
      _render(color, _pendingMinY, _pendingMaxY);
    }
  }

  void _addEdge(double x0, double y0, double x1, double y1) {
    int winding = 1;
    if (y0 > y1) {
      var t = y0;
      y0 = y1;
      y1 = t;
      t = x0;
      x0 = x1;
      x1 = t;
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

    if (xAtFirst.isInfinite ||
        xAtFirst.isNaN ||
        slope.isInfinite ||
        slope.isNaN) return;

    final maxSubLine = height * kSubpixelCount - 1;
    if (lastLine < 0 || firstLine > maxSubLine) return;

    if (firstLine < 0) {
      xAtFirst += (-firstLine) * slope;
      firstLine = 0;
    }
    if (lastLine > maxSubLine) {
      lastLine = maxSubLine;
    }

    // Ajustar X para o início da scanline inteira (sub-scanline: firstLine & ~7)
    // Isso facilita o loop principal pois ScanEdge.x será sempre o valor em s=0.
    int lineStartSub = (firstLine >> kSubpixelShift) << kSubpixelShift;
    double xAtLineStart = xAtFirst - (firstLine - lineStartSub) * slope;

    final edge = _obtainEdge(
      x: (xAtLineStart * kFixedOne).toInt(),
      slope: (slope * kFixedOne).toInt(),
      firstLine: firstLine,
      lastLine: lastLine,
      winding: winding,
    );

    final scanlineIdx = firstLine >> kSubpixelShift;
    final lastScanlineIdx = lastLine >> kSubpixelShift;

    edge.next = _edgeTable[scanlineIdx];
    _edgeTable[scanlineIdx] = edge;

    if (scanlineIdx < _pendingMinY) _pendingMinY = scanlineIdx;
    if (lastScanlineIdx > _pendingMaxY) _pendingMaxY = lastScanlineIdx;
  }

  void _render(int color, int yStart, int yEnd) {
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;
    final colorA = (color >> 24) & 0xFF;
    final sourceOpaque = colorA >= 255;

    for (int y = yStart; y <= yEnd; y++) {
      // Limpa apenas faixa suja da scanline anterior.
      if (_prevDirtyMinX <= _prevDirtyMaxX) {
        final clearStart = _prevDirtyMinX * kSubpixelCount;
        final clearEnd = (_prevDirtyMaxX + 1) * kSubpixelCount;
        _nzScanline.fillRange(clearStart, clearEnd, 0);
      }

      // 1. Ativar novas arestas
      ScanEdge? e = _edgeTable[y];
      while (e != null) {
        ScanEdge? next = e.next;
        e.next = _activeEdges;
        _activeEdges = e;
        e = next;
      }
      _edgeTable[y] = null;

      if (_activeEdges == null) {
        _prevDirtyMinX = 1;
        _prevDirtyMaxX = 0;
        continue;
      }

      // 2. Plotar flags Non-Zero
      int dirtyMinX = width;
      int dirtyMaxX = -1;

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
              if (ix < dirtyMinX) dirtyMinX = ix;
              if (ix > dirtyMaxX) dirtyMaxX = ix;
            } else if (ix < 0) {
              _nzScanline[s] +=
                  winding; // Toggle no início da linha (por subamostra)
              dirtyMinX = 0;
              if (dirtyMaxX < 0) dirtyMaxX = 0;
            }
          }
          x += slope;
        }

        if (isLastScanline) {
          final dead = curr;
          final next = curr.next;
          if (prev == null) {
            _activeEdges = next;
          } else {
            prev.next = next;
          }
          curr = next;
          _recycleEdge(dead);
        } else {
          curr.x = x;
          prev = curr;
          curr = curr.next;
        }
      }

      if (dirtyMaxX < 0) {
        _prevDirtyMinX = 1;
        _prevDirtyMaxX = 0;
        continue;
      }

      // 3. Sweep horizontal (Blit)
      final rowOffset = y * width;
      int acc0 = 0;
      int acc1 = 0;
      int acc2 = 0;
      int acc3 = 0;
      int acc4 = 0;
      int acc5 = 0;
      int acc6 = 0;
      int acc7 = 0;

      for (int x = dirtyMinX; x < width; x++) {
        final base = x << kSubpixelShift;

        final f0 = _nzScanline[base];
        final f1 = _nzScanline[base + 1];
        final f2 = _nzScanline[base + 2];
        final f3 = _nzScanline[base + 3];
        final f4 = _nzScanline[base + 4];
        final f5 = _nzScanline[base + 5];
        final f6 = _nzScanline[base + 6];
        final f7 = _nzScanline[base + 7];

        if (f0 != 0) acc0 += f0;
        if (f1 != 0) acc1 += f1;
        if (f2 != 0) acc2 += f2;
        if (f3 != 0) acc3 += f3;
        if (f4 != 0) acc4 += f4;
        if (f5 != 0) acc5 += f5;
        if (f6 != 0) acc6 += f6;
        if (f7 != 0) acc7 += f7;

        int mask = 0;
        if (acc0 != 0) mask |= 1;
        if (acc1 != 0) mask |= 2;
        if (acc2 != 0) mask |= 4;
        if (acc3 != 0) mask |= 8;
        if (acc4 != 0) mask |= 16;
        if (acc5 != 0) mask |= 32;
        if (acc6 != 0) mask |= 64;
        if (acc7 != 0) mask |= 128;

        if (mask != 0) {
          final alphaBase = kPopCountAlpha8[mask];
          final alpha = sourceOpaque ? alphaBase : (alphaBase * colorA) >> 8;
          if (alpha >= 255) {
            _framebuffer[rowOffset + x] = color;
          } else {
            _blendPixel(rowOffset + x, colorR, colorG, colorB, alpha);
          }
        }

        final anyCoverage =
            (acc0 | acc1 | acc2 | acc3 | acc4 | acc5 | acc6 | acc7) != 0;
        if (x >= dirtyMaxX && !anyCoverage) {
          break;
        }
      }

      _prevDirtyMinX = dirtyMinX;
      _prevDirtyMaxX = dirtyMaxX;
    }
  }

  @pragma('vm:prefer-inline')
  ScanEdge _obtainEdge({
    required int x,
    required int slope,
    required int firstLine,
    required int lastLine,
    required int winding,
  }) {
    final edge = _freeEdges;
    if (edge != null) {
      _freeEdges = edge.next;
      edge.x = x;
      edge.slope = slope;
      edge.firstLine = firstLine;
      edge.lastLine = lastLine;
      edge.winding = winding;
      edge.next = null;
      return edge;
    }
    return ScanEdge(
      x: x,
      slope: slope,
      firstLine: firstLine,
      lastLine: lastLine,
      winding: winding,
    );
  }

  @pragma('vm:prefer-inline')
  void _recycleEdge(ScanEdge edge) {
    edge.next = _freeEdges;
    _freeEdges = edge;
  }

  void _recycleChain(ScanEdge head) {
    ScanEdge? curr = head;
    while (curr != null) {
      final next = curr.next;
      curr.next = _freeEdges;
      _freeEdges = curr;
      curr = next;
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
