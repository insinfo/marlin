library lnaf_se;

import 'dart:math' as math;
import 'dart:typed_data';
import '../common/polygon_contract.dart';
import 'lnaf_se_tables.dart';

enum _FillRule { evenOdd, nonZero }

class _Pt {
  final double x;
  final double y;
  const _Pt(this.x, this.y);
}

class LnafSeLut {
  final int dirCount;
  final int binsPerOctant;
  final int maxDist16;
  final Uint8List table;
  final Float32List nx;
  final Float32List ny;

  static const int _distStrideMax = 1024;
  static LnafSeLut? _cachedDefault;

  LnafSeLut._(
    this.dirCount,
    this.binsPerOctant,
    this.maxDist16,
    this.table,
    this.nx,
    this.ny,
  );

  int get distStride => 2 * maxDist16 + 1;

  @pragma('vm:prefer-inline')
  int alpha(int dirId, int dist16) {
    if (dist16 <= -maxDist16) return 0;
    if (dist16 >= maxDist16) return 255;
    return table[dirId * distStride + (dist16 + maxDist16)];
  }

  static LnafSeLut build({
    int binsPerOctant = 16,
    int maxDist16 = 32,
  }) {
    if (binsPerOctant <= 0) {
      throw ArgumentError('binsPerOctant must be > 0');
    }
    if (maxDist16 <= 0 || (2 * maxDist16 + 1) > _distStrideMax) {
      throw ArgumentError('maxDist16 invalido');
    }

    if (binsPerOctant == kLnafBinsPerOctant &&
        maxDist16 == kLnafMaxDist16) {
      return precomputedDefault();
    }

    final dirCount = 8 * binsPerOctant;
    final stride = 2 * maxDist16 + 1;
    final table = Uint8List(dirCount * stride);
    final nx = Float32List(dirCount);
    final ny = Float32List(dirCount);
    _populateDirectionVectors(nx, ny, binsPerOctant);

    for (int id = 0; id < dirCount; id++) {
      final nxx = nx[id];
      final nyy = ny[id];
      for (int di = -maxDist16; di <= maxDist16; di++) {
        // Queremos alpha crescente com dist16 (mais "dentro" => maior cobertura).
        // Como o clipping usa n·x >= d, inverter o sinal de d alinha a LUT com
        // o dist16 produzido por _alphaAt.
        final d = -di / 16.0;
        final cov = _coverageHalfPlane(nxx, nyy, d);
        final a = (cov * 255.0 + 0.5).floor();
        table[id * stride + (di + maxDist16)] = a.clamp(0, 255);
      }
    }

    for (int id = 0; id < dirCount; id++) {
      final base = id * stride;
      for (int i = 1; i < stride; i++) {
        final prev = table[base + i - 1];
        final cur = table[base + i];
        if (cur < prev) table[base + i] = prev;
      }
    }

    return LnafSeLut._(dirCount, binsPerOctant, maxDist16, table, nx, ny);
  }

  static LnafSeLut precomputedDefault() {
    final cached = _cachedDefault;
    if (cached != null) return cached;

    final nx = Float32List(kLnafDirCount);
    final ny = Float32List(kLnafDirCount);
    _populateDirectionVectors(nx, ny, kLnafBinsPerOctant);

    final lut = LnafSeLut._(
      kLnafDirCount,
      kLnafBinsPerOctant,
      kLnafMaxDist16,
      kLnafCoverageTable,
      nx,
      ny,
    );
    _cachedDefault = lut;
    return lut;
  }

  static void _populateDirectionVectors(
    Float32List nx,
    Float32List ny,
    int binsPerOctant,
  ) {
    for (int oct = 0; oct < 8; oct++) {
      final base = oct * (math.pi / 4.0);
      for (int b = 0; b < binsPerOctant; b++) {
        final t = (b + 0.5) / binsPerOctant;
        final ang = base + t * (math.pi / 4.0);
        final id = oct * binsPerOctant + b;
        nx[id] = math.cos(ang).toDouble();
        ny[id] = math.sin(ang).toDouble();
      }
    }
  }

  static double _coverageHalfPlane(double nx, double ny, double d) {
    const x0 = -0.5, x1 = 0.5;
    const y0 = -0.5, y1 = 0.5;

    final px = Float64List(8);
    final py = Float64List(8);
    int n = 4;
    px[0] = x0;
    py[0] = y0;
    px[1] = x1;
    py[1] = y0;
    px[2] = x1;
    py[2] = y1;
    px[3] = x0;
    py[3] = y1;

    final outx = Float64List(8);
    final outy = Float64List(8);
    int outN = 0;

    double sx = px[n - 1];
    double sy = py[n - 1];
    double sVal = nx * sx + ny * sy - d;
    bool sIn = sVal >= 0.0;

    for (int i = 0; i < n; i++) {
      final ex = px[i];
      final ey = py[i];
      final eVal = nx * ex + ny * ey - d;
      final eIn = eVal >= 0.0;

      if (sIn && eIn) {
        outx[outN] = ex;
        outy[outN] = ey;
        outN++;
      } else if (sIn && !eIn) {
        final t = sVal / (sVal - eVal);
        outx[outN] = sx + (ex - sx) * t;
        outy[outN] = sy + (ey - sy) * t;
        outN++;
      } else if (!sIn && eIn) {
        final t = sVal / (sVal - eVal);
        outx[outN] = sx + (ex - sx) * t;
        outy[outN] = sy + (ey - sy) * t;
        outN++;
        outx[outN] = ex;
        outy[outN] = ey;
        outN++;
      }

      sx = ex;
      sy = ey;
      sVal = eVal;
      sIn = eIn;
    }

    if (outN < 3) return 0.0;
    double area2 = 0.0;
    double ax = outx[outN - 1];
    double ay = outy[outN - 1];
    for (int i = 0; i < outN; i++) {
      final bx = outx[i];
      final by = outy[i];
      area2 += ax * by - bx * ay;
      ax = bx;
      ay = by;
    }
    final area = (area2.abs()) * 0.5;
    if (area <= 0.0) return 0.0;
    if (area >= 1.0) return 1.0;
    return area;
  }
}

class LNAFSERasterizer implements PolygonContract {
  static const int kScale = 256;
  static const int kHalf = 128;
  static const int kInvQ = 20;

  final int width;
  final int height;
  final bool useSimdFill;
  final LnafSeLut lut;
  final Uint32List _pixels32;
  Int32x4List? _pixelsV;

  late Int32List _eYStart;
  late Int32List _eYEnd;
  late Int32List _eX;
  late Int32List _eDx;
  late Int32List _eA;
  late Int32List _eB;
  late Int64List _eC;
  late Int32List _eInvDen;
  late Int32List _eDir;
  late Int32List _eWind;
  late Int32List _eNext;
  late Int32List _bucketHead;

  late Int32List _active;
  int _activeCount = 0;

  late Int32List _ix;
  late Int32List _ie;
  late Int32List _qsL;
  late Int32List _qsR;

  LNAFSERasterizer(
      {required this.width,
      required this.height,
      this.useSimdFill = false,
      LnafSeLut? lut})
      : lut = lut ?? LnafSeLut.build(),
        _pixels32 = Uint32List(width * height) {
    if (useSimdFill) {
      _pixelsV = _pixels32.buffer.asInt32x4List();
    }
  }

  Uint32List get buffer => _pixels32;

  void clear([int color = 0xFF000000]) {
    final c = color & 0xFFFFFFFF;
    if (!useSimdFill) {
      _pixels32.fillRange(0, _pixels32.length, c);
      return;
    }
    final v = _pixelsV!;
    final vv = Int32x4(c, c, c, c);
    final n4 = v.length;
    for (int i = 0; i < n4; i++) {
      v[i] = vv;
    }
    final start = n4 << 2;
    for (int i = start; i < _pixels32.length; i++) {
      _pixels32[i] = c;
    }
  }

  @override
  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;
    final contours = _toContours(vertices, contourVertexCounts);
    if (contours.isEmpty) return;
    _buildEdges(contours);
    _rasterize(
      color,
      windingRule == 0 ? _FillRule.evenOdd : _FillRule.nonZero,
    );
  }

  List<List<_Pt>> _toContours(List<double> vertices, List<int>? contourCounts) {
    final totalPoints = vertices.length ~/ 2;
    final counts = _resolveContours(totalPoints, contourCounts);
    final out = <List<_Pt>>[];
    for (final c in counts) {
      if (c.count < 2) continue;
      final pts = <_Pt>[];
      for (int i = 0; i < c.count; i++) {
        final p = c.start + i;
        pts.add(_Pt(vertices[p * 2], vertices[p * 2 + 1]));
      }
      if (pts.length >= 2) out.add(pts);
    }
    return out;
  }

  @pragma('vm:prefer-inline')
  static int _ceilDiv(int a, int b) {
    if (a >= 0) return (a + b - 1) ~/ b;
    return -((-a) ~/ b);
  }

  void _buildEdges(List<List<_Pt>> contours) {
    int edgeCount = 0;
    for (final c in contours) {
      if (c.length < 2) continue;
      for (int i = 0; i < c.length; i++) {
        final p0 = c[i];
        final p1 = c[(i + 1) % c.length];
        if (p0.y == p1.y) continue;
        edgeCount++;
      }
    }
    if (edgeCount == 0) {
      _bucketHead = Int32List(height)..fillRange(0, height, -1);
      _active = Int32List(0);
      _ix = Int32List(0);
      _ie = Int32List(0);
      _activeCount = 0;
      return;
    }

    _eYStart = Int32List(edgeCount);
    _eYEnd = Int32List(edgeCount);
    _eX = Int32List(edgeCount);
    _eDx = Int32List(edgeCount);
    _eA = Int32List(edgeCount);
    _eB = Int32List(edgeCount);
    _eC = Int64List(edgeCount);
    _eInvDen = Int32List(edgeCount);
    _eDir = Int32List(edgeCount);
    _eWind = Int32List(edgeCount);
    _eNext = Int32List(edgeCount);

    _bucketHead = Int32List(height);
    _bucketHead.fillRange(0, height, -1);

    _active = Int32List(edgeCount);
    _ix = Int32List(edgeCount);
    _ie = Int32List(edgeCount);
    _qsL = Int32List(64);
    _qsR = Int32List(64);

    int e = 0;
    final binsPerOct = lut.binsPerOctant;

    for (final c in contours) {
      if (c.length < 2) continue;
      for (int i = 0; i < c.length; i++) {
        final p0 = c[i];
        final p1 = c[(i + 1) % c.length];
        if (p0.y == p1.y) continue;

        int x0 = (p0.x * kScale).round();
        int y0 = (p0.y * kScale).round();
        int x1 = (p1.x * kScale).round();
        int y1 = (p1.y * kScale).round();

        final winding = (y1 > y0) ? 1 : -1;

        if (y0 > y1) {
          final tx = x0;
          x0 = x1;
          x1 = tx;
          final ty = y0;
          y0 = y1;
          y1 = ty;
        }

        final yStart = _ceilDiv(y0 - kHalf, kScale);
        final yEndEx = _ceilDiv(y1 - kHalf, kScale);

        if (yEndEx <= 0 || yStart >= height) continue;
        final yS = yStart.clamp(0, height);
        final yE = yEndEx.clamp(0, height);
        if (yS >= yE) continue;

        final yCenter = yS * kScale + kHalf;
        final dy = (y1 - y0);
        final dx = (x1 - x0);
        final t = (yCenter - y0);
        final xAt = x0 + ((dx * t) ~/ dy);
        final xStep = (dx * kScale) ~/ dy;

        final A = (y0 - y1);
        final B = (x1 - x0);
        final C = (x0 * y1) - (x1 * y0);
        final len = math.sqrt((A.toDouble() * A.toDouble()) + (B.toDouble() * B.toDouble()));
        final invDen = len <= 0.0
            ? 0
            : ((16.0 * (1 << kInvQ)) / (kScale * len))
                .round()
                .clamp(0, 0x7FFFFFFF);
        final dirId = _dirQuantize(A, B, binsPerOct);

        final idx = e++;
        _eYStart[idx] = yS;
        _eYEnd[idx] = yE;
        _eX[idx] = xAt;
        _eDx[idx] = xStep;
        _eA[idx] = A;
        _eB[idx] = B;
        _eC[idx] = C;
        _eInvDen[idx] = invDen;
        _eDir[idx] = dirId;
        _eWind[idx] = winding;

        final head = _bucketHead[yS];
        _eNext[idx] = head;
        _bucketHead[yS] = idx;
      }
    }
    _activeCount = 0;
  }

  @pragma('vm:prefer-inline')
  static int _dirQuantize(int A, int B, int binsPerOctant) {
    int a = A;
    int b = B;
    if (a == 0 && b == 0) return 0;
    final absA = a < 0 ? -a : a;
    final absB = b < 0 ? -b : b;
    int oct;
    final aGeB = absA >= absB;
    if (a >= 0) {
      if (b >= 0) {
        oct = aGeB ? 0 : 1;
      } else {
        oct = aGeB ? 7 : 6;
      }
    } else {
      if (b >= 0) {
        oct = aGeB ? 3 : 2;
      } else {
        oct = aGeB ? 4 : 5;
      }
    }
    final maxv = aGeB ? absA : absB;
    final minv = aGeB ? absB : absA;
    if (maxv == 0) return oct * binsPerOctant;
    final ratioQ12 = (minv << 12) ~/ maxv;
    int bin = (ratioQ12 * binsPerOctant) >> 12;
    if (bin >= binsPerOctant) bin = binsPerOctant - 1;
    return oct * binsPerOctant + bin;
  }

  void _rasterize(int argb, _FillRule rule) {
    final srcA0 = (argb >>> 24) & 255;
    final srcR = (argb >>> 16) & 255;
    final srcG = (argb >>> 8) & 255;
    final srcB = argb & 255;

    for (int y = 0; y < height; y++) {
      for (int e = _bucketHead[y]; e != -1; e = _eNext[e]) {
        _active[_activeCount++] = e;
      }
      if (_activeCount == 0) continue;

      int n = 0;
      final yCenter = y * kScale + kHalf;
      for (int i = 0; i < _activeCount; i++) {
        final e = _active[i];
        if (y >= _eYEnd[e]) continue;
        _ix[n] = _eX[e];
        _ie[n] = e;
        _eX[e] = _eX[e] + _eDx[e];
        _active[n] = e;
        n++;
      }
      _activeCount = n;
      if (n < 2) continue;
      _sortPairsByX(_ix, _ie, n);

      if (rule == _FillRule.evenOdd) {
        for (int i = 0; i + 1 < n; i += 2) {
          final x0 = _ix[i];
          final e0 = _ie[i];
          final x1 = _ix[i + 1];
          final e1 = _ie[i + 1];
          if (x0 == x1) continue;
          _fillSpanAA(y, x0, x1, e0, e1, yCenter, srcA0, srcR, srcG, srcB);
        }
      } else {
        int winding = 0;
        int xStart = 0;
        int eStart = -1;
        for (int i = 0; i < n; i++) {
          final x = _ix[i];
          final e = _ie[i];
          final w = _eWind[e];
          final newW = winding + w;
          if (winding == 0 && newW != 0) {
            xStart = x;
            eStart = e;
          } else if (winding != 0 && newW == 0) {
            final xEnd = x;
            final eEnd = e;
            if (xStart != xEnd) {
              _fillSpanAA(
                y,
                xStart,
                xEnd,
                eStart,
                eEnd,
                yCenter,
                srcA0,
                srcR,
                srcG,
                srcB,
              );
            }
            eStart = -1;
          }
          winding = newW;
        }
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _fillSpanAA(
    int y,
    int x0,
    int x1,
    int leftEdge,
    int rightEdge,
    int yCenter,
    int srcA0,
    int srcR,
    int srcG,
    int srcB,
  ) {
    int xa = x0;
    int xb = x1;
    int eL = leftEdge;
    int eR = rightEdge;
    if (xa > xb) {
      final t = xa;
      xa = xb;
      xb = t;
      final te = eL;
      eL = eR;
      eR = te;
    }
    final leftPix = xa >> 8;
    final rightPix = (xb - 1) >> 8;
    if (rightPix < 0 || leftPix >= width) return;
    final row = y * width;

    if (leftPix == rightPix) {
      // Single-pixel span: both edges in same pixel.
      // Analytic area: integrate width between left and right edges.
      final pix = leftPix;
      if (pix < 0 || pix >= width) return;
      final dxL = _eDx[eL];
      final dxR = _eDx[eR];
      final xLTop = xa - (dxL >> 1);
      final xLBot = xa + (dxL >> 1);
      final xRTop = xb - (dxR >> 1);
      final xRBot = xb + (dxR >> 1);
      final pxLeft = pix << 8;
      final covR = _integrateCovRight(xRTop - pxLeft, xRBot - pxLeft);
      final covL = _integrateCovRight(xLTop - pxLeft, xLBot - pxLeft);
      int cov = covR - covL;
      if (cov < 0) cov = 0;
      if (cov > 255) cov = 255;
      final effA = (cov * srcA0 + 127) ~/ 255;
      if (effA <= 0) return;
      final idx = row + pix;
      _pixels32[idx] = _blendOver(_pixels32[idx], srcR, srcG, srcB, effA);
      return;
    }

    // ── Analytic trapezoid coverage for boundary pixels ───────────────
    // Edge sweeps from xTop to xBot within pixel height. Coverage =
    // ∫₀¹ clamp(u(t), 0, 1) dt  where u(t) = (edgeX(t) - pxLeft) / 256.
    // _integrateCovLeft/Right compute this integral analytically in Q8
    // fixed-point, giving exact coverage for any edge angle.
    //
    // Band width = ceil(|dxStep| / 256) + 1  pixels, extending the
    // transition zone for shallow edges.

    final dxL = _eDx[eL];
    final dxR = _eDx[eR];
    final absDxL = dxL < 0 ? -dxL : dxL;
    final absDxR = dxR < 0 ? -dxR : dxR;
    final bandL = (absDxL >> 8) + 1;
    final bandR = (absDxR >> 8) + 1;

    // Edge x at top/bottom of this pixel row
    final xLTop = xa - (dxL >> 1);
    final xLBot = xa + (dxL >> 1);
    final xRTop = xb - (dxR >> 1);
    final xRBot = xb + (dxR >> 1);

    final spanWidth = rightPix - leftPix + 1;

    if (bandL + bandR >= spanWidth) {
      // Thin span: both edges affect all pixels
      final pxS = leftPix < 0 ? 0 : leftPix;
      final pxE = rightPix >= width ? width - 1 : rightPix;
      for (int px = pxS; px <= pxE; px++) {
        final pxLeft = px << 8;
        final covR = _integrateCovRight(xRTop - pxLeft, xRBot - pxLeft);
        final covL = _integrateCovRight(xLTop - pxLeft, xLBot - pxLeft);
        int a = covR - covL;
        if (a < 0) a = 0;
        if (a > 255) a = 255;
        final effA = (a * srcA0 + 127) ~/ 255;
        if (effA > 0) {
          _pixels32[row + px] =
              _blendOver(_pixels32[row + px], srcR, srcG, srcB, effA);
        }
      }
      return;
    }

    // Left AA band
    {
      final pxS = leftPix < 0 ? 0 : leftPix;
      final pxE = (leftPix + bandL) > width ? width : (leftPix + bandL);
      for (int px = pxS; px < pxE; px++) {
        final pxLeft = px << 8;
        // Coverage = fraction of pixel to the RIGHT of left edge (inside)
        // = 1 - ∫₀¹ clamp((edgeX(t) - pxLeft) / 256, 0, 1) dt
        final a = 255 - _integrateCovRight(xLTop - pxLeft, xLBot - pxLeft);
        final effA = (a * srcA0 + 127) ~/ 255;
        if (effA > 0) {
          _pixels32[row + px] =
              _blendOver(_pixels32[row + px], srcR, srcG, srcB, effA);
        }
      }
    }

    // Solid interior
    final fs = (leftPix + bandL).clamp(0, width);
    final fe = (rightPix - bandR + 1).clamp(0, width);
    if (fs < fe) {
      _fillSolidSpan(
          row, fs, fe, (srcA0 << 24) | (srcR << 16) | (srcG << 8) | srcB);
    }

    // Right AA band
    {
      final pxS = (rightPix - bandR + 1) < 0 ? 0 : (rightPix - bandR + 1);
      final pxE = (rightPix + 1) > width ? width : (rightPix + 1);
      for (int px = pxS; px < pxE; px++) {
        final pxLeft = px << 8;
        // Coverage = fraction of pixel to the LEFT of right edge (inside)
        // = ∫₀¹ clamp((edgeX(t) - pxLeft) / 256, 0, 1) dt
        final a = _integrateCovRight(xRTop - pxLeft, xRBot - pxLeft);
        final effA = (a * srcA0 + 127) ~/ 255;
        if (effA > 0) {
          _pixels32[row + px] =
              _blendOver(_pixels32[row + px], srcR, srcG, srcB, effA);
        }
      }
    }
  }

  /// Analytic integral of clamp((u(t))/256, 0, 1) for t ∈ [0,1],
  /// where u(t) = u0 + (u1 - u0)*t.  u0,u1 in Q8 (256 = 1 pixel).
  /// Returns coverage 0..255 — the fraction of the pixel width that
  /// lies to the LEFT of the midpoint 256 (i.e. inside the pixel).
  ///
  /// This is the exact area-under-curve for a linear edge sweeping
  /// from u0 (top) to u1 (bottom) within a single pixel column.
  @pragma('vm:prefer-inline')
  static int _integrateCovRight(int u0, int u1) {
    // Ensure u0 <= u1 (swap if needed, integral is symmetric)
    if (u0 > u1) {
      final t = u0;
      u0 = u1;
      u1 = t;
    }
    // Both outside left → 0
    if (u1 <= 0) return 0;
    // Both outside right → 255
    if (u0 >= 256) return 255;

    final du = u1 - u0;

    if (du == 0) {
      // Horizontal edge segment in this pixel row
      if (u0 <= 0) return 0;
      if (u0 >= 256) return 255;
      return (u0 * 255 + 128) >> 8;
    }

    // Clamp bounds: find t-range where u(t) ∈ [0, 256]
    // u(t) = u0 + du*t  →  t = (u - u0) / du
    // t_enter = max(0, (0 - u0) / du) = max(0, -u0/du)
    // t_exit  = min(1, (256 - u0) / du)
    //
    // Area = ∫₀¹ clamp(u(t)/256, 0, 1) dt
    //      = (integral of 0 below 0) + (integral of u/256 in [0,256]) + (integral of 1 above 256)
    //
    // Using Q16 for precision in intermediate calculations.

    // t values scaled by du to avoid division:
    // t_low  = max(0, -u0)   [times when u(t) = 0]
    // t_high = min(du, 256 - u0) [times when u(t) = 256]
    int tLow = -u0;
    if (tLow < 0) tLow = 0;
    int tHigh = 256 - u0;
    if (tHigh > du) tHigh = du;

    // Area of the ramp portion (where 0 < u < 256):
    // ∫_{tLow/du}^{tHigh/du} (u0 + du*t) / 256 dt
    // = 1/256 * [ u0*(tHigh-tLow)/du + du/2 * (tHigh²-tLow²)/du² ]
    // = 1/(256*du) * [ u0*(tHigh-tLow) + (tHigh²-tLow²)/2 ]
    // = 1/(256*du) * [ u0*(tHigh-tLow) + (tHigh+tLow)*(tHigh-tLow)/2 ]
    // = (tHigh-tLow) / (256*du) * [ u0 + (tHigh+tLow)/2 ]
    //
    // Let mid = u0 + (tHigh+tLow)/2  — this is the average u value
    // Area_ramp = (tHigh-tLow) * mid / (256 * du)
    //
    // Area of the saturated portion (where u >= 256):
    // = (du - tHigh) / du   [fraction of t where u >= 256]

    final span = tHigh - tLow;
    // mid * 2 = 2*u0 + tHigh + tLow
    final mid2 = 2 * u0 + tHigh + tLow;

    // Total area * 256 * du * 2:
    //   ramp:      span * mid2
    //   saturated: (du - tHigh) * 256 * 2
    final rampArea = span * mid2;
    final satArea = (du - tHigh) * 512;
    final totalNumer = rampArea + satArea;
    final totalDenom = 512 * du; // = 256 * du * 2

    int result = (totalNumer * 255 + (totalDenom >> 1)) ~/ totalDenom;
    if (result < 0) result = 0;
    if (result > 255) result = 255;
    return result;
  }

  @pragma('vm:prefer-inline')
  int _evalF(int e, int x, int y) => (_eA[e] * x) + (_eB[e] * y) + _eC[e].toInt();

  @pragma('vm:prefer-inline')
  int _alphaAt(int e, int xC, int yC, bool insidePositive) {
    int f = _evalF(e, xC, yC);
    if (!insidePositive) f = -f;
    final invDen = _eInvDen[e];
    if (invDen == 0) return 255;
    int dist16;
    if (f >= 0) {
      dist16 = (f * invDen + (1 << (kInvQ - 1))) >> kInvQ;
    } else {
      dist16 = -(((-f) * invDen + (1 << (kInvQ - 1))) >> kInvQ);
    }
    final clampDist16 = lut.maxDist16;
    if (dist16 <= -clampDist16) return 0;
    if (dist16 >= clampDist16) return 255;
    return lut.alpha(_eDir[e], dist16);
  }

  void _fillSolidSpan(int row, int x0, int x1, int argb) {
    int i = row + x0;
    final end = row + x1;
    final c = argb & 0xFFFFFFFF;
    if (!useSimdFill) {
      for (; i < end; i++) {
        _pixels32[i] = c;
      }
      return;
    }
    final v = _pixelsV!;
    final vv = Int32x4(c, c, c, c);
    int head = (i + 3) & ~3;
    for (; i < head && i < end; i++) {
      _pixels32[i] = c;
    }
    int i4 = i >> 2;
    int end4 = end >> 2;
    for (; i4 < end4; i4++) {
      v[i4] = vv;
    }
    i = end4 << 2;
    for (; i < end; i++) {
      _pixels32[i] = c;
    }
  }

  @pragma('vm:prefer-inline')
  static int _blendOver(int dst, int sr, int sg, int sb, int sa) {
    final da = (dst >>> 24) & 255;
    final dr = (dst >>> 16) & 255;
    final dg = (dst >>> 8) & 255;
    final db = dst & 255;
    final invA = 255 - sa;
    final outA = sa + ((da * invA + 127) ~/ 255);
    final outR = ((sr * sa + dr * invA) + 127) ~/ 255;
    final outG = ((sg * sa + dg * invA) + 127) ~/ 255;
    final outB = ((sb * sa + db * invA) + 127) ~/ 255;
    return (outA << 24) | (outR << 16) | (outG << 8) | outB;
  }

  void _sortPairsByX(Int32List xs, Int32List es, int n) {
    if (n <= 16) {
      _insertionSort(xs, es, n);
      return;
    }
    int sp = 0;
    _qsL[sp] = 0;
    _qsR[sp] = n - 1;
    sp++;
    while (sp > 0) {
      sp--;
      int l = _qsL[sp];
      int r = _qsR[sp];
      while (l < r) {
        int i = l;
        int j = r;
        final pivot = xs[(l + r) >> 1];
        while (i <= j) {
          while (xs[i] < pivot) i++;
          while (xs[j] > pivot) j--;
          if (i <= j) {
            final tx = xs[i];
            xs[i] = xs[j];
            xs[j] = tx;
            final te = es[i];
            es[i] = es[j];
            es[j] = te;
            i++;
            j--;
          }
        }
        if (j - l < r - i) {
          if (l < j) {
            if (sp >= _qsL.length) _growStack();
            _qsL[sp] = l;
            _qsR[sp] = j;
            sp++;
          }
          l = i;
        } else {
          if (i < r) {
            if (sp >= _qsL.length) _growStack();
            _qsL[sp] = i;
            _qsR[sp] = r;
            sp++;
          }
          r = j;
        }
      }
    }
  }

  void _growStack() {
    final nl = Int32List(_qsL.length * 2);
    final nr = Int32List(_qsR.length * 2);
    nl.setAll(0, _qsL);
    nr.setAll(0, _qsR);
    _qsL = nl;
    _qsR = nr;
  }

  @pragma('vm:prefer-inline')
  static void _insertionSort(Int32List xs, Int32List es, int n) {
    for (int i = 1; i < n; i++) {
      final keyX = xs[i];
      final keyE = es[i];
      int j = i - 1;
      while (j >= 0 && xs[j] > keyX) {
        xs[j + 1] = xs[j];
        es[j + 1] = es[j];
        j--;
      }
      xs[j + 1] = keyX;
      es[j + 1] = keyE;
    }
  }
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
