/// Port of Blend2D composition operators (compop_p.h / compopgeneric_p.h).
///
/// Full set of Porter-Duff and advanced blend modes, operating on ARGB32
/// pixels (0xAARRGGBB). Operations use premultiplied alpha internally where
/// mathematically required, matching the Blend2D reference pipeline.
///
/// Inspired by: `blend2d/core/compop_p.h`, `pipeline/reference/compopgeneric_p.h`

import '../core/bl_types.dart';
import '../pixelops/bl_pixelops.dart';

/// All composition operators supported by the port.
/// Aligned with BLCompOp enum from C++ Blend2D (context.h lines 244-290).
///
/// Porter-Duff:
///   srcOver, srcCopy, srcIn, srcOut, srcAtop,
///   dstOver, dstCopy, dstIn, dstOut, dstAtop,
///   xor, clear
///
/// Advanced (separable):
///   plus, minus, modulate, multiply, screen, overlay,
///   darken, lighten, colorDodge, colorBurn,
///   linearBurn, linearLight, pinLight,
///   hardLight, softLight, difference, exclusion
class BLCompOpKernel {
  const BLCompOpKernel._();

  // -------------------------------------------------------------------------
  // Dispatch
  // -------------------------------------------------------------------------

  static int compose(BLCompOp op, int dst, int src) {
    switch (op) {
      case BLCompOp.srcOver:
        return srcOver(dst, src);
      case BLCompOp.srcCopy:
        return src;
      case BLCompOp.srcIn:
        return _srcIn(dst, src);
      case BLCompOp.srcOut:
        return _srcOut(dst, src);
      case BLCompOp.srcAtop:
        return _srcAtop(dst, src);
      case BLCompOp.dstOver:
        return _dstOver(dst, src);
      case BLCompOp.dstCopy:
        return dst;
      case BLCompOp.dstIn:
        return _dstIn(dst, src);
      case BLCompOp.dstOut:
        return _dstOut(dst, src);
      case BLCompOp.dstAtop:
        return _dstAtop(dst, src);
      case BLCompOp.xor_:
        return _xor(dst, src);
      case BLCompOp.clear:
        return 0;
      case BLCompOp.plus:
        return _plus(dst, src);
      case BLCompOp.minus:
        return _minus(dst, src);
      case BLCompOp.modulate:
        return _modulate(dst, src);
      case BLCompOp.multiply:
        return _multiply(dst, src);
      case BLCompOp.screen:
        return _screen(dst, src);
      case BLCompOp.overlay:
        return _overlay(dst, src);
      case BLCompOp.darken:
        return _darken(dst, src);
      case BLCompOp.lighten:
        return _lighten(dst, src);
      case BLCompOp.colorDodge:
        return _colorDodge(dst, src);
      case BLCompOp.colorBurn:
        return _colorBurn(dst, src);
      case BLCompOp.linearBurn:
        return _linearBurn(dst, src);
      case BLCompOp.linearLight:
        return _linearLight(dst, src);
      case BLCompOp.pinLight:
        return _pinLight(dst, src);
      case BLCompOp.hardLight:
        return _hardLight(dst, src);
      case BLCompOp.softLight:
        return _softLight(dst, src);
      case BLCompOp.difference:
        return _difference(dst, src);
      case BLCompOp.exclusion:
        return _exclusion(dst, src);
    }
  }

  // -------------------------------------------------------------------------
  // srcOver — Dca' = Sca + Dca.(1 - Sa)
  // -------------------------------------------------------------------------

  static int srcOver(int dst, int src) {
    final srcA = (src >>> 24) & 0xFF;
    if (srcA == 0) return dst;
    if (srcA == 255) return src;

    final dstA = (dst >>> 24) & 0xFF;
    if (dstA == 0) return src;

    final dstR = (dst >>> 16) & 0xFF;
    final dstG = (dst >>> 8) & 0xFF;
    final dstB = dst & 0xFF;

    final srcR = (src >>> 16) & 0xFF;
    final srcG = (src >>> 8) & 0xFF;
    final srcB = src & 0xFF;

    final invA = 255 - srcA;

    // Fast-path: destino opaco (caso mais comum no bootstrap).
    if (dstA == 255) {
      final outR = udiv255(srcR * srcA + dstR * invA);
      final outG = udiv255(srcG * srcA + dstG * invA);
      final outB = udiv255(srcB * srcA + dstB * invA);
      return 0xFF000000 | (outR << 16) | (outG << 8) | outB;
    }

    // Caminho geral com alpha de destino.
    final outA = srcA + udiv255(dstA * invA);
    if (outA <= 0) return 0;

    final srcRp = udiv255(srcR * srcA);
    final srcGp = udiv255(srcG * srcA);
    final srcBp = udiv255(srcB * srcA);

    final dstRp = udiv255(dstR * dstA);
    final dstGp = udiv255(dstG * dstA);
    final dstBp = udiv255(dstB * dstA);

    final outRp = srcRp + udiv255(dstRp * invA);
    final outGp = srcGp + udiv255(dstGp * invA);
    final outBp = srcBp + udiv255(dstBp * invA);

    final outR = clamp255((outRp * 255 + (outA ~/ 2)) ~/ outA);
    final outG = clamp255((outGp * 255 + (outA ~/ 2)) ~/ outA);
    final outB = clamp255((outBp * 255 + (outA ~/ 2)) ~/ outA);
    final clampedA = outA > 255 ? 255 : outA;

    return (clampedA << 24) | (outR << 16) | (outG << 8) | outB;
  }

  // -------------------------------------------------------------------------
  // Porter-Duff operators
  // -------------------------------------------------------------------------

  /// SrcIn: Dca' = Sca.Da, Da' = Sa.Da
  static int _srcIn(int dst, int src) {
    final sa = alphaOf(src), da = alphaOf(dst);
    if (sa == 0 || da == 0) return 0;
    return _applyAlpha(src, da);
  }

  /// SrcOut: Dca' = Sca.(1-Da), Da' = Sa.(1-Da)
  static int _srcOut(int dst, int src) {
    final da = alphaOf(dst);
    return _applyAlpha(src, 255 - da);
  }

  /// SrcAtop: Dca' = Sca.Da + Dca.(1-Sa), Da' = Da
  static int _srcAtop(int dst, int src) {
    final sa = alphaOf(src), da = alphaOf(dst);
    final r = udiv255(redOf(src) * da + redOf(dst) * neg255(sa));
    final g = udiv255(greenOf(src) * da + greenOf(dst) * neg255(sa));
    final b = udiv255(blueOf(src) * da + blueOf(dst) * neg255(sa));
    return packArgb(da, clamp255(r), clamp255(g), clamp255(b));
  }

  /// DstOver: Dca' = Dca + Sca.(1-Da), Da' = Da + Sa.(1-Da)
  static int _dstOver(int dst, int src) => srcOver(src, dst);

  /// DstIn: Dca' = Dca.Sa, Da' = Da.Sa
  static int _dstIn(int dst, int src) {
    final sa = alphaOf(src);
    if (sa == 255) return dst;
    if (sa == 0) return 0;
    return _applyAlpha(dst, sa);
  }

  /// DstOut: Dca' = Dca.(1-Sa), Da' = Da.(1-Sa)
  static int _dstOut(int dst, int src) {
    final sa = alphaOf(src);
    return _applyAlpha(dst, 255 - sa);
  }

  /// DstAtop: Dca' = Dca.Sa + Sca.(1-Da), Da' = Sa
  static int _dstAtop(int dst, int src) {
    final sa = alphaOf(src), da = alphaOf(dst);
    final r = udiv255(redOf(dst) * sa + redOf(src) * neg255(da));
    final g = udiv255(greenOf(dst) * sa + greenOf(src) * neg255(da));
    final b = udiv255(blueOf(dst) * sa + blueOf(src) * neg255(da));
    return packArgb(sa, clamp255(r), clamp255(g), clamp255(b));
  }

  /// Xor: Dca' = Sca.(1-Da) + Dca.(1-Sa), Da' = Sa.(1-Da) + Da.(1-Sa)
  static int _xor(int dst, int src) {
    final sa = alphaOf(src), da = alphaOf(dst);
    final outA = udiv255(sa * neg255(da) + da * neg255(sa));
    final r = udiv255(redOf(src) * neg255(da) + redOf(dst) * neg255(sa));
    final g = udiv255(greenOf(src) * neg255(da) + greenOf(dst) * neg255(sa));
    final b = udiv255(blueOf(src) * neg255(da) + blueOf(dst) * neg255(sa));
    return packArgb(clamp255(outA), clamp255(r), clamp255(g), clamp255(b));
  }

  // -------------------------------------------------------------------------
  // Additive / subtractive
  // -------------------------------------------------------------------------

  /// Plus: Dca' = min(Sca + Dca, 1), Da' = min(Sa + Da, 1) — saturated add
  static int _plus(int dst, int src) {
    return packArgb(
      addus8(alphaOf(dst), alphaOf(src)),
      addus8(redOf(dst), redOf(src)),
      addus8(greenOf(dst), greenOf(src)),
      addus8(blueOf(dst), blueOf(src)),
    );
  }

  /// Minus: Dca' = max(Dca - Sca, 0), Da' = Da + Sa.(1-Da)
  static int _minus(int dst, int src) {
    final sa = alphaOf(src), da = alphaOf(dst);
    final outA = sa + udiv255(da * neg255(sa));
    final r = (redOf(dst) - redOf(src)).clamp(0, 255);
    final g = (greenOf(dst) - greenOf(src)).clamp(0, 255);
    final b = (blueOf(dst) - blueOf(src)).clamp(0, 255);
    return packArgb(clamp255(outA), r, g, b);
  }

  /// Modulate (Multiply without src-over backdrop): Dca' = Sca.Dca, Da' = Sa.Da
  static int _modulate(int dst, int src) {
    return packArgb(
      udiv255(alphaOf(src) * alphaOf(dst)),
      udiv255(redOf(src) * redOf(dst)),
      udiv255(greenOf(src) * greenOf(dst)),
      udiv255(blueOf(src) * blueOf(dst)),
    );
  }

  // -------------------------------------------------------------------------
  // Separable blend modes (Section 13.3 of PDF spec / SVG compositing)
  // All apply the generic formula:
  //   Dca' = B(Dca, Sca) + Sca.(1-Da) + Dca.(1-Sa)
  //   Da'  = Sa + Da - Sa.Da
  // where B(Dc, Sc) is the per-channel blend function.
  // -------------------------------------------------------------------------

  static int _blendSeparable(
      int dst, int src, int Function(int dc, int sc, int da, int sa) blendCh) {
    final sa = alphaOf(src), da = alphaOf(dst);
    if (sa == 0) return dst;
    final outA = sa + da - udiv255(sa * da);
    if (outA <= 0) return 0;

    // Premultiply channels for the blend formula
    final sr = redOf(src), sg = greenOf(src), sb = blueOf(src);
    final dr = redOf(dst), dg = greenOf(dst), db = blueOf(dst);

    final sra = udiv255(sr * sa),
        sga = udiv255(sg * sa),
        sba = udiv255(sb * sa);
    final dra = udiv255(dr * da),
        dga = udiv255(dg * da),
        dba = udiv255(db * da);

    // B(Dca, Sca) + Sca.(1 - Da) + Dca.(1 - Sa)
    int outR = blendCh(dra, sra, da, sa) +
        udiv255(sra * neg255(da)) +
        udiv255(dra * neg255(sa));
    int outG = blendCh(dga, sga, da, sa) +
        udiv255(sga * neg255(da)) +
        udiv255(dga * neg255(sa));
    int outB = blendCh(dba, sba, da, sa) +
        udiv255(sba * neg255(da)) +
        udiv255(dba * neg255(sa));

    // Un-premultiply result
    final ca = clamp255(outA);
    if (ca == 0) return 0;
    return packArgb(
      ca,
      clamp255((outR * 255 + (ca ~/ 2)) ~/ ca),
      clamp255((outG * 255 + (ca ~/ 2)) ~/ ca),
      clamp255((outB * 255 + (ca ~/ 2)) ~/ ca),
    );
  }

  /// Multiply: B(Dc,Sc) = Dc*Sc
  static int _multiply(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) => udiv255(dc * sc));

  /// Screen: B(Dc,Sc) = Dc + Sc - Dc*Sc
  static int _screen(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) => dc + sc - udiv255(dc * sc));

  /// Overlay: B(Dc,Sc) = HardLight with reversed args
  static int _overlay(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        // Overlay = HardLight(Dc, Sc) but conditioned on Dc
        if (2 * dc <= da) {
          return udiv255(2 * dc * sc);
        } else {
          return da * sa ~/ 255 - udiv255(2 * (da - dc) * (sa - sc));
        }
      });

  /// Darken: B(Dc,Sc) = min(Dc*Sa, Sc*Da)
  static int _darken(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        final a = udiv255(dc * sa);
        final b = udiv255(sc * da);
        return a < b ? a : b;
      });

  /// Lighten: B(Dc,Sc) = max(Dc*Sa, Sc*Da)
  static int _lighten(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        final a = udiv255(dc * sa);
        final b = udiv255(sc * da);
        return a > b ? a : b;
      });

  /// ColorDodge
  static int _colorDodge(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        if (dc == 0) return 0;
        if (sc >= sa) return udiv255(da * sa);
        return clamp255((dc * sa * 255) ~/ ((sa - sc) * 255 + 1));
      });

  /// ColorBurn
  static int _colorBurn(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        if (dc >= da) return udiv255(da * sa);
        if (sc == 0) return 0;
        final val = udiv255(da * sa) -
            clamp255(((da - dc) * sa * 255) ~/ (sc * 255 + 1));
        return val < 0 ? 0 : val;
      });

  /// LinearBurn: B(Dc,Sc) = max(Dc + Sc - Da*Sa, 0)
  static int _linearBurn(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        final val = dc + sc - udiv255(da * sa);
        return val < 0 ? 0 : val;
      });

  /// LinearLight: combination of LinearDodge and LinearBurn
  static int _linearLight(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        final val = dc + 2 * sc - udiv255(sa * da);
        return clamp255(val);
      });

  /// PinLight: combination of Darken and Lighten
  static int _pinLight(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        if (2 * sc <= sa) {
          // Darken variant
          final dsa = udiv255(dc * sa);
          final sda = 2 * sc;
          return dsa < sda ? dsa : sda;
        } else {
          // Lighten variant
          final dsa = udiv255(dc * sa);
          final sda = 2 * sc - sa;
          return dsa > sda ? dsa : sda;
        }
      });

  /// HardLight: B(Dc,Sc) = Overlay with Sc/Dc swapped
  static int _hardLight(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        if (2 * sc <= sa) {
          return udiv255(2 * dc * sc);
        } else {
          return udiv255(da * sa) - udiv255(2 * (da - dc) * (sa - sc));
        }
      });

  /// SoftLight (W3C formula)
  static int _softLight(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        if (da == 0) return 0;
        final m = (dc * 255) ~/ da; // Dc/Da * 255
        if (2 * sc <= sa) {
          // Dc * (Sa - (2*Sc - Sa) * (255 - m)) / 255
          final t =
              udiv255(dc * (sa - udiv255((2 * sc - sa).abs() * (255 - m))));
          return t;
        } else {
          // Dc * Sa + (sqrt(Dc/Da) * Da - Dc) * (2*Sc - Sa)
          final dOverDa = dc / (da == 0 ? 1 : da);
          final sqrtD = (dOverDa.clamp(0.0, 1.0));
          final sqrtVal =
              (sqrtD <= 0) ? 0.0 : (sqrtD >= 1.0 ? 1.0 : _sqrt(sqrtD));
          final g = (sqrtVal * da).toInt();
          final val = udiv255(dc * sa) + udiv255((g - dc) * (2 * sc - sa));
          return clamp255(val);
        }
      });

  /// Difference: B(Dc,Sc) = |Dc*Sa - Sc*Da|
  static int _difference(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        final a = udiv255(dc * sa);
        final b = udiv255(sc * da);
        return (a - b).abs();
      });

  /// Exclusion: B(Dc,Sc) = Dc + Sc - 2*Dc*Sc
  static int _exclusion(int dst, int src) =>
      _blendSeparable(dst, src, (dc, sc, da, sa) {
        return dc + sc - 2 * udiv255(dc * sc);
      });

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Scale all channels of [px] by [alpha] / 255.
  static int _applyAlpha(int px, int alpha) {
    if (alpha == 255) return px;
    if (alpha == 0) return 0;
    final a = udiv255(alphaOf(px) * alpha);
    final r = udiv255(redOf(px) * alpha);
    final g = udiv255(greenOf(px) * alpha);
    final b = udiv255(blueOf(px) * alpha);
    return packArgb(a, r, g, b);
  }

  /// Fast sqrt for [0..1] range.
  static double _sqrt(double x) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    // Newton's method with 3 iterations for decent precision
    double r = x;
    r = 0.5 * (r + x / r);
    r = 0.5 * (r + x / r);
    r = 0.5 * (r + x / r);
    return r;
  }
}
