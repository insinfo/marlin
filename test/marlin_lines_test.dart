import 'package:test/test.dart';
import 'package:marlin/src/marlin/marlin_renderer.dart';
import 'package:marlin/src/marlin/geom/path_2d.dart';
import 'dart:math' as math;

void main() {
  test('Marlin Line Rendering Test', () {
    const int size = 600;
    const int width = size + 100;
    const int height = size;

    final renderer = MarlinRenderer(width, height);
    // Background White
    renderer.clear(0xFFFFFFFF); 

    // Paint
    paint(renderer, width.toDouble(), height.toDouble());

    // Verify output
    final buffer = renderer.buffer;
    int drawnPixels = 0;
    for (int p in buffer) {
      if (p != 0xFFFFFFFF) {
        drawnPixels++;
      }
    }
    
    print('Drawn Pixels: $drawnPixels');
    expect(drawnPixels, greaterThan(0));
  });
}

void paint(MarlinRenderer renderer, double width, double height) {
    final double size = math.min(width, height);
    // double radius = 0.25 * size; // Unused
    
    final Path2DFloat path = Path2DFloat(); // Concrete class
    const double lineStroke = 2.5;
    const double thinStroke = 1.5;
    
    // Colors
    const int col2 = 0xFFFFFF00; // Yellow (ARGB)
    const int col3 = 0xFF00FF00; // Green 
    
    for (double angle = 0.2; angle <= 90.0; angle += 1.0) {
        double angRad = angle * math.pi / 180.0;
        double cos = math.cos(angRad);
        double sin = math.sin(angRad);
        
        // Thick line
        renderer.init(0, 0, width.toInt(), height.toInt(), 1); // NonZero
        drawLine(path, 5.0 * cos, 5.0 * sin, size * cos, size * sin, lineStroke);
        replayPath(path, renderer);
        renderer.endRendering(col2); // Draw Yellow
        
        // Thin line
        renderer.init(0, 0, width.toInt(), height.toInt(), 1);
        drawLine(path, 5.0 * cos, 5.0 * sin, size * cos, size * sin, thinStroke);
        replayPath(path, renderer);
        renderer.endRendering(col3); // Draw Green
    }
}

void drawLine(Path2D path, double x1, double y1, double x2, double y2, double w) {
    double dx = x2 - x1;
    double dy = y2 - y1;
    double d = math.sqrt(dx * dx + dy * dy);
    
    if (d == 0) return;

    dx = w * (y2 - y1) / d;
    dy = w * (x2 - x1) / d;

    path.reset();
    path.moveTo(x1 - dx, y1 + dy);
    path.lineTo(x2 - dx, y2 + dy);
    path.lineTo(x2 + dx, y2 - dy);
    path.lineTo(x1 + dx, y1 - dy);
    path.closePath(); 
}

void replayPath(Path2D path, MarlinRenderer renderer) {
  final PathIterator pi = path.getPathIterator(null);
  final List<double> coords = List<double>.filled(6, 0.0);
  while (!pi.isDone()) {
    switch (pi.currentSegment(coords)) {
      case 0: // SEG_MOVETO
        renderer.moveTo(coords[0], coords[1]);
        break;
      case 1: // SEG_LINETO
        renderer.lineTo(coords[0], coords[1]);
        break;
      case 2: // SEG_QUADTO
        renderer.quadTo(coords[0], coords[1], coords[2], coords[3]);
        break;
      case 3: // SEG_CUBICTO
        renderer.curveTo(coords[0], coords[1], coords[2], coords[3], coords[4], coords[5]);
        break;
      case 4: // SEG_CLOSE
        renderer.closePath();
        break;
    }
    pi.next();
  }
}
