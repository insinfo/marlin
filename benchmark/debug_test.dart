import 'package:marlin/marlin.dart';
import 'dart:io';
import 'dart:typed_data';

void main() {
  final r = MarlinRenderer(100, 100);
  r.clear(0xFFFFFFFF);
  
  r.init();
  r.moveTo(50, 10);
  r.lineTo(10, 90);
  r.lineTo(90, 90);
  r.closePath();
  r.endRendering(0xFFFF0000);
  
  // Count non-white pixels
  int nonWhite = 0;
  int redPixels = 0;
  for (final pixel in r.buffer) {
    if (pixel != 0xFFFFFFFF && pixel != -1) nonWhite++;
    if (pixel == -65536) redPixels++; // -65536 = 0xFFFF0000 as signed int32
  }
  print('Non-white pixels: $nonWhite');
  print('Red pixels: $redPixels');
  
  // Check specific pixels
  for (int y = 0; y < 100; y += 10) {
    for (int x = 0; x < 100; x += 10) {
      final pixel = r.buffer[y * 100 + x];
      if (pixel != -1) { // not white
        print('Pixel at ($x,$y): 0x${(pixel & 0xFFFFFFFF).toRadixString(16)}');
      }
    }
  }
  
  // Save image to verify
  final rgbaData = Uint8List(100 * 100 * 4);
  for (int i = 0; i < 100 * 100; i++) {
    final int argb = r.buffer[i];
    final int a = (argb >> 24) & 0xFF;
    final int red = (argb >> 16) & 0xFF;
    final int g = (argb >> 8) & 0xFF;
    final int b = argb & 0xFF;
    rgbaData[i * 4] = red;
    rgbaData[i * 4 + 1] = g;
    rgbaData[i * 4 + 2] = b;
    rgbaData[i * 4 + 3] = a;
  }
  
  final pngBytes = PngWriter.encodeRgba(rgbaData, 100, 100);
  Directory('output').createSync(recursive: true);
  File('output/debug_triangle.png').writeAsBytesSync(pngBytes);
  print('Saved: output/debug_triangle.png');
}
