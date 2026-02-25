import 'package:test/test.dart';
import '../lib/src/blend2d/pipeline/bl_compop_kernel.dart';
import '../lib/src/blend2d/core/bl_types.dart';
import '../lib/src/blend2d/core/bl_image.dart';
import '../lib/src/blend2d/context/bl_context.dart';
import '../lib/src/blend2d/pixelops/bl_pixelops.dart';

void main() {
  group('BLPixelOps', () {
    test('udiv255 matches exact division for key values', () {
      expect(udiv255(0), 0);
      expect(udiv255(255), 1);
      expect(udiv255(255 * 255), 255);
      expect(udiv255(128 * 255), 128);
      // Verify rounding: 127 * 2 + 1 = 255 -> 1
      expect(udiv255(255), 1);
    });

    test('premultiply preserves opaque pixels', () {
      const opaque = 0xFFAABBCC;
      expect(premultiply(opaque), opaque);
    });

    test('premultiply zeroes transparent pixels', () {
      const transparent = 0x00AABBCC;
      expect(premultiply(transparent), 0);
    });

    test('premultiply halves channels at alpha=128', () {
      const argb = 0x80FF8040;
      final p = premultiply(argb);
      final pa = alphaOf(p);
      final pr = redOf(p);
      // Alpha should be ~128 (0x80)
      expect(pa, closeTo(0x80, 1));
      // Red 255 * 128/255 ≈ 128
      expect(pr, closeTo(128, 2));
    });

    test('unpremultiply is inverse of premultiply', () {
      const original = 0xCCAA6633;
      final p = premultiply(original);
      final u = unpremultiply(p);
      // Should be close to original (rounding errors possible)
      expect(alphaOf(u), alphaOf(original));
      expect(redOf(u), closeTo(redOf(original), 2));
      expect(greenOf(u), closeTo(greenOf(original), 2));
      expect(blueOf(u), closeTo(blueOf(original), 2));
    });

    test('swizzle ARGB to ABGR swaps R and B', () {
      const argb = 0xFFAABBCC;
      final abgr = swizzleArgbToAbgr(argb);
      expect(alphaOf(abgr), 0xFF);
      expect(redOf(abgr), 0xCC); // was blue
      expect(greenOf(abgr), 0xBB);
      expect(blueOf(abgr), 0xAA); // was red
    });

    test('packArgb round-trips with channel extraction', () {
      final packed = packArgb(0xAA, 0xBB, 0xCC, 0xDD);
      expect(alphaOf(packed), 0xAA);
      expect(redOf(packed), 0xBB);
      expect(greenOf(packed), 0xCC);
      expect(blueOf(packed), 0xDD);
    });
  });

  group('BLCompOpKernel', () {
    const white = 0xFFFFFFFF;
    const black = 0xFF000000;
    const red = 0xFFFF0000;
    const green = 0xFF00FF00;
    const blue = 0xFF0000FF;
    const transparent = 0x00000000;
    const halfAlphaRed = 0x80FF0000;

    test('srcCopy returns source unchanged', () {
      expect(BLCompOpKernel.compose(BLCompOp.srcCopy, white, red), red);
      expect(BLCompOpKernel.compose(BLCompOp.srcCopy, black, transparent),
          transparent);
    });

    test('srcOver opaque source replaces destination', () {
      expect(BLCompOpKernel.compose(BLCompOp.srcOver, white, red), red);
      expect(BLCompOpKernel.compose(BLCompOp.srcOver, black, blue), blue);
    });

    test('srcOver transparent source preserves destination', () {
      expect(
          BLCompOpKernel.compose(BLCompOp.srcOver, white, transparent), white);
    });

    test('clear always returns 0', () {
      expect(BLCompOpKernel.compose(BLCompOp.clear, white, red), 0);
      expect(BLCompOpKernel.compose(BLCompOp.clear, black, transparent), 0);
    });

    test('dstCopy always returns destination', () {
      expect(BLCompOpKernel.compose(BLCompOp.dstCopy, white, red), white);
      expect(BLCompOpKernel.compose(BLCompOp.dstCopy, black, blue), black);
    });

    test('dstOver is srcOver with args swapped (opaque dst unchanged)', () {
      // When dst is opaque, dstOver = dst (since Da=1, Sca*(1-Da) = 0)
      final r1 = BLCompOpKernel.compose(BLCompOp.dstOver, white, red);
      expect(r1, white);
    });

    test('plus saturates', () {
      final result = BLCompOpKernel.compose(BLCompOp.plus, white, red);
      expect(alphaOf(result), 255);
      expect(redOf(result), 255);
      expect(greenOf(result), 255);
      expect(blueOf(result), 255);
    });

    test('xor of opaque src over opaque dst = 0', () {
      // Sa.(1-Da) + Da.(1-Sa) = 1*0 + 1*0 = 0
      final result = BLCompOpKernel.compose(BLCompOp.xor_, white, red);
      expect(alphaOf(result), 0);
    });

    test('screen of black with anything = the other', () {
      // Screen: Sc + Dc - Sc*Dc. With Dc=0: result = Sc
      final result = BLCompOpKernel.compose(BLCompOp.screen, black, red);
      expect(redOf(result), closeTo(255, 2));
      expect(greenOf(result), closeTo(0, 2));
      expect(blueOf(result), closeTo(0, 2));
    });

    test('multiply of white with color = color', () {
      // Multiply: Dc*Sc. With Dc=1: result = Sc
      final result = BLCompOpKernel.compose(BLCompOp.multiply, white, red);
      expect(redOf(result), closeTo(255, 2));
      expect(greenOf(result), closeTo(0, 2));
    });

    test('difference of same color = black', () {
      final result = BLCompOpKernel.compose(BLCompOp.difference, red, red);
      expect(redOf(result), closeTo(0, 2));
      expect(greenOf(result), closeTo(0, 2));
      expect(blueOf(result), closeTo(0, 2));
    });

    test('all comp-ops produce valid pixels (no crash)', () {
      for (final op in BLCompOp.values) {
        final result = BLCompOpKernel.compose(op, halfAlphaRed, green);
        expect(alphaOf(result), inInclusiveRange(0, 255),
            reason: 'Op $op alpha out of range');
        expect(redOf(result), inInclusiveRange(0, 255),
            reason: 'Op $op red out of range');
        expect(greenOf(result), inInclusiveRange(0, 255),
            reason: 'Op $op green out of range');
        expect(blueOf(result), inInclusiveRange(0, 255),
            reason: 'Op $op blue out of range');
      }
    });
  });

  group('BLContext save/restore', () {
    test('save and restore preserves compOp', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      ctx.setCompOp(BLCompOp.multiply);
      ctx.save();
      ctx.setCompOp(BLCompOp.screen);
      expect(ctx.compOp, BLCompOp.screen);
      ctx.restore();
      expect(ctx.compOp, BLCompOp.multiply);
      await ctx.dispose();
    });

    test('save and restore preserves globalAlpha', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      ctx.setGlobalAlpha(0.5);
      ctx.save();
      ctx.setGlobalAlpha(0.1);
      ctx.restore();
      expect(ctx.globalAlpha, 0.5);
      await ctx.dispose();
    });

    test('restore on empty stack returns false', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      expect(ctx.restore(), false);
      await ctx.dispose();
    });

    test('savedCount tracks stack depth', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      expect(ctx.savedCount, 0);
      ctx.save();
      expect(ctx.savedCount, 1);
      ctx.save();
      expect(ctx.savedCount, 2);
      ctx.restore();
      expect(ctx.savedCount, 1);
      await ctx.dispose();
    });
  });

  group('BLContext clip', () {
    test('clipToRect intersects correctly', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.setClipRect(const BLRectI(10, 10, 40, 40));
      ctx.clipToRect(const BLRectI(20, 20, 40, 40));
      // Intersection should be (20,20,30,30)
      // (10..50) ∩ (20..60) = (20..50) → width=30, height=30
      expect(ctx.clipRect!.x, 20);
      expect(ctx.clipRect!.y, 20);
      expect(ctx.clipRect!.width, 30);
      expect(ctx.clipRect!.height, 30);
      await ctx.dispose();
    });
  });

  group('BLContext transform', () {
    test('identity transform does not modify points', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      expect(ctx.isTransformIdentity, true);
      final (x, y) = ctx.transformPoint(10.0, 20.0);
      expect(x, closeTo(10.0, 1e-10));
      expect(y, closeTo(20.0, 1e-10));
      await ctx.dispose();
    });

    test('translate shifts points', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      ctx.translate(5.0, 10.0);
      expect(ctx.isTransformIdentity, false);
      final (x, y) = ctx.transformPoint(0.0, 0.0);
      expect(x, closeTo(5.0, 1e-10));
      expect(y, closeTo(10.0, 1e-10));
      await ctx.dispose();
    });

    test('scale multiplies coordinates', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      ctx.scale(2.0, 3.0);
      final (x, y) = ctx.transformPoint(10.0, 10.0);
      expect(x, closeTo(20.0, 1e-10));
      expect(y, closeTo(30.0, 1e-10));
      await ctx.dispose();
    });

    test('resetTransform goes back to identity', () async {
      final image = BLImage(16, 16);
      final ctx = BLContext(image);
      ctx.translate(100, 200);
      ctx.resetTransform();
      expect(ctx.isTransformIdentity, true);
      await ctx.dispose();
    });
  });
}
