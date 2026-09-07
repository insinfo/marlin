import 'dart:math' as math;

import 'bl_path.dart';

/// Dash pattern generator (port of Blend2D's dasher).
///
/// Converts a solid [BLPath] into a dashed [BLPath] by applying a repeating
/// dash/gap pattern. The result can then be stroked via [BLStroker].
///
/// Inspired by: `blend2d/core/pathstroke.cpp` dash logic.
class BLDasher {
  const BLDasher._();

  /// Applies a dash pattern to [input] and returns a new dashed path.
  ///
  /// [dashArray] is a list of alternating dash/gap lengths (e.g. `[10, 5]`).
  /// [dashOffset] shifts the start of the dash pattern.
  ///
  /// Each contour in [input] is independently dashed.
  static BLPath dashPath(
    BLPath input,
    List<double> dashArray, {
    double dashOffset = 0.0,
  }) {
    if (dashArray.isEmpty) return input;

    final result = BLPath();
    final data = input.toPathData();
    final verts = data.vertices;
    final counts = data.contourVertexCounts ?? [verts.length ~/ 2];

    int vertOffset = 0;
    for (final cnt in counts) {
      if (cnt < 2) {
        vertOffset += cnt;
        continue;
      }
      _dashContour(result, verts, vertOffset, cnt, dashArray, dashOffset);
      vertOffset += cnt;
    }

    return result;
  }

  static void _dashContour(
    BLPath out,
    List<double> verts,
    int start,
    int count,
    List<double> pattern,
    double offset,
  ) {
    // Compute total pattern length
    double patternLen = 0;
    for (final d in pattern) {
      patternLen += d.abs();
    }
    if (patternLen <= 0) return;

    // Normalize offset into [0, patternLen)
    double dashState = offset % patternLen;
    if (dashState < 0) dashState += patternLen;

    // Find initial dash index and remaining length in that dash
    int dashIdx = 0;
    double rem = dashState;
    while (dashIdx < pattern.length && rem >= pattern[dashIdx]) {
      rem -= pattern[dashIdx];
      dashIdx++;
    }
    if (dashIdx >= pattern.length) {
      dashIdx = 0;
      rem = 0;
    }
    double dashRemaining = pattern[dashIdx] - rem;
    bool isDash = (dashIdx & 1) == 0; // even indices = dash, odd = gap
    bool inDash = false;

    for (int seg = 0; seg < count - 1; seg++) {
      final i0 = start + seg;
      final i1 = start + seg + 1;
      double x0 = verts[i0 * 2], y0 = verts[i0 * 2 + 1];
      final x1 = verts[i1 * 2], y1 = verts[i1 * 2 + 1];

      final dx = x1 - x0, dy = y1 - y0;
      double segLen = math.sqrt(dx * dx + dy * dy);
      if (segLen < 1e-12) continue;

      final ux = dx / segLen, uy = dy / segLen;
      double consumed = 0;

      while (consumed < segLen - 1e-10) {
        final available = segLen - consumed;
        final take = math.min(dashRemaining, available);

        final px = x0 + ux * (consumed + take);
        final py = y0 + uy * (consumed + take);

        if (isDash) {
          if (!inDash) {
            final sx = x0 + ux * consumed;
            final sy = y0 + uy * consumed;
            out.moveTo(sx, sy);
            inDash = true;
          }
          out.lineTo(px, py);
        } else {
          inDash = false;
        }

        consumed += take;
        dashRemaining -= take;

        if (dashRemaining <= 1e-10) {
          dashIdx = (dashIdx + 1) % pattern.length;
          dashRemaining = pattern[dashIdx];
          isDash = (dashIdx & 1) == 0;
          if (!isDash) inDash = false;
        }
      }
    }
  }
}

/// Options for dashed stroke.
class BLDashOptions {
  /// Alternating dash/gap lengths.
  final List<double> dashArray;

  /// Offset within the dash pattern to start from.
  final double dashOffset;

  const BLDashOptions({
    required this.dashArray,
    this.dashOffset = 0.0,
  });
}
