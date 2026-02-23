/// Constantes de raster inspiradas em `Pipeline::A8Info` do Blend2D.
class BLA8Info {
  static const int kShift = 8;
  static const int kScale = 1 << kShift;
  static const int kMask = kScale - 1;
  static const int kHalf = kScale >> 1;
}

int blFloorDiv(int a, int b) {
  assert(b > 0);
  if (a >= 0) return a ~/ b;
  return -(((-a) + b - 1) ~/ b);
}

int blCeilDiv(int a, int b) {
  assert(b > 0);
  if (a >= 0) return (a + b - 1) ~/ b;
  return -((-a) ~/ b);
}
