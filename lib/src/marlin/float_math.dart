

import 'dart:math' as math;

/// Fast math operations for renderer
class FloatMath {
  FloatMath._();

  /// Fast ceiling as int
  static int ceilInt(double a) {
    final int intpart = a.toInt();
    if (a <= intpart || a.isNaN || a.isInfinite) {
      return intpart;
    }
    return intpart + 1;
  }

  /// Fast floor as int
  static int floorInt(double a) {
    final int intpart = a.toInt();
    if (a >= intpart || a.isNaN || a.isInfinite) {
      return intpart;
    }
    return intpart - 1;
  }

  /// Fast ceiling as double
  static double ceilF(double a) {
    final double result = a.ceilToDouble();
    return result;
  }

  /// Fast floor as double
  static double floorF(double a) {
    return a.floorToDouble();
  }

  /// Power of two
  static double powerOfTwoD(int n) {
    return math.pow(2, n).toDouble();
  }

  /// Absolute value
  static double abs(double a) => a.abs();

  /// Maximum of two values
  static double max(double a, double b) => a > b ? a : b;

  /// Minimum of two values
  static double min(double a, double b) => a < b ? a : b;

  /// Maximum of two ints
  static int maxInt(int a, int b) => a > b ? a : b;

  /// Minimum of two ints
  static int minInt(int a, int b) => a < b ? a : b;

  /// Square root
  static double sqrt(double a) => math.sqrt(a);
}
