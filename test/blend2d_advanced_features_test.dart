import 'package:test/test.dart';
import '../lib/src/blend2d/context/bl_context.dart';
import '../lib/src/blend2d/core/bl_image.dart';
import '../lib/src/blend2d/core/bl_types.dart';
import '../lib/src/blend2d/geometry/bl_dasher.dart';
import '../lib/src/blend2d/geometry/bl_path.dart';

/// Count non-background pixels.
int _countDrawn(BLImage image, {int background = 0xFFFFFFFF}) {
  int count = 0;
  for (int i = 0; i < image.pixels.length; i++) {
    if (image.pixels[i] != background) count++;
  }
  return count;
}

void main() {
  // =========================================================================
  // Dasher tests
  // =========================================================================
  group('BLDasher', () {
    test('dashPath with [10, 5] produces gaps', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 0);

      final dashed = BLDasher.dashPath(path, [10, 5]);
      final data = dashed.toPathData();

      // Should have multiple contours (dashes)
      expect(data.contourVertexCounts, isNotNull);
      expect(data.contourVertexCounts!.length, greaterThan(1));
    });

    test('dashPath with empty dashArray returns original path', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(50, 0);

      final dashed = BLDasher.dashPath(path, []);
      // Should be the same path object
      expect(identical(dashed, path), isTrue);
    });

    test('dashPath with offset shifts pattern', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 0);

      final d1 = BLDasher.dashPath(path, [10, 10]);
      final d2 = BLDasher.dashPath(path, [10, 10], dashOffset: 5);

      final v1 = d1.toPathData().vertices;
      final v2 = d2.toPathData().vertices;

      // Different offsets should produce different vertex data
      expect(v1.length == v2.length && v1[0] == v2[0], isFalse);
    });

    test('diagonal line dashes correctly', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(70.71, 70.71); // ~100 units diagonal

      final dashed = BLDasher.dashPath(path, [20, 10]);
      final data = dashed.toPathData();
      expect(data.vertices.length, greaterThan(4));
    });
  });

  // =========================================================================
  // fillCircle / strokeCircle tests
  // =========================================================================
  group('BLContext - Circle/Ellipse', () {
    test('fillCircle fills a circular area', () async {
      final image = BLImage(128, 128);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      await ctx.fillCircle(64, 64, 30, color: 0xFFFF0000);

      final drawn = _countDrawn(image);
      // Area of circle r=30 ≈ π*30² ≈ 2827 pixels
      expect(drawn, greaterThan(2500));
      expect(drawn, lessThan(3200));

      // Center should be drawn
      expect(image.pixels[64 * 128 + 64] != 0xFFFFFFFF, isTrue);
      // Far corner should not
      expect(image.pixels[5 * 128 + 5], 0xFFFFFFFF);

      await ctx.dispose();
    });

    test('strokeCircle produces ring', () async {
      final image = BLImage(128, 128);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      await ctx.strokeCircle(64, 64, 40,
          color: 0xFF0000FF, options: const BLStrokeOptions(width: 4.0));

      final drawn = _countDrawn(image);
      // ring ≈ π*84*4 - π*76*4 → should be a moderate number of pixels
      expect(drawn, greaterThan(200));
      // Center should be background (hollow)
      expect(image.pixels[64 * 128 + 64], 0xFFFFFFFF);

      await ctx.dispose();
    });

    test('fillEllipse fills an elliptical area', () async {
      final image = BLImage(128, 128);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      await ctx.fillEllipse(64, 64, 50, 20, color: 0xFF00FF00);

      final drawn = _countDrawn(image);
      // Area ≈ π*50*20 ≈ 3142 pixels
      expect(drawn, greaterThan(2500));
      expect(drawn, lessThan(4000));

      await ctx.dispose();
    });
  });

  // =========================================================================
  // globalAlpha integration
  // =========================================================================
  group('BLContext - globalAlpha integration', () {
    test('globalAlpha < 1 reduces opacity on render', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);
      ctx.setGlobalAlpha(0.5);

      await ctx.fillPolygon(
        [0, 0, 31, 0, 31, 31, 0, 31],
        color: 0xFFFF0000,
      );

      // srcOver of 0x80FF0000 over white:
      // alpha stays 0xFF (opaque bg), but G and B channels
      // should reflect the blend (white + semi-red → pinkish).
      final pixel = image.pixels[16 * 32 + 16];
      final a = (pixel >> 24) & 0xFF;
      final r = (pixel >> 16) & 0xFF;
      final g = (pixel >> 8) & 0xFF;
      final b = pixel & 0xFF;
      expect(a, 0xFF); // stays opaque because srcOver on opaque bg
      expect(r, greaterThan(g)); // red > green (it's reddish)
      // G and B should be > 0 (white bleed-through)
      expect(g, greaterThan(0));
      expect(b, greaterThan(0));

      await ctx.dispose();
    });
  });

  // =========================================================================
  // clipRect integration
  // =========================================================================
  group('BLContext - clipRect integration', () {
    test('clipRect rejects polygons outside region', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);
      ctx.setClipRect(const BLRectI(10, 10, 20, 20));

      // Polygon entirely outside clip (above)
      await ctx.fillPolygon(
        [0, 0, 5, 0, 5, 5, 0, 5],
        color: 0xFF0000FF,
      );

      // Nothing should be drawn (polygon is fully outside clip bbox)
      expect(_countDrawn(image), 0);

      await ctx.dispose();
    });

    test('degenerate clip blocks all drawing', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);
      ctx.setClipRect(const BLRectI(0, 0, 0, 0)); // degenerate

      await ctx.fillPolygon(
        [0, 0, 31, 0, 31, 31, 0, 31],
        color: 0xFF000000,
      );

      // Nothing should be drawn
      expect(_countDrawn(image), 0);

      await ctx.dispose();
    });
  });

  // =========================================================================
  // drawImage tests
  // =========================================================================
  group('BLContext - drawImage', () {
    test('drawImage composites source on destination', () {
      final dst = BLImage(64, 64);
      final ctx = BLContext(dst);
      ctx.clear(0xFFFFFFFF);

      // Create a small red source image
      final src = BLImage(10, 10);
      src.clear(0xFFFF0000);

      ctx.drawImage(src, dx: 20, dy: 20);

      // Pixel at (25, 25) should be red
      expect(dst.pixels[25 * 64 + 25], 0xFFFF0000);
      // Pixel at (5, 5) should be white
      expect(dst.pixels[5 * 64 + 5], 0xFFFFFFFF);
    });

    test('drawImage respects clipRect', () {
      final dst = BLImage(64, 64);
      final ctx = BLContext(dst);
      ctx.clear(0xFFFFFFFF);
      ctx.setClipRect(const BLRectI(25, 25, 10, 10));

      final src = BLImage(20, 20);
      src.clear(0xFF00FF00);

      ctx.drawImage(src, dx: 20, dy: 20);

      // (22, 22) is outside clip → should be white
      expect(dst.pixels[22 * 64 + 22], 0xFFFFFFFF);
      // (27, 27) is inside clip → should be green
      expect(dst.pixels[27 * 64 + 27], 0xFF00FF00);
    });
  });

  // =========================================================================
  // strokeDashedPath tests
  // =========================================================================
  group('BLContext - strokeDashedPath', () {
    test('strokeDashedPath produces dashed line', () async {
      final image = BLImage(128, 128);
      final ctx = BLContext(image);
      ctx.clear(0xFFFFFFFF);

      final path = BLPath();
      path.moveTo(10, 64);
      path.lineTo(118, 64);

      await ctx.strokeDashedPath(
        path,
        dashArray: [10, 5],
        color: 0xFF000000,
        options: const BLStrokeOptions(width: 2.0),
      );

      final drawn = _countDrawn(image);
      // Dashed line should have some pixels
      expect(drawn, greaterThan(50));
      // But fewer than a solid line would have (~108 * 2 = ~216)
      expect(drawn, lessThan(300));

      await ctx.dispose();
    });
  });
}
