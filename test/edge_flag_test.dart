import 'package:test/test.dart';
import 'dart:io';
import '../lib/src/edge_flag/rasterizer.dart';

void main() {
  test('Render Triangle EvenOdd', () {
    int w = 100;
    int h = 100;
    var rasterizer = ScanlineEdgeFlagRasterizer(w, h);
    
    // Triangle
    List<double> vertices = [
      10.0, 10.0,
      90.0, 50.0,
      10.0, 90.0,
    ];
    
    rasterizer.rasterize(vertices, FillRule.evenOdd);
    
    var output = rasterizer.outputBuffer;
    
    // Check center pixel
    int cx = 30;
    int cy = 50;
    int val = output[cy * w + cx];
    print('Pixel at $cx,$cy: $val');
    expect(val, greaterThan(0));
    
    // Save to PPM for visualization if needed
    File('triangle_test.ppm').writeAsStringSync('P2\n$w $h\n255\n${output.join(" ")}\n');
  });

  test('Render Triangle NonZero', () {
    int w = 100;
    int h = 100;
    var rasterizer = ScanlineEdgeFlagRasterizer(w, h);
    
    // Triangle
    List<double> vertices = [
      10.0, 10.0,
      90.0, 50.0,
      10.0, 90.0,
    ];
    
    rasterizer.rasterize(vertices, FillRule.nonZero);
    
    var output = rasterizer.outputBuffer;
    
    int cx = 30;
    int cy = 50;
    int val = output[cy * w + cx];
    print('Pixel at $cx,$cy: $val');
    expect(val, greaterThan(0));
  });
}
