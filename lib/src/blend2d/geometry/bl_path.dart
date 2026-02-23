class BLPathData {
  final List<double> vertices;
  final List<int>? contourVertexCounts;

  /// `contourClosed[i]` é true se o contorno i foi fechado explicitamente
  /// via `close()`. Usado pelo stroker para decidir caps vs join de fechamento.
  final List<bool>? contourClosed;

  const BLPathData({
    required this.vertices,
    required this.contourVertexCounts,
    this.contourClosed,
  });
}

/// Path minimal para bootstrap do contexto Blend2D em Dart.
class BLPath {
  final List<double> _vertices = <double>[];
  final List<int> _contourCounts = <int>[];
  final List<bool> _contourClosed = <bool>[];
  static const int _maxCurveDepth = 16;

  bool _hasCurrent = false;
  int _currentCount = 0;
  double _lastX = 0.0;
  double _lastY = 0.0;

  void moveTo(double x, double y) {
    _finishContour();
    _hasCurrent = true;
    _lastX = x;
    _lastY = y;
    _vertices.add(x);
    _vertices.add(y);
    _currentCount = 1;
  }

  void lineTo(double x, double y) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    if (x == _lastX && y == _lastY) return;
    _vertices.add(x);
    _vertices.add(y);
    _lastX = x;
    _lastY = y;
    _currentCount++;
  }

  void quadTo(
    double cx,
    double cy,
    double x,
    double y, {
    double tolerance = 0.25,
  }) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    final tolSq = tolerance * tolerance;
    _flattenQuad(_lastX, _lastY, cx, cy, x, y, tolSq, 0);
  }

  void cubicTo(
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x,
    double y, {
    double tolerance = 0.25,
  }) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    final tolSq = tolerance * tolerance;
    _flattenCubic(_lastX, _lastY, c1x, c1y, c2x, c2y, x, y, tolSq, 0);
  }

  /// Fecha o contorno atual explicitamente.
  /// Marca o contorno como closed para o stroker (sem cap nas extremidades).
  void close() {
    if (!_hasCurrent) return;
    _finishContour(closed: true);
  }

  BLPathData toPathData() {
    _finishContour();
    return BLPathData(
      vertices: List<double>.from(_vertices),
      contourVertexCounts:
          _contourCounts.isEmpty ? null : List<int>.from(_contourCounts),
      contourClosed:
          _contourClosed.isEmpty ? null : List<bool>.from(_contourClosed),
    );
  }

  void clear() {
    _vertices.clear();
    _contourCounts.clear();
    _contourClosed.clear();
    _hasCurrent = false;
    _currentCount = 0;
  }

  void _finishContour({bool closed = false}) {
    if (!_hasCurrent) return;
    if (_currentCount >= 2) {
      // Aceita contornos de 2+ pontos para stroke (linhas abertas).
      // O raster ignora contornos com < 3 pontos via fillPolygon.
      _contourCounts.add(_currentCount);
      _contourClosed.add(closed);
    } else {
      // Remove vertices insuficientes do contorno atual.
      final removeCount = _currentCount * 2;
      if (removeCount > 0 && removeCount <= _vertices.length) {
        _vertices.removeRange(_vertices.length - removeCount, _vertices.length);
      }
    }
    _hasCurrent = false;
    _currentCount = 0;
  }

  @pragma('vm:prefer-inline')
  static double _pointLineDistanceSq(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final dx = bx - ax;
    final dy = by - ay;
    final den = dx * dx + dy * dy;
    if (den <= 1e-12) {
      final ex = px - ax;
      final ey = py - ay;
      return ex * ex + ey * ey;
    }
    final t = (((px - ax) * dx) + ((py - ay) * dy)) / den;
    final qx = ax + t * dx;
    final qy = ay + t * dy;
    final ex = px - qx;
    final ey = py - qy;
    return ex * ex + ey * ey;
  }

  @pragma('vm:prefer-inline')
  static double _quadFlatnessSq(
    double x0,
    double y0,
    double cx,
    double cy,
    double x1,
    double y1,
  ) {
    return _pointLineDistanceSq(cx, cy, x0, y0, x1, y1);
  }

  @pragma('vm:prefer-inline')
  static double _cubicFlatnessSq(
    double x0,
    double y0,
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x1,
    double y1,
  ) {
    final d1 = _pointLineDistanceSq(c1x, c1y, x0, y0, x1, y1);
    final d2 = _pointLineDistanceSq(c2x, c2y, x0, y0, x1, y1);
    return d1 > d2 ? d1 : d2;
  }

  void _flattenQuad(
    double x0,
    double y0,
    double cx,
    double cy,
    double x1,
    double y1,
    double tolSq,
    int depth,
  ) {
    if (depth >= _maxCurveDepth || _quadFlatnessSq(x0, y0, cx, cy, x1, y1) <= tolSq) {
      lineTo(x1, y1);
      return;
    }

    final x01 = (x0 + cx) * 0.5;
    final y01 = (y0 + cy) * 0.5;
    final x12 = (cx + x1) * 0.5;
    final y12 = (cy + y1) * 0.5;
    final x012 = (x01 + x12) * 0.5;
    final y012 = (y01 + y12) * 0.5;

    _flattenQuad(x0, y0, x01, y01, x012, y012, tolSq, depth + 1);
    _flattenQuad(x012, y012, x12, y12, x1, y1, tolSq, depth + 1);
  }

  void _flattenCubic(
    double x0,
    double y0,
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x1,
    double y1,
    double tolSq,
    int depth,
  ) {
    if (depth >= _maxCurveDepth ||
        _cubicFlatnessSq(x0, y0, c1x, c1y, c2x, c2y, x1, y1) <= tolSq) {
      lineTo(x1, y1);
      return;
    }

    final x01 = (x0 + c1x) * 0.5;
    final y01 = (y0 + c1y) * 0.5;
    final x12 = (c1x + c2x) * 0.5;
    final y12 = (c1y + c2y) * 0.5;
    final x23 = (c2x + x1) * 0.5;
    final y23 = (c2y + y1) * 0.5;

    final x012 = (x01 + x12) * 0.5;
    final y012 = (y01 + y12) * 0.5;
    final x123 = (x12 + x23) * 0.5;
    final y123 = (y12 + y23) * 0.5;

    final x0123 = (x012 + x123) * 0.5;
    final y0123 = (y012 + y123) * 0.5;

    _flattenCubic(x0, y0, x01, y01, x012, y012, x0123, y0123, tolSq, depth + 1);
    _flattenCubic(x0123, y0123, x123, y123, x23, y23, x1, y1, tolSq, depth + 1);
  }
}
