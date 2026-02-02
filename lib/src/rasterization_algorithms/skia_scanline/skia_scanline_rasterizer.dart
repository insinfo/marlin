//C:\MyDartProjects\marlin\lib\src\rasterization_algorithms\skia_scanline\skia_scanline_rasterizer.dart

import 'dart:typed_data';

/// Regra de preenchimento para o rasterizador
enum FillRule { nonZero, evenOdd }

/// Constantes globais de ponto fixo
const int kFixedBits = 16;
const int kFixedOne = 1 << kFixedBits;
const int kFixedHalf = 1 << (kFixedBits - 1);
const int kFixedMask = kFixedOne - 1;

/// Constantes de subpixel para Anti-Aliasing (8x supersampling vertical)
const int kSubpixelBits = 3;
const int kSubpixelCount = 1 << kSubpixelBits;
const int kSubpixelMask = kSubpixelCount - 1;

/// Representação de uma aresta para o algoritmo de scanline
class SkEdge {
  int fX = 0;  // X atual (ponto fixo)
  int fDx = 0; // Incremento de X por sub-scanline (ponto fixo)
  int fFirstY = 0; // Primeira sub-scanline
  int fLastY = 0;  // Última sub-scanline
  int fWinding = 0; // Direção (+1 ou -1)
  SkEdge? fNext;  // Próxima na AET
  SkEdge? fNextY; // Próxima no bucket do EdgeTable

  bool setLine(double x0, double y0, double x1, double y1) {
    var fy0 = (y0 * kSubpixelCount * kFixedOne).toInt();
    var fy1 = (y1 * kSubpixelCount * kFixedOne).toInt();
    var fx0 = (x0 * kFixedOne).toInt();
    var fx1 = (x1 * kFixedOne).toInt();

    int winding = 1;
    if (fy0 > fy1) {
      final t = fy0; fy0 = fy1; fy1 = t;
      final tx = fx0; fx0 = fx1; fx1 = tx;
      winding = -1;
    }

    final top = (fy0 + kFixedMask) >> kFixedBits;
    final bot = (fy1 - 1) >> kFixedBits;
    if (top > bot) return false;

    final dy = fy1 - fy0;
    final dx = fx1 - fx0;
    int dxdy = 0;
    if (dy != 0) {
      // Usar double para precisão de slope
      dxdy = ((dx.toDouble() / dy.toDouble()) * kFixedOne).toInt();
    }

    final clipY = (top << kFixedBits) + kFixedHalf - fy0;
    final startX = fx0 + ((clipY.toDouble() * dxdy) / kFixedOne).toInt();

    fX = startX;
    fDx = dxdy;
    fFirstY = top;
    fLastY = bot;
    fWinding = winding;
    return true;
  }
}

/// Lista encadeada de arestas gerenciada pelo rasterizador
class EdgeList {
  SkEdge? head;

  void add(SkEdge edge) {
    edge.fNext = head;
    head = edge;
  }

  void sort() {
    if (head == null || head!.fNext == null) return;
    head = _mergeSort(head);
  }

  SkEdge? _mergeSort(SkEdge? h) {
    if (h == null || h.fNext == null) return h;
    var s = h;
    var f = h.fNext;
    while (f != null && f.fNext != null) {
      s = s.fNext!;
      f = f.fNext!.fNext;
    }
    final mid = s.fNext;
    s.fNext = null;
    return _merge(_mergeSort(h), _mergeSort(mid));
  }

  SkEdge? _merge(SkEdge? a, SkEdge? b) {
    if (a == null) return b;
    if (b == null) return a;
    if (a.fX <= b.fX) {
      a.fNext = _merge(a.fNext, b);
      return a;
    } else {
      b.fNext = _merge(a, b.fNext);
      return b;
    }
  }
}

/// Rasterizador de estilo Skia (CPU Scanline com 8x Supersampling e Otimizações SIMD)
class SkiaRasterizer {
  final int width;
  final int height;
  late Uint32List framebuffer;
  late Int32List _scanlineAccumulator;
  late Int32x4List _accSIMD;

  final bool useSimd;
  FillRule fillRule = FillRule.nonZero;

  SkiaRasterizer({required this.width, required this.height, this.useSimd = true}) {
    framebuffer = Uint32List(width * height);
    _scanlineAccumulator = Int32List(width);
    // View SIMD para incrementos rápidos
    _accSIMD = _scanlineAccumulator.buffer.asInt32x4List();
  }

  void clear([int backgroundColor = 0xFFFFFFFF]) {
    framebuffer.fillRange(0, framebuffer.length, backgroundColor);
  }

  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;
    final n = vertices.length ~/ 2;

    int minYSub = 0x7FFFFFFF;
    int maxYSub = -0x80000000;
    final edges = <SkEdge>[];

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final edge = SkEdge();
      if (edge.setLine(vertices[i * 2], vertices[i * 2 + 1], vertices[j * 2], vertices[j * 2 + 1])) {
        edges.add(edge);
        if (edge.fFirstY < minYSub) minYSub = edge.fFirstY;
        if (edge.fLastY > maxYSub) maxYSub = edge.fLastY;
      }
    }

    if (edges.isEmpty) return;

    final subHeight = height << kSubpixelBits;
    final edgeTable = List<SkEdge?>.filled(subHeight, null);
    for (final edge in edges) {
      final y = edge.fFirstY.clamp(0, subHeight - 1);
      edge.fNextY = edgeTable[y];
      edgeTable[y] = edge;
    }

    final aet = EdgeList();
    final startY = (minYSub >> kSubpixelBits).clamp(0, height - 1);
    final stopY = (maxYSub >> kSubpixelBits).clamp(0, height - 1);

    for (int y = startY; y <= stopY; y++) {
      _scanlineAccumulator.fillRange(0, width, 0);

      for (int s = 0; s < kSubpixelCount; s++) {
        final subY = (y << kSubpixelBits) + s;
        if (subY >= subHeight) break;

        // 1. Manutenção da AET
        var e = edgeTable[subY];
        while (e != null) {
          final next = e.fNextY;
          aet.add(e);
          e = next;
        }
        _removeFinished(aet, subY);
        aet.sort();

        // 2. Preenchimento de sub-scanline
        if (aet.head != null) {
          if (useSimd) {
            _fillSubScanlineSIMD(aet);
          } else {
            _fillSubScanlineScalar(aet);
          }
        }

        // 3. Avançar para próxima sub-scanline
        _advanceEdges(aet);
      }

      // 4. Blit final com AA
      if (useSimd) {
        _blitAccumulatedSIMD(y, color);
      } else {
        _blitAccumulatedScalar(y, color);
      }
    }
  }

  void _fillSubScanlineScalar(EdgeList aet) {
    var edge = aet.head;
    int winding = 0;
    int leftX = -1;

    while (edge != null) {
      final x = (edge.fX >> kFixedBits);
      final prevWinding = winding;
      winding += edge.fWinding;

      final wasIn = _isInside(prevWinding);
      final isIn = _isInside(winding);

      if (!wasIn && isIn) {
        leftX = x;
      } else if (wasIn && !isIn) {
        final start = leftX.clamp(0, width);
        final end = x.clamp(0, width);
        for (int i = start; i < end; i++) {
          _scanlineAccumulator[i]++;
        }
      }
      edge = edge.fNext;
    }
  }

  void _blitAccumulatedScalar(int y, int color) {
    final rowOffset = y * width;
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;
    final colorA = (color >> 24) & 0xFF;

    for (int x = 0; x < width; x++) {
      final count = _scanlineAccumulator[x];
      if (count == 0) continue;

      if (count >= kSubpixelCount) {
        framebuffer[rowOffset + x] = color;
      } else {
        final int alpha = (count * colorA) >> kSubpixelBits;
        final bg = framebuffer[rowOffset + x];
        final int invA = 255 - alpha;
        final int r = (colorR * alpha + ((bg >> 16) & 0xFF) * invA) >> 8;
        final int g = (colorG * alpha + ((bg >> 8) & 0xFF) * invA) >> 8;
        final int b = (colorB * alpha + (bg & 0xFF) * invA) >> 8;
        framebuffer[rowOffset + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
      }
    }
  }

  void _removeFinished(EdgeList aet, int y) {
    SkEdge? prev;
    var curr = aet.head;
    while (curr != null) {
      if (curr.fLastY < y) {
        if (prev == null) {
          aet.head = curr.fNext;
          curr = aet.head;
        } else {
          prev.fNext = curr.fNext;
          curr = prev.fNext;
        }
      } else {
        prev = curr;
        curr = curr.fNext;
      }
    }
  }

  void _fillSubScanlineSIMD(EdgeList aet) {
    var edge = aet.head;
    int winding = 0;
    int leftX = -1;

    while (edge != null) {
      final x = (edge.fX >> kFixedBits);
      final prevWinding = winding;
      winding += edge.fWinding;

      final wasIn = _isInside(prevWinding);
      final isIn = _isInside(winding);

      if (!wasIn && isIn) {
        leftX = x;
      } else if (wasIn && !isIn) {
        final start = leftX.clamp(0, width);
        final end = x.clamp(0, width);
        _incrementSpanSIMD(start, end);
      }
      edge = edge.fNext;
    }
  }

  /// Otimização SIMD: incrementa span do acumulador 4 pixels por vez
  void _incrementSpanSIMD(int start, int end) {
    if (end <= start) return;
    int i = start;
    // Cabeçalho escalar para alinhamento
    while (i < end && (i & 3) != 0) {
      _scanlineAccumulator[i]++;
      i++;
    }
    // Corpo SIMD
    if (i + 4 <= end) {
      final one = Int32x4(1, 1, 1, 1);
      int simdIdx = i >> 2;
      while (i + 4 <= end) {
        _accSIMD[simdIdx] = _accSIMD[simdIdx] + one;
        simdIdx++;
        i += 4;
      }
    }
    // Rodapé escalar
    while (i < end) {
      _scanlineAccumulator[i]++;
      i++;
    }
  }

  void _blitAccumulatedSIMD(int y, int color) {
    final rowOffset = y * width;
    final colorR = (color >> 16) & 0xFF;
    final colorG = (color >> 8) & 0xFF;
    final colorB = color & 0xFF;
    final colorA = (color >> 24) & 0xFF;

    final int simdWidth = width >> 2;

    for (int i = 0; i < simdWidth; i++) {
      final counts = _accSIMD[i];
      // Pular blocos vazios rapidamente
      if (counts.x == 0 && counts.y == 0 && counts.z == 0 && counts.w == 0) continue;

      final baseIdx = i << 2;
      for (int k = 0; k < 4; k++) {
        final x = baseIdx + k;
        final count = _scanlineAccumulator[x];
        if (count == 0) continue;

        if (count >= kSubpixelCount) {
          framebuffer[rowOffset + x] = color;
        } else {
          final int alpha = (count * colorA) >> kSubpixelBits;
          final bg = framebuffer[rowOffset + x];
          final int invA = 255 - alpha;
          final int r = (colorR * alpha + ((bg >> 16) & 0xFF) * invA) >> 8;
          final int g = (colorG * alpha + ((bg >> 8) & 0xFF) * invA) >> 8;
          final int b = (colorB * alpha + (bg & 0xFF) * invA) >> 8;
          framebuffer[rowOffset + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
      }
    }

    for (int x = simdWidth << 2; x < width; x++) {
      final count = _scanlineAccumulator[x];
      if (count == 0) continue;
      if (count >= kSubpixelCount) {
        framebuffer[rowOffset + x] = color;
      } else {
        final int alpha = (count * colorA) >> kSubpixelBits;
        final bg = framebuffer[rowOffset + x];
        final int invA = 255 - alpha;
        final int r = (colorR * alpha + ((bg >> 16) & 0xFF) * invA) >> 8;
        final int g = (colorG * alpha + ((bg >> 8) & 0xFF) * invA) >> 8;
        final int b = (colorB * alpha + (bg & 0xFF) * invA) >> 8;
        framebuffer[rowOffset + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
      }
    }
  }

  void _advanceEdges(EdgeList aet) {
    var edge = aet.head;
    while (edge != null) {
      edge.fX += edge.fDx;
      edge = edge.fNext;
    }
  }

  bool _isInside(int winding) {
    if (fillRule == FillRule.evenOdd) {
      return (winding & 1) != 0;
    } else {
      return winding != 0;
    }
  }

  Uint32List get buffer => framebuffer;
}

/// Mock de blitter para compatibilidade se necessário
abstract class Blitter {
  void blitH(int x, int y, int width);
  void blitAntiH(int x, int y, List<int> alphas, int count);
}

class AlphaBlitter implements Blitter {
  final Uint32List buffer;
  final int bufferWidth;
  final int color;
  AlphaBlitter(this.buffer, this.bufferWidth, this.color);
  @override void blitH(int x, int y, int width) {}
  @override void blitAntiH(int x, int y, List<int> alphas, int count) {}
}
