import 'package:test/test.dart';
import '../lib/src/blend2d/geometry/bl_path.dart';

void main() {
  group('BLPath', () {
    test('moveTo + lineTo creates single contour', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 0);
      path.lineTo(100, 100);

      final data = path.toPathData();
      expect(data.vertices.length, 6); // 3 points * 2
      expect(data.contourVertexCounts, [3]);
      expect(data.contourClosed, [false]);
    });

    test('close() marks contour as closed', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 0);
      path.lineTo(100, 100);
      path.close();

      final data = path.toPathData();
      expect(data.contourVertexCounts, [3]);
      expect(data.contourClosed, [true]);
    });

    test('multiple contours tracked separately', () {
      final path = BLPath();
      // Contour 1 (closed)
      path.moveTo(0, 0);
      path.lineTo(10, 0);
      path.lineTo(10, 10);
      path.close();

      // Contour 2 (open)
      path.moveTo(50, 50);
      path.lineTo(60, 50);
      path.lineTo(60, 60);

      final data = path.toPathData();
      expect(data.contourVertexCounts!.length, 2);
      expect(data.contourVertexCounts, [3, 3]);
      expect(data.contourClosed, [true, false]);
    });

    test('single-point contour discarded', () {
      final path = BLPath();
      path.moveTo(50, 50); // Single point, should be discarded
      path.moveTo(0, 0);
      path.lineTo(100, 0);
      path.lineTo(100, 100);

      final data = path.toPathData();
      expect(data.contourVertexCounts, [3]);
      expect(data.vertices.length, 6);
    });

    test('2-point contour preserved for stroke', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 100);

      final data = path.toPathData();
      expect(data.contourVertexCounts, [2]);
      expect(data.vertices.length, 4);
    });

    test('duplicate lineTo ignored', () {
      final path = BLPath();
      path.moveTo(10, 20);
      path.lineTo(30, 40);
      path.lineTo(30, 40); // duplicate, should be ignored
      path.lineTo(50, 60);

      final data = path.toPathData();
      expect(data.contourVertexCounts, [3]); // 3 unique points
    });

    test('lineTo without moveTo creates implicit moveTo', () {
      final path = BLPath();
      path.lineTo(100, 100);
      path.lineTo(200, 200);

      final data = path.toPathData();
      expect(data.vertices.length, 4);
      expect(data.vertices[0], 100.0); // implicit moveTo at first lineTo
      expect(data.vertices[1], 100.0);
    });

    test('quadTo flattens to line segments', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.quadTo(50, 100, 100, 0);

      final data = path.toPathData();
      // Should produce more than 2 points due to flattening
      expect(data.contourVertexCounts![0], greaterThan(2));
      // First point is the moveTo
      expect(data.vertices[0], 0.0);
      expect(data.vertices[1], 0.0);
      // Last point is the endpoint
      expect(data.vertices[data.vertices.length - 2], 100.0);
      expect(data.vertices[data.vertices.length - 1], 0.0);
    });

    test('cubicTo flattens to line segments', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.cubicTo(33, 100, 66, -100, 100, 0);

      final data = path.toPathData();
      expect(data.contourVertexCounts![0], greaterThan(3));
      expect(data.vertices[0], 0.0);
      expect(data.vertices[1], 0.0);
      expect(data.vertices[data.vertices.length - 2], 100.0);
      expect(data.vertices[data.vertices.length - 1], closeTo(0.0, 0.01));
    });

    test('clear resets all state', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(100, 100);
      path.lineTo(200, 200);
      path.close();

      path.clear();

      final data = path.toPathData();
      expect(data.vertices.isEmpty, true);
      expect(data.contourVertexCounts, isNull);
    });

    test('toPathData can be called multiple times', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(10, 0);
      path.lineTo(10, 10);

      final data1 = path.toPathData();
      final data2 = path.toPathData();
      expect(data1.vertices.length, data2.vertices.length);
      expect(data1.contourVertexCounts, data2.contourVertexCounts);
    });
  });
}
