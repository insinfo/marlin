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
  // Porter-Duff (aligned with BL_COMP_OP_* from context.h)
  srcOver, // 0 — default
  srcCopy, // 1
  srcIn, // 2
  srcOut, // 3
  srcAtop, // 4
  dstOver, // 5
  dstCopy, // 6
  dstIn, // 7
  dstOut, // 8
  dstAtop, // 9
  xor_, // 10 — 'xor' is reserved in Dart
  clear, // 11

  // Advanced blend modes (separable)
  plus, // 12
  minus, // 13
  modulate, // 14
  multiply, // 15
  screen, // 16
  overlay, // 17
  darken, // 18
  lighten, // 19
  colorDodge, // 20
  colorBurn, // 21
  linearBurn, // 22
  linearLight, // 23
  pinLight, // 24
  hardLight, // 25
  softLight, // 26
  difference, // 27
  exclusion, // 28
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

class BLConicGradient {
  final BLPoint center;
  final double angle; // Offset inicial em radianos
  final List<BLGradientStop> stops;
  final BLGradientExtendMode extendMode;

  const BLConicGradient({
    required this.center,
    this.angle = 0.0,
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

// ---------------------------------------------------------------------------
// Stroke types (Fase 5 - port do PathStroker do Blend2D)
// ---------------------------------------------------------------------------

/// Estilo de cap para extremidades de contornos abertos.
/// Alinhado com BLStrokeCap do C++.
enum BLStrokeCap {
  /// Termina exatamente no ponto final (padrão).
  butt,

  /// Estende o cap em halfWidth além do ponto final (forma quadrada).
  square,

  /// Cap circular com raio = halfWidth.
  round,

  /// Cap circular recuado (inverso do round).
  roundRev,

  /// Cap triangular apontando para fora.
  triangle,

  /// Cap triangular apontando para dentro.
  triangleRev,
}

/// Estilo de join para vértices internos de contornos.
/// Alinhado com BLStrokeJoin do C++.
enum BLStrokeJoin {
  /// Chanfrado simples (bevel).
  bevel,

  /// Miter cortado quando excede o limite.
  miterClip,

  /// Miter com fallback para bevel.
  miterBevel,

  /// Miter com fallback para round.
  miterRound,

  /// Join circular.
  round,
}

/// Opções de stroke usadas por BLContext.strokePath() e BLStroker.
/// Equivalente a BLStrokeOptions do C++.
class BLStrokeOptions {
  /// Largura total do stroke.
  final double width;

  /// Limite do miter (em múltiplos de halfWidth).
  /// Default 4.0 corresponde a BL_STROKE_MITER_LIMIT_DEFAULT.
  final double miterLimit;

  /// Cap do início do contorno.
  final BLStrokeCap startCap;

  /// Cap do fim do contorno.
  final BLStrokeCap endCap;

  /// Estilo de join nos vértices internos.
  final BLStrokeJoin join;

  /// Tolerância de flatten para curvas (De Casteljau).
  final double flattenTolerance;

  const BLStrokeOptions({
    this.width = 1.0,
    this.miterLimit = 4.0,
    this.startCap = BLStrokeCap.butt,
    this.endCap = BLStrokeCap.butt,
    this.join = BLStrokeJoin.bevel,
    this.flattenTolerance = 0.25,
  });

  BLStrokeOptions copyWith({
    double? width,
    double? miterLimit,
    BLStrokeCap? startCap,
    BLStrokeCap? endCap,
    BLStrokeJoin? join,
    double? flattenTolerance,
  }) {
    return BLStrokeOptions(
      width: width ?? this.width,
      miterLimit: miterLimit ?? this.miterLimit,
      startCap: startCap ?? this.startCap,
      endCap: endCap ?? this.endCap,
      join: join ?? this.join,
      flattenTolerance: flattenTolerance ?? this.flattenTolerance,
    );
  }
}
