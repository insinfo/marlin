import '../core/bl_types.dart';
import 'dart:typed_data';

class BLPatternFetcher {
  static const int _fpShift = 8;
  static const int _fpOne = 1 << _fpShift;

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
  final bool _useBilinearRepeatRepeat;
  final bool _useBilinearPadPad;
  final int _offsetXi;
  final int _offsetYi;
  int _seqY = 0;
  int _seqNextX = 0;
  final int _dxFxFp;
  final int _dxFyFp;
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
        _useBilinearRepeatRepeat =
          pattern.filter == BLPatternFilter.bilinear &&
          pattern.extendModeX == BLGradientExtendMode.repeat &&
          pattern.extendModeY == BLGradientExtendMode.repeat,
        _useBilinearPadPad =
          pattern.filter == BLPatternFilter.bilinear &&
          pattern.extendModeX == BLGradientExtendMode.pad &&
          pattern.extendModeY == BLGradientExtendMode.pad,
        _dxFxFp = (pattern.transform.m00 * _fpOne).round(),
        _dxFyFp = (pattern.transform.m10 * _fpOne).round(),
        _offsetXi = pattern.offset.x.round(),
        _offsetYi = pattern.offset.y.round();

  @pragma('vm:prefer-inline')
  int fetch(int x, int y) {
    if (_filter == BLPatternFilter.nearest) {
      return _fetchNearest(x, y);
    }
    return _fetchBilinear(x, y);
  }

  @pragma('vm:prefer-inline')
  int _fetchNearest(int x, int y) {
    if (_useFastNearestInt) {
      final sx = _applyExtend(x - _offsetXi, _w, pattern.extendModeX);
      final sy = _applyExtend(y - _offsetYi, _h, pattern.extendModeY);
      if (sx < 0 || sy < 0) return 0;
      return _pixels[sy * _w + sx];
    }

    int ix;
    int iy;

    if (_isIdentity) {
      _seqFpValid = false;
      ix = (x - _offsetX).floor();
      iy = (y - _offsetY).floor();
    } else {
      int fxFp;
      int fyFp;
      if (_seqFpValid && y == _seqY && x == _seqNextX) {
        fxFp = _seqFxFp;
        fyFp = _seqFyFp;
      } else {
        fxFp = ((_m00 * x + _m01 * y + _m20 - _offsetX) * _fpOne).floor();
        fyFp = ((_m10 * x + _m11 * y + _m21 - _offsetY) * _fpOne).floor();
      }

      _seqFpValid = true;
      _seqY = y;
      _seqNextX = x + 1;
      _seqFxFp = fxFp + _dxFxFp;
      _seqFyFp = fyFp + _dxFyFp;

      ix = fxFp >> _fpShift;
      iy = fyFp >> _fpShift;
    }

    final sx = _applyExtend(ix, _w, pattern.extendModeX);
    final sy = _applyExtend(iy, _h, pattern.extendModeY);

    if (sx < 0 || sy < 0) return 0;
    return _pixels[sy * _w + sx];
  }

  @pragma('vm:prefer-inline')
  int _fetchBilinear(int x, int y) {
    if (_isIdentity) {
      _seqFpValid = false;
    }

    int x0;
    int y0;
    int ux;
    int uy;

    if (_isIdentity) {
      final fx = x - _offsetX;
      final fy = y - _offsetY;
      x0 = fx.floor();
      y0 = fy.floor();
      ux = ((fx - x0) * 256.0 + 0.5).toInt();
      uy = ((fy - y0) * 256.0 + 0.5).toInt();
      if (ux < 0) ux = 0;
      if (ux > 256) ux = 256;
      if (uy < 0) uy = 0;
      if (uy > 256) uy = 256;
      _seqFpValid = false;
    } else {
      int fxFp;
      int fyFp;
      if (_seqFpValid && y == _seqY && x == _seqNextX) {
        fxFp = _seqFxFp;
        fyFp = _seqFyFp;
      } else {
        fxFp = ((_m00 * x + _m01 * y + _m20 - _offsetX) * _fpOne).floor();
        fyFp = ((_m10 * x + _m11 * y + _m21 - _offsetY) * _fpOne).floor();
      }

      _seqFpValid = true;
      _seqY = y;
      _seqNextX = x + 1;
      _seqFxFp = fxFp + _dxFxFp;
      _seqFyFp = fyFp + _dxFyFp;

      x0 = fxFp >> _fpShift;
      y0 = fyFp >> _fpShift;
      ux = fxFp & (_fpOne - 1);
      uy = fyFp & (_fpOne - 1);
    }

    if (_useBilinearRepeatRepeat) {
      return _sampleBilinearRepeatRepeat(x0, y0, ux, uy);
    }
    if (_useBilinearPadPad) {
      return _sampleBilinearPadPad(x0, y0, ux, uy);
    }

    final sx0 = _applyExtend(x0, _w, pattern.extendModeX);
    final sy0 = _applyExtend(y0, _h, pattern.extendModeY);
    final sx1 = _applyExtend(x0 + 1, _w, pattern.extendModeX);
    final sy1 = _applyExtend(y0 + 1, _h, pattern.extendModeY);

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

  @pragma('vm:prefer-inline')
  int _sampleBilinearRepeatRepeat(int x0, int y0, int ux, int uy) {
    int sx0 = x0 % _w;
    if (sx0 < 0) sx0 += _w;
    int sy0 = y0 % _h;
    if (sy0 < 0) sy0 += _h;

    int sx1 = sx0 + 1;
    if (sx1 == _w) sx1 = 0;
    int sy1 = sy0 + 1;
    if (sy1 == _h) sy1 = 0;

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

  @pragma('vm:prefer-inline')
  int _sampleBilinearPadPad(int x0, int y0, int ux, int uy) {
    int sx0;
    int sx1;
    if (x0 <= 0) {
      sx0 = 0;
      sx1 = 0;
    } else {
      final maxX = _w - 1;
      if (x0 >= maxX) {
        sx0 = maxX;
        sx1 = maxX;
      } else {
        sx0 = x0;
        sx1 = x0 + 1;
      }
    }

    int sy0;
    int sy1;
    if (y0 <= 0) {
      sy0 = 0;
      sy1 = 0;
    } else {
      final maxY = _h - 1;
      if (y0 >= maxY) {
        sy0 = maxY;
        sy1 = maxY;
      } else {
        sy0 = y0;
        sy1 = y0 + 1;
      }
    }

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
