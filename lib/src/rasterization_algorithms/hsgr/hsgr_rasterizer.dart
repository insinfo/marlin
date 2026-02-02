/// ============================================================================
/// HSGR — Hilbert-Space Guided Rasterization
/// ============================================================================
///
/// Percorre pixels em ordem Hilbert para maior localidade de cache.
/// Para AA: usa distâncias assinadas às arestas e mistura racional.
///
/// Inclui:
/// - drawTriangle()
/// - drawPolygon() com triangulação (ear clipping) para polígonos simples
///
/// ============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

/// Função de borda incremental (Ax + By + C)
class EdgeFunction {
  final double a, b, c;
  final double deltaX;
  final double deltaY;
  final double normalLength;

  EdgeFunction._(this.a, this.b, this.c)
      : deltaX = a,
        deltaY = b,
        normalLength = math.sqrt(a * a + b * b);

  factory EdgeFunction.fromPoints(double x1, double y1, double x2, double y2) {
    // edge(x,y) = (y1 - y2)x + (x2 - x1)y + (x1*y2 - x2*y1)
    final a = (y1 - y2);
    final b = (x2 - x1);
    final c = (x1 * y2 - x2 * y1);
    return EdgeFunction._(a, b, c);
  }

  double evaluate(double x, double y) => a * x + b * y + c;
}

/// Curva de Hilbert (ordem N => size = 2^N)
class HilbertCurve {
  final int order;
  final int size;

  HilbertCurve(this.order) : size = 1 << order;

  /// Itera todos os pontos (x,y) em [0..size) em ordem Hilbert.
  /// Implementação via mapeamento índice->(x,y) (d2xy), sem recursão.
  Iterable<List<int>> points() sync* {
    final n = size;
    final total = n * n;
    for (int d = 0; d < total; d++) {
      yield _d2xy(n, d);
    }
  }

  static List<int> _d2xy(int n, int d) {
    int t = d;
    int x = 0;
    int y = 0;

    for (int s = 1; s < n; s <<= 1) {
      final rx = 1 & (t >> 1);
      final ry = 1 & (t ^ rx);

      final rotated = _rot(s, x, y, rx, ry);
      x = rotated[0];
      y = rotated[1];

      x += s * rx;
      y += s * ry;

      t >>= 2;
    }

    return [x, y];
  }

  static List<int> _rot(int s, int x, int y, int rx, int ry) {
    if (ry == 0) {
      if (rx == 1) {
        x = s - 1 - x;
        y = s - 1 - y;
      }
      // swap x,y
      final t = x;
      x = y;
      y = t;
    }
    return [x, y];
  }
}

/// Função de cobertura racional
double computeRationalCoverage(
  List<double> signedDistances, {
  double k = 2.0,
  double m = 2.0,
}) {
  double coverage = 1.0;

  for (final d in signedDistances) {
    final absD = d.abs().clamp(0.0, 10.0);
    final kd = k * absD;
    final kdm = math.pow(kd, m);
    final weight = 1.0 / (1.0 + kdm);
    coverage *= weight;
  }

  return coverage;
}

// ─────────────────────────────────────────────────────────────────────────────
// TRIANGULAÇÃO (EAR CLIPPING) PARA POLÍGONOS SIMPLES
// ─────────────────────────────────────────────────────────────────────────────

class _P {
  final double x;
  final double y;
  const _P(this.x, this.y);
}

double _cross(_P a, _P b, _P c) {
  final abx = b.x - a.x;
  final aby = b.y - a.y;
  final acx = c.x - a.x;
  final acy = c.y - a.y;
  return abx * acy - aby * acx;
}

double _signedArea(List<_P> pts) {
  double s = 0.0;
  for (int i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    s += (pts[j].x * pts[i].y) - (pts[i].x * pts[j].y);
  }
  return s * 0.5;
}

bool _pointInTriangle(_P p, _P a, _P b, _P c) {
  final s1 = _cross(a, b, p);
  final s2 = _cross(b, c, p);
  final s3 = _cross(c, a, p);

  final hasNeg = (s1 < 0) || (s2 < 0) || (s3 < 0);
  final hasPos = (s1 > 0) || (s2 > 0) || (s3 > 0);
  return !(hasNeg && hasPos);
}

List<List<double>> _triangulateEarClipping(List<double> vertices) {
  if (vertices.length < 6 || (vertices.length & 1) == 1) return const [];

  var pts = <_P>[];
  for (int i = 0; i < vertices.length; i += 2) {
    pts.add(_P(vertices[i], vertices[i + 1]));
  }

  // remove último se repetir o primeiro
  if (pts.length >= 2) {
    final first = pts.first;
    final last = pts.last;
    if ((first.x == last.x) && (first.y == last.y)) {
      pts.removeLast();
    }
  }

  if (pts.length < 3) return const [];

  // garantir CCW
  if (_signedArea(pts) < 0) {
    pts = pts.reversed.toList(); // <- correção: não existe pts.reverse()
  }

  final idx = List<int>.generate(pts.length, (i) => i);
  final triangles = <List<double>>[];

  const eps = 1e-12;

  int guard = 0;
  while (idx.length > 3 && guard++ < 10000) {
    bool earFound = false;

    for (int i = 0; i < idx.length; i++) {
      final iPrev = idx[(i - 1 + idx.length) % idx.length];
      final iCurr = idx[i];
      final iNext = idx[(i + 1) % idx.length];

      final pPrev = pts[iPrev];
      final pCurr = pts[iCurr];
      final pNext = pts[iNext];

      // convexidade (para CCW deve ser > 0)
      final crossVal = (pNext.x - pCurr.x) * (pPrev.y - pCurr.y) -
          (pNext.y - pCurr.y) * (pPrev.x - pCurr.x);

      if (crossVal <= eps) continue;

      bool hasPointInside = false;
      for (int j = 0; j < idx.length; j++) {
        final iTest = idx[j];
        if (iTest == iPrev || iTest == iCurr || iTest == iNext) continue;

        if (_pointInTriangle(pts[iTest], pPrev, pCurr, pNext)) {
          hasPointInside = true;
          break;
        }
      }
      if (hasPointInside) continue;

      // é uma orelha
      triangles.add([
        pPrev.x, pPrev.y,
        pCurr.x, pCurr.y,
        pNext.x, pNext.y,
      ]);
      idx.removeAt(i);
      earFound = true;
      break;
    }

    // fallback: fan triangulation
    if (!earFound) {
      for (int i = 1; i + 1 < idx.length; i++) {
        final p0 = pts[idx[0]];
        final p1 = pts[idx[i]];
        final p2 = pts[idx[i + 1]];
        triangles.add([p0.x, p0.y, p1.x, p1.y, p2.x, p2.y]);
      }
      return triangles;
    }
  }

  if (idx.length == 3) {
    final p0 = pts[idx[0]];
    final p1 = pts[idx[1]];
    final p2 = pts[idx[2]];
    triangles.add([p0.x, p0.y, p1.x, p1.y, p2.x, p2.y]);
  }

  return triangles;
}

// ─────────────────────────────────────────────────────────────────────────────
// RASTERIZADOR HSGR
// ─────────────────────────────────────────────────────────────────────────────

class HSGRRasterizer {
  final int width;
  final int height;

  late final Uint32List _buffer;

  HSGRRasterizer({required this.width, required this.height}) {
    _buffer = Uint32List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _buffer.fillRange(0, _buffer.length, backgroundColor);
  }

  Uint32List get buffer => _buffer;

  /// Desenha um polígono via triangulação (ear clipping).
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;

    if (vertices.length == 6) {
      drawTriangle(
        vertices[0], vertices[1],
        vertices[2], vertices[3],
        vertices[4], vertices[5],
        color,
      );
      return;
    }

    final tris = _triangulateEarClipping(vertices);
    for (final t in tris) {
      drawTriangle(
        t[0], t[1],
        t[2], t[3],
        t[4], t[5],
        color,
      );
    }
  }

  /// Desenha um triângulo usando traversal Hilbert
  void drawTriangle(
    double x1, double y1,
    double x2, double y2,
    double x3, double y3,
    int color,
  ) {
    final minX = math.min(x1, math.min(x2, x3)).floor().clamp(0, width - 1);
    final maxX = math.max(x1, math.max(x2, x3)).ceil().clamp(0, width - 1);
    final minY = math.min(y1, math.min(y2, y3)).floor().clamp(0, height - 1);
    final maxY = math.max(y1, math.max(y2, y3)).ceil().clamp(0, height - 1);

    final bboxWidth = maxX - minX + 1;
    final bboxHeight = maxY - minY + 1;
    final bboxSize = math.max(bboxWidth, bboxHeight);

    // order = ceil(log2(bboxSize))
    final order =
        (math.log(bboxSize) / math.ln2).ceil().clamp(1, 10);
    final hilbert = HilbertCurve(order);

    final edges = [
      EdgeFunction.fromPoints(x1, y1, x2, y2),
      EdgeFunction.fromPoints(x2, y2, x3, y3),
      EdgeFunction.fromPoints(x3, y3, x1, y1),
    ];

    final normalLengths = edges.map((e) => e.normalLength).toList();

    var prevX = -1, prevY = -1;
    final edgeValues = [0.0, 0.0, 0.0];

    for (final coords in hilbert.points()) {
      final localX = coords[0];
      final localY = coords[1];

      final globalX = minX + localX;
      final globalY = minY + localY;

      if (globalX > maxX || globalY > maxY) continue;

      final px = globalX + 0.5;
      final py = globalY + 0.5;

      if (prevX >= 0) {
        final dx = globalX - prevX;
        final dy = globalY - prevY;

        for (int e = 0; e < 3; e++) {
          edgeValues[e] += edges[e].deltaX * dx + edges[e].deltaY * dy;
        }
      } else {
        for (int e = 0; e < 3; e++) {
          edgeValues[e] = edges[e].evaluate(px, py);
        }
      }

      prevX = globalX;
      prevY = globalY;

      // Teste de inclusão robusto ao winding:
      bool allPositive = true;
      bool allNegative = true;
      for (final v in edgeValues) {
        if (v < 0) allPositive = false;
        if (v > 0) allNegative = false;
        if (!allPositive && !allNegative) break;
      }

      final idx = globalY * width + globalX;

      if (allPositive || allNegative) {
        _buffer[idx] = color;
      } else {
        bool anyClose = false;
        final signedDistances = <double>[];

        for (int e = 0; e < 3; e++) {
          final dist = edgeValues[e] / normalLengths[e];
          signedDistances.add(dist);
          if (dist.abs() < 1.5) anyClose = true;
        }

        if (anyClose) {
          final coverage = computeRationalCoverage(signedDistances);
          if (coverage > 0.01) {
            _blendPixelByIndex(idx, color, (coverage * 255).toInt());
          }
        }
      }
    }
  }

  void _blendPixelByIndex(int idx, int foreground, int alpha) {
    if (alpha >= 255) {
      _buffer[idx] = foreground;
      return;
    }

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
}