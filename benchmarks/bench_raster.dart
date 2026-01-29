import 'dart:math' as math;
import 'dart:typed_data';

const int W = 512;
const int H = 512;

void main() {
  final polys = <List<math.Point<double>>>[
    _makeStar(cx: 256, cy: 256, r1: 220, r2: 90, spikes: 11),
    _makeCirclePoly(cx: 256, cy: 256, r: 220, segments: 256),
    _makeRandomPoly(seed: 1, n: 200, margin: 20),
  ];

  final out = Uint8List(W * H);

  final rasterizers = <_Raster>[
    _Raster('cells_prefix (Blend2D-like)', rasterCellsPrefix),
    _Raster('scanline_analytic (Skia-like mask)', rasterScanlineAnalytic),
    _Raster('aet_sub4 (Marlin-like)', rasterAetSub4),
    _Raster('edge_flag_sub4 (Kallio-like PoC)', rasterEdgeFlagSub4),
  ];

  // Warmup
  for (final r in rasterizers) {
    for (final p in polys) {
      for (int i = 0; i < 30; i++) {
        r.fn(p, W, H, out);
      }
    }
  }

  // Bench
  for (final r in rasterizers) {
    int checksum = 0;
    final sw = Stopwatch()..start();
    const iters = 120;

    for (int i = 0; i < iters; i++) {
      final p = polys[i % polys.length];
      checksum ^= r.fn(p, W, H, out);
    }
    sw.stop();

    final ms = sw.elapsedMicroseconds / 1000.0;
    print('${r.name.padRight(30)}  ${ms.toStringAsFixed(2)} ms   checksum=$checksum');
  }
}

class _Raster {
  final String name;
  final int Function(List<math.Point<double>>, int, int, Uint8List) fn;
  _Raster(this.name, this.fn);
}

int _checksum(Uint8List a) {
  int s = 0;
  for (final v in a) {
    s = (s * 1315423911) ^ v;
  }
  return s;
}

void _clear(Uint8List out) => out.fillRange(0, out.length, 0);

List<math.Point<double>> _makeStar({
  required double cx,
  required double cy,
  required double r1,
  required double r2,
  required int spikes,
}) {
  final pts = <math.Point<double>>[];
  final step = math.pi / spikes;
  for (int i = 0; i < spikes * 2; i++) {
    final r = (i.isEven) ? r1 : r2;
    final a = i * step - math.pi / 2;
    pts.add(math.Point(cx + math.cos(a) * r, cy + math.sin(a) * r));
  }
  return pts;
}

List<math.Point<double>> _makeCirclePoly({
  required double cx,
  required double cy,
  required double r,
  required int segments,
}) {
  final pts = <math.Point<double>>[];
  for (int i = 0; i < segments; i++) {
    final a = (i / segments) * math.pi * 2;
    pts.add(math.Point(cx + math.cos(a) * r, cy + math.sin(a) * r));
  }
  return pts;
}

List<math.Point<double>> _makeRandomPoly({required int seed, required int n, required double margin}) {
  final rnd = math.Random(seed);
  final pts = <math.Point<double>>[];
  for (int i = 0; i < n; i++) {
    final x = margin + rnd.nextDouble() * (W - 2 * margin);
    final y = margin + rnd.nextDouble() * (H - 2 * margin);
    pts.add(math.Point(x, y));
  }
  // ordena por ângulo pra virar um polígono “mais” simples (não perfeito)
  final cx = pts.map((p) => p.x).reduce((a, b) => a + b) / pts.length;
  final cy = pts.map((p) => p.y).reduce((a, b) => a + b) / pts.length;
  pts.sort((a, b) => math.atan2(a.y - cy, a.x - cx).compareTo(math.atan2(b.y - cy, b.x - cx)));
  return pts;
}

/// 1) Blend2D-like: coverDelta + area, prefix-sum por scanline.
/// Ideia inspirada no “cells: area+cover” e na cobertura calculada via prefix-sum. :contentReference[oaicite:4]{index=4}
int rasterCellsPrefix(List<math.Point<double>> poly, int w, int h, Uint8List out) {
  _clear(out);

  final coverDelta = Int32List(w + 1);
  final area = Int32List(w);

  final xs = <double>[];
  for (int y = 0; y < h; y++) {
    coverDelta.fillRange(0, coverDelta.length, 0);
    area.fillRange(0, area.length, 0);
    xs.clear();

    final yy = y + 0.5; // pixel center
    for (int i = 0; i < poly.length; i++) {
      final a = poly[i];
      final b = poly[(i + 1) % poly.length];
      final y0 = a.y, y1 = b.y;
      if ((yy >= y0 && yy < y1) || (yy >= y1 && yy < y0)) {
        final t = (yy - y0) / (y1 - y0);
        final x = a.x + (b.x - a.x) * t;
        xs.add(x);
      }
    }
    xs.sort();

    for (int i = 0; i + 1 < xs.length; i += 2) {
      double x0 = xs[i];
      double x1 = xs[i + 1];
      if (x0 > x1) {
        final tmp = x0; x0 = x1; x1 = tmp;
      }
      if (x1 <= 0 || x0 >= w) continue;

      x0 = x0.clamp(0.0, w.toDouble());
      x1 = x1.clamp(0.0, w.toDouble());

      final xL = x0.floor();
      final xR = x1.floor();

      final fL = x0 - xL;
      final fR = x1 - xR;

      if (xL == xR) {
        // span dentro de 1 pixel
        area[xL] += ((x1 - x0) * 255).round();
      } else {
        // bordas
        area[xL] += ((1.0 - fL) * 255).round();
        if (xR >= 0 && xR < w) {
          area[xR] += (fR * 255).round();
        }

        // interior cheio via prefix-sum
        final start = xL + 1;
        final end = xR; // exclusivo
        if (start < end) {
          coverDelta[start] += 255;
          coverDelta[end] -= 255;
        }
      }
    }

    int cover = 0;
    final row = y * w;
    for (int x = 0; x < w; x++) {
      cover += coverDelta[x];
      int a = cover + area[x];
      if (a < 0) a = 0;
      if (a > 255) a = 255;
      out[row + x] = a;
    }
  }

  return _checksum(out);
}

/// 2) “Skia-like” (no sentido de gerar uma coverage mask A8 por scanline) :contentReference[oaicite:5]{index=5}
/// Implementação analítica simples: interseções + borda parcial + interior cheio.
int rasterScanlineAnalytic(List<math.Point<double>> poly, int w, int h, Uint8List out) {
  _clear(out);

  final xs = <double>[];
  for (int y = 0; y < h; y++) {
    xs.clear();
    final yy = y + 0.5;
    for (int i = 0; i < poly.length; i++) {
      final a = poly[i];
      final b = poly[(i + 1) % poly.length];
      final y0 = a.y, y1 = b.y;
      if ((yy >= y0 && yy < y1) || (yy >= y1 && yy < y0)) {
        final t = (yy - y0) / (y1 - y0);
        xs.add(a.x + (b.x - a.x) * t);
      }
    }
    xs.sort();

    final row = y * w;
    for (int i = 0; i + 1 < xs.length; i += 2) {
      double x0 = xs[i];
      double x1 = xs[i + 1];
      if (x0 > x1) {
        final tmp = x0; x0 = x1; x1 = tmp;
      }
      if (x1 <= 0 || x0 >= w) continue;

      x0 = x0.clamp(0.0, w.toDouble());
      x1 = x1.clamp(0.0, w.toDouble());

      final xl = x0.floor();
      final xr = x1.floor();
      if (xl == xr) {
        final a = ((x1 - x0) * 255).round();
        out[row + xl] = math.max(out[row + xl], a);
        continue;
      }

      // pixel de borda esquerda
      out[row + xl] = math.max(out[row + xl], ((1.0 - (x0 - xl)) * 255).round());

      // interior cheio
      for (int x = xl + 1; x < xr; x++) {
        out[row + x] = 255;
      }

      // pixel de borda direita
      if (xr >= 0 && xr < w) {
        out[row + xr] = math.max(out[row + xr], ((x1 - xr) * 255).round());
      }
    }
  }

  return _checksum(out);
}

/// 3) Marlin-like: AET + supersampling 4x4 + acumula em alphaRow.
/// Marlin usa scanline + supersampling + AET e trabalha em tiles. :contentReference[oaicite:6]{index=6}
/// Aqui é uma versão bem reduzida (sem tiles grandes, só acumula por linha).
int rasterAetSub4(List<math.Point<double>> poly, int w, int h, Uint8List out) {
  _clear(out);
  const S = 4;
  const subShift = 2; // log2(S)
  final hSub = h * S;
  final wSub = w * S;

  final buckets = List.generate(hSub + 1, (_) => <_Edge>[]);
  for (int i = 0; i < poly.length; i++) {
    final p0 = poly[i];
    final p1 = poly[(i + 1) % poly.length];

    int x0 = (p0.x * S).round();
    int y0 = (p0.y * S).round();
    int x1 = (p1.x * S).round();
    int y1 = (p1.y * S).round();

    if (y0 == y1) continue;
    if (y0 > y1) {
      final tx = x0; x0 = x1; x1 = tx;
      final ty = y0; y0 = y1; y1 = ty;
    }

    if (y1 <= 0 || y0 >= hSub) continue;

    final dy = (y1 - y0);
    final dxFix = (((x1 - x0) << 16) ~/ dy); // subpixel por subpixel em 16.16
    final xFix0 = (x0 << 16);

    final yStart = y0.clamp(0, hSub);
    final yEnd = y1.clamp(0, hSub);

    // avança x até yStart se houve clamp
    final xFixStart = xFix0 + dxFix * (yStart - y0);
    buckets[yStart].add(_Edge(yMax: yEnd, xFix: xFixStart, dxFix: dxFix));
  }

  final active = <_Edge>[];
  final alphaRow = Int32List(w);

  void addSpan(int x0Sub, int x1Sub) {
    if (x0Sub < 0) x0Sub = 0;
    if (x1Sub > wSub) x1Sub = wSub;
    if (x1Sub <= x0Sub) return;

    int p0 = x0Sub >> subShift;
    int p1 = (x1Sub - 1) >> subShift;
    if (p0 == p1) {
      alphaRow[p0] += (x1Sub - x0Sub);
      return;
    }
    alphaRow[p0] += (((p0 + 1) << subShift) - x0Sub);
    for (int p = p0 + 1; p < p1; p++) {
      alphaRow[p] += S;
    }
    alphaRow[p1] += (x1Sub - (p1 << subShift));
  }

  int curPixY = -1;
  for (int ySub = 0; ySub < hSub; ySub++) {
    final pixY = ySub >> subShift;
    if (pixY != curPixY) {
      curPixY = pixY;
      alphaRow.fillRange(0, w, 0);
    }

    active.addAll(buckets[ySub]);
    active.removeWhere((e) => ySub >= e.yMax);

    active.sort((a, b) => a.xFix.compareTo(b.xFix));

    for (int i = 0; i + 1 < active.length; i += 2) {
      final x0Sub = active[i].xFix >> 16;
      final x1Sub = active[i + 1].xFix >> 16;
      addSpan(x0Sub, x1Sub);
    }

    // step X
    for (final e in active) {
      e.xFix += e.dxFix;
    }

    // flush quando terminar o bloco de 4 sub-linhas
    if ((ySub & (S - 1)) == (S - 1)) {
      final row = pixY * w;
      for (int x = 0; x < w; x++) {
        final a = (alphaRow[x] * 255) ~/ (S * S);
        out[row + x] = a.clamp(0, 255);
      }
    }
  }

  return _checksum(out);
}

class _Edge {
  final int yMax;
  int xFix;   // 16.16 em unidades de subpixel
  final int dxFix;
  _Edge({required this.yMax, required this.xFix, required this.dxFix});
}

/// 4) Edge-flag-like PoC: marca “flags” de aresta (bits) e varre togglando inside.
/// O paper descreve exatamente esse espírito: marcar arestas e preencher com “pen” que alterna ao ler bits. :contentReference[oaicite:7]{index=7}
/// (Esta PoC não tem todas as otimizações do paper.)
int rasterEdgeFlagSub4(List<math.Point<double>> poly, int w, int h, Uint8List out) {
  _clear(out);
  const S = 4;
  const subShift = 2;
  final hSub = h * S;
  final wSub = w * S;

  final buckets = List.generate(hSub + 1, (_) => <_Edge>[]);
  for (int i = 0; i < poly.length; i++) {
    final p0 = poly[i];
    final p1 = poly[(i + 1) % poly.length];

    int x0 = (p0.x * S).round();
    int y0 = (p0.y * S).round();
    int x1 = (p1.x * S).round();
    int y1 = (p1.y * S).round();

    if (y0 == y1) continue;
    if (y0 > y1) {
      final tx = x0; x0 = x1; x1 = tx;
      final ty = y0; y0 = y1; y1 = ty;
    }
    if (y1 <= 0 || y0 >= hSub) continue;

    final dy = (y1 - y0);
    final dxFix = (((x1 - x0) << 16) ~/ dy);
    final xFix0 = (x0 << 16);

    final yStart = y0.clamp(0, hSub);
    final yEnd = y1.clamp(0, hSub);
    final xFixStart = xFix0 + dxFix * (yStart - y0);
    buckets[yStart].add(_Edge(yMax: yEnd, xFix: xFixStart, dxFix: dxFix));
  }

  final active = <_Edge>[];
  final alphaRow = Int32List(w);
  final words = (wSub + 31) >> 5;
  final flags = Uint32List(words);

  int curPixY = -1;
  for (int ySub = 0; ySub < hSub; ySub++) {
    final pixY = ySub >> subShift;
    if (pixY != curPixY) {
      curPixY = pixY;
      alphaRow.fillRange(0, w, 0);
    }

    flags.fillRange(0, flags.length, 0);

    active.addAll(buckets[ySub]);
    active.removeWhere((e) => ySub >= e.yMax);

    // marca as interseções (edge flags)
    for (final e in active) {
      final xSub = e.xFix >> 16;
      if (xSub >= 0 && xSub < wSub) {
        final wi = xSub >> 5;
        final bi = xSub & 31;
        flags[wi] ^= (1 << bi); // “complement operation”
      }
      e.xFix += e.dxFix;
    }

    // varre e alterna inside
    bool inside = false;
    for (int xSub = 0; xSub < wSub; xSub++) {
      final wi = xSub >> 5;
      final bi = xSub & 31;
      final bit = (flags[wi] >> bi) & 1;
      if (bit != 0) inside = !inside;
      if (inside) alphaRow[xSub >> subShift] += 1;
    }

    if ((ySub & (S - 1)) == (S - 1)) {
      final row = pixY * w;
      for (int x = 0; x < w; x++) {
        out[row + x] = ((alphaRow[x] * 255) ~/ (S * S)).clamp(0, 255);
      }
    }
  }

  return _checksum(out);
}
