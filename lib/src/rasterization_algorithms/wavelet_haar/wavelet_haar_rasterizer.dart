/// ============================================================================
/// WAVELET_HAAR — Wavelet Rasterization (Haar, box-filter)
/// ============================================================================
///
/// Implementação baseada em Wavelet Rasterization (Manson & Schaefer, 2011).
/// Calcula coeficientes de Haar via integrais de contorno (linhas e Bézier
/// quadráticos) e reconstrói a ocupação por quadtree até resolução de pixel.
/// ============================================================================

import 'dart:typed_data';
import 'dart:math' as math;

class WaveletHaarRasterizer {
  final int width;
  final int height;

  final int _gridRes;
  final int _maxDepth;

  final Uint32List _buffer;
  final Float32List _grid;
  final Int32List _xToGrid;
  final Int32List _yToGrid;

  late final _WaveletTree _tree;

  WaveletHaarRasterizer({required this.width, required this.height})
      : _gridRes = _nextPow2(width > height ? width : height),
        _maxDepth = _log2(_nextPow2(width > height ? width : height)) - 1,
        _buffer = Uint32List(width * height),
        _grid = Float32List(_nextPow2(width > height ? width : height) *
            _nextPow2(width > height ? width : height)),
        _xToGrid = Int32List(width),
        _yToGrid = Int32List(height) {
    _tree = _WaveletTree(_maxDepth, _gridRes);
    for (int x = 0; x < width; x++) {
      _xToGrid[x] = (x * _gridRes) ~/ width;
    }
    for (int y = 0; y < height; y++) {
      _yToGrid[y] = (y * _gridRes) ~/ height;
    }
  }

  void clear([int color = 0xFFFFFFFF]) {
    _buffer.fillRange(0, _buffer.length, color);
  }

  void drawPolygon(
    List<double> vertices,
    int color, {
    int windingRule = 1,
    List<int>? contourVertexCounts,
  }) {
    if (vertices.length < 6) return;

    _tree.reset();

    final n = vertices.length ~/ 2;
    final invW = 1.0 / width;
    final invH = 1.0 / height;

    double area2 = 0.0;
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = vertices[i * 2];
      final y0 = vertices[i * 2 + 1];
      final x1 = vertices[j * 2];
      final y1 = vertices[j * 2 + 1];
      area2 += x0 * y1 - y0 * x1;
      if (x0 < minX) minX = x0;
      if (x0 > maxX) maxX = x0;
      if (y0 < minY) minY = y0;
      if (y0 > maxY) maxY = y0;
    }
    final ccw = area2 >= 0.0;

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      if (ccw) {
        final x0 = vertices[i * 2] * invW;
        final y0 = vertices[i * 2 + 1] * invH;
        final x1 = vertices[j * 2] * invW;
        final y1 = vertices[j * 2 + 1] * invH;
        _tree.insertLine(x0, y0, x1, y1);
      } else {
        final x0 = vertices[j * 2] * invW;
        final y0 = vertices[j * 2 + 1] * invH;
        final x1 = vertices[i * 2] * invW;
        final y1 = vertices[i * 2 + 1] * invH;
        _tree.insertLine(x0, y0, x1, y1);
      }
    }

    _grid.fillRange(0, _grid.length, 0);
    _tree.writeGrid(_grid);
    final pxMinX = (minX.floor() - 1).clamp(0, width - 1);
    final pxMaxX = (maxX.ceil() + 1).clamp(0, width - 1);
    final pxMinY = (minY.floor() - 1).clamp(0, height - 1);
    final pxMaxY = (maxY.ceil() + 1).clamp(0, height - 1);
    _rasterizeGridToBuffer(color, pxMinX, pxMaxX, pxMinY, pxMaxY);
  }

  /// Rasteriza uma curva Bézier quadrática (p0, p1, p2)
  void drawQuadraticBezier(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    int color,
  ) {
    _tree.reset();

    final invW = 1.0 / width;
    final invH = 1.0 / height;

    _tree.insertQuadraticBezier(
      x0 * invW,
      y0 * invH,
      x1 * invW,
      y1 * invH,
      x2 * invW,
      y2 * invH,
    );

    _grid.fillRange(0, _grid.length, 0);
    _tree.writeGrid(_grid);
    _rasterizeGridToBuffer(color, 0, width - 1, 0, height - 1);
  }

  /// Rasteriza uma lista de curvas Bézier quadráticas.
  /// Espera uma lista com múltiplos de 6: [x0,y0,x1,y1,x2,y2, ...]
  void drawQuadraticBezierPath(List<double> controls, int color) {
    if (controls.length < 6) return;
    if (controls.length % 6 != 0) return;

    _tree.reset();

    final invW = 1.0 / width;
    final invH = 1.0 / height;

    for (int i = 0; i < controls.length; i += 6) {
      _tree.insertQuadraticBezier(
        controls[i] * invW,
        controls[i + 1] * invH,
        controls[i + 2] * invW,
        controls[i + 3] * invH,
        controls[i + 4] * invW,
        controls[i + 5] * invH,
      );
    }

    _grid.fillRange(0, _grid.length, 0);
    _tree.writeGrid(_grid);
    _rasterizeGridToBuffer(color, 0, width - 1, 0, height - 1);
  }

  void _rasterizeGridToBuffer(
      int color, int minX, int maxX, int minY, int maxY) {
    final fgR = (color >> 16) & 0xFF;
    final fgG = (color >> 8) & 0xFF;
    final fgB = color & 0xFF;

    for (int y = minY; y <= maxY; y++) {
      final gridRow = _yToGrid[y] * _gridRes;
      int row = y * width + minX;
      for (int x = minX; x <= maxX; x++) {
        final val = _grid[gridRow + _xToGrid[x]];
        if (val <= 0.0) {
          row++;
          continue;
        }
        if (val >= 1.0) {
          _buffer[row] = color;
          row++;
          continue;
        }
        final alpha = (val * 255).round();
        _blendPixelIndexRgb(row, color, fgR, fgG, fgB, alpha);
        row++;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _blendPixelIndexRgb(
      int idx, int foreground, int fgR, int fgG, int fgB, int alpha) {
    if (alpha >= 255) {
      _buffer[idx] = foreground;
      return;
    }

    final bg = _buffer[idx];
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;

    final invA = 255 - alpha;
    final r = (fgR * alpha + bgR * invA) ~/ 255;
    final g = (fgG * alpha + bgG * invA) ~/ 255;
    final b = (fgB * alpha + bgB * invA) ~/ 255;

    _buffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  Uint32List get buffer => _buffer;
}

class _WaveletTree {
  final int maxDepth;
  final int gridRes;

  double coeffConst = 0.0;

  final _NodePool _nodes;
  final _LeafPool _leaves;

  late int _root;

  _WaveletTree(this.maxDepth, this.gridRes)
      : _nodes = _NodePool(1024),
        _leaves = _LeafPool(1024) {
    _root = _nodes.alloc();
  }

  void reset() {
    coeffConst = 0.0;
    _nodes.reset();
    _leaves.reset();
    _root = _nodes.alloc();
  }

  void insertLine(double x0, double y0, double x1, double y1) {
    coeffConst += (x0 * y1 - y0 * x1) * 0.5;
    _insertLine(_root, _Line(x0, y0, x1, y1), 0);
  }

  void insertQuadraticBezier(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
  ) {
    coeffConst += -((2 * y1 * x2 +
                y0 * (2 * x1 + x2) -
                2 * x1 * y2 -
                x0 * (2 * y1 + y2)) /
            3.0) *
        0.5;
    _insertBez2Split(_root, _Bez2(x0, y0, x1, y1, x2, y2), 0);
  }

  void _insertLine(int node, _Line p, int depth) {
    var curNode = node;
    var curDepth = depth;
    var line = p;

    while (true) {
      final i = line.x0 < 0.5 ? 0 : 1;
      final j = line.y0 < 0.5 ? 0 : 1;
      final ij = (j << 1) | i;

      final ni = line.x1 < 0.5 ? 0 : 1;
      final nj = line.y1 < 0.5 ? 0 : 1;
      final nij = (nj << 1) | ni;

      if (ij != nij) {
        _insertLineSplit(curNode, line, curDepth);
        return;
      }

      line = _Line(
        line.x0 * 2 - i,
        line.y0 * 2 - j,
        line.x1 * 2 - i,
        line.y1 * 2 - j,
      );

      _calcCoeffsLineNode(curNode, line, i, j);

      if (curDepth < maxDepth - 1) {
        final child = _nodes.getOrCreateChild(curNode, ij);
        curNode = child;
        curDepth++;
      } else {
        final leaf = _nodes.getOrCreateLeaf(curNode, ij, _leaves);
        _insertLineLeaf(leaf, line);
        return;
      }
    }
  }

  void _insertLineSplit(int node, _Line p, int depth) {
    final scaled = _Line(p.x0 * 2, p.y0 * 2, p.x1 * 2, p.y1 * 2);

    final s = List<_Line>.generate(4, (_) => _Line(0, 0, 0, 0));
    final sin = List<bool>.filled(4, false);
    final x = List<_Line>.generate(2, (_) => _Line(0, 0, 0, 0));
    final xin = List<bool>.filled(2, false);

    _splitLine(scaled, x[0], x[1], xin, 0);
    for (int i = 0; i < 2; i++) {
      if (!xin[i]) continue;
      _splitLine(x[i], s[i], s[i + 2], sin, 1, i);

      for (int j = 0; j < 2; j++) {
        final ij = i + j * 2;
        if (!sin[ij]) continue;

        _calcCoeffsLineNode(node, s[ij], i, j);

        if (depth < maxDepth - 1) {
          final child = _nodes.getOrCreateChild(node, ij);
          _insertLine(child, s[ij], depth + 1);
        } else {
          final leaf = _nodes.getOrCreateLeaf(node, ij, _leaves);
          _insertLineLeaf(leaf, s[ij]);
        }
      }
    }
  }

  void _insertLineLeaf(int leaf, _Line p) {
    final i = p.x0 < 0.5 ? 0 : 1;
    final j = p.y0 < 0.5 ? 0 : 1;

    final ni = p.x1 < 0.5 ? 0 : 1;
    final nj = p.y1 < 0.5 ? 0 : 1;
    if (i != ni || j != nj) {
      _insertLineSplitLeaf(leaf, p);
      return;
    }

    final mapped = _Line(
      p.x0 * 2 - i,
      p.y0 * 2 - j,
      p.x1 * 2 - i,
      p.y1 * 2 - j,
    );

    _calcCoeffsLineLeaf(leaf, mapped, i, j);
  }

  void _insertLineSplitLeaf(int leaf, _Line p) {
    final scaled = _Line(p.x0 * 2, p.y0 * 2, p.x1 * 2, p.y1 * 2);

    final s = List<_Line>.generate(4, (_) => _Line(0, 0, 0, 0));
    final sin = List<bool>.filled(4, false);
    final x = List<_Line>.generate(2, (_) => _Line(0, 0, 0, 0));
    final xin = List<bool>.filled(2, false);

    _splitLine(scaled, x[0], x[1], xin, 0);
    for (int i = 0; i < 2; i++) {
      if (!xin[i]) continue;
      _splitLine(x[i], s[i], s[i + 2], sin, 1, i);

      for (int j = 0; j < 2; j++) {
        final ij = i + j * 2;
        if (!sin[ij]) continue;

        _calcCoeffsLineLeaf(leaf, s[ij], i, j);
      }
    }
  }

  void _insertBez2Split(int node, _Bez2 p, int depth) {
    final scaled = p.scaled(2.0);

    final s = List<List<_Bez2>>.generate(4, (_) => <_Bez2>[]);
    final x = List<List<_Bez2>>.generate(2, (_) => <_Bez2>[]);

    _splitBez2(scaled, x[0], x[1], 0);
    for (int i = 0; i < 2; i++) {
      for (int ci = 0; ci < x[i].length; ci++) {
        _splitBez2(x[i][ci], s[i], s[i + 2], 1);

        for (int j = 0; j < 2; j++) {
          final ij = i + j * 2;
          for (int cj = 0; cj < s[ij].length; cj++) {
            _calcCoeffsBez2Node(node, s[ij][cj], i, j);

            if (depth < maxDepth - 1) {
              final child = _nodes.getOrCreateChild(node, ij);
              _insertBez2Split(child, s[ij][cj], depth + 1);
            } else {
              final leaf = _nodes.getOrCreateLeaf(node, ij, _leaves);
              _insertBez2SplitLeaf(leaf, s[ij][cj]);
            }
          }
        }
      }
    }
  }

  void _insertBez2SplitLeaf(int leaf, _Bez2 p) {
    final scaled = p.scaled(2.0);

    final s = List<List<_Bez2>>.generate(4, (_) => <_Bez2>[]);
    final x = List<List<_Bez2>>.generate(2, (_) => <_Bez2>[]);

    _splitBez2(scaled, x[0], x[1], 0);
    for (int i = 0; i < 2; i++) {
      for (int ci = 0; ci < x[i].length; ci++) {
        _splitBez2(x[i][ci], s[i], s[i + 2], 1);

        for (int j = 0; j < 2; j++) {
          final ij = i + j * 2;
          for (int cj = 0; cj < s[ij].length; cj++) {
            _calcCoeffsBez2Leaf(leaf, s[ij][cj], i, j);
          }
        }
      }
    }
  }

  void _splitLine(
    _Line p,
    _Line a,
    _Line b,
    List<bool> flags,
    int dir, [
    int iOffset = 0,
  ]) {
    final xp = dir == 0 ? p.x0 : p.y0;
    final x = dir == 0 ? p.x1 : p.y1;

    final inp = xp < 1.0;
    final inn = x < 1.0;

    final sel = (inp ? 2 : 0) + (inn ? 1 : 0);

    bool ina = false;
    bool inb = false;

    if (sel == 3) {
      ina = true;
      inb = false;
      a.set(p);
    } else if (sel == 2 || sel == 1) {
      final div = x - xp;
      var t = (1 - xp) / div;
      if (t < 0 || t > 1) t = 0.5;

      final mx = dir == 0 ? 1.0 : (p.x1 - p.x0) * t + p.x0;
      final my = dir == 1 ? 1.0 : (p.y1 - p.y0) * t + p.y0;

      ina = true;
      inb = true;

      if (sel == 2) {
        a.setXY(p.x0, p.y0, mx, my);
        b.setXY(mx, my, p.x1, p.y1);
      } else {
        b.setXY(p.x0, p.y0, mx, my);
        a.setXY(mx, my, p.x1, p.y1);
      }
    } else {
      ina = false;
      inb = true;
      b.set(p);
    }

    if (flags.length == 2) {
      flags[0] = ina;
      flags[1] = inb;
    } else {
      flags[iOffset] = ina;
      flags[iOffset + 2] = inb;
    }

    if (inb) {
      if (dir == 0) {
        b.x0 -= 1.0;
        b.x1 -= 1.0;
      } else {
        b.y0 -= 1.0;
        b.y1 -= 1.0;
      }
    }
  }

  void _splitBez2(_Bez2 curve, List<_Bez2> segs1, List<_Bez2> segs2, int dir) {
    segs1.clear();
    segs2.clear();

    final tvals = <double>[];
    _findRootsBez2(curve, tvals, dir);

    if (tvals.isEmpty) {
      if (curve.get(dir, 0) < 1.0) {
        segs1.add(curve);
      } else {
        segs2.add(curve);
      }
    } else if (tvals.length == 1) {
      final t = tvals[0];
      final cut = curve.cut(t);
      if (curve.get(dir, 0) < 1.0) {
        segs1.add(cut.a);
        segs2.add(cut.b);
      } else {
        segs2.add(cut.a);
        segs1.add(cut.b);
      }
    } else {
      final t0 = tvals[0];
      final t1 = tvals[1];
      if (curve.get(dir, 0) < 1.0) {
        final cut1 = curve.cut(t1);
        final cut0 = cut1.a.cut(t0 / t1);
        segs1.add(cut0.a);
        segs2.add(cut0.b);
        segs1.add(cut1.b);
      } else {
        final cut1 = curve.cut(t1);
        final cut0 = cut1.a.cut(t0 / t1);
        segs2.add(cut0.a);
        segs1.add(cut0.b);
        segs2.add(cut1.b);
      }
    }

    for (int i = 0; i < segs2.length; i++) {
      segs2[i] = segs2[i].shift(dir, -1.0);
    }
  }

  void _findRootsBez2(_Bez2 curve, List<double> tvals, int dir) {
    final a = curve.get(dir, 0) - 1.0;
    final b = curve.get(dir, 1) - 1.0;
    final c = curve.get(dir, 2) - 1.0;

    final A = a - 2 * b + c;
    final B = 2 * (b - a);
    final C = a;

    if (A.abs() < 1e-9) {
      if (B.abs() < 1e-9) return;
      final t = -C / B;
      if (t > 0 && t < 1) tvals.add(t);
    } else {
      final disc = B * B - 4 * A * C;
      if (disc < 0) return;
      final root = math.sqrt(disc);
      final t0 = (-B - root) / (2 * A);
      final t1 = (-B + root) / (2 * A);
      if (t0 > 0 && t0 < 1) tvals.add(t0);
      if (t1 > 0 && t1 < 1) tvals.add(t1);
      if (tvals.length > 1 && tvals[0] > tvals[1]) {
        final tmp = tvals[0];
        tvals[0] = tvals[1];
        tvals[1] = tmp;
      }
    }
  }

  void _calcCoeffsLineNode(int node, _Line p, int i, int j) {
    final norm0 = (p.y1 - p.y0) * 0.125;
    final norm1 = (p.x0 - p.x1) * 0.125;
    final lin0 = p.x0 + p.x1;
    final lin1 = p.y0 + p.y1;

    final base = node * 3;

    if (i == 0) {
      if (j == 0) {
        _nodes.coeffs[base] += lin0 * norm0;
        _nodes.coeffs[base + 2] += lin0 * norm0;
        _nodes.coeffs[base + 1] += lin1 * norm1;
      } else {
        _nodes.coeffs[base] += lin0 * norm0;
        _nodes.coeffs[base + 2] -= lin0 * norm0;
        _nodes.coeffs[base + 1] += (2 - lin1) * norm1;
      }
    } else {
      if (j == 0) {
        _nodes.coeffs[base] += (2 - lin0) * norm0;
        _nodes.coeffs[base + 2] += (2 - lin0) * norm0;
        _nodes.coeffs[base + 1] += lin1 * norm1;
      } else {
        _nodes.coeffs[base] += (2 - lin0) * norm0;
        _nodes.coeffs[base + 2] -= (2 - lin0) * norm0;
        _nodes.coeffs[base + 1] += (2 - lin1) * norm1;
      }
    }

    _nodes.boundary[node * 4 + (i + j * 2)] = 1;
  }

  void _calcCoeffsLineLeaf(int leaf, _Line p, int i, int j) {
    final norm0 = (p.y1 - p.y0) * 0.125;
    final norm1 = (p.x0 - p.x1) * 0.125;
    final lin0 = p.x0 + p.x1;
    final lin1 = p.y0 + p.y1;

    final base = leaf * 3;

    if (i == 0) {
      if (j == 0) {
        _leaves.coeffs[base] += lin0 * norm0;
        _leaves.coeffs[base + 2] += lin0 * norm0;
        _leaves.coeffs[base + 1] += lin1 * norm1;
      } else {
        _leaves.coeffs[base] += lin0 * norm0;
        _leaves.coeffs[base + 2] -= lin0 * norm0;
        _leaves.coeffs[base + 1] += (2 - lin1) * norm1;
      }
    } else {
      if (j == 0) {
        _leaves.coeffs[base] += (2 - lin0) * norm0;
        _leaves.coeffs[base + 2] += (2 - lin0) * norm0;
        _leaves.coeffs[base + 1] += lin1 * norm1;
      } else {
        _leaves.coeffs[base] += (2 - lin0) * norm0;
        _leaves.coeffs[base + 2] -= (2 - lin0) * norm0;
        _leaves.coeffs[base + 1] += (2 - lin1) * norm1;
      }
    }

    _leaves.boundary[leaf * 4 + (i + j * 2)] = 1;
  }

  void _calcCoeffsBez2Node(int node, _Bez2 p, int i, int j) {
    final base = node * 3;
    final coeffs = _calcCoeffsBez2(p, i, j);
    _nodes.coeffs[base] += coeffs[0];
    _nodes.coeffs[base + 1] += coeffs[1];
    _nodes.coeffs[base + 2] += coeffs[2];
    _nodes.boundary[node * 4 + (i + j * 2)] = 1;
  }

  void _calcCoeffsBez2Leaf(int leaf, _Bez2 p, int i, int j) {
    final base = leaf * 3;
    final coeffs = _calcCoeffsBez2(p, i, j);
    _leaves.coeffs[base] += coeffs[0];
    _leaves.coeffs[base + 1] += coeffs[1];
    _leaves.coeffs[base + 2] += coeffs[2];
    _leaves.boundary[leaf * 4 + (i + j * 2)] = 1;
  }

  Float64List _calcCoeffsBez2(_Bez2 p, int i, int j) {
    final p00 = p.x0;
    final p01 = p.y0;
    final p10 = p.x1;
    final p11 = p.y1;
    final p20 = p.x2;
    final p21 = p.y2;

    double c10;
    if (i == 0) {
      c10 = (3 * p01 - 2 * p11) * p00 +
          2 * p01 * p10 +
          (p01 + 2 * p11) * p20 -
          (p00 + 2 * p10 + 3 * p20) * p21;
    } else {
      c10 = 2 * p11 * (p00 - p20) -
          p01 * (-6 + 3 * p00 + 2 * p10 + p20) +
          (-6 + p00 + 2 * p10 + 3 * p20) * p21;
    }

    double c01;
    if (j == 0) {
      c01 = 2 * p11 * p20 +
          p01 * (2 * p10 + p20) +
          (-2 * p10 + 3 * p20) * p21 -
          p00 * (3 * p01 + 2 * p11 + p21);
    } else {
      c01 = -(p01 * (2 * p10 + p20)) +
          p20 * (6 - 2 * p11 - 3 * p21) +
          2 * p10 * p21 +
          p00 * (-6 + 3 * p01 + 2 * p11 + p21);
    }

    double c11;
    if (i == 0) {
      if (j == 0) {
        c11 = 3 * p00 * p01 +
            2 * p01 * p10 -
            2 * p00 * p11 +
            (p01 + 2 * p11) * p20 -
            (p00 + 2 * p10 + 3 * p20) * p21;
      } else {
        c11 = -2 * p11 * p20 -
            p01 * (2 * p10 + p20) +
            (2 * p10 + 3 * p20) * p21 +
            p00 * (-3 * p01 + 2 * p11 + p21);
      }
    } else {
      if (j == 0) {
        c11 = 2 * p11 * (p00 - p20) -
            p01 * (-6 + 3 * p00 + 2 * p10 + p20) +
            (-6 + p00 + 2 * p10 + 3 * p20) * p21;
      } else {
        c11 = 2 * p11 * (-p00 + p20) +
            p01 * (-6 + 3 * p00 + 2 * p10 + p20) -
            (-6 + p00 + 2 * p10 + 3 * p20) * p21;
      }
    }

    final res = Float64List(3);
    res[0] = c10 * -0.04166666666666;
    res[1] = c01 * -0.04166666666666;
    res[2] = c11 * -0.04166666666666;
    return res;
  }

  void writeGrid(Float32List grid) {
    _writeNode(_root, coeffConst, 0, 0, gridRes, grid);
  }

  void _writeNode(
      int node, double val, int offX, int offY, int res, Float32List grid) {
    final base = node * 3;
    final c0 = val +
        _nodes.coeffs[base] +
        _nodes.coeffs[base + 1] +
        _nodes.coeffs[base + 2];
    final c1 = val -
        _nodes.coeffs[base] +
        _nodes.coeffs[base + 1] -
        _nodes.coeffs[base + 2];
    final c2 = val +
        _nodes.coeffs[base] -
        _nodes.coeffs[base + 1] -
        _nodes.coeffs[base + 2];
    final c3 = val -
        _nodes.coeffs[base] -
        _nodes.coeffs[base + 1] +
        _nodes.coeffs[base + 2];

    final cvals0 = c0;
    final cvals1 = c1;
    final cvals2 = c2;
    final cvals3 = c3;

    final res2 = res >> 1;

    for (int k = 0; k < 4; k++) {
      final x = k & 1;
      final y = (k >> 1) & 1;

      final childOffX = offX + x * res2;
      final childOffY = offY + y * res2;

      final child = _nodes.children[node * 4 + k];
      final cval =
          k == 0 ? cvals0 : (k == 1 ? cvals1 : (k == 2 ? cvals2 : cvals3));

      if (child < 0) {
        if (_nodes.boundary[node * 4 + k] != 0) {
          _writeValue(cval, childOffX, childOffY, res2, grid);
        } else if (cval > 0.5) {
          _writeValue(1.0, childOffX, childOffY, res2, grid);
        }
      } else if (res > 4) {
        _writeNode(child, cval, childOffX, childOffY, res2, grid);
      } else {
        _writeLeaf(child, cval, childOffX, childOffY, res2, grid);
      }
    }
  }

  void _writeLeaf(
      int leaf, double val, int offX, int offY, int res, Float32List grid) {
    final base = leaf * 3;
    final c0 = val +
        _leaves.coeffs[base] +
        _leaves.coeffs[base + 1] +
        _leaves.coeffs[base + 2];
    final c1 = val -
        _leaves.coeffs[base] +
        _leaves.coeffs[base + 1] -
        _leaves.coeffs[base + 2];
    final c2 = val +
        _leaves.coeffs[base] -
        _leaves.coeffs[base + 1] -
        _leaves.coeffs[base + 2];
    final c3 = val -
        _leaves.coeffs[base] -
        _leaves.coeffs[base + 1] +
        _leaves.coeffs[base + 2];

    final cvals0 = c0;
    final cvals1 = c1;
    final cvals2 = c2;
    final cvals3 = c3;

    for (int k = 0; k < 4; k++) {
      final x = k & 1;
      final y = (k >> 1) & 1;

      final idx = (offY + y) * gridRes + (offX + x);
      final cval =
          k == 0 ? cvals0 : (k == 1 ? cvals1 : (k == 2 ? cvals2 : cvals3));

      if (_leaves.boundary[leaf * 4 + k] != 0) {
        grid[idx] = cval;
      } else if (cval > 0.5) {
        grid[idx] = 1.0;
      }
    }
  }

  void _writeValue(double val, int offX, int offY, int res, Float32List grid) {
    for (int y = offY; y < offY + res; y++) {
      final row = y * gridRes;
      for (int x = offX; x < offX + res; x++) {
        grid[row + x] = val;
      }
    }
  }
}

class _Line {
  double x0;
  double y0;
  double x1;
  double y1;

  _Line(this.x0, this.y0, this.x1, this.y1);

  void set(_Line o) {
    x0 = o.x0;
    y0 = o.y0;
    x1 = o.x1;
    y1 = o.y1;
  }

  void setXY(double ax0, double ay0, double ax1, double ay1) {
    x0 = ax0;
    y0 = ay0;
    x1 = ax1;
    y1 = ay1;
  }
}

class _Bez2 {
  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const _Bez2(this.x0, this.y0, this.x1, this.y1, this.x2, this.y2);

  double get(int dir, int idx) {
    if (idx == 0) return dir == 0 ? x0 : y0;
    if (idx == 1) return dir == 0 ? x1 : y1;
    return dir == 0 ? x2 : y2;
  }

  _Bez2 scaled(double s) {
    return _Bez2(x0 * s, y0 * s, x1 * s, y1 * s, x2 * s, y2 * s);
  }

  _Bez2 shift(int dir, double delta) {
    if (dir == 0) {
      return _Bez2(x0 + delta, y0, x1 + delta, y1, x2 + delta, y2);
    }
    return _Bez2(x0, y0 + delta, x1, y1 + delta, x2, y2 + delta);
  }

  _Bez2Cut cut(double t) {
    final t1 = 1.0 - t;
    final a1x = x0 * t1 + x1 * t;
    final a1y = y0 * t1 + y1 * t;
    final b1x = x1 * t1 + x2 * t;
    final b1y = y1 * t1 + y2 * t;

    final a2x = a1x * t1 + b1x * t;
    final a2y = a1y * t1 + b1y * t;

    final a = _Bez2(x0, y0, a1x, a1y, a2x, a2y);
    final b = _Bez2(a2x, a2y, b1x, b1y, x2, y2);
    return _Bez2Cut(a, b);
  }
}

class _Bez2Cut {
  final _Bez2 a;
  final _Bez2 b;
  const _Bez2Cut(this.a, this.b);
}

class _NodePool {
  int _capacity;
  int count = 0;

  late Int32List children;
  late Float64List coeffs;
  late Uint8List boundary;

  _NodePool(int capacity) : _capacity = capacity {
    children = Int32List(_capacity * 4);
    coeffs = Float64List(_capacity * 3);
    boundary = Uint8List(_capacity * 4);
    for (int i = 0; i < children.length; i++) {
      children[i] = -1;
    }
  }

  void reset() {
    count = 0;
  }

  int alloc() {
    if (count >= _capacity) {
      _grow();
    }
    final idx = count++;
    final cBase = idx * 4;
    children[cBase] = -1;
    children[cBase + 1] = -1;
    children[cBase + 2] = -1;
    children[cBase + 3] = -1;

    final bBase = idx * 4;
    boundary[bBase] = 0;
    boundary[bBase + 1] = 0;
    boundary[bBase + 2] = 0;
    boundary[bBase + 3] = 0;

    final coeffBase = idx * 3;
    coeffs[coeffBase] = 0;
    coeffs[coeffBase + 1] = 0;
    coeffs[coeffBase + 2] = 0;

    return idx;
  }

  int getOrCreateChild(int node, int childIndex) {
    final idx = node * 4 + childIndex;
    var child = children[idx];
    if (child < 0) {
      child = alloc();
      children[idx] = child;
    }
    return child;
  }

  int getOrCreateLeaf(int node, int childIndex, _LeafPool leaves) {
    final idx = node * 4 + childIndex;
    var child = children[idx];
    if (child < 0) {
      child = leaves.alloc();
      children[idx] = child;
    }
    return child;
  }

  void _grow() {
    final newCap = _capacity * 2;
    final newChildren = Int32List(newCap * 4);
    final newCoeffs = Float64List(newCap * 3);
    final newBoundary = Uint8List(newCap * 4);

    newChildren.setAll(0, children);
    newCoeffs.setAll(0, coeffs);
    newBoundary.setAll(0, boundary);

    for (int i = children.length; i < newChildren.length; i++) {
      newChildren[i] = -1;
    }

    children = newChildren;
    coeffs = newCoeffs;
    boundary = newBoundary;
    _capacity = newCap;
  }
}

class _LeafPool {
  int _capacity;
  int count = 0;

  late Float64List coeffs;
  late Uint8List boundary;

  _LeafPool(int capacity) : _capacity = capacity {
    coeffs = Float64List(_capacity * 3);
    boundary = Uint8List(_capacity * 4);
  }

  void reset() {
    count = 0;
  }

  int alloc() {
    if (count >= _capacity) {
      _grow();
    }
    final idx = count++;

    final bBase = idx * 4;
    boundary[bBase] = 0;
    boundary[bBase + 1] = 0;
    boundary[bBase + 2] = 0;
    boundary[bBase + 3] = 0;

    final coeffBase = idx * 3;
    coeffs[coeffBase] = 0;
    coeffs[coeffBase + 1] = 0;
    coeffs[coeffBase + 2] = 0;

    return idx;
  }

  void _grow() {
    final newCap = _capacity * 2;
    final newCoeffs = Float64List(newCap * 3);
    final newBoundary = Uint8List(newCap * 4);

    newCoeffs.setAll(0, coeffs);
    newBoundary.setAll(0, boundary);

    coeffs = newCoeffs;
    boundary = newBoundary;
    _capacity = newCap;
  }
}

int _nextPow2(int v) {
  var p = 1;
  while (p < v) {
    p <<= 1;
  }
  return p;
}

int _log2(int v) {
  var r = 0;
  var x = v;
  while (x > 1) {
    x >>= 1;
    r++;
  }
  return r;
}
