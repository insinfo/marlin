library blend2d_core_types;

import 'bl_image.dart';

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

enum BLGradientExtendMode {
  pad,
  repeat,
  reflect,
}

enum BLPatternFilter {
  nearest,
  bilinear,
}

class BLMatrix2D {
  final double m00;
  final double m01;
  final double m10;
  final double m11;
  final double m20;
  final double m21;

  const BLMatrix2D(
    this.m00,
    this.m01,
    this.m10,
    this.m11,
    this.m20,
    this.m21,
  );

  static const BLMatrix2D identity = BLMatrix2D(1.0, 0.0, 0.0, 1.0, 0.0, 0.0);
}

class BLLinearGradient {
  final BLPoint p0;
  final BLPoint p1;
  final List<BLGradientStop> stops;
  final BLGradientExtendMode extendMode;

  const BLLinearGradient({
    required this.p0,
    required this.p1,
    required this.stops,
    this.extendMode = BLGradientExtendMode.pad,
  });
}

class BLRadialGradient {
  final BLPoint c0;
  final BLPoint c1;
  final double r0;
  final double r1;
  final List<BLGradientStop> stops;
  final BLGradientExtendMode extendMode;

  const BLRadialGradient({
    required this.c0,
    required this.c1,
    required this.r0,
    this.r1 = 0.0,
    required this.stops,
    this.extendMode = BLGradientExtendMode.pad,
  });
}

class BLPattern {
  final BLImage image;
  final BLPoint offset;
  final BLGradientExtendMode extendModeX;
  final BLGradientExtendMode extendModeY;
  final BLPatternFilter filter;
  final BLMatrix2D transform;

  const BLPattern({
    required this.image,
    this.offset = const BLPoint(0.0, 0.0),
    this.extendModeX = BLGradientExtendMode.pad,
    this.extendModeY = BLGradientExtendMode.pad,
    this.filter = BLPatternFilter.nearest,
    this.transform = BLMatrix2D.identity,
  });
}

