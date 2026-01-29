import 'package:test/test.dart';
import 'dart:io';
import '../lib/src/edge_flag/rasterizer.dart';

void main() {
  test('Render Triangle EvenOdd 8x', () {
    int w = 100;
    int h = 100;
    var rasterizer = ScanlineEdgeFlagRasterizer(w, h, samples: 8);
    
    // Triangle
    List<double> vertices = [
      10.0, 10.0,
      90.0, 50.0,
      10.0, 90.0,
    ];
    
    rasterizer.rasterize(vertices, FillRule.evenOdd);
    
    var output = rasterizer.outputBuffer;
    
    int cx = 30;
    int cy = 50;
    int val = output[cy * w + cx];
    print('8x Pixel at $cx,$cy: $val');
    expect(val, greaterThan(0));
  });

  // New Tests for 16x and 32x
  test('Render Triangle EvenOdd 16x', () {
    int w = 100;
    int h = 100;
    var rasterizer = ScanlineEdgeFlagRasterizer(w, h, samples: 16);
    List<double> vertices = [10.0, 10.0, 90.0, 50.0, 10.0, 90.0];
    rasterizer.rasterize(vertices, FillRule.evenOdd);
    var output = rasterizer.outputBuffer;
    int val = output[50 * w + 30];
    print('16x Pixel at 30,50: $val');
    expect(val, greaterThan(0));
  });

  test('Render Triangle EvenOdd 32x', () {
    int w = 100;
    int h = 100;
    var rasterizer = ScanlineEdgeFlagRasterizer(w, h, samples: 32);
    List<double> vertices = [10.0, 10.0, 90.0, 50.0, 10.0, 90.0];
    rasterizer.rasterize(vertices, FillRule.evenOdd);
    var output = rasterizer.outputBuffer;
    int val = output[50 * w + 30];
    print('32x Pixel at 30,50: $val');
    expect(val, greaterThan(0));
  });

  test('Render Triangle NonZero 16x', () {
    int w = 100;
    int h = 100;
    var rasterizer = ScanlineEdgeFlagRasterizer(w, h, samples: 16);
    List<double> vertices = [10.0, 10.0, 90.0, 50.0, 10.0, 90.0];
    rasterizer.rasterize(vertices, FillRule.nonZero);
    var output = rasterizer.outputBuffer;
    int val = output[50 * w + 30];
    print('NonZero 16x Pixel at 30,50: $val');
    expect(val, greaterThan(0));
  });
}
