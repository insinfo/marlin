/// Interface for objects that can consume a path.
abstract class PathConsumer2D {
  /// Start a new subpath at (x0, y0)
  void moveTo(double x0, double y0);

  /// Add a line segment to the current subpath
  void lineTo(double x1, double y1);

  /// Add a quadratic curve segment to the current subpath
  void quadTo(double x1, double y1, double x2, double y2);

  /// Add a cubic curve segment to the current subpath
  void curveTo(double x1, double y1, double x2, double y2, double x3, double y3);

  /// Close the current subpath
  void closePath();

  /// Called when the path is done
  void pathDone();
  
  /// Get the native consumer (Java legacy, unused in Dart)
  // int getNativeConsumer(); 
}
