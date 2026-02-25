import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/bl_types.dart';
import '../pipeline/bl_compop_kernel.dart';
import 'bl_edge_builder.dart';
import 'bl_raster_defs.dart';

/// Rasterizador nativo (bootstrap) do port Blend2D em Dart.
///
/// Implementacao atual:
/// - Acumulacao analitica de `cover/area` por celula.
/// - Bit-mask por scanline para resolver apenas regioes ativas.
/// - Fill rule `evenOdd` e `nonZero`.
/// - Suporte a multiplos contornos (`contourVertexCounts`) para furos.
/// - Composicao `srcCopy` e `srcOver`.
class BLAnalyticRasterizer {
  static const int _kCovShift = BLA8Info.kShift;
  static const int _kCovOne = BLA8Info.kScale;
  static const int _kMaskWordBits = 32;

  final int width;
  final int height;
  final Uint32List _buffer;
  final Int32List _covers;
  final Int32List _areas;
  final Uint32List _activeMask;
  final Int32List _rowMinX;
  final Int32List _rowMaxX;
  final int _wordsPerRow;

  int _dirtyMinY = 1 << 30;
  int _dirtyMaxY = -1;

  BLAnalyticRasterizer(
    this.width,
    this.height, {
    bool useSimd = false,
    bool useIsolates = false,
    int tileHeight = 64,
    int minParallelDirtyHeight = 256,
    int aaSubsampleY = 2,
  })  : _buffer = Uint32List(width * height),
        _covers = Int32List(width * height),
        _areas = Int32List(width * height),
        _wordsPerRow = (width + _kMaskWordBits - 1) ~/ _kMaskWordBits,
        _activeMask = Uint32List(
            ((width + _kMaskWordBits - 1) ~/ _kMaskWordBits) * height),
        _rowMinX = Int32List(height),
        _rowMaxX = Int32List(height) {
    _rowMinX.fillRange(0, _rowMinX.length, width);
    _rowMaxX.fillRange(0, _rowMaxX.length, -1);
    // Flags mantidas por compatibilidade de construcao da API.
    // Implementacao paralela/SIMD sera adicionada em fases seguintes.
    if (useSimd ||
        useIsolates ||
        tileHeight <= 0 ||
        minParallelDirtyHeight <= 0 ||
        aaSubsampleY < 0) {
      // no-op
    }
  }

  /// Read-only access to the internal ARGB32 pixel buffer.
  Uint32List get pixelBuffer => _buffer;

  void clear([int argb = 0xFFFFFFFF]) {
    _buffer.fillRange(0, _buffer.length, argb);
    _covers.fillRange(0, _covers.length, 0);
    _areas.fillRange(0, _areas.length, 0);
    _activeMask.fillRange(0, _activeMask.length, 0);
    _rowMinX.fillRange(0, _rowMinX.length, width);
    _rowMaxX.fillRange(0, _rowMaxX.length, -1);
    _resetDirty();
  }

  Future<void> drawPolygon(
    List<double> vertices,
    int color, {
    BLFillRule fillRule = BLFillRule.nonZero,
    BLCompOp compOp = BLCompOp.srcOver,
    List<int>? contourVertexCounts,
  }) async {
    final pointCount = vertices.length ~/ 2;
    if (pointCount < 3) return;

    final contours =
        BLEdgeBuilder.resolveContours(pointCount, contourVertexCounts);
    if (contours.isEmpty) return;

    _resetDirty();
    for (final contour in contours) {
      if (contour.count < 2) continue;
      final end = contour.start + contour.count;
      for (int p = contour.start; p < end; p++) {
        final next = (p + 1 < end) ? (p + 1) : contour.start;
        final x0 = vertices[p * 2];
        final y0 = vertices[p * 2 + 1];
        final x1 = vertices[next * 2];
        final y1 = vertices[next * 2 + 1];
        _rasterizeEdge(x0, y0, x1, y1);
      }
    }
    if (_dirtyMaxY >= _dirtyMinY) {
      _resolveMaskedCoverage(color, compOp, fillRule);
    }
  }

  Future<void> drawPolygonFetched(
    List<double> vertices,
    BLPixelFetcher fetcher, {
    BLFillRule fillRule = BLFillRule.nonZero,
    BLCompOp compOp = BLCompOp.srcOver,
    List<int>? contourVertexCounts,
  }) async {
    final pointCount = vertices.length ~/ 2;
    if (pointCount < 3) return;

    final contours =
        BLEdgeBuilder.resolveContours(pointCount, contourVertexCounts);
    if (contours.isEmpty) return;

    _resetDirty();
    for (final contour in contours) {
      if (contour.count < 2) continue;
      final end = contour.start + contour.count;
      for (int p = contour.start; p < end; p++) {
        final next = (p + 1 < end) ? (p + 1) : contour.start;
        final x0 = vertices[p * 2];
        final y0 = vertices[p * 2 + 1];
        final x1 = vertices[next * 2];
        final y1 = vertices[next * 2 + 1];
        _rasterizeEdge(x0, y0, x1, y1);
      }
    }
    if (_dirtyMaxY >= _dirtyMinY) {
      _resolveMaskedCoverageFetched(fetcher, compOp, fillRule);
    }
  }

  Uint32List get buffer => _buffer;

  Future<void> dispose() async {}

  void _rasterizeEdge(double x0, double y0, double x1, double y1) {
    if (math.max(y0, y1) < 0.0 || math.min(y0, y1) >= height) return;

    int dir = 1;
    if (y0 > y1) {
      final tx = x0;
      final ty = y0;
      x0 = x1;
      y0 = y1;
      x1 = tx;
      y1 = ty;
      dir = -1;
    }

    final yClip0 = math.max(0.0, y0);
    final yClip1 = math.min(height.toDouble(), y1);
    if (yClip0 >= yClip1) return;

    final invDy = 1.0 / (y1 - y0);
    final dxdy = (x1 - x0) * invDy;

    if (y0 < yClip0) {
      x0 += dxdy * (yClip0 - y0);
      y0 = yClip0;
    }

    final yStart = y0.floor();
    final yEnd = (yClip1 - 0.00001).floor();

    double currentX = x0;
    for (int y = yStart; y <= yEnd; y++) {
      final nextY = math.min((y + 1).toDouble(), yClip1);
      final dy = nextY - y0;
      final nextX = currentX + dxdy * dy;
      _addSegment(y, currentX, y0 - y, nextX, nextY - y, dir);
      currentX = nextX;
      y0 = nextY;
    }
  }

  void _addSegment(int y, double x0, double y0, double x1, double y1, int dir) {
    if (y < 0 || y >= height) return;

    final y0Fixed = (y0 * _kCovOne).round();
    final y1Fixed = (y1 * _kCovOne).round();
    final distY = (y1Fixed - y0Fixed) * dir;
    if (distY == 0) return;

    _markDirtyLine(y);

    int ix0 = x0.floor();
    int ix1 = x1.floor();
    if (ix0 < 0) ix0 = 0;
    if (ix0 >= width) ix0 = width - 1;
    if (ix1 < 0) ix1 = 0;
    if (ix1 >= width) ix1 = width - 1;

    final rowOffset = y * width;
    if (ix0 == ix1) {
      final xAvg = (x0 + x1) * 0.5 - ix0;
      final areaVal = (distY * (xAvg * _kCovOne)).round() >> _kCovShift;
      final idx = rowOffset + ix0;
      _covers[idx] += distY;
      _areas[idx] += areaVal;
      _markCellActive(y, ix0);
      return;
    }

    final dx = x1 - x0;
    if (dx.abs() < 1e-20) {
      final xAvg = (x0 + x1) * 0.5 - ix0;
      final areaVal = (distY * (xAvg * _kCovOne)).round() >> _kCovShift;
      final idx = rowOffset + ix0;
      _covers[idx] += distY;
      _areas[idx] += areaVal;
      _markCellActive(y, ix0);
      return;
    }

    final step = ix1 > ix0 ? 1 : -1;
    double borderX = step > 0 ? (ix0 + 1).toDouble() : ix0.toDouble();

    double currX0 = x0;
    int currIX = ix0;
    int currYFixed = y0Fixed;
    int consumedDistY = 0;

    while (currIX != ix1) {
      final t = (borderX - x0) / dx;
      final nextY = y0 + t * (y1 - y0);
      final nextYFixed = (nextY * _kCovOne).round();
      final distYLocal = (nextYFixed - currYFixed) * dir;
      consumedDistY += distYLocal;
      currYFixed = nextYFixed;

      final xAvgLocal = (currX0 + borderX) * 0.5 - currIX;
      final areaValLocal =
          (distYLocal * (xAvgLocal * _kCovOne)).round() >> _kCovShift;

      final idx = rowOffset + currIX;
      _covers[idx] += distYLocal;
      _areas[idx] += areaValLocal;
      _markCellActive(y, currIX);

      currX0 = borderX;
      currIX += step;
      borderX += step;
    }

    final distYLocal = distY - consumedDistY;
    final xAvgLocal = (currX0 + x1) * 0.5 - ix1;
    final areaValLocal =
        (distYLocal * (xAvgLocal * _kCovOne)).round() >> _kCovShift;

    final idx = rowOffset + ix1;
    _covers[idx] += distYLocal;
    _areas[idx] += areaValLocal;
    _markCellActive(y, ix1);
  }

  @pragma('vm:prefer-inline')
  void _markCellActive(int y, int x) {
    final rowWordOffset = y * _wordsPerRow;
    final word = x >> 5;
    final bit = x & 31;
    _activeMask[rowWordOffset + word] |= (1 << bit);
    if (x < _rowMinX[y]) _rowMinX[y] = x;
    if (x > _rowMaxX[y]) _rowMaxX[y] = x;
  }

  @pragma('vm:prefer-inline')
  void _markDirtyLine(int y) {
    if (y < _dirtyMinY) _dirtyMinY = y;
    if (y > _dirtyMaxY) _dirtyMaxY = y;
  }

  @pragma('vm:prefer-inline')
  void _resetDirty() {
    _dirtyMinY = 1 << 30;
    _dirtyMaxY = -1;
  }

  void _resolveMaskedCoverage(
    int src,
    BLCompOp compOp,
    BLFillRule fillRule,
  ) {
    if (fillRule == BLFillRule.evenOdd) {
      _resolveMaskedCoverageEvenOdd(src, compOp);
    } else {
      _resolveMaskedCoverageNonZero(src, compOp);
    }
  }

  void _resolveMaskedCoverageFetched(
    BLPixelFetcher fetcher,
    BLCompOp compOp,
    BLFillRule fillRule,
  ) {
    if (fillRule == BLFillRule.evenOdd) {
      _resolveMaskedCoverageEvenOddFetched(fetcher, compOp);
    } else {
      _resolveMaskedCoverageNonZeroFetched(fetcher, compOp);
    }
  }

  void _resolveMaskedCoverageNonZero(
    int src,
    BLCompOp compOp,
  ) {
    final srcA = (src >>> 24) & 0xFF;
    final srcRgb = src & 0x00FFFFFF;
    final opaqueFastPath = srcA == 255 &&
        (compOp == BLCompOp.srcOver || compOp == BLCompOp.srcCopy);

    if (_dirtyMaxY < _dirtyMinY) return;
    final yStart = _dirtyMinY.clamp(0, height - 1);
    final yEnd = _dirtyMaxY.clamp(0, height - 1);

    for (int y = yStart; y <= yEnd; y++) {
      final rowWordOffset = y * _wordsPerRow;
      int firstX = _rowMinX[y];
      int lastX = _rowMaxX[y];
      if (firstX < 0 || firstX >= width || lastX < 0 || firstX > lastX) {
        continue;
      }
      if (firstX < 0) firstX = 0;
      if (lastX >= width) lastX = width - 1;

      final rowOffset = y * width;
      int cellAcc = 0;

      int x = firstX;
      while (x <= lastX) {
        final eventX = _findNextSetBitInRange(rowWordOffset, x, lastX);
        final spanEnd = (eventX < 0 ? lastX + 1 : eventX);
        if (x < spanEnd) {
          final covAlpha = _coverageToAlphaNonZero(cellAcc);
          if (covAlpha > 0 && srcA != 0) {
            final effA =
                srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
            if (effA > 0) {
              if (opaqueFastPath && covAlpha == 255) {
                _buffer.fillRange(rowOffset + x, rowOffset + spanEnd, src);
              } else {
                final effSrc = (effA << 24) | srcRgb;
                if (compOp == BLCompOp.srcCopy && effA == 255) {
                  _buffer.fillRange(rowOffset + x, rowOffset + spanEnd, effSrc);
                } else {
                  for (int p = x; p < spanEnd; p++) {
                    final idx = rowOffset + p;
                    _buffer[idx] =
                        BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
                  }
                }
              }
            }
          }
          x = spanEnd;
          if (eventX < 0) break;
        }

        final idx = rowOffset + x;
        final cv = _covers[idx];
        final ar = _areas[idx];
        _covers[idx] = 0;
        _areas[idx] = 0;

        final cell0 = cv - ar;
        final cell1 = ar;
        cellAcc += cell0;
        final coverage = cellAcc;
        cellAcc += cell1;

        final covAlpha = _coverageToAlphaNonZero(coverage);
        if (covAlpha > 0 && srcA != 0) {
          final effA =
              srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
          if (effA > 0) {
            if (opaqueFastPath && covAlpha == 255) {
              _buffer[idx] = src;
            } else {
              final effSrc = (effA << 24) | srcRgb;
              if (compOp == BLCompOp.srcCopy && effA == 255) {
                _buffer[idx] = effSrc;
              } else {
                _buffer[idx] =
                    BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
              }
            }
          }
        }

        x++;
      }

      _activeMask.fillRange(rowWordOffset, rowWordOffset + _wordsPerRow, 0);
      _rowMinX[y] = width;
      _rowMaxX[y] = -1;
    }

    _resetDirty();
  }

  void _resolveMaskedCoverageEvenOdd(
    int src,
    BLCompOp compOp,
  ) {
    final srcA = (src >>> 24) & 0xFF;
    final srcRgb = src & 0x00FFFFFF;
    final opaqueFastPath = srcA == 255 &&
        (compOp == BLCompOp.srcOver || compOp == BLCompOp.srcCopy);

    if (_dirtyMaxY < _dirtyMinY) return;
    final yStart = _dirtyMinY.clamp(0, height - 1);
    final yEnd = _dirtyMaxY.clamp(0, height - 1);

    for (int y = yStart; y <= yEnd; y++) {
      final rowWordOffset = y * _wordsPerRow;
      int firstX = _rowMinX[y];
      int lastX = _rowMaxX[y];
      if (firstX < 0 || firstX >= width || lastX < 0 || firstX > lastX) {
        continue;
      }
      if (firstX < 0) firstX = 0;
      if (lastX >= width) lastX = width - 1;

      final rowOffset = y * width;
      int cellAcc = 0;

      int x = firstX;
      while (x <= lastX) {
        final eventX = _findNextSetBitInRange(rowWordOffset, x, lastX);
        final spanEnd = (eventX < 0 ? lastX + 1 : eventX);
        if (x < spanEnd) {
          final covAlpha = _coverageToAlphaEvenOdd(cellAcc);
          if (covAlpha > 0 && srcA != 0) {
            final effA =
                srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
            if (effA > 0) {
              if (opaqueFastPath && covAlpha == 255) {
                _buffer.fillRange(rowOffset + x, rowOffset + spanEnd, src);
              } else {
                final effSrc = (effA << 24) | srcRgb;
                if (compOp == BLCompOp.srcCopy && effA == 255) {
                  _buffer.fillRange(rowOffset + x, rowOffset + spanEnd, effSrc);
                } else {
                  for (int p = x; p < spanEnd; p++) {
                    final idx = rowOffset + p;
                    _buffer[idx] =
                        BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
                  }
                }
              }
            }
          }
          x = spanEnd;
          if (eventX < 0) break;
        }

        final idx = rowOffset + x;
        final cv = _covers[idx];
        final ar = _areas[idx];
        _covers[idx] = 0;
        _areas[idx] = 0;

        final cell0 = cv - ar;
        final cell1 = ar;
        cellAcc += cell0;
        final coverage = cellAcc;
        cellAcc += cell1;

        final covAlpha = _coverageToAlphaEvenOdd(coverage);
        if (covAlpha > 0 && srcA != 0) {
          final effA =
              srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
          if (effA > 0) {
            if (opaqueFastPath && covAlpha == 255) {
              _buffer[idx] = src;
            } else {
              final effSrc = (effA << 24) | srcRgb;
              if (compOp == BLCompOp.srcCopy && effA == 255) {
                _buffer[idx] = effSrc;
              } else {
                _buffer[idx] =
                    BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
              }
            }
          }
        }

        x++;
      }

      _activeMask.fillRange(rowWordOffset, rowWordOffset + _wordsPerRow, 0);
      _rowMinX[y] = width;
      _rowMaxX[y] = -1;
    }

    _resetDirty();
  }

  void _resolveMaskedCoverageNonZeroFetched(
    BLPixelFetcher fetcher,
    BLCompOp compOp,
  ) {
    if (_dirtyMaxY < _dirtyMinY) return;
    final yStart = _dirtyMinY.clamp(0, height - 1);
    final yEnd = _dirtyMaxY.clamp(0, height - 1);

    for (int y = yStart; y <= yEnd; y++) {
      final rowWordOffset = y * _wordsPerRow;
      int firstX = _rowMinX[y];
      int lastX = _rowMaxX[y];
      if (firstX < 0 || firstX >= width || lastX < 0 || firstX > lastX) {
        continue;
      }
      if (firstX < 0) firstX = 0;
      if (lastX >= width) lastX = width - 1;

      final rowOffset = y * width;
      int cellAcc = 0;

      int x = firstX;
      while (x <= lastX) {
        final eventX = _findNextSetBitInRange(rowWordOffset, x, lastX);
        final spanEnd = (eventX < 0 ? lastX + 1 : eventX);

        if (x < spanEnd) {
          final covAlpha = _coverageToAlphaNonZero(cellAcc);
          if (covAlpha > 0) {
            for (int p = x; p < spanEnd; p++) {
              final idx = rowOffset + p;
              final srcPx = fetcher(p, y);
              final srcA = (srcPx >>> 24) & 0xFF;
              if (srcA == 0) continue;

              final effA =
                  srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
              if (effA <= 0) continue;

              final effSrc = (effA << 24) | (srcPx & 0x00FFFFFF);
              if (compOp == BLCompOp.srcCopy && effA == 255) {
                _buffer[idx] = effSrc;
              } else {
                _buffer[idx] =
                    BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
              }
            }
          }

          x = spanEnd;
          if (eventX < 0) break;
        }

        final idx = rowOffset + x;
        final cv = _covers[idx];
        final ar = _areas[idx];
        _covers[idx] = 0;
        _areas[idx] = 0;

        final cell0 = cv - ar;
        final cell1 = ar;
        cellAcc += cell0;
        final coverage = cellAcc;
        cellAcc += cell1;

        final covAlpha = _coverageToAlphaNonZero(coverage);
        if (covAlpha > 0) {
          final srcPx = fetcher(x, y);
          final srcA = (srcPx >>> 24) & 0xFF;
          if (srcA != 0) {
            final effA =
                srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
            if (effA > 0) {
              final effSrc = (effA << 24) | (srcPx & 0x00FFFFFF);
              if (compOp == BLCompOp.srcCopy && effA == 255) {
                _buffer[idx] = effSrc;
              } else {
                _buffer[idx] =
                    BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
              }
            }
          }
        }

        x++;
      }

      _activeMask.fillRange(rowWordOffset, rowWordOffset + _wordsPerRow, 0);
      _rowMinX[y] = width;
      _rowMaxX[y] = -1;
    }

    _resetDirty();
  }

  void _resolveMaskedCoverageEvenOddFetched(
    BLPixelFetcher fetcher,
    BLCompOp compOp,
  ) {
    if (_dirtyMaxY < _dirtyMinY) return;
    final yStart = _dirtyMinY.clamp(0, height - 1);
    final yEnd = _dirtyMaxY.clamp(0, height - 1);

    for (int y = yStart; y <= yEnd; y++) {
      final rowWordOffset = y * _wordsPerRow;
      int firstX = _rowMinX[y];
      int lastX = _rowMaxX[y];
      if (firstX < 0 || firstX >= width || lastX < 0 || firstX > lastX) {
        continue;
      }
      if (firstX < 0) firstX = 0;
      if (lastX >= width) lastX = width - 1;

      final rowOffset = y * width;
      int cellAcc = 0;

      int x = firstX;
      while (x <= lastX) {
        final eventX = _findNextSetBitInRange(rowWordOffset, x, lastX);
        final spanEnd = (eventX < 0 ? lastX + 1 : eventX);

        if (x < spanEnd) {
          final covAlpha = _coverageToAlphaEvenOdd(cellAcc);
          if (covAlpha > 0) {
            for (int p = x; p < spanEnd; p++) {
              final idx = rowOffset + p;
              final srcPx = fetcher(p, y);
              final srcA = (srcPx >>> 24) & 0xFF;
              if (srcA == 0) continue;

              final effA =
                  srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
              if (effA <= 0) continue;

              final effSrc = (effA << 24) | (srcPx & 0x00FFFFFF);
              if (compOp == BLCompOp.srcCopy && effA == 255) {
                _buffer[idx] = effSrc;
              } else {
                _buffer[idx] =
                    BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
              }
            }
          }

          x = spanEnd;
          if (eventX < 0) break;
        }

        final idx = rowOffset + x;
        final cv = _covers[idx];
        final ar = _areas[idx];
        _covers[idx] = 0;
        _areas[idx] = 0;

        final cell0 = cv - ar;
        final cell1 = ar;
        cellAcc += cell0;
        final coverage = cellAcc;
        cellAcc += cell1;

        final covAlpha = _coverageToAlphaEvenOdd(coverage);
        if (covAlpha > 0) {
          final srcPx = fetcher(x, y);
          final srcA = (srcPx >>> 24) & 0xFF;
          if (srcA != 0) {
            final effA =
                srcA == 255 ? covAlpha : ((covAlpha * srcA + 127) ~/ 255);
            if (effA > 0) {
              final effSrc = (effA << 24) | (srcPx & 0x00FFFFFF);
              if (compOp == BLCompOp.srcCopy && effA == 255) {
                _buffer[idx] = effSrc;
              } else {
                _buffer[idx] =
                    BLCompOpKernel.compose(compOp, _buffer[idx], effSrc);
              }
            }
          }
        }

        x++;
      }

      _activeMask.fillRange(rowWordOffset, rowWordOffset + _wordsPerRow, 0);
      _rowMinX[y] = width;
      _rowMaxX[y] = -1;
    }

    _resetDirty();
  }

  @pragma('vm:prefer-inline')
  int _findNextSetBitInRange(int rowWordOffset, int startX, int endX) {
    int wordIndex = startX >> 5;
    final endWord = endX >> 5;
    final startBit = startX & 31;

    int word =
        _activeMask[rowWordOffset + wordIndex] & (0xFFFFFFFF << startBit);
    while (true) {
      if (word != 0) {
        final bit = _firstSetBit(word);
        final x = (wordIndex << 5) + bit;
        return x <= endX ? x : -1;
      }
      wordIndex++;
      if (wordIndex > endWord) break;
      word = _activeMask[rowWordOffset + wordIndex];
    }
    return -1;
  }

  @pragma('vm:prefer-inline')
  int _coverageToAlphaNonZero(int coverage) {
    int absCover = coverage;
    final mask = absCover >> 31;
    absCover = (absCover ^ mask) - mask;

    int covAlpha = (absCover * 255) >> _kCovShift;
    if (covAlpha <= 0) return 0;
    if (covAlpha > 255) return 255;
    return covAlpha;
  }

  @pragma('vm:prefer-inline')
  int _coverageToAlphaEvenOdd(int coverage) {
    int absCover = coverage;
    final mask = absCover >> 31;
    absCover = (absCover ^ mask) - mask;

    absCover &= (_kCovOne * 2) - 1;
    if (absCover > _kCovOne) {
      absCover = (_kCovOne * 2) - absCover;
    }

    int covAlpha = (absCover * 255) >> _kCovShift;
    if (covAlpha <= 0) return 0;
    if (covAlpha > 255) return 255;
    return covAlpha;
  }

  @pragma('vm:prefer-inline')
  static int _firstSetBit(int word) {
    final low = word & -word;
    return low.bitLength - 1;
  }
}
