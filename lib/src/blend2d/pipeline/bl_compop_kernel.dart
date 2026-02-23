import '../core/bl_types.dart';

/// Kernels escalares basicos de composicao (bootstrap do port).
class BLCompOpKernel {
  const BLCompOpKernel._();

  static int compose(BLCompOp op, int dst, int src) {
    switch (op) {
      case BLCompOp.srcCopy:
        return src;
      case BLCompOp.srcOver:
        return srcOver(dst, src);
    }
  }

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

    // Fast-path mais comum no bootstrap atual: destino opaco.
    if (dstA == 255) {
      final outR = (srcR * srcA + dstR * invA + 127) ~/ 255;
      final outG = (srcG * srcA + dstG * invA + 127) ~/ 255;
      final outB = (srcB * srcA + dstB * invA + 127) ~/ 255;
      return 0xFF000000 | (outR << 16) | (outG << 8) | outB;
    }

    // Caminho geral com alpha de destino.
    final outA = srcA + ((dstA * invA + 127) ~/ 255);
    if (outA <= 0) return 0;

    final srcRp = (srcR * srcA + 127) ~/ 255;
    final srcGp = (srcG * srcA + 127) ~/ 255;
    final srcBp = (srcB * srcA + 127) ~/ 255;

    final dstRp = (dstR * dstA + 127) ~/ 255;
    final dstGp = (dstG * dstA + 127) ~/ 255;
    final dstBp = (dstB * dstA + 127) ~/ 255;

    final outRp = srcRp + ((dstRp * invA + 127) ~/ 255);
    final outGp = srcGp + ((dstGp * invA + 127) ~/ 255);
    final outBp = srcBp + ((dstBp * invA + 127) ~/ 255);

    final outR = ((outRp * 255) + (outA ~/ 2)) ~/ outA;
    final outG = ((outGp * 255) + (outA ~/ 2)) ~/ outA;
    final outB = ((outBp * 255) + (outA ~/ 2)) ~/ outA;

    final clampedR = outR < 0 ? 0 : (outR > 255 ? 255 : outR);
    final clampedG = outG < 0 ? 0 : (outG > 255 ? 255 : outG);
    final clampedB = outB < 0 ? 0 : (outB > 255 ? 255 : outB);
    final clampedA = outA > 255 ? 255 : outA;

    return (clampedA << 24) | (clampedR << 16) | (clampedG << 8) | clampedB;
  }
}

