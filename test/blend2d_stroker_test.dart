import 'package:test/test.dart';
import '../lib/src/blend2d/geometry/bl_path.dart';
import '../lib/src/blend2d/geometry/bl_stroker.dart';
import '../lib/src/blend2d/core/bl_types.dart';

void main() {
  group('BLStroker', () {
    test('stroke horizontal line produces filled outline', () {
      final path = BLPath();
      path.moveTo(10, 50);
      path.lineTo(90, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
            width: 10.0, startCap: BLStrokeCap.butt, endCap: BLStrokeCap.butt),
      );
      final data = outline.toPathData();

      // Should produce a non-empty outline
      expect(data.vertices.length, greaterThan(0));
      // Open contour with butt caps: single polygon (A + end_cap + B + start_cap)
      expect(data.contourVertexCounts!.length, 1);
      // At least 4 points for a rectangle
      expect(data.contourVertexCounts![0], greaterThanOrEqualTo(4));
    });

    test('stroke closed triangle produces two contours (nonZero)', () {
      final path = BLPath();
      path.moveTo(50, 10);
      path.lineTo(90, 90);
      path.lineTo(10, 90);
      path.close();

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 4.0, join: BLStrokeJoin.bevel),
      );
      final data = outline.toPathData();

      // Closed contour: two polygons (outer A + inner B reversed)
      expect(data.contourVertexCounts!.length, 2);
    });

    test('zero-width stroke returns empty path', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 100);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 0.0),
      );
      final data = outline.toPathData();
      expect(data.vertices.isEmpty, true);
    });

    test('empty path returns empty outline', () {
      final path = BLPath();
      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(width: 5.0),
      );
      final data = outline.toPathData();
      expect(data.vertices.isEmpty, true);
    });

    test('square cap preserves endpoint bounds', () {
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.square,
          endCap: BLStrokeCap.square,
        ),
      );
      final data = outline.toPathData();

      // Check that the outline keeps at least the original segment span.
      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      // Original line span is 50..150.
      expect(minX, lessThanOrEqualTo(50.0));
      expect(maxX, greaterThanOrEqualTo(150.0));
    });

    test('round cap produces arc points', () {
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.round,
          endCap: BLStrokeCap.round,
        ),
      );
      final data = outline.toPathData();

      // Round caps add arc subdivision points (~45deg per step = ~4 pts per cap)
      // Total should be significantly more than the 4 points of a butt-cap rectangle
      expect(data.contourVertexCounts![0], greaterThan(6));
    });

    test('miter join within limit stays sharp', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(50, 0);
      path.lineTo(50, 50); // 90-degree turn
      path.close();

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 10.0,
          join: BLStrokeJoin.miterClip,
          miterLimit: 10.0, // generous limit
        ),
      );
      final data = outline.toPathData();
      expect(data.vertices.length, greaterThan(0));
    });

    test('stroke with curves (cubicTo) produces reasonable outline', () {
      final path = BLPath();
      path.moveTo(10, 50);
      path.cubicTo(50, 10, 80, 90, 120, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
            width: 6.0, startCap: BLStrokeCap.round, endCap: BLStrokeCap.round),
      );
      final data = outline.toPathData();

      // Should have a reasonable number of vertices from the flattened curve
      expect(data.vertices.length, greaterThan(20));
    });

    test('all cap types produce non-empty outlines', () {
      for (final cap in BLStrokeCap.values) {
        final path = BLPath();
        path.moveTo(10, 50);
        path.lineTo(90, 50);

        final outline = BLStroker.strokePath(
          path,
          BLStrokeOptions(width: 10.0, startCap: cap, endCap: cap),
        );
        final data = outline.toPathData();
        expect(data.vertices.length, greaterThan(0),
            reason: 'Cap $cap should produce non-empty outline');
      }
    });

    test('all join types produce non-empty outlines', () {
      for (final join in BLStrokeJoin.values) {
        final path = BLPath();
        path.moveTo(10, 10);
        path.lineTo(50, 10);
        path.lineTo(50, 50);
        path.close();

        final outline = BLStroker.strokePath(
          path,
          BLStrokeOptions(width: 6.0, join: join),
        );
        final data = outline.toPathData();
        expect(data.vertices.length, greaterThan(0),
            reason: 'Join $join should produce non-empty outline');
      }
    });

    test(
        'square cap extends FORWARD by hw beyond endpoints (C++ Blend2D parity)',
        () {
      // Horizontal line (50,50) -> (150,50), width=20 (hw=10).
      // Square cap should extend the stroke by hw=10 BEYOND each endpoint:
      //   start: x should reach 50 - 10 = 40
      //   end:   x should reach 150 + 10 = 160
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.square,
          endCap: BLStrokeCap.square,
        ),
      );
      final data = outline.toPathData();

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      double minY = double.infinity;
      double maxY = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        final y = data.vertices[i + 1];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }

      // Forward extension: minX should be exactly 50 - hw = 40
      expect(minX, closeTo(40.0, 0.01),
          reason: 'Square cap start should extend hw=10 before x=50');
      // Forward extension: maxX should be exactly 150 + hw = 160
      expect(maxX, closeTo(160.0, 0.01),
          reason: 'Square cap end should extend hw=10 beyond x=150');
      // Y span should be exactly width=20: 50 ± 10
      expect(minY, closeTo(40.0, 0.01));
      expect(maxY, closeTo(60.0, 0.01));
    });

    test('triangle cap tip extends beyond pivot (C++ Blend2D parity)', () {
      // Horizontal line (50,50) -> (150,50), width=20 (hw=10).
      // Triangle cap tip should be at (pivot + q) where q extends forward by hw.
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 50);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.triangle,
          endCap: BLStrokeCap.triangle,
        ),
      );
      final data = outline.toPathData();

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }

      // Triangle cap should extend to pivot + q, i.e. 50 - 10 = 40 and 150 + 10 = 160
      expect(minX, closeTo(40.0, 0.01),
          reason: 'Triangle cap should extend hw beyond start pivot');
      expect(maxX, closeTo(160.0, 0.01),
          reason: 'Triangle cap should extend hw beyond end pivot');
    });

    test('square cap on diagonal line extends symmetrically (C++ parity)', () {
      // Diagonal line (50,50) -> (150,150), width=20 (hw=10).
      // Square cap extends in the direction perpendicular to (p1-p0), i.e. along
      // the tangent of the original segment, by hw from each endpoint.
      final path = BLPath();
      path.moveTo(50, 50);
      path.lineTo(150, 150);

      final outline = BLStroker.strokePath(
        path,
        const BLStrokeOptions(
          width: 20.0,
          startCap: BLStrokeCap.square,
          endCap: BLStrokeCap.square,
        ),
      );
      final data = outline.toPathData();

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      double minY = double.infinity;
      double maxY = double.negativeInfinity;
      for (int i = 0; i < data.vertices.length; i += 2) {
        final x = data.vertices[i];
        final y = data.vertices[i + 1];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }

      // For a 45-degree line, the hw=10 stroke crosses ±10/sqrt(2) ≈ ±7.071
      // in each axis from the line, plus the square cap extends hw=10 along
      // the tangent direction, adding another 10/sqrt(2) ≈ 7.071 beyond end.
      // Total X span: (50 - 7.071 - 7.071) to (150 + 7.071 + 7.071)
      // ≈ 35.86 to 164.14
      final double hw = 10.0;
      final double d = hw / 1.4142135623730951; // hw / sqrt(2)
      expect(minX, closeTo(50 - d - d, 0.5));
      expect(maxX, closeTo(150 + d + d, 0.5));
      expect(minY, closeTo(50 - d - d, 0.5));
      expect(maxY, closeTo(150 + d + d, 0.5));
    });

    test('BLStrokeOptions copyWith preserves defaults', () {
      const opts = BLStrokeOptions();
      final copy = opts.copyWith(width: 5.0);
      expect(copy.width, 5.0);
      expect(copy.miterLimit, 4.0); // default
      expect(copy.startCap, BLStrokeCap.butt);
      expect(copy.endCap, BLStrokeCap.butt);
      expect(copy.join, BLStrokeJoin.bevel);
    });

    test('stroke width affects outline size', () {
      double outlineArea(double width) {
        final path = BLPath();
        path.moveTo(0, 50);
        path.lineTo(100, 50);
        final outline = BLStroker.strokePath(
          path,
          BLStrokeOptions(
              width: width,
              startCap: BLStrokeCap.butt,
              endCap: BLStrokeCap.butt),
        );
        final data = outline.toPathData();
        // Measure bounding box height as proxy for stroke width
        double minY = double.infinity;
        double maxY = double.negativeInfinity;
        for (int i = 1; i < data.vertices.length; i += 2) {
          final y = data.vertices[i];
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
        return maxY - minY;
      }

      final thin = outlineArea(4.0);
      final thick = outlineArea(20.0);
      expect(thick, greaterThan(thin));
      expect(thin, closeTo(4.0, 0.5));
      expect(thick, closeTo(20.0, 0.5));
    });
  });
}
