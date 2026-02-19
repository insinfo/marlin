/// ============================================================================
/// TESSELLATION — Rasterizacao via triangulacao de contornos
/// ============================================================================
///
/// Converte contornos (com buracos) em triangulos e rasteriza os triangulos.
/// Inclui tesselação adaptativa simples baseada em comprimento de aresta.
/// ============================================================================

import 'dart:typed_data';
import 'dart:math' as math;

import 'tessellation_tables.dart';

class TessellationRasterizer {
  final int width;
  final int height;
  final int samplesPerAxis;
  final bool useRotatedGrid;
  final double rotationRadians;
  final bool swapXY;
  final bool enableDebugLogs;
  final int maxDebugSteps;

  final Uint32List _buffer;
  final Uint16List _sampleMask;
  final List<int> _maskTouched = <int>[];
  late final int _sampleCount;
  late final Float32List _sampleOffsets;
  late final List<int> _alphaLut;
  final List<double> _trianglesScratch = <double>[];
  final List<List<double>> _contourScratch = <List<double>>[];
  List<double> _swapScratch = <double>[];

  TessellationRasterizer({
    required this.width,
    required this.height,
    this.samplesPerAxis = 2,
    this.useRotatedGrid = true,
    this.rotationRadians = 0.4636476090008061,
    this.swapXY = false,
    this.enableDebugLogs = false,
    this.maxDebugSteps = 500000,
  })  : _buffer = Uint32List(width * height),
        _sampleMask = Uint16List(width * height) {
    _initSamples();
  }

  void _debug(String message) {
    if (enableDebugLogs) {
      print('[TessellationRasterizer] $message');
    }
  }

  void _initSamples() {
    final n = samplesPerAxis.clamp(2, 4);
    _sampleCount = n * n;

    final offsets = Float32List(_sampleCount * 2);
    final inv = 1.0 / n;
    final cosA = useRotatedGrid ? math.cos(rotationRadians) : 1.0;
    final sinA = useRotatedGrid ? math.sin(rotationRadians) : 0.0;

    var idx = 0;
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        final ux = (x + 0.5) * inv - 0.5;
        final uy = (y + 0.5) * inv - 0.5;

        final rx = useRotatedGrid ? (ux * cosA - uy * sinA) : ux;
        final ry = useRotatedGrid ? (ux * sinA + uy * cosA) : uy;

        final ox = (rx + 0.5).clamp(0.0, 1.0);
        final oy = (ry + 0.5).clamp(0.0, 1.0);

        offsets[idx++] = ox;
        offsets[idx++] = oy;
      }
    }
    _sampleOffsets = offsets;

    _alphaLut =
        _sampleCount == 4 ? kTessellationAlphaLut4 : kTessellationAlphaLut16;
  }

  void clear([int color = 0xFFFFFFFF]) {
    _buffer.fillRange(0, _buffer.length, color);
  }

  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
    double maxEdgeLength = 0.0,
    double minSegmentLength = 0.75,
    double curvatureBoost = 1.5,
    int maxSubdivPerEdge = 8,
    int maxContourVertices = 2048,
  }) {
    if (vertices.length < 6) return;

    final workingVertices = swapXY ? _swapVertices(vertices) : vertices;
    final contours = _splitContours(workingVertices, contourVertexCounts);
    if (contours.isEmpty) return;

    _contourScratch.clear();
    for (final contour in contours) {
      final cleaned = _sanitizeContour(contour);
      if (cleaned.length < 6) continue;
      List<double> prepared = cleaned;
      if (maxEdgeLength > 0.0) {
        prepared = _adaptiveRefineContour(cleaned, maxEdgeLength,
            minSegmentLength, curvatureBoost, maxSubdivPerEdge);
      }
      if ((prepared.length >> 1) > maxContourVertices) {
        prepared = _downsampleContour(prepared, maxContourVertices);
      }
      _contourScratch.add(prepared);
    }
    if (_contourScratch.isEmpty) return;

    _trianglesScratch.clear();
    List<double> triangles;
    try {
      triangles =
          _triangulateContours(_contourScratch, _trianglesScratch, windingRule);
    } catch (e) {
      _debug('Triangulation skipped polygon due to error: $e');
      return;
    }
    if (triangles.isEmpty) return;

    _rasterizeTriangles(triangles, color);
  }

  List<List<double>> _splitContours(List<double> vertices, List<int>? counts) {
    final totalPoints = vertices.length ~/ 2;
    if (totalPoints < 3) return <List<double>>[];
    if (counts == null || counts.isEmpty) {
      return <List<double>>[List<double>.from(vertices)];
    }

    final out = <List<double>>[];
    int offset = 0;
    for (final count in counts) {
      if (count < 3 || offset + count > totalPoints) break;
      final start = offset * 2;
      final end = (offset + count) * 2;
      out.add(vertices.sublist(start, end));
      offset += count;
    }
    if (out.isEmpty) {
      return <List<double>>[List<double>.from(vertices)];
    }
    return out;
  }

  List<double> _swapVertices(List<double> vertices) {
    if (_swapScratch.length != vertices.length) {
      _swapScratch = List<double>.filled(vertices.length, 0.0, growable: false);
    }
    for (int i = 0; i < vertices.length; i += 2) {
      _swapScratch[i] = vertices[i + 1];
      _swapScratch[i + 1] = vertices[i];
    }
    return _swapScratch;
  }

  List<double> _sanitizeContour(List<double> contour) {
    if (contour.length < 6) return contour;
    const eps = 1e-6;
    final cleaned = <double>[];
    final n = contour.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final x = contour[i * 2];
      final y = contour[i * 2 + 1];
      if (!x.isFinite || !y.isFinite) continue;
      if (cleaned.length >= 2) {
        final lastX = cleaned[cleaned.length - 2];
        final lastY = cleaned[cleaned.length - 1];
        if ((x - lastX).abs() <= eps && (y - lastY).abs() <= eps) {
          continue;
        }
      }
      cleaned.add(x);
      cleaned.add(y);
    }
    if (cleaned.length < 6) return cleaned;
    final firstX = cleaned[0];
    final firstY = cleaned[1];
    final lastX = cleaned[cleaned.length - 2];
    final lastY = cleaned[cleaned.length - 1];
    if ((firstX - lastX).abs() <= eps && (firstY - lastY).abs() <= eps) {
      cleaned.removeRange(cleaned.length - 2, cleaned.length);
    }
    if (cleaned.length < 6) return cleaned;

    final out = <double>[];
    final m = cleaned.length ~/ 2;
    for (int i = 0; i < m; i++) {
      final i0 = (i - 1 + m) % m;
      final i1 = i;
      final i2 = (i + 1) % m;
      final ax = cleaned[i0 * 2];
      final ay = cleaned[i0 * 2 + 1];
      final bx = cleaned[i1 * 2];
      final by = cleaned[i1 * 2 + 1];
      final cx = cleaned[i2 * 2];
      final cy = cleaned[i2 * 2 + 1];
      final abx = bx - ax;
      final aby = by - ay;
      final bcx = cx - bx;
      final bcy = cy - by;
      final cross = abx * bcy - aby * bcx;
      final dot = abx * bcx + aby * bcy;
      if (cross.abs() <= eps && dot >= 0) {
        continue;
      }
      out.add(bx);
      out.add(by);
    }
    return out.length >= 6 ? out : cleaned;
  }

  List<double> _adaptiveRefineContour(
      List<double> contour,
      double maxEdgeLength,
      double minSegmentLength,
      double curvatureBoost,
      int maxSubdivPerEdge) {
    if (contour.length < 6) return contour;
    final out = <double>[];
    final n = contour.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final k = (i - 1 + n) % n;
      final x0 = contour[i * 2];
      final y0 = contour[i * 2 + 1];
      final x1 = contour[j * 2];
      final y1 = contour[j * 2 + 1];
      final xPrev = contour[k * 2];
      final yPrev = contour[k * 2 + 1];
      out.add(x0);
      out.add(y0);

      final dx = x1 - x0;
      final dy = y1 - y0;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len > minSegmentLength && len > maxEdgeLength) {
        final e0x = x0 - xPrev;
        final e0y = y0 - yPrev;
        final e1x = x1 - x0;
        final e1y = y1 - y0;
        final l0 = math.sqrt(e0x * e0x + e0y * e0y);
        final l1 = math.sqrt(e1x * e1x + e1y * e1y);
        double angleBoost = 1.0;
        if (l0 > 1e-6 && l1 > 1e-6) {
          var cosAngle = (e0x * e1x + e0y * e1y) / (l0 * l1);
          if (cosAngle < -1.0) cosAngle = -1.0;
          if (cosAngle > 1.0) cosAngle = 1.0;
          final curvature = 1.0 - cosAngle;
          angleBoost = 1.0 + curvatureBoost * curvature;
        }
        var steps = (len / maxEdgeLength * angleBoost).ceil();
        if (steps < 2) steps = 2;
        if (steps > maxSubdivPerEdge) steps = maxSubdivPerEdge;
        final inv = 1.0 / steps;
        for (int s = 1; s < steps; s++) {
          final t = s * inv;
          out.add(x0 + dx * t);
          out.add(y0 + dy * t);
        }
      }
    }
    return out;
  }

  List<double> _downsampleContour(List<double> contour, int maxVertices) {
    final n = contour.length >> 1;
    if (n <= maxVertices) return contour;
    final step = n / maxVertices;
    final out = <double>[];
    double cursor = 0.0;
    for (int i = 0; i < maxVertices; i++) {
      int idx = cursor.floor();
      if (idx >= n) idx = n - 1;
      out.add(contour[idx * 2]);
      out.add(contour[idx * 2 + 1]);
      cursor += step;
    }
    return out;
  }

  List<double> _triangulateContours(
      List<List<double>> contours, List<double> out, int windingRule) {
    if (contours.isEmpty) return <double>[];

    final outers = <List<double>>[];
    final holes = <List<double>>[];

    for (final contour in contours) {
      if (contour.length < 6) continue;
      final area = _signedArea(contour);
      if (area >= 0) {
        outers.add(contour);
      } else {
        holes.add(contour);
      }
    }

    if (outers.isEmpty) {
      holes.clear();
      for (final contour in contours) {
        if (contour.length < 6) continue;
        outers.add(_reversePairs(contour));
      }
    }

    final holeBuckets = _assignHolesToOuters(outers, holes, windingRule);
    for (int i = 0; i < outers.length; i++) {
      final outer = _ensureWinding(outers[i], true);
      final bucket = holeBuckets[i];
      final fixedHoles = <List<double>>[];
      for (final hole in bucket) {
        fixedHoles.add(_ensureWinding(hole, false));
      }
      _earcutWithHoles(outer, fixedHoles, out);
    }
    return out;
  }

  double _signedArea(List<double> contour) {
    double area = 0.0;
    final n = contour.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = contour[i * 2];
      final y0 = contour[i * 2 + 1];
      final x1 = contour[j * 2];
      final y1 = contour[j * 2 + 1];
      area += (x0 * y1) - (y0 * x1);
    }
    return area * 0.5;
  }

  List<double> _reversePairs(List<double> list) {
    final out = <double>[];
    for (int i = list.length - 2; i >= 0; i -= 2) {
      out.add(list[i]);
      out.add(list[i + 1]);
    }
    return out;
  }

  List<List<List<double>>> _assignHolesToOuters(
      List<List<double>> outers, List<List<double>> holes, int windingRule) {
    final buckets = List<List<List<double>>>.generate(
        outers.length, (_) => <List<double>>[]);
    if (holes.isEmpty || outers.isEmpty) return buckets;

    for (final hole in holes) {
      if (hole.length < 6) continue;
      final px = hole[0];
      final py = hole[1];
      int target = 0;
      for (int i = 0; i < outers.length; i++) {
        if (_pointInPolygon(px, py, outers[i], windingRule)) {
          target = i;
          break;
        }
      }
      buckets[target].add(hole);
    }
    return buckets;
  }

  List<double> _ensureWinding(List<double> contour, bool ccw) {
    final area = _signedArea(contour);
    if ((area >= 0) == ccw) return contour;
    return _reversePairs(contour);
  }

  void _earcutWithHoles(
      List<double> outer, List<List<double>> holes, List<double> out) {
    _debug(
        'earcut start: outerPts=${outer.length ~/ 2}, holes=${holes.length}');
    final initial = _linkedList(outer, false);
    if (initial == null) return;
    _EarNode outerNode = initial;

    if (holes.isNotEmpty) {
      outerNode = _eliminateHoles(holes, outerNode);
    }

    double minX = 0.0;
    double minY = 0.0;
    double maxX = 0.0;
    double maxY = 0.0;
    _EarNode p = outerNode;
    minX = maxX = p.x;
    minY = maxY = p.y;
    do {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
      p = p.next!;
    } while (p != outerNode);
    final size = math.max(maxX - minX, maxY - minY);
    final invSize = size == 0 ? 0.0 : (32767.0 / size);

    final maxIterations =
        (_nodeCount(outerNode) * 8).clamp(1024, maxDebugSteps);
    _earcutLinked(outerNode, out, minX, minY, invSize, 0, maxIterations);
    _debug('earcut end: tris=${out.length ~/ 6}');
  }

  _EarNode? _linkedList(List<double> data, bool clockwise) {
    final area = _signedArea(data);
    final shouldForward = (area > 0) == !clockwise;
    _EarNode? last;
    if (shouldForward) {
      for (int i = 0; i < data.length; i += 2) {
        last = _insertNode(i, data[i], data[i + 1], last);
      }
    } else {
      for (int i = data.length - 2; i >= 0; i -= 2) {
        last = _insertNode(i, data[i], data[i + 1], last);
      }
    }
    if (last == null) return null;
    if (_equals(last, last.next!)) {
      _removeNode(last);
      last = last.next;
    }
    return _filterPoints(last);
  }

  _EarNode _insertNode(int i, double x, double y, _EarNode? last) {
    final node = _EarNode(i, x, y);
    if (last == null) {
      node.prev = node;
      node.next = node;
    } else {
      node.next = last.next;
      node.prev = last;
      last.next!.prev = node;
      last.next = node;
    }
    return node;
  }

  void _removeNode(_EarNode node) {
    node.next!.prev = node.prev;
    node.prev!.next = node.next;
    if (node.prevZ != null) node.prevZ!.nextZ = node.nextZ;
    if (node.nextZ != null) node.nextZ!.prevZ = node.prevZ;
  }

  _EarNode? _filterPoints(_EarNode? start, [_EarNode? end]) {
    if (start == null) return start;
    var endNode = end ?? start;
    var p = start;
    bool again;
    int steps = 0;
    do {
      if (++steps > maxDebugSteps) {
        throw StateError(
            'Loop guard hit in _filterPoints (steps=$steps). Possible malformed ring.');
      }
      again = false;
      if (!p.steiner &&
          (_equals(p, p.next!) || _area(p.prev!, p, p.next!) == 0)) {
        _removeNode(p);
        p = endNode = p.prev!;
        if (p == p.next) return null;
        again = true;
      } else {
        p = p.next!;
      }
    } while (again || p != endNode);
    return endNode;
  }

  _EarNode _eliminateHoles(List<List<double>> holes, _EarNode outerNode) {
    final queue = <_EarNode>[];
    for (final hole in holes) {
      final list = _linkedList(hole, true);
      if (list == null) continue;
      queue.add(_getLeftmost(list));
    }
    queue.sort((a, b) => a.x.compareTo(b.x));
    for (final hole in queue) {
      _eliminateHole(hole, outerNode);
      final filtered = _filterPoints(outerNode);
      if (filtered == null) {
        return outerNode;
      }
      outerNode = filtered;
    }
    return outerNode;
  }

  void _eliminateHole(_EarNode hole, _EarNode outerNode) {
    final bridge = _findHoleBridge(hole, outerNode);
    if (bridge == null) return;
    final bridgeReverse = _splitPolygon(bridge, hole);
    _filterPoints(bridge, bridge.next);
    _filterPoints(bridgeReverse, bridgeReverse.next);
  }

  _EarNode? _findHoleBridge(_EarNode hole, _EarNode outerNode) {
    final hx = hole.x;
    final hy = hole.y;
    _EarNode? bridge;
    double qx = -double.infinity;
    _EarNode p = outerNode;
    int steps = 0;
    do {
      if (++steps > maxDebugSteps) {
        throw StateError(
            'Loop guard hit in _findHoleBridge pass1 (steps=$steps).');
      }
      if ((p.y > hy) != (p.next!.y > hy)) {
        final x = p.x + (hy - p.y) * (p.next!.x - p.x) / (p.next!.y - p.y);
        if (x <= hx && x > qx) {
          qx = x;
          if (x == hx) {
            if (hy == p.y) return p;
            if (hy == p.next!.y) return p.next;
          }
          bridge = p.x < p.next!.x ? p : p.next;
        }
      }
      p = p.next!;
    } while (p != outerNode);

    if (bridge == null) return null;
    if (hx == qx) return bridge;

    final bridgeX = bridge.x;
    final bridgeY = bridge.y;
    double bestDist = double.infinity;
    _EarNode? best;
    p = bridge;
    steps = 0;
    do {
      if (++steps > maxDebugSteps) {
        throw StateError(
            'Loop guard hit in _findHoleBridge pass2 (steps=$steps).');
      }
      if (p.x >= hx &&
          p.x <= bridgeX &&
          _pointInTriangle(
              hy < bridgeY ? hx : qx, hy, bridgeX, bridgeY, qx, hy, p.x, p.y)) {
        final dx = hx - p.x;
        final dy = hy - p.y;
        final dist = dx * dx + dy * dy;
        if (dist < bestDist && _locallyInside(p, hole)) {
          bestDist = dist;
          best = p;
        }
      }
      p = p.next!;
    } while (p != bridge);

    return best ?? bridge;
  }

  _EarNode _splitPolygon(_EarNode a, _EarNode b) {
    final a2 = _EarNode(a.i, a.x, a.y);
    final b2 = _EarNode(b.i, b.x, b.y);

    final an = a.next!;
    final bp = b.prev!;

    a.next = b;
    b.prev = a;

    a2.next = an;
    an.prev = a2;

    b2.next = a2;
    a2.prev = b2;

    bp.next = b2;
    b2.prev = bp;

    return b2;
  }

  void _earcutLinked(_EarNode? ear, List<double> out, double minX, double minY,
      double invSize, int pass, int maxIterations) {
    if (ear == null) return;

    if (pass == 0 && invSize != 0.0) {
      _indexCurve(ear, minX, minY, invSize);
    }

    _EarNode? stop = ear;
    _EarNode? prev;
    _EarNode? next;

    int guard = 0;
    while (ear!.prev != ear.next) {
      guard++;
      if (guard > maxIterations) {
        throw StateError(
            'Loop guard hit in _earcutLinked (pass=$pass, guard=$guard, max=$maxIterations).');
      }
      prev = ear.prev;
      next = ear.next;

      if (invSize != 0.0
          ? _isEarHashed(ear, minX, minY, invSize)
          : _isEar(ear)) {
        out.add(prev!.x);
        out.add(prev.y);
        out.add(ear.x);
        out.add(ear.y);
        out.add(next!.x);
        out.add(next.y);

        _removeNode(ear);
        ear = next.next;
        stop = next.next;
        continue;
      }

      ear = next;
      if (ear == stop) {
        if (pass == 0) {
          _earcutLinked(_cureLocalIntersections(ear, out), out, minX, minY,
              invSize, 1, maxIterations);
        } else if (pass == 1) {
          _earcutLinked(_splitEarcut(ear, out, minX, minY, invSize), out, minX,
              minY, invSize, 2, maxIterations);
        }
        return;
      }
    }
  }

  _EarNode? _cureLocalIntersections(_EarNode? start, List<double> out) {
    if (start == null) return start;
    _EarNode p = start;
    int steps = 0;
    do {
      if (++steps > maxDebugSteps) {
        throw StateError(
            'Loop guard hit in _cureLocalIntersections (steps=$steps).');
      }
      final a = p.prev!;
      final b = p.next!.next!;
      if (!_equals(a, b) &&
          _intersects(a, p, p.next!, b) &&
          _locallyInside(a, b) &&
          _locallyInside(b, a)) {
        out.add(a.x);
        out.add(a.y);
        out.add(p.x);
        out.add(p.y);
        out.add(b.x);
        out.add(b.y);

        _removeNode(p);
        _removeNode(p.next!);
        p = start = b;
      }
      p = p.next!;
    } while (p != start);
    return _filterPoints(p);
  }

  _EarNode? _splitEarcut(_EarNode? start, List<double> out, double minX,
      double minY, double invSize) {
    if (start == null) return start;
    _EarNode a = start;
    int stepsOuter = 0;
    do {
      if (++stepsOuter > maxDebugSteps) {
        throw StateError('Loop guard hit in _splitEarcut outer loop.');
      }
      _EarNode b = a.next!.next!;
      int stepsInner = 0;
      while (b != a.prev) {
        if (++stepsInner > maxDebugSteps) {
          throw StateError('Loop guard hit in _splitEarcut inner loop.');
        }
        if (a.i != b.i && _isValidDiagonal(a, b)) {
          var c = _splitPolygon(a, b);
          final fa = _filterPoints(a);
          final fc = _filterPoints(c);
          if (fa != null) {
            _earcutLinked(fa, out, minX, minY, invSize, 0, 100000);
          }
          if (fc != null) {
            _earcutLinked(fc, out, minX, minY, invSize, 0, 100000);
          }
          return null;
        }
        b = b.next!;
      }
      a = a.next!;
    } while (a != start);
    return start;
  }

  bool _isValidDiagonal(_EarNode a, _EarNode b) {
    return a.next!.i != b.i &&
        a.prev!.i != b.i &&
        !_intersectsPolygon(a, b) &&
        _locallyInside(a, b) &&
        _locallyInside(b, a) &&
        _middleInside(a, b);
  }

  bool _intersectsPolygon(_EarNode a, _EarNode b) {
    _EarNode p = a;
    int steps = 0;
    do {
      if (++steps > maxDebugSteps) {
        throw StateError('Loop guard hit in _intersectsPolygon.');
      }
      if (p.i != a.i &&
          p.next!.i != a.i &&
          p.i != b.i &&
          p.next!.i != b.i &&
          _intersects(p, p.next!, a, b)) {
        return true;
      }
      p = p.next!;
    } while (p != a);
    return false;
  }

  bool _middleInside(_EarNode a, _EarNode b) {
    final mx = (a.x + b.x) * 0.5;
    final my = (a.y + b.y) * 0.5;
    return _pointInPolygon(mx, my, _nodeToList(a), 1);
  }

  List<double> _nodeToList(_EarNode start) {
    final out = <double>[];
    var p = start;
    do {
      out.add(p.x);
      out.add(p.y);
      p = p.next!;
    } while (p != start);
    return out;
  }

  bool _locallyInside(_EarNode a, _EarNode b) {
    if (_area(a.prev!, a, a.next!) > 0) {
      return _area(a, b, a.prev!) > 0 && _area(a, a.next!, b) > 0;
    }
    return _area(a, b, a.next!) >= 0 || _area(a, a.prev!, b) >= 0;
  }

  bool _intersects(_EarNode p1, _EarNode q1, _EarNode p2, _EarNode q2) {
    if ((_equals(p1, q1) && _equals(p2, q2)) ||
        (_equals(p1, q2) && _equals(p2, q1))) {
      return true;
    }
    return (_area(p1, q1, p2) > 0) != (_area(p1, q1, q2) > 0) &&
        (_area(p2, q2, p1) > 0) != (_area(p2, q2, q1) > 0);
  }

  bool _isEar(_EarNode ear) {
    final a = ear.prev!;
    final b = ear;
    final c = ear.next!;
    if (_area(a, b, c) <= 0) return false;
    var p = ear.next!.next!;
    int steps = 0;
    while (p != ear.prev) {
      if (++steps > maxDebugSteps) {
        throw StateError('Loop guard hit in _isEar.');
      }
      if (_pointInTriangle(p.x, p.y, a.x, a.y, b.x, b.y, c.x, c.y)) {
        return false;
      }
      p = p.next!;
    }
    return true;
  }

  bool _isEarHashed(_EarNode ear, double minX, double minY, double invSize) {
    final a = ear.prev!;
    final b = ear;
    final c = ear.next!;
    if (_area(a, b, c) <= 0) return false;

    final minTX = math.min(a.x, math.min(b.x, c.x));
    final minTY = math.min(a.y, math.min(b.y, c.y));
    final maxTX = math.max(a.x, math.max(b.x, c.x));
    final maxTY = math.max(a.y, math.max(b.y, c.y));

    final minZ = _zOrder(minTX, minTY, minX, minY, invSize);
    final maxZ = _zOrder(maxTX, maxTY, minX, minY, invSize);

    var p = ear.prevZ;
    while (p != null && p.z >= minZ) {
      if (p != a &&
          p != c &&
          _pointInTriangle(p.x, p.y, a.x, a.y, b.x, b.y, c.x, c.y)) {
        return false;
      }
      p = p.prevZ;
    }
    p = ear.nextZ;
    while (p != null && p.z <= maxZ) {
      if (p != a &&
          p != c &&
          _pointInTriangle(p.x, p.y, a.x, a.y, b.x, b.y, c.x, c.y)) {
        return false;
      }
      p = p.nextZ;
    }
    return true;
  }

  void _indexCurve(_EarNode start, double minX, double minY, double invSize) {
    var p = start;
    int steps = 0;
    do {
      if (++steps > maxDebugSteps) {
        throw StateError('Loop guard hit in _indexCurve.');
      }
      if (p.z == 0) {
        p.z = _zOrder(p.x, p.y, minX, minY, invSize);
      }
      p.prevZ = p.prev;
      p.nextZ = p.next;
      p = p.next!;
    } while (p != start);

    p.prevZ!.nextZ = null;
    p.prevZ = null;
    _sortLinked(p);
  }

  _EarNode _sortLinked(_EarNode list) {
    int inSize = 1;
    int passGuard = 0;
    while (true) {
      if (++passGuard > 64) {
        throw StateError(
            'Loop guard hit in _sortLinked pass count. Possible corrupt z-list.');
      }
      _EarNode? p = list;
      list = _EarNode(0, 0, 0);
      _EarNode tail = list;
      int numMerges = 0;
      int mergeGuard = 0;

      while (p != null) {
        if (++mergeGuard > maxDebugSteps) {
          throw StateError('Loop guard hit in _sortLinked merge loop.');
        }
        numMerges++;
        _EarNode? q = p;
        int pSize = 0;
        for (int i = 0; i < inSize; i++) {
          pSize++;
          q = q!.nextZ;
          if (q == null) break;
        }
        int qSize = inSize;

        while (pSize > 0 || (qSize > 0 && q != null)) {
          _EarNode e;
          if (pSize == 0) {
            e = q!;
            q = q.nextZ;
            qSize--;
          } else if (qSize == 0 || q == null) {
            e = p!;
            p = p.nextZ;
            pSize--;
          } else if (p!.z <= q.z) {
            e = p;
            p = p.nextZ;
            pSize--;
          } else {
            e = q;
            q = q.nextZ;
            qSize--;
          }
          tail.nextZ = e;
          e.prevZ = tail;
          tail = e;
        }
        p = q;
      }

      tail.nextZ = null;
      list = list.nextZ!;
      list.prevZ = null;
      if (numMerges <= 1) return list;
      inSize *= 2;
    }
  }

  int _zOrder(double x, double y, double minX, double minY, double invSize) {
    int ix = ((x - minX) * invSize).toInt();
    int iy = ((y - minY) * invSize).toInt();
    ix = (ix | (ix << 8)) & 0x00FF00FF;
    ix = (ix | (ix << 4)) & 0x0F0F0F0F;
    ix = (ix | (ix << 2)) & 0x33333333;
    ix = (ix | (ix << 1)) & 0x55555555;
    iy = (iy | (iy << 8)) & 0x00FF00FF;
    iy = (iy | (iy << 4)) & 0x0F0F0F0F;
    iy = (iy | (iy << 2)) & 0x33333333;
    iy = (iy | (iy << 1)) & 0x55555555;
    return ix | (iy << 1);
  }

  _EarNode _getLeftmost(_EarNode start) {
    var p = start;
    var leftmost = start;
    int steps = 0;
    do {
      if (++steps > maxDebugSteps) {
        throw StateError('Loop guard hit in _getLeftmost.');
      }
      if (p.x < leftmost.x || (p.x == leftmost.x && p.y < leftmost.y)) {
        leftmost = p;
      }
      p = p.next!;
    } while (p != start);
    return leftmost;
  }

  int _nodeCount(_EarNode start) {
    int count = 0;
    var p = start;
    do {
      count++;
      p = p.next!;
      if (count > 1000000) return count;
    } while (p != start);
    return count;
  }

  double _area(_EarNode a, _EarNode b, _EarNode c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  }

  bool _equals(_EarNode a, _EarNode b) => a.x == b.x && a.y == b.y;

  double _area2(
      double ax, double ay, double bx, double by, double cx, double cy) {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  }

  bool _pointInTriangle(double px, double py, double ax, double ay, double bx,
      double by, double cx, double cy) {
    final ab = _area2(ax, ay, bx, by, px, py);
    final bc = _area2(bx, by, cx, cy, px, py);
    final ca = _area2(cx, cy, ax, ay, px, py);
    final hasNeg = (ab < 0) || (bc < 0) || (ca < 0);
    final hasPos = (ab > 0) || (bc > 0) || (ca > 0);
    return !(hasNeg && hasPos);
  }

  void _rasterizeTriangles(List<double> tris, int color) {
    _maskTouched.clear();
    final total = tris.length ~/ 6;
    for (int i = 0; i < total; i++) {
      final ax = tris[i * 6];
      final ay = tris[i * 6 + 1];
      final bx = tris[i * 6 + 2];
      final by = tris[i * 6 + 3];
      final cx = tris[i * 6 + 4];
      final cy = tris[i * 6 + 5];
      _rasterizeTriangleMask(ax, ay, bx, by, cx, cy);
    }

    for (final idx in _maskTouched) {
      final mask = _sampleMask[idx];
      _sampleMask[idx] = 0;
      if (mask == 0) continue;
      final alpha = _alphaLut[_popcount16(mask)];
      if (alpha == 0) continue;
      final x = idx % width;
      final y = idx ~/ width;
      if (alpha >= 255) {
        _buffer[idx] = color;
      } else {
        _blendPixel(x, y, color, alpha);
      }
    }
  }

  void _rasterizeTriangleMask(
      double ax, double ay, double bx, double by, double cx, double cy) {
    final area = _area2(ax, ay, bx, by, cx, cy);
    if (area == 0) return;

    double minX = math.min(ax, math.min(bx, cx));
    double minY = math.min(ay, math.min(by, cy));
    double maxX = math.max(ax, math.max(bx, cx));
    double maxY = math.max(ay, math.max(by, cy));

    int x0 = minX.floor();
    int y0 = minY.floor();
    int x1 = maxX.ceil();
    int y1 = maxY.ceil();

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > width) x1 = width;
    if (y1 > height) y1 = height;

    final offsets = _sampleOffsets;
    final samplesLen = offsets.length;
    final sampleCount = _sampleCount;
    final maskMax = 1 << sampleCount;

    for (int y = y0; y < y1; y++) {
      for (int x = x0; x < x1; x++) {
        int mask = 0;
        final baseX = x;
        final baseY = y;
        for (int s = 0; s < samplesLen; s += 2) {
          final bit = 1 << (s >> 1);
          final px = baseX + offsets[s];
          final py = baseY + offsets[s + 1];

          final ab = _area2(ax, ay, bx, by, px, py);
          final bc = _area2(bx, by, cx, cy, px, py);
          final ca = _area2(cx, cy, ax, ay, px, py);

          final allPos = ab >= 0 && bc >= 0 && ca >= 0;
          final allNeg = ab <= 0 && bc <= 0 && ca <= 0;
          if (!allPos && !allNeg) continue;

          mask |= bit;
          if (mask == maskMax - 1) break;
        }
        if (mask == 0) continue;
        final idx = y * width + x;
        if (_sampleMask[idx] == 0) {
          _maskTouched.add(idx);
        }
        _sampleMask[idx] |= mask;
      }
    }
  }

  int _popcount16(int v) {
    return _popcount4[v & 0xF] +
        _popcount4[(v >> 4) & 0xF] +
        _popcount4[(v >> 8) & 0xF] +
        _popcount4[(v >> 12) & 0xF];
  }

  void _blendPixel(int x, int y, int foreground, int alpha) {
    final idx = y * width + x;
    final bg = _buffer[idx];
    final fgR = (foreground >> 16) & 0xFF;
    final fgG = (foreground >> 8) & 0xFF;
    final fgB = foreground & 0xFF;
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    final invA = 255 - alpha;
    final r = (fgR * alpha + bgR * invA) ~/ 255;
    final g = (fgG * alpha + bgG * invA) ~/ 255;
    final b = (fgB * alpha + bgB * invA) ~/ 255;

    _buffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  bool _pointInPolygon(double x, double y, List<double> poly, int windingRule) {
    final n = poly.length ~/ 2;
    bool inside = false;
    int winding = 0;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = poly[i * 2];
      final y0 = poly[i * 2 + 1];
      final x1 = poly[j * 2];
      final y1 = poly[j * 2 + 1];
      if ((y0 > y) == (y1 > y)) continue;
      final t = (y - y0) / (y1 - y0);
      final ix = x0 + (x1 - x0) * t;
      if (ix < x) continue;
      if (windingRule == 0) {
        inside = !inside;
      } else {
        winding += y1 > y0 ? 1 : -1;
      }
    }
    return windingRule == 0 ? inside : winding != 0;
  }

  Uint32List get buffer => _buffer;
}

const List<int> _popcount4 = <int>[
  0,
  1,
  1,
  2,
  1,
  2,
  2,
  3,
  1,
  2,
  2,
  3,
  2,
  3,
  3,
  4,
];

class _EarNode {
  final int i;
  final double x;
  final double y;
  _EarNode? prev;
  _EarNode? next;
  _EarNode? prevZ;
  _EarNode? nextZ;
  int z = 0;
  bool steiner = false;

  _EarNode(this.i, this.x, this.y);
}
