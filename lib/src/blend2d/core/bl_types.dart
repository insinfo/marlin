library blend2d_core_types;

typedef BLColor = int; // 0xAARRGGBB
typedef BLPixelFetcher = int Function(int x, int y);

enum BLFillRule {
  evenOdd,
  nonZero,
}

extension BLFillRuleX on BLFillRule {
  int get windingRule => this == BLFillRule.evenOdd ? 0 : 1;

  static BLFillRule fromWindingRule(int windingRule) {
    return windingRule == 0 ? BLFillRule.evenOdd : BLFillRule.nonZero;
  }
}

enum BLCompOp {
  srcOver,
  srcCopy,
}

class BLPoint {
  final double x;
  final double y;

  const BLPoint(this.x, this.y);
}

class BLRectI {
  final int x;
  final int y;
  final int width;
  final int height;

  const BLRectI(this.x, this.y, this.width, this.height);
}

class BLGradientStop {
  final double offset; // [0..1]
  final BLColor color;

  const BLGradientStop(this.offset, this.color);
}

class BLLinearGradient {
  final BLPoint p0;
  final BLPoint p1;
  final List<BLGradientStop> stops;

  const BLLinearGradient({
    required this.p0,
    required this.p1,
    required this.stops,
  });
}

