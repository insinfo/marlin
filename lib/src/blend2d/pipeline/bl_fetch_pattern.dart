import '../core/bl_types.dart';
import 'dart:typed_data';

class BLPatternFetcher {
  static const int _fpShift = 8;
  static const int _fpOne = 1 << _fpShift;
  static const int _fpMask = _fpOne - 1;

  final BLPattern pattern;
  final int _w;
  final int _h;
  final Uint32List _pixels;
  final double _offsetX;
  final double _offsetY;
  final double _m00;
  final double _m01;
  final double _m10;
  final double _m11;
  final double _m20;
  final double _m21;
  final BLPatternFilter _filter;
  final bool _isIdentity;
  final bool _useFastNearestInt;
  final int _offsetXi;
  final int _offsetYi;

  // Per-pixel step in fixed-point 24.8
  final int _dxFxFp;
  final int _dxFyFp;

  // --- C++ affine context parameters (ox/oy/rx/ry/corx/cory port) ---
  final BLGradientExtendMode _extX;
  final BLGradientExtendMode _extY;
  /// Tile period X in fp: 0 for pad, w*fpOne for repeat, 2*w*fpOne for reflect.
  final int _periodXFp;
  /// Tile period Y in fp.
  final int _periodYFp;
  /// True when |dxFxFp| < periodXFp (branchless single-subtraction per pixel).
  final bool _canFastAdvX;
  /// True when |dxFyFp| < periodYFp.
  final bool _canFastAdvY;

  // Sequential tracking state
  int _seqY = 0;
  int _seqNextX = 0;
  int _seqFxFp = 0;
  int _seqFyFp = 0;
  bool _seqFpValid = false;

  BLPatternFetcher(this.pattern)
      : _w = pattern.image.width,
        _h = pattern.image.height,
        _pixels = pattern.image.pixels,
        _offsetX = pattern.offset.x,
        _offsetY = pattern.offset.y,
        _m00 = pattern.transform.m00,
        _m01 = pattern.transform.m01,
        _m10 = pattern.transform.m10,
        _m11 = pattern.transform.m11,
        _m20 = pattern.transform.m20,
        _m21 = pattern.transform.m21,
        _filter = pattern.filter,
        _extX = pattern.extendModeX,
        _extY = pattern.extendModeY,
        _isIdentity =
            pattern.transform.m00 == 1.0 &&
            pattern.transform.m01 == 0.0 &&
            pattern.transform.m10 == 0.0 &&
            pattern.transform.m11 == 1.0 &&
            pattern.transform.m20 == 0.0 &&
            pattern.transform.m21 == 0.0,
        _useFastNearestInt =
            pattern.filter == BLPatternFilter.nearest &&
            pattern.transform.m00 == 1.0 &&
            pattern.transform.m01 == 0.0 &&
            pattern.transform.m10 == 0.0 &&
            pattern.transform.m11 == 1.0 &&
            pattern.transform.m20 == 0.0 &&
            pattern.transform.m21 == 0.0 &&
            pattern.offset.x == pattern.offset.x.roundToDouble() &&
            pattern.offset.y == pattern.offset.y.roundToDouble(),
        _dxFxFp = (pattern.transform.m00 * _fpOne).round(),
        _dxFyFp = (pattern.transform.m10 * _fpOne).round(),
        _offsetXi = pattern.offset.x.round(),
        _offsetYi = pattern.offset.y.round(),
        _periodXFp =
            _computePeriodFp(pattern.image.width, pattern.extendModeX),
        _periodYFp =
            _computePeriodFp(pattern.image.height, pattern.extendModeY),
        _canFastAdvX = _checkFastAdv(
            (pattern.transform.m00 * _fpOne).round(),
            _computePeriodFp(pattern.image.width, pattern.extendModeX)),
        _canFastAdvY = _checkFastAdv(
            (pattern.transform.m10 * _fpOne).round(),
            _computePeriodFp(pattern.image.height, pattern.extendModeY));

  /// Tile period in fixed-point: 0 for pad, w*fpOne for repeat, 2*w*fpOne for reflect.
  static int _computePeriodFp(int size, BLGradientExtendMode mode) {
    if (mode == BLGradientExtendMode.pad) return 0;
    final base = size * _fpOne;
    return mode == BLGradientExtendMode.reflect ? base * 2 : base;
  }

  /// True when |step| < period (branchless single-subtraction is sufficient).
  static bool _checkFastAdv(int stepFp, int periodFp) {
    if (periodFp <= 0) return false;
    final abs = stepFp < 0 ? -stepFp : stepFp;
    return abs < periodFp;
  }

  @pragma('vm:prefer-inline')
  int fetch(int x, int y) {
    if (_filter == BLPatternFilter.nearest) {
      return _fetchNearest(x, y);
    }
    return _fetchBilinear(x, y);
  }

  @pragma('vm:prefer-inline')
  int _fetchNearest(int x, int y) {
    // Fast path: identity transform + integer offsets
    if (_useFastNearestInt) {
      final sx = _applyExtend(x - _offsetXi, _w, _extX);
      final sy = _applyExtend(y - _offsetYi, _h, _extY);
      if (sx < 0 || sy < 0) return 0;
      return _pixels[sy * _w + sx];
    }

    // Identity transform (non-integer offsets)
    if (_isIdentity) {
      _seqFpValid = false;
      final ix = (x - _offsetX).floor();
      final iy = (y - _offsetY).floor();
      final sx = _applyExtend(ix, _w, _extX);
      final sy = _applyExtend(iy, _h, _extY);
      if (sx < 0 || sy < 0) return 0;
      return _pixels[sy * _w + sx];
    }

    // Affine transform with C++ affine context optimization:
    // Normalize at span start (full modulo), then per-pixel branchless
    // overflow check replaces modulo (port of ox/oy/rx/ry from C++).
    int fxFp;
    int fyFp;
    if (_seqFpValid && y == _seqY && x == _seqNextX) {
      fxFp = _seqFxFp;
      fyFp = _seqFyFp;
    } else {
      // Span start: compute from transform + normalize
      fxFp = ((_m00 * x + _m01 * y + _m20 - _offsetX) * _fpOne).floor();
      fyFp = ((_m10 * x + _m11 * y + _m21 - _offsetY) * _fpOne).floor();
      if (_periodXFp > 0) fxFp = _normFp(fxFp, _periodXFp);
      if (_periodYFp > 0) fyFp = _normFp(fyFp, _periodYFp);
    }

    // Advance sequential state with branchless overflow check
    _advanceSeq(x, y, fxFp, fyFp);

    // Get pixel index from (possibly normalized) coordinate
    final ix = fxFp >> _fpShift;
    final iy = fyFp >> _fpShift;
    final sx = _periodXFp > 0 ? _indexFromNorm(ix, _w, _extX) : _applyExtend(ix, _w, _extX);
    final sy = _periodYFp > 0 ? _indexFromNorm(iy, _h, _extY) : _applyExtend(iy, _h, _extY);
    if (sx < 0 || sy < 0) return 0;
    return _pixels[sy * _w + sx];
  }

  @pragma('vm:prefer-inline')
  int _fetchBilinear(int x, int y) {
    // Identity transform: compute directly
    if (_isIdentity) {
      _seqFpValid = false;
      final fx = x - _offsetX;
      final fy = y - _offsetY;
      final x0 = fx.floor();
      final y0 = fy.floor();
      int ux = ((fx - x0) * 256.0 + 0.5).toInt();
      int uy = ((fy - y0) * 256.0 + 0.5).toInt();
      if (ux < 0) ux = 0;
      if (ux > 256) ux = 256;
      if (uy < 0) uy = 0;
      if (uy > 256) uy = 256;
      return _sampleBilinear4(x0, y0, ux, uy);
    }

    // Affine transform with C++ affine context optimization
    int fxFp;
    int fyFp;
    if (_seqFpValid && y == _seqY && x == _seqNextX) {
      fxFp = _seqFxFp;
      fyFp = _seqFyFp;
    } else {
      fxFp = ((_m00 * x + _m01 * y + _m20 - _offsetX) * _fpOne).floor();
      fyFp = ((_m10 * x + _m11 * y + _m21 - _offsetY) * _fpOne).floor();
      if (_periodXFp > 0) fxFp = _normFp(fxFp, _periodXFp);
      if (_periodYFp > 0) fyFp = _normFp(fyFp, _periodYFp);
    }

    _advanceSeq(x, y, fxFp, fyFp);

    final x0 = fxFp >> _fpShift;
    final y0 = fyFp >> _fpShift;
    final ux = fxFp & _fpMask;
    final uy = fyFp & _fpMask;

    return _sampleBilinear4(x0, y0, ux, uy);
  }

  // ---------- Sequential advance (C++ advance_x port) ----------

  @pragma('vm:prefer-inline')
  void _advanceSeq(int x, int y, int fxFp, int fyFp) {
    int nextFx = fxFp + _dxFxFp;
    int nextFy = fyFp + _dxFyFp;
    if (_periodXFp > 0) {
      if (_canFastAdvX) {
        // Branchless: single subtraction replaces modulo (C++ ox/rx trick)
        if (nextFx >= _periodXFp) nextFx -= _periodXFp;
        if (nextFx < 0) nextFx += _periodXFp;
      } else {
        nextFx = _normFp(nextFx, _periodXFp);
      }
    }
    if (_periodYFp > 0) {
      if (_canFastAdvY) {
        if (nextFy >= _periodYFp) nextFy -= _periodYFp;
        if (nextFy < 0) nextFy += _periodYFp;
      } else {
        nextFy = _normFp(nextFy, _periodYFp);
      }
    }
    _seqFpValid = true;
    _seqY = y;
    _seqNextX = x + 1;
    _seqFxFp = nextFx;
    _seqFyFp = nextFy;
  }

  // ---------- Bilinear 4-sample (unified) ----------

  @pragma('vm:prefer-inline')
  int _sampleBilinear4(int x0, int y0, int ux, int uy) {
    int sx0, sx1, sy0, sy1;
    if (_periodXFp > 0) {
      sx0 = _indexFromNorm(x0, _w, _extX);
      sx1 = _indexFromNorm(x0 + 1, _w, _extX);
    } else {
      sx0 = _applyExtend(x0, _w, _extX);
      sx1 = _applyExtend(x0 + 1, _w, _extX);
    }
    if (_periodYFp > 0) {
      sy0 = _indexFromNorm(y0, _h, _extY);
      sy1 = _indexFromNorm(y0 + 1, _h, _extY);
    } else {
      sy0 = _applyExtend(y0, _h, _extY);
      sy1 = _applyExtend(y0 + 1, _h, _extY);
    }
    if (sx0 < 0 || sy0 < 0 || sx1 < 0 || sy1 < 0) return 0;

    final p00 = _pixels[sy0 * _w + sx0];
    final p10 = _pixels[sy0 * _w + sx1];
    final p01 = _pixels[sy1 * _w + sx0];
    final p11 = _pixels[sy1 * _w + sx1];

    final w00 = (256 - ux) * (256 - uy);
    final w10 = ux * (256 - uy);
    final w01 = (256 - ux) * uy;
    final w11 = ux * uy;
    return _blend4(p00, p10, p01, p11, w00, w10, w01, w11);
  }

  // ---------- Normalization helpers (C++ normalize_px_py port) ----------

  /// Normalize fixed-point coordinate to [0, period) using full modulo.
  /// Called at span start; per-pixel advance uses branchless subtraction.
  @pragma('vm:prefer-inline')
  static int _normFp(int v, int period) {
    v = v % period;
    if (v < 0) v += period;
    return v;
  }

  /// Get pixel index from normalized coordinate (no modulo needed).
  /// For repeat: v is in [0, size), bilinear neighbor v+1 may equal size.
  /// For reflect: v is in [0, 2*size), XOR-style fold for mirroring.
  /// For pad: v may be any value, clamp to [0, size-1].
  @pragma('vm:prefer-inline')
  static int _indexFromNorm(int v, int size, BLGradientExtendMode mode) {
    switch (mode) {
      case BLGradientExtendMode.pad:
        if (v < 0) return 0;
        if (v >= size) return size - 1;
        return v;
      case BLGradientExtendMode.repeat:
        v %= size;
        if (v < 0) v += size;
        return v;
      case BLGradientExtendMode.reflect:
        final period = size * 2;
        v %= period;
        if (v < 0) v += period;
        if (v >= size) return period - 1 - v;
        return v;
    }
  }

  @pragma('vm:prefer-inline')
  static int _blend4(
    int p00,
    int p10,
    int p01,
    int p11,
    int w00,
    int w10,
    int w01,
    int w11,
  ) {
    final a = (((p00 >>> 24) & 0xFF) * w00 +
            ((p10 >>> 24) & 0xFF) * w10 +
            ((p01 >>> 24) & 0xFF) * w01 +
            ((p11 >>> 24) & 0xFF) * w11)
        >> 16;

    final r = (((p00 >>> 16) & 0xFF) * w00 +
            ((p10 >>> 16) & 0xFF) * w10 +
            ((p01 >>> 16) & 0xFF) * w01 +
            ((p11 >>> 16) & 0xFF) * w11)
        >> 16;

    final g = (((p00 >>> 8) & 0xFF) * w00 +
            ((p10 >>> 8) & 0xFF) * w10 +
            ((p01 >>> 8) & 0xFF) * w01 +
            ((p11 >>> 8) & 0xFF) * w11)
        >> 16;

    final b = (((p00) & 0xFF) * w00 +
            ((p10) & 0xFF) * w10 +
            ((p01) & 0xFF) * w01 +
            ((p11) & 0xFF) * w11)
        >> 16;

    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  @pragma('vm:prefer-inline')
  static int _applyExtend(int v, int size, BLGradientExtendMode mode) {
    if (size <= 0) return -1;

    switch (mode) {
      case BLGradientExtendMode.pad:
        if (v < 0) return 0;
        if (v >= size) return size - 1;
        return v;

      case BLGradientExtendMode.repeat:
        int r = v % size;
        if (r < 0) r += size;
        return r;

      case BLGradientExtendMode.reflect:
        if (size == 1) return 0;
        final period = size * 2;
        int r = v % period;
        if (r < 0) r += period;
        return r < size ? r : (period - 1 - r);
    }
  }
}
