library lnaf_se;

// Resultado dos benchmarks no projeto:
// - LUT de cobertura nao melhorou o throughput do LNAF-SE no workload real.
// - LUT tambem nao trouxe ganho consistente de qualidade visual frente ao Marlin.
// Diretriz atual: caminho padrao sem LUT, mantendo LUT apenas como opcao de teste.

import 'dart:math' as math;
import 'dart:typed_data';
import '../common/polygon_contract.dart';
import 'lnaf_se_tables.dart';

enum _FillRule { evenOdd, nonZero }

class _LnafSeQualityConfig {
  final int bandBias;
  final int maxBand;
  final int lutMix;
  final int softnessQ8;
  final bool wideSweepFullSpan;
  const _LnafSeQualityConfig({
    required this.bandBias,
    required this.maxBand,
    required this.lutMix,
    required this.softnessQ8,
    required this.wideSweepFullSpan,
  });
}

const int _kEnvBandBias =
    int.fromEnvironment('LNAF_SE_BAND_BIAS', defaultValue: 1);
const int _kEnvMaxBand =
    int.fromEnvironment('LNAF_SE_MAX_BAND', defaultValue: 2);
const int _kEnvLutMix = int.fromEnvironment('LNAF_SE_LUT_MIX', defaultValue: 0);
const int _kEnvSoftnessQ8 =
    int.fromEnvironment('LNAF_SE_SOFTNESS_Q8', defaultValue: 256);
const bool _kEnvWideSweep =
    bool.fromEnvironment('LNAF_SE_WIDE_SWEEP', defaultValue: true);

const _LnafSeQualityConfig _kLnafSeConfig = _LnafSeQualityConfig(
  bandBias: _kEnvBandBias,
  maxBand: _kEnvMaxBand,
  lutMix: _kEnvLutMix,
  softnessQ8: _kEnvSoftnessQ8,
  wideSweepFullSpan: _kEnvWideSweep,
);

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

    if (binsPerOctant == kLnafBinsPerOctant && maxDist16 == kLnafMaxDist16) {
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
  static const int kFlatEdgeDy =
      int.fromEnvironment('LNAF_SE_FLAT_EDGE_DY', defaultValue: 0);
  static const int kFlatSlopeShift =
      int.fromEnvironment('LNAF_SE_FLAT_SLOPE_SHIFT', defaultValue: 5);

  final int width;
  final int height;
  final bool useSimdFill;
  final _LnafSeQualityConfig _qualityCfg;
  final LnafSeLut lut;
  final Uint32List _pixels32;
  Int32x4List? _pixelsV;

  late Int32List _eYEnd;
  late Int32List _eXHi;
  late Int32List _eDxHi;
  late Int32List _eDx;
  late Int32List _eA;
  late Int32List _eB;
  late Int64List _eC;
  late Int32List _eX0;
  late Int32List _eY0;
  late Int32List _eX1;
  late Int32List _eY1;
  late Int32List _eInvDen;
  late Int32List _eDir;
  late Int32List _eWind;
  late Int32List _eNext;
  late Int32List _bucketHead;
  int _edgeCount = 0;

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
      : _qualityCfg = _kLnafSeConfig,
        lut = lut ?? LnafSeLut.build(),
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
    _buildEdges(vertices, contourVertexCounts);
    if (_edgeCount == 0) return;
    _rasterize(
      color,
      windingRule == 0 ? _FillRule.evenOdd : _FillRule.nonZero,
    );
  }

  @pragma('vm:prefer-inline')
  static int _ceilDiv(int a, int b) {
    if (a >= 0) return (a + b - 1) ~/ b;
    return -((-a) ~/ b);
  }

  @pragma('vm:prefer-inline')
  static int _divRound(int num, int den) {
    if (den == 0) return 0;
    if (num >= 0) {
      return (num + (den >> 1)) ~/ den;
    }
    return -(((-num) + (den >> 1)) ~/ den);
  }

  @pragma('vm:prefer-inline')
  static bool _skipEdgeBySlope(int dxAbs, int dyAbs) {
    if (dyAbs <= 0) return true;
    // Suppress ultra-flat micro-edges that generate long horizontal streaks.
    if (kFlatEdgeDy > 0 &&
        dyAbs <= kFlatEdgeDy &&
        dxAbs >= (dyAbs << kFlatSlopeShift)) {
      return true;
    }
    return false;
  }

  void _buildEdges(List<double> vertices, List<int>? contourCounts) {
    final totalPoints = vertices.length >> 1;
    bool useSingleContour;
    if (contourCounts == null || contourCounts.isEmpty) {
      useSingleContour = true;
    } else {
      int consumed = 0;
      bool hasAny = false;
      bool valid = true;
      for (final raw in contourCounts) {
        if (raw <= 0) continue;
        hasAny = true;
        if (consumed + raw > totalPoints) {
          valid = false;
          break;
        }
        consumed += raw;
      }
      useSingleContour = !valid || !hasAny || consumed != totalPoints;
    }

    void forEachContour(void Function(int start, int count) body) {
      if (useSingleContour) {
        body(0, totalPoints);
        return;
      }
      int start = 0;
      for (final raw in contourCounts!) {
        if (raw <= 0) continue;
        body(start, raw);
        start += raw;
      }
    }

    int edgeCount = 0;
    forEachContour((start, count) {
      if (count < 2) return;
      for (int i = 0; i < count; i++) {
        final p0 = start + i;
        final p1 = start + ((i + 1) % count);
        final x0 = (vertices[p0 << 1] * kScale).round();
        final x1 = (vertices[p1 << 1] * kScale).round();
        final y0 = (vertices[(p0 << 1) + 1] * kScale).round();
        final y1 = (vertices[(p1 << 1) + 1] * kScale).round();
        final dxAbs = (x1 - x0).abs();
        final dyAbs = (y1 - y0).abs();
        if (_skipEdgeBySlope(dxAbs, dyAbs)) continue;
        edgeCount++;
      }
    });
    if (edgeCount == 0) {
      _bucketHead = Int32List(height)..fillRange(0, height, -1);
      _active = Int32List(0);
      _ix = Int32List(0);
      _ie = Int32List(0);
      _activeCount = 0;
      _edgeCount = 0;
      return;
    }

    _eYEnd = Int32List(edgeCount);
    _eXHi = Int32List(edgeCount);
    _eDxHi = Int32List(edgeCount);
    _eDx = Int32List(edgeCount);
    _eA = Int32List(edgeCount);
    _eB = Int32List(edgeCount);
    _eC = Int64List(edgeCount);
    _eX0 = Int32List(edgeCount);
    _eY0 = Int32List(edgeCount);
    _eX1 = Int32List(edgeCount);
    _eY1 = Int32List(edgeCount);
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
    final needLutMetrics = _qualityCfg.lutMix > 0;

    forEachContour((start, count) {
      if (count < 2) return;
      for (int i = 0; i < count; i++) {
        final p0 = start + i;
        final p1 = start + ((i + 1) % count);
        final p0x = p0 << 1;
        final p1x = p1 << 1;

        int x0 = (vertices[p0x] * kScale).round();
        int y0 = (vertices[p0x + 1] * kScale).round();
        int x1 = (vertices[p1x] * kScale).round();
        int y1 = (vertices[p1x + 1] * kScale).round();
        final dxAbs = (x1 - x0).abs();
        final dyAbs = (y1 - y0).abs();
        if (_skipEdgeBySlope(dxAbs, dyAbs)) continue;

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
        final xAt = x0 + _divRound(dx * t, dy);
        final xStepHi = _divRound((dx * kScale) << 8, dy);
        final xStep = xStepHi >> 8;

        final A = (y0 - y1);
        final B = (x1 - x0);
        final C = (x0 * y1) - (x1 * y0);
        int invDen = 0;
        int dirId = 0;
        if (needLutMetrics) {
          final len = math.sqrt(
              (A.toDouble() * A.toDouble()) + (B.toDouble() * B.toDouble()));
          invDen = len <= 0.0
              ? 0
              : ((16.0 * (1 << kInvQ)) / (kScale * len))
                  .round()
                  .clamp(0, 0x7FFFFFFF);
          dirId = _dirQuantize(A, B, binsPerOct);
        }

        final idx = e++;
        _eYEnd[idx] = yE;
        _eXHi[idx] = xAt << 8;
        _eDxHi[idx] = xStepHi;
        _eDx[idx] = xStep;
        _eA[idx] = A;
        _eB[idx] = B;
        _eC[idx] = C;
        _eX0[idx] = x0;
        _eY0[idx] = y0;
        _eX1[idx] = x1;
        _eY1[idx] = y1;
        _eInvDen[idx] = invDen;
        _eDir[idx] = dirId;
        _eWind[idx] = winding;

        final head = _bucketHead[yS];
        _eNext[idx] = head;
        _bucketHead[yS] = idx;
      }
    });
    _edgeCount = e;
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
        final x = (_eXHi[e] + 128) >> 8;
        _ix[n] = x;
        _ie[n] = e;
        _eXHi[e] = _eXHi[e] + _eDxHi[e];
        _active[n] = e;
        n++;
      }
      _activeCount = n;
      if (n < 2) continue;
      _sortPairsByX(_ix, _ie, n);

      if (rule == _FillRule.evenOdd) {
        int parity = 0;
        int xStart = 0;
        int eStart = -1;
        int i = 0;
        while (i < n) {
          final x = _ix[i];
          int j = i + 1;
          while (j < n && _ix[j] == x) {
            j++;
          }
          final oldParity = parity;
          parity ^= ((j - i) & 1);
          if (oldParity == 0 && parity != 0) {
            xStart = x;
            eStart = _ie[i];
          } else if (oldParity != 0 && parity == 0) {
            final eEnd = _ie[i];
            if (xStart != x) {
              _fillSpanAA(
                y,
                xStart,
                x,
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
          i = j;
        }
      } else {
        int winding = 0;
        int xStart = 0;
        int eStart = -1;
        int i = 0;
        while (i < n) {
          final x = _ix[i];
          int j = i + 1;
          int groupWind = _eWind[_ie[i]];
          while (j < n && _ix[j] == x) {
            groupWind += _eWind[_ie[j]];
            j++;
          }

          final oldW = winding;
          final newW = winding + groupWind;

          if (oldW == 0 && newW != 0) {
            xStart = x;
            int rep = _ie[i];
            if (newW > 0) {
              for (int k = i; k < j; k++) {
                final e = _ie[k];
                if (_eWind[e] > 0) {
                  rep = e;
                  break;
                }
              }
            } else {
              for (int k = i; k < j; k++) {
                final e = _ie[k];
                if (_eWind[e] < 0) {
                  rep = e;
                  break;
                }
              }
            }
            eStart = rep;
          } else if (oldW != 0 && newW == 0) {
            int eEnd = _ie[i];
            if (oldW > 0) {
              for (int k = i; k < j; k++) {
                final e = _ie[k];
                if (_eWind[e] < 0) {
                  eEnd = e;
                  break;
                }
              }
            } else {
              for (int k = i; k < j; k++) {
                final e = _ie[k];
                if (_eWind[e] > 0) {
                  eEnd = e;
                  break;
                }
              }
            }
            if (xStart != x) {
              _fillSpanAA(
                y,
                xStart,
                x,
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
          i = j;
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
    final useLutRefinement = _qualityCfg.lutMix > 0;

    if (leftPix == rightPix) {
      final pix = leftPix;
      if (pix < 0 || pix >= width) return;
      final xInside = (xa + xb) >> 1;
      final insidePositiveL = _evalF(eL, xInside, yCenter) >= 0;
      final insidePositiveR = _evalF(eR, xInside, yCenter) >= 0;
      final dxL = _eDx[eL];
      final dxR = _eDx[eR];
      final xLTop = xa - (dxL >> 1);
      final xLBot = xa + (dxL >> 1);
      final xRTop = xb - (dxR >> 1);
      final xRBot = xb + (dxR >> 1);
      final pxLeft = pix << 8;
      final cov = _coverageAtPixel(
        xLTop,
        xLBot,
        xRTop,
        xRBot,
        pxLeft,
        yCenter,
        eL,
        eR,
        false,
        insidePositiveL,
        insidePositiveR,
      );
      final effA = (cov * srcA0 + 127) ~/ 255;
      if (effA <= 0) return;
      final idx = row + pix;
      _pixels32[idx] = _blendOver(_pixels32[idx], srcR, srcG, srcB, effA);
      return;
    }

    final xInside = (xa + xb) >> 1;
    final insidePositiveL = _evalF(eL, xInside, yCenter) >= 0;
    final insidePositiveR = _evalF(eR, xInside, yCenter) >= 0;

    final yTop = yCenter - kHalf;
    final yBot = yCenter + kHalf;

    final dxL = _eDx[eL];
    final dxR = _eDx[eR];
    int xLTop = xa - (dxL >> 1);
    int xLBot = xa + (dxL >> 1);
    int xRTop = xb - (dxR >> 1);
    int xRBot = xb + (dxR >> 1);

    final approxSweepL = (xLBot - xLTop).abs();
    final approxSweepR = (xRBot - xRTop).abs();
    if (approxSweepL > 256) {
      xLTop = _edgeXAtY(eL, yTop);
      xLBot = _edgeXAtY(eL, yBot);
    }
    if (approxSweepR > 256) {
      xRTop = _edgeXAtY(eR, yTop);
      xRBot = _edgeXAtY(eR, yBot);
    }

    final sweepL = ((xLBot - xLTop).abs() + 255) >> 8;
    final sweepR = ((xRBot - xRTop).abs() + 255) >> 8;
    int bandL = sweepL + _qualityCfg.bandBias;
    int bandR = sweepR + _qualityCfg.bandBias;
    if (bandL > _qualityCfg.maxBand) bandL = _qualityCfg.maxBand;
    if (bandR > _qualityCfg.maxBand) bandR = _qualityCfg.maxBand;

    final spanWidth = rightPix - leftPix + 1;
    final wideSweep = (sweepL > (_qualityCfg.maxBand + 2) ||
        sweepR > (_qualityCfg.maxBand + 2));

    if (wideSweep && _qualityCfg.wideSweepFullSpan && spanWidth <= 14) {
      // Keep the wide-sweep AA local to the current span neighborhood.
      // This avoids long horizontal leaks on near-flat edges.
      int extra = math.max(sweepL, sweepR) + 1;
      if (extra > 8) extra = 8;
      int pxS = leftPix - extra;
      int pxEEx = rightPix + 1 + extra;
      if (pxS < 0) pxS = 0;
      if (pxEEx > width) pxEEx = width;
      if (pxS >= pxEEx) return;
      _renderAaSegmentFast(
        row: row,
        pxS: pxS,
        pxEEx: pxEEx,
        xLTop: xLTop,
        xLBot: xLBot,
        xRTop: xRTop,
        xRBot: xRBot,
        yCenter: yCenter,
        eL: eL,
        eR: eR,
        useLutRefinement: useLutRefinement,
        insidePositiveL: insidePositiveL,
        insidePositiveR: insidePositiveR,
        srcA0: srcA0,
        srcR: srcR,
        srcG: srcG,
        srcB: srcB,
      );
      final fs = (leftPix + 1).clamp(0, width);
      final fe = rightPix.clamp(0, width);
      if (fs < fe) {
        _fillInteriorRange(row, fs, fe, srcA0, srcR, srcG, srcB);
      }
      return;
    }

    if (wideSweep) {
      // For large spans, avoid full-span AA but widen edge bands to keep
      // coverage smooth on steep edges.
      if (sweepL > bandL) bandL = sweepL;
      if (sweepR > bandR) bandR = sweepR;
      if (bandL > 6) bandL = 6;
      if (bandR > 6) bandR = 6;
    }

    if (bandL + bandR >= spanWidth) {
      final pxS = leftPix < 0 ? 0 : leftPix;
      final pxE = rightPix >= width ? width - 1 : rightPix;
      _renderAaSegmentFast(
        row: row,
        pxS: pxS,
        pxEEx: pxE + 1,
        xLTop: xLTop,
        xLBot: xLBot,
        xRTop: xRTop,
        xRBot: xRBot,
        yCenter: yCenter,
        eL: eL,
        eR: eR,
        useLutRefinement: useLutRefinement,
        insidePositiveL: insidePositiveL,
        insidePositiveR: insidePositiveR,
        srcA0: srcA0,
        srcR: srcR,
        srcG: srcG,
        srcB: srcB,
      );
      return;
    }

    {
      final pxS = leftPix < 0 ? 0 : leftPix;
      final pxE = (leftPix + bandL) > width ? width : (leftPix + bandL);
      _renderAaSegmentFast(
        row: row,
        pxS: pxS,
        pxEEx: pxE,
        xLTop: xLTop,
        xLBot: xLBot,
        xRTop: xRTop,
        xRBot: xRBot,
        yCenter: yCenter,
        eL: eL,
        eR: eR,
        useLutRefinement: useLutRefinement,
        insidePositiveL: insidePositiveL,
        insidePositiveR: insidePositiveR,
        srcA0: srcA0,
        srcR: srcR,
        srcG: srcG,
        srcB: srcB,
      );
    }

    final fs = (leftPix + bandL).clamp(0, width);
    final fe = (rightPix - bandR + 1).clamp(0, width);
    if (fs < fe) {
      _fillInteriorRange(row, fs, fe, srcA0, srcR, srcG, srcB);
    }

    {
      final pxS = (rightPix - bandR + 1) < 0 ? 0 : (rightPix - bandR + 1);
      final pxE = (rightPix + 1) > width ? width : (rightPix + 1);
      _renderAaSegmentFast(
        row: row,
        pxS: pxS,
        pxEEx: pxE,
        xLTop: xLTop,
        xLBot: xLBot,
        xRTop: xRTop,
        xRBot: xRBot,
        yCenter: yCenter,
        eL: eL,
        eR: eR,
        useLutRefinement: useLutRefinement,
        insidePositiveL: insidePositiveL,
        insidePositiveR: insidePositiveR,
        srcA0: srcA0,
        srcR: srcR,
        srcG: srcG,
        srcB: srcB,
      );
    }
  }

  @pragma('vm:prefer-inline')
  int _evalF(int e, int x, int y) =>
      (_eA[e] * x) + (_eB[e] * y) + _eC[e].toInt();

  @pragma('vm:prefer-inline')
  int _edgeXAtY(int e, int yFixed) {
    final y0 = _eY0[e];
    final y1 = _eY1[e];
    final dy = y1 - y0;
    if (dy == 0) return _eX0[e];
    final dx = _eX1[e] - _eX0[e];
    return _eX0[e] + _divRound(dx * (yFixed - y0), dy);
  }

  @pragma('vm:prefer-inline')
  int _alphaAt(
    int e,
    int xC,
    int yC, {
    required bool insidePositive,
    required int softnessQ8,
  }) {
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

    if (softnessQ8 > 256) {
      dist16 = (dist16 * 256) ~/ softnessQ8;
    }

    final clampDist16 = lut.maxDist16;
    if (dist16 <= -clampDist16) return 0;
    if (dist16 >= clampDist16) return 255;
    return lut.alpha(_eDir[e], dist16);
  }

  @pragma('vm:prefer-inline')
  int _refineCoverageWithLut({
    required int baseCoverage,
    required int pxLeft,
    required int yCenter,
    required int leftEdge,
    required int rightEdge,
    required bool insidePositiveL,
    required bool insidePositiveR,
    required int lutMix,
    required int softnessQ8,
  }) {
    final xCenter = pxLeft + kHalf;
    final aL = _alphaAt(
      leftEdge,
      xCenter,
      yCenter,
      insidePositive: insidePositiveL,
      softnessQ8: softnessQ8,
    );
    final aR = _alphaAt(
      rightEdge,
      xCenter,
      yCenter,
      insidePositive: insidePositiveR,
      softnessQ8: softnessQ8,
    );
    final lutCoverage = aL < aR ? aL : aR;
    int cov =
        ((baseCoverage * (255 - lutMix)) + (lutCoverage * lutMix) + 127) ~/ 255;
    if (cov < 0) cov = 0;
    if (cov > 255) cov = 255;
    return cov;
  }

  @pragma('vm:prefer-inline')
  int _coverageAtPixel(
    int xLTop,
    int xLBot,
    int xRTop,
    int xRBot,
    int pxLeft,
    int yCenter,
    int eL,
    int eR,
    bool useLutRefinement,
    bool insidePositiveL,
    bool insidePositiveR,
  ) {
    final leftMin = xLTop < xLBot ? xLTop : xLBot;
    final rightMax = xRTop > xRBot ? xRTop : xRBot;
    final leftCenter = (xLTop + xLBot) >> 1;
    final rightCenter = (xRTop + xRBot) >> 1;

    // Invalid/inverted span at this row; reject to avoid horizontal streaks.
    if (rightMax <= leftMin) return 0;
    if (rightCenter <= leftCenter) return 0;

    // Hard guard against far leaks caused by near-horizontal micro-edges.
    // We only evaluate pixels near the center-row span neighborhood.
    final pxRight = pxLeft + kScale;
    if (pxRight <= leftCenter - kScale || pxLeft >= rightCenter + kScale) {
      return 0;
    }

    final covR = _integrateCovRight(xRTop - pxLeft, xRBot - pxLeft);
    final covL = _integrateCovRight(xLTop - pxLeft, xLBot - pxLeft);
    int cov = covR - covL;
    if (cov < 0) cov = 0;
    if (cov > 255) cov = 255;
    if (!useLutRefinement) return cov;

    if (useLutRefinement) {
      cov = _refineCoverageWithLut(
        baseCoverage: cov,
        pxLeft: pxLeft,
        yCenter: yCenter,
        leftEdge: eL,
        rightEdge: eR,
        insidePositiveL: insidePositiveL,
        insidePositiveR: insidePositiveR,
        lutMix: _qualityCfg.lutMix,
        softnessQ8: _qualityCfg.softnessQ8,
      );
    }
    return cov;
  }

  @pragma('vm:prefer-inline')
  void _renderAaSegmentFast({
    required int row,
    required int pxS,
    required int pxEEx,
    required int xLTop,
    required int xLBot,
    required int xRTop,
    required int xRBot,
    required int yCenter,
    required int eL,
    required int eR,
    required bool useLutRefinement,
    required bool insidePositiveL,
    required bool insidePositiveR,
    required int srcA0,
    required int srcR,
    required int srcG,
    required int srcB,
  }) {
    if (pxS >= pxEEx) return;
    final srcOpaque = (0xFF << 24) | (srcR << 16) | (srcG << 8) | srcB;
    for (int px = pxS; px < pxEEx; px++) {
      final pxLeft = px << 8;
      final cov = _coverageAtPixel(
        xLTop,
        xLBot,
        xRTop,
        xRBot,
        pxLeft,
        yCenter,
        eL,
        eR,
        useLutRefinement,
        insidePositiveL,
        insidePositiveR,
      );
      final effA = (cov * srcA0 + 127) ~/ 255;
      if (effA >= 255) {
        _pixels32[row + px] = srcOpaque;
      } else if (effA > 0) {
        final dst = _pixels32[row + px];
        _pixels32[row + px] = _blendOver(dst, srcR, srcG, srcB, effA);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _fillInteriorRange(
    int row,
    int x0,
    int x1,
    int srcA0,
    int srcR,
    int srcG,
    int srcB,
  ) {
    if (x0 >= x1) return;
    if (srcA0 >= 255) {
      _fillSolidSpan(
          row, x0, x1, (0xFF << 24) | (srcR << 16) | (srcG << 8) | srcB);
    } else if (srcA0 > 0) {
      _blendSolidSpan(row, x0, x1, srcR, srcG, srcB, srcA0);
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

    // Hot path: edge sweep entirely inside pixel [0, 256].
    // Coverage is the average x-position over the scanline in Q8.
    if (u0 >= 0 && u1 <= 256) {
      int cov = (u0 + u1) >> 1;
      if (cov < 0) cov = 0;
      if (cov > 255) cov = 255;
      return cov;
    }

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

  void _fillSolidSpan(int row, int x0, int x1, int argb) {
    int i = row + x0;
    final end = row + x1;
    final c = argb & 0xFFFFFFFF;
    if (!useSimdFill) {
      _pixels32.fillRange(i, end, c);
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

  void _blendSolidSpan(
      int row, int x0, int x1, int sr, int sg, int sb, int sa) {
    for (int i = row + x0; i < row + x1; i++) {
      _pixels32[i] = _blendOver(_pixels32[i], sr, sg, sb, sa);
    }
  }

  @pragma('vm:prefer-inline')
  static int _blendOver(int dst, int sr, int sg, int sb, int sa) {
    if (sa <= 0) return dst;
    if (sa >= 255) return (0xFF << 24) | (sr << 16) | (sg << 8) | sb;
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
