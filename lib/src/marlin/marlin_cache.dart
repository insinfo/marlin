import 'dart:typed_data';
import 'marlin_const.dart';
import 'context/renderer_context.dart';

/// An object used to cache pre-rendered complex paths.
class MarlinCache {
  static const int _initialChunkArray =
      MarlinConst.tileSize * MarlinConst.initialPixelDim;

  // 64 is maxAAAlpha (8x8)
  static final Uint8List alphaMap = _buildAlphaMap(MarlinConst.maxAAAlpha);

  int bboxX0 = 0, bboxY0 = 0, bboxX1 = 0, bboxY1 = 0;

  // 1D dirty arrays
  final Int32List rowAAChunkIndex = Int32List(MarlinConst.tileSize);
  final Int32List rowAAx0 = Int32List(MarlinConst.tileSize);
  final Int32List rowAAx1 = Int32List(MarlinConst.tileSize);

  Uint8List rowAAChunk;
  int rowAAChunkPos = 0;

  // touchedTile[i] is the sum of all the alphas in the tile
  Int32List touchedTile;

  final RendererContext rdrCtx;

  final Uint8List _rowAAChunkInitial;
  final Int32List _touchedTileInitial;

  int tileMin = 2147483647; // Integer.MAX_VALUE
  int tileMax = -2147483648; // Integer.MIN_VALUE

  MarlinCache(this.rdrCtx)
      : _rowAAChunkInitial = Uint8List(_initialChunkArray + 1),
        _touchedTileInitial = Int32List(MarlinConst.initialArray),
        rowAAChunk = Uint8List(_initialChunkArray + 1),
        touchedTile = Int32List(MarlinConst.initialArray) {
    rowAAChunk = _rowAAChunkInitial;
    touchedTile = _touchedTileInitial;
  }

  void init(int minx, int miny, int maxx, int maxy) {
    bboxX0 = minx;
    bboxY0 = miny;
    bboxX1 = maxx;
    bboxY1 = maxy;

    final int nxTiles =
        (maxx - minx + MarlinConst.tileSize) >> MarlinConst.tileSizeLg;

    if (nxTiles > MarlinConst.initialArray) {
      touchedTile = rdrCtx.getIntArrayCache(nxTiles).getArray();
    }
  }

  void dispose() {
    resetTileLine(0);

    if (rowAAChunk != _rowAAChunkInitial) {
      rdrCtx.putDirtyByteArray(rowAAChunk);
      rowAAChunk = _rowAAChunkInitial;
    }
    if (touchedTile != _touchedTileInitial) {
      rdrCtx.putIntArray(touchedTile, 0, 0);
      touchedTile = _touchedTileInitial;
    }
  }

  void resetTileLine(int pminY) {
    bboxY0 = pminY;
    rowAAChunkPos = 2; // keep 0 as invalid index in rowAAChunkIndex
    rowAAChunkIndex.fillRange(0, rowAAChunkIndex.length, 0);

    if (tileMin != 2147483647) {
      // [tileMin, tileMax) is the touched range from previous strip.
      if (tileMax > tileMin) {
        touchedTile.fillRange(tileMin, tileMax, 0);
      }
      tileMin = 2147483647;
      tileMax = -2147483648;
    }
  }

  void clearAARow(int y) {
    final int row = y - bboxY0;
    rowAAx0[row] = 0;
    rowAAx1[row] = 0;
  }

  void copyAARow(Int32List alphaRow, int y, int px0, int px1) {
    if (px1 <= px0) return;

    final int pxBBox1 = px1 < bboxX1 ? px1 : bboxX1;
    if (pxBBox1 <= px0) return;

    final int row = y - bboxY0;
    rowAAx0[row] = px0;
    rowAAx1[row] = pxBBox1;

    final int from = px0 - bboxX0;
    final int to = pxBBox1 - bboxX0;
    final int clearTo = px1 - bboxX0;
    final int maxLen = (to - from) * 2 + 2;

    if (rowAAChunk.length < rowAAChunkPos + maxLen) {
      int newSize = rowAAChunk.length * 2;
      if (newSize < rowAAChunkPos + maxLen)
        newSize = rowAAChunkPos + maxLen + 4096;

      Uint8List newChunk = rdrCtx.getDirtyByteArrayCache(newSize).getArray();
      newChunk.setRange(0, rowAAChunkPos, rowAAChunk);
      rowAAChunk = newChunk;
    }

    rowAAChunkIndex[row] = rowAAChunkPos;

    int pos = rowAAChunkPos;
    final Uint8List chunk = rowAAChunk;

    int x = from;
    int sum = alphaRow[x];
    if (sum < 0) sum = 0;
    if (sum > MarlinConst.maxAAAlpha) sum = MarlinConst.maxAAAlpha;
    int currentRunVal = alphaMap[sum];
    alphaRow[x] = 0;
    int currentRunLen = 1;

    if (sum != 0) {
      touchedTile[x >> MarlinConst.tileSizeLg] += sum;
    }

    for (x = from + 1; x < to; x++) {
      sum += alphaRow[x];
      alphaRow[x] = 0;
      if (sum < 0) sum = 0;
      if (sum > MarlinConst.maxAAAlpha) sum = MarlinConst.maxAAAlpha;
      final int val = alphaMap[sum];

      if (sum != 0) {
        touchedTile[x >> MarlinConst.tileSizeLg] += sum;
      }

      if (val == currentRunVal && currentRunLen < 255) {
        currentRunLen++;
      } else {
        chunk[pos++] = currentRunVal;
        chunk[pos++] = currentRunLen;
        currentRunVal = val;
        currentRunLen = 1;
      }
    }

    chunk[pos++] = currentRunVal;
    chunk[pos++] = currentRunLen;

    chunk[pos++] = 0;
    chunk[pos++] = 0;

    rowAAChunkPos = pos;

    int tx = from >> MarlinConst.tileSizeLg;
    if (tx < tileMin) tileMin = tx;
    tx = ((to - 1) >> MarlinConst.tileSizeLg) + 1;
    if (tx > tileMax) tileMax = tx;

    final int clearEnd = clearTo < alphaRow.length ? clearTo : alphaRow.length;
    if (clearEnd > from) {
      alphaRow.fillRange(from, clearEnd, 0);
    }
  }

  int alphaSumInTile(int x) {
    return touchedTile[(x - bboxX0) >> MarlinConst.tileSizeLg];
  }

  static Uint8List _buildAlphaMap(int maxalpha) {
    final Uint8List map = Uint8List(maxalpha + 1);
    final int halfmaxalpha = maxalpha >> 2; // Marlin uses this heuristic
    for (int i = 0; i <= maxalpha; i++) {
      // (i * 255 + half) / max
      map[i] = ((i * 255 + halfmaxalpha) ~/ maxalpha);
    }
    return map;
  }
}
