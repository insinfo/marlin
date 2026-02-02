import 'dart:typed_data';
import 'marlin_const.dart';
import 'context/renderer_context.dart';


/// An object used to cache pre-rendered complex paths.
class MarlinCache {
  static const int _initialChunkArray = MarlinConst.tileSize * MarlinConst.initialPixelDim;
  
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
    
    final int nxTiles = (maxx - minx + MarlinConst.tileSize) >> MarlinConst.tileSizeLg;
    
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
    rowAAChunkPos = 2; // Start at 2 so 0 is invalid index
    rowAAChunkIndex.fillRange(0, rowAAChunkIndex.length, 0);
    
    if (tileMin != 2147483647) {
        if (tileMax == 1) {
            touchedTile[0] = 0;
        } else {
            // IntArrayCache.fill(touchedTile, tileMin, tileMax, 0);
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
    
    final int row = y - bboxY0;
    rowAAx0[row] = px0; // Start X
    
    // Position finding
    // Ensure space logic same as before or improved
    // We assume enough space or grow?
    // We'll grow if needed. RLE worst case is 2 bytes per pixel (alternating).
    // Plus terminator.
    final int maxLen = (px1 - px0) * 2 + 2;
    
    if (rowAAChunk.length < rowAAChunkPos + maxLen) {
        // resize logic
        int newSize = rowAAChunk.length * 2;
        if (newSize < rowAAChunkPos + maxLen) newSize = rowAAChunkPos + maxLen + 4096;
        
        Uint8List newChunk = rdrCtx.getDirtyByteArrayCache(newSize).getArray();
        newChunk.setRange(0, rowAAChunkPos, rowAAChunk);
        rowAAChunk = newChunk;
    }
    
    rowAAChunkIndex[row] = rowAAChunkPos;
    
    int pos = rowAAChunkPos;
    final Uint8List chunk = rowAAChunk;
    
    int currentRunVal = alphaRow[px0];
    // Clear alphaRow as we read (Marlin contract)
    alphaRow[px0] = 0; 
    
    int currentRunLen = 1;
    
    for (int x = px0 + 1; x < px1; x++) {
        int val = alphaRow[x];
        alphaRow[x] = 0; // Clear
        
        if (val == currentRunVal && currentRunLen < 255) {
            currentRunLen++;
        } else {
            // Flush run
            chunk[pos++] = currentRunVal;
            chunk[pos++] = currentRunLen;
            
            currentRunVal = val;
            currentRunLen = 1;
        }
    }
    // Flush last run
    chunk[pos++] = currentRunVal;
    chunk[pos++] = currentRunLen;
    
    // Terminator
    chunk[pos++] = 0;
    chunk[pos++] = 0;
    
    rowAAChunkPos = pos;
    
    // Update tile limits
    int tx = (px0 - bboxX0) >> MarlinConst.tileSizeLg;
    if (tx < tileMin) tileMin = tx;
    tx = ((px1 - bboxX0 - 1) >> MarlinConst.tileSizeLg) + 1;
    if (tx > tileMax) tileMax = tx;
    
    // Update touchedTile (approximate - explicit sum is better but expensive?
    // Original code updated touchedTile per pixel.
    // Here we can just mark tiles as touched?
    // _blit checks `touchedTile[t] == 0`.
    // We should mark them 1.
    // Loop tiles spanned
    int t0 = (px0 - bboxX0) >> MarlinConst.tileSizeLg;
    int t1 = ((px1 - 1 - bboxX0) >> MarlinConst.tileSizeLg);
    for(int t=t0; t<=t1; t++) {
        touchedTile[t] += 1;
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
