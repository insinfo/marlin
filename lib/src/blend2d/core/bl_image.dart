import 'dart:typed_data';

/// Superficie ARGB32 usada pelo port Blend2D em Dart.
class BLImage {
  final int width;
  final int height;
  final Uint32List pixels;

  BLImage(this.width, this.height)
      : assert(width > 0),
        assert(height > 0),
        pixels = Uint32List(width * height);

  void clear([int argb = 0xFFFFFFFF]) {
    pixels.fillRange(0, pixels.length, argb);
  }

  void copyFrom(Uint32List source) {
    if (source.length != pixels.length) {
      throw ArgumentError(
        'source length ${source.length} != target length ${pixels.length}',
      );
    }
    pixels.setAll(0, source);
  }
}

