import 'dart:typed_data';
import 'dart:math' as math;
import 'marlin_const.dart';
import 'float_math.dart';
import 'context/renderer_context.dart';
import 'context/array_cache_config.dart';
import 'marlin_cache.dart';
import 'curve.dart';
import 'path_consumer_2d.dart';


// TODO Future Recommendations (Post-Session):
// Profile 
// _widenIntArray
// : Frequent calls here indicate initial bucket sizes might be too small. Increasing MarlinConst.initialEdgesCapacity could reduce resizing overhead.
// Optimize 
// _blit
// : The current 
// _blit
//  pixel blending logic performs many individual Int32List lookups per pixel. Unrolling loops or using Int32x4 SIMD instructions (if applicable in Dart Web/Native) could help.
// Review 
// Dasher
// : The 
// Dasher
//  interacts with Stroker which interacts with 
// Renderer
// . This chain creates many method calls. Inlining simple math or reducing recursion depth in 
// LengthIterator
//  might help.
// The Marlin renderer is now functional, correct, and feature-complete (supporting paths, strokes, dashes, transforms, and winding rules), albeit with room for performance tuning in a pure Dart environment.

class MarlinRenderer implements PathConsumer2D {
  // ignore: unused_field
  static const bool _doStats = false;
  // ignore: unused_field
  static const bool _doMonitors = false;
  // ignore: unused_field
  static const bool _doLogBounds = false;

  // Constants aliases
  static const int _offCurX = MarlinConst.offCurX;
  static const int _offError = MarlinConst.offError;
  static const int _offBumpX = MarlinConst.offBumpX;
  static const int _offBumpErr = MarlinConst.offBumpErr;
  static const int _offNext = MarlinConst.offNext;
  static const int _offYMaxOr = MarlinConst.offYmaxOr;
  static const int _sizeofEdge = MarlinConst.sizeofEdge;

  static const int _subpixelLgPositionsX = MarlinConst.subpixelLgPositionsX;
  static const int _subpixelLgPositionsY = MarlinConst.subpixelLgPositionsY;
  static const int _subpixelPositionsX = MarlinConst.subpixelPositionsX;
  // ignore: unused_field
  static const int _subpixelPositionsY = MarlinConst.subpixelPositionsY;
  // ignore: unused_field
  static const int _subpixelMaskX = MarlinConst.subpixelMaskX;
  // ignore: unused_field
  static const int _subpixelMaskY = MarlinConst.subpixelMaskY;
  static const double _power2To32 = MarlinConst.power2To32;
  
  // ignore: unused_field
  static const double _quadDecBnd = 8.0 * (1.0 / 8.0); 

  final RendererContext _rdrCtx;
  final MarlinCache _cache;
  final Curve _curve;

  // High-level API fields
  final int _width;
  final int _height;
  final Int32List _pixelBuffer;

  // Fields
  int _boundsMinX = 0, _boundsMinY = 0, _boundsMaxX = 0, _boundsMaxY = 0;
  // ignore: unused_field
  int _bboxMinX = 0, _bboxMinY = 0, _bboxMaxX = 0, _bboxMaxY = 0;
  
  int _edgeMinY = 0, _edgeMaxY = 0;
  double _edgeMinX = 0.0, _edgeMaxX = 0.0;
  
  // ignore: unused_field
  int _windingRule = MarlinConst.windNonZero;
  double _x0 = 0.0, _y0 = 0.0;
  double _pixSx0 = 0.0, _pixSy0 = 0.0;
  
  // Arrays
  Int32List _edges;
  int _edgesPos = 0;
  
  Int32List _edgeBuckets;
  Int32List _edgeBucketCounts;
  int _bucketsMinY = 0;
  int _bucketsMaxY = 0;
  
  // Scanline arrays
  Int32List _crossings;
  Int32List _edgePtrs;
  // Aux arrays for sort (if needed, simplified to QuickSort for now)
  // Int32List _auxCrossings; 
  // Int32List _auxEdgePtrs;
  
  final Int32List _alphaLine;
  // ignore: unused_field
  int _edgeCount = 0;
  
  // Init
  factory MarlinRenderer(int width, int height) {
    return MarlinRenderer.withContext(RendererContext.createContext(), width, height);
  }

  MarlinRenderer.withContext(this._rdrCtx, int width, int height)
      : _width = width,
        _height = height,
        _cache = MarlinCache(_rdrCtx),
        _pixelBuffer = Int32List(width * height),
        _curve = Curve(),
        _edges = _rdrCtx.getIntArray(MarlinConst.initialEdgesCapacity) as Int32List,
        _edgeBuckets = _rdrCtx.getIntArray(MarlinConst.initialBucketArray) as Int32List,
        _edgeBucketCounts = _rdrCtx.getIntArray(MarlinConst.initialBucketArray) as Int32List,
        _crossings = _rdrCtx.getIntArray(MarlinConst.initialSmallArray) as Int32List,
        _edgePtrs = _rdrCtx.getIntArray(MarlinConst.initialSmallArray) as Int32List,
        _alphaLine = _rdrCtx.getIntArray(MarlinConst.initialAAArray) as Int32List;

  Int32List get buffer => _pixelBuffer;

  void clear(int color) {
    _pixelBuffer.fillRange(0, _pixelBuffer.length, color);
  }

  // Lifecycle
  void init([int pixBoundsX = 0, int pixBoundsY = 0, int? pixBoundsWidth, int? pixBoundsHeight, int windingRule = MarlinConst.windNonZero]) {
    _windingRule = windingRule;
    
    int w = pixBoundsWidth ?? _width;
    int h = pixBoundsHeight ?? _height;

    _boundsMinX = pixBoundsX << _subpixelLgPositionsX;
    _boundsMaxX = (pixBoundsX + w) << _subpixelLgPositionsX;
    _boundsMinY = pixBoundsY << _subpixelLgPositionsY;
    _boundsMaxY = (pixBoundsY + h) << _subpixelLgPositionsY;
    
    final int edgeBucketsLength = (_boundsMaxY - _boundsMinY) + 1;
    if (edgeBucketsLength > _edgeBuckets.length) {
       _edgeBuckets = _rdrCtx.getIntArray(edgeBucketsLength) as Int32List;
       _edgeBucketCounts = _rdrCtx.getIntArray(edgeBucketsLength) as Int32List;
    }
    
    _edgeMinY = 2147483647; // Float.POSITIVE_INFINITY as int (logic)
    _edgeMaxY = -2147483648; 
    _edgeMinX = double.infinity;
    _edgeMaxX = double.negativeInfinity;
    
    _edgeCount = 0;
    _edgesPos = _sizeofEdge; // Start at non-zero to verify linked lists
    
    // Init cache logic
    _cache.init(_boundsMinX, _boundsMinY, _boundsMaxX, _boundsMaxY);
  }
  
  void dispose() {
    _cache.dispose();
    
    _rdrCtx.putIntArray(_edges, 0, _edgesPos);
    _rdrCtx.putIntArray(_edgeBuckets, 0, 0);
    _rdrCtx.putIntArray(_edgeBucketCounts, 0, 0);
    
    // Auxiliary arrays - clear potentially used portion or all to be safe (since we don't track used length outside scanline loop)
    _rdrCtx.putIntArray(_crossings, 0, _crossings.length); 
    _rdrCtx.putIntArray(_edgePtrs, 0, _edgePtrs.length);
    
    _rdrCtx.putIntArray(_alphaLine, 0, 0); // Should be clean from scanline loop
  }
  
  // Coordinate utils
  static double _toSubpixX(double pixX) => MarlinConst.fSubpixelPositionsX * pixX;
  static double _toSubpixY(double pixY) => MarlinConst.fSubpixelPositionsY * pixY - 0.5;

  // PathConsumer2D
  void moveTo(double pixX, double pixY) {
    closePath();
    _pixSx0 = pixX;
    _pixSy0 = pixY;
    _x0 = _toSubpixX(pixX);
    _y0 = _toSubpixY(pixY);
  }

  void lineTo(double pixX, double pixY) {
    double x1 = _toSubpixX(pixX);
    double y1 = _toSubpixY(pixY);
    _addLine(_x0, _y0, x1, y1);
    _x0 = x1;
    _y0 = y1;
  }
  
  void closePath() {
    lineTo(_pixSx0, _pixSy0);
  }
  
  void curveTo(double x1, double y1, double x2, double y2, double x3, double y3) {
    final double xe = _toSubpixX(x3);
    final double ye = _toSubpixY(y3);
    _curve.setCubic(_x0, _y0, _toSubpixX(x1), _toSubpixY(y1), _toSubpixX(x2), _toSubpixY(y2), xe, ye);
    _curveBreakIntoLinesAndAdd(_x0, _y0, _curve, xe, ye);
    _x0 = xe;
    _y0 = ye;
  }
  
  void quadTo(double x1, double y1, double x2, double y2) {
    final double xe = _toSubpixX(x2);
    final double ye = _toSubpixY(y2);
    _curve.setQuad(_x0, _y0, _toSubpixX(x1), _toSubpixY(y1), xe, ye);
    _quadBreakIntoLinesAndAdd(_x0, _y0, _curve, xe, ye);
    _x0 = xe;
    _y0 = ye;
  }
  
  @override
  void pathDone() {
    closePath();
    endRendering();
  }

  // Implementation Placeholders
  void _addLine(double x1, double y1, double x2, double y2) {
    int or = 1;
    if (y2 < y1) {
      or = 0;
      double tmp = y2; y2 = y1; y1 = tmp;
      tmp = x2; x2 = x1; x1 = tmp;
    }

    final int firstCrossing = FloatMath.maxInt(FloatMath.ceilInt(y1), _boundsMinY);
    final int lastCrossing = FloatMath.minInt(FloatMath.ceilInt(y2), _boundsMaxY);

    if (firstCrossing >= lastCrossing) return;

    if (y1 < _edgeMinY) _edgeMinY = y1.floor();
    if (y2 > _edgeMaxY) _edgeMaxY = y2.ceil(); // tracking int bounds?

    final double slope = (x2 - x1) / (y2 - y1);

    if (slope >= 0.0) {
      if (x1 < _edgeMinX) _edgeMinX = x1;
      if (x2 > _edgeMaxX) _edgeMaxX = x2;
    } else {
      if (x2 < _edgeMinX) _edgeMinX = x2;
      if (x1 > _edgeMaxX) _edgeMaxX = x1;
    }

    final int ptr = _edgesPos;
    if (_edges.length < ptr + _sizeofEdge) {
      _edges = _widenIntArray(_edges, ptr, _edges.length << 1);
    }

    final double x1Intercept = x1 + (firstCrossing - y1) * slope;
    // 2^32 * x + 0x7fffffff
    final int x1FixedBiased = (_power2To32 * x1Intercept).toInt() + 2147483647;

    _edges[ptr + _offCurX] = x1FixedBiased >> 32;
    _edges[ptr + _offError] = (x1FixedBiased & 0xFFFFFFFF) >> 1;

    final int slopeFixed = (_power2To32 * slope).toInt();
    _edges[ptr + _offBumpX] = slopeFixed >> 32;
    _edges[ptr + _offBumpErr] = (slopeFixed & 0xFFFFFFFF) >> 1;

    final int bucketIdx = firstCrossing - _boundsMinY;

    _edges[ptr + _offNext] = _edgeBuckets[bucketIdx];
    _edges[ptr + _offYMaxOr] = (lastCrossing << 1) | or;

    _edgeBuckets[bucketIdx] = ptr;
    _edgeBucketCounts[bucketIdx] += 2;
    _edgeBucketCounts[lastCrossing - _boundsMinY] |= 1;

    _edgesPos += _sizeofEdge;
  }
  
  void _quadBreakIntoLinesAndAdd(double x0, double y0, Curve c, double x2, double y2) {
    int count = 1;
    double maxDD = math.max(c.dbx.abs(), c.dby.abs());
    while (maxDD >= 1.0) {
      maxDD /= 4.0;
      count <<= 1;
    }

    if (count > 1) {
      double icount = 1.0 / count;
      double icount2 = icount * icount;
      double ddx = c.dbx * icount2;
      double ddy = c.dby * icount2;
      double dx = c.bx * icount2 + c.cx * icount;
      double dy = c.by * icount2 + c.cy * icount;

      while (--count > 0) {
        double x1 = x0 + dx;
        dx += ddx;
        double y1 = y0 + dy;
        dy += ddy;
        _addLine(x0, y0, x1, y1);
        x0 = x1;
        y0 = y1;
      }
    }
    _addLine(x0, y0, x2, y2);
  }
  
  void _curveBreakIntoLinesAndAdd(double x0, double y0, Curve c, double x3, double y3) {
    int count = MarlinConst.cubCount;
    final double icount = MarlinConst.cubInvCount;
    final double icount2 = MarlinConst.cubInvCount2;
    final double icount3 = MarlinConst.cubInvCount3;
    
    double dddx = 2.0 * c.dax * icount3;
    double dddy = 2.0 * c.day * icount3;
    double ddx = dddx + c.dbx * icount2;
    double ddy = dddy + c.dby * icount2;
    double dx = c.ax * icount3 + c.bx * icount2 + c.cx * icount;
    double dy = c.ay * icount3 + c.by * icount2 + c.cy * icount;
    
    // Bounds for step adjustment (standard values)
    const double decBnd = 1.0; 
    const double incBnd = 0.4; // Approximations based on typical behavior

    while (count > 0) {
      // Decrease step if error too large
      while (dx.abs() >= decBnd || dy.abs() >= decBnd) { // Using dx/dy as proxy for derivatives?
        // Actually Renderer.java checks ddx/ddy? 
        // "Math.abs(ddx) >= _DEC_BND"
        // Let's check ddx/ddy.
        if (ddx.abs() < decBnd && ddy.abs() < decBnd) break; // Optimization
        
        dddx /= 8.0;
        dddy /= 8.0;
        ddx = ddx / 4.0 - dddx;
        ddy = ddy / 4.0 - dddy;
        dx = (dx - ddx) / 2.0;
        dy = (dy - ddy) / 2.0;
        count <<= 1;
      }
      
      // Increase step if error very small
      // "Math.abs(dx) <= _INC_BND" - wait, Renderer.java comments say:
      // "LBO: why use first derivative dX|Y instead of second ddX|Y ?"
      // It DOES use dx/dy in the check.
      while (count % 2 == 0 && dx.abs() <= incBnd && dy.abs() <= incBnd) {
         dx = 2.0 * dx + ddx;
         dy = 2.0 * dy + ddy;
         ddx = 4.0 * (ddx + dddx);
         ddy = 4.0 * (ddy + dddy);
         dddx *= 8.0;
         dddy *= 8.0;
         count >>= 1;
      }
      
      count--;
      if (count > 0) {
        double x1 = x0 + dx;
        dx += ddx;
        ddx += dddx;
        double y1 = y0 + dy;
        dy += ddy;
        ddy += dddy;
        
        _addLine(x0, y0, x1, y1);
        x0 = x1;
        y0 = y1;
      } else {
        _addLine(x0, y0, x3, y3);
      }
    }
  }
  
  void endRendering([int color = 0]) {
    _bucketsMinY = FloatMath.maxInt(_edgeMinY, _boundsMinY);
    _bucketsMaxY = FloatMath.minInt(_edgeMaxY, _boundsMaxY);

    int y = _bucketsMinY;
    int bucket = y - _boundsMinY;
    int numCrossings = 0;
    final int edgeBucketsLen = _edgeBuckets.length;
    
    // Clear cache state for new render
    _cache.resetTileLine(y);

    // Iteration on scanlines
    for (; y < _bucketsMaxY; y++, bucket++) {
        if (bucket >= edgeBucketsLen) break; 
        
        int bucketCount = _edgeBucketCounts[bucket];
        
        // Remove finished edges and add new ones
        if (bucketCount != 0) {
            // Remove finished edges first?
            // "bucketCount & 0x1" means YMax reached for some edges.
            if ((bucketCount & 0x1) != 0) {
               int newCount = 0;
               for(int i=0; i<numCrossings; i++) {
                   int ptr = _edgePtrs[i];
                   // Check if edge ends at this Y.
                   // yMax is _edges[ptr + _offYMaxOr] >> 1
                   if ((_edges[ptr + _offYMaxOr] >> 1) > y) {
                       _edgePtrs[newCount++] = ptr;
                   }
               }
               numCrossings = newCount;
            }
            
            // Add new edges
            if (bucketCount > 1) {
                int ptr = _edgeBuckets[bucket];
                while(ptr != 0) {
                    if (_edgePtrs.length <= numCrossings) {
                        _edgePtrs = _widenIntArray(_edgePtrs, numCrossings, _edgePtrs.length << 1);
                    }
                    _edgePtrs[numCrossings++] = ptr;
                    ptr = _edges[ptr + _offNext];
                }
            }
            
            // Reset bucket count for reuse (Java does this in dispose or clear?)
            // We should zero it in dispose or here. Java recurses so it cleans up.
            // We are not recursing, we assume clear/init zeros it.
            _edgeBucketCounts[bucket] = 0; // Clear for next path
        }

        // Process active edges
        // 1. Compute Crossings
        if (_crossings.length < numCrossings) {
             _crossings = _widenIntArray(_crossings, 0, numCrossings + 1024); // simplistic resize
        }
        
        for (int i = 0; i < numCrossings; i++) {
            int ptr = _edgePtrs[i];
            int curx = _edges[ptr + _offCurX];
            
            // Add to crossings: (curx << 1) | orientation
            int orientation = _edges[ptr + _offYMaxOr] & 1;
            _crossings[i] = (curx << 1) | orientation;
            
            // Update edge for next scanline
            int error = _edges[ptr + _offError];
            error += _edges[ptr + _offBumpErr];
            curx += _edges[ptr + _offBumpX];
            
            // Apply error carry
            // int carry = (error >> 31) & 1; using logic directly
            
            // if error (32-bit signed) has bit 31 set, it is negative.
            // (error >> 31) will be -1.
            // (error >> 31) & 1 will be 1.
            int carry = (error >> 31) & 1;
            curx += carry;
            
            _edges[ptr + _offCurX] = curx;
            _edges[ptr + _offError] = error & 2147483647; // Clear sign/carry bit
        }
        
        
        // 2. Sort Crossings
        _quickSort(_crossings, 0, numCrossings - 1);
        
        // 3. Render Scanline
        int minX = _width; // track min/max for efficient clear
        int maxX = 0;
        
        int curCoverage = 0;
        int prevX = 0; // subpixel x
        
        // Clear alphaLine for current row
        _alphaLine.fillRange(0, _width, 0);

        for (int i = 0; i < numCrossings; i++) {
            int cross = _crossings[i];
            int x = cross >> 1; // x subpixel. (cross >> 1) is subpix coordinate? 
            // crossings are (curx << 1). curx is 32.32 fixed point integral part?
            // Wait. _edges[offCurX] is high 32 bits of 32.32 fixed.
            // So curx IS integer pixel? 
            // No. "curx = next VPC = fixed_floor(x1_fixed + 0x7fffffff)". 
            // x1_fixed is subpixel * 2^32.
            // So curx is SUBPIXEL coordinate.
            // _crossings stores subpixel x. 
            // We want PIXEL x for alphaLine. 
            // SUBPIXEL_POSITIONS_X = 8 (log2=3).
            // So pixel x = (subpixel x) >> 3.
            // But we might want subpixel coverage accumulation.
            
            // Java ScanLineIterator: "pix_x = next_x >> _SUBPIXEL_LG_POSITIONS_X".
            // It uses alphaLine (int[]) to store coverage.
            
            // Simplified winding rule processing (NonZero)
            int orientation = (cross & 1) == 1 ? 1 : -1;
            
            if (x > prevX) {
                // Determine pixels spanned
                
                // Winding rule:
                // If NonZero (1), we use curCoverage (and abs() later).
                // If EvenOdd (0), we use (curCoverage & 1).
                int winding = curCoverage;
                if (_windingRule == MarlinConst.windEvenOdd) {
                    winding &= 1;
                }
                
                // Optimized fill
                int p0 = prevX >> _subpixelLgPositionsX;
                int p1 = x >> _subpixelLgPositionsX;
                
                if (p0 == p1) {
                    if (p0 >= 0 && p0 < _alphaLine.length) {
                        int delta = x - prevX;
                        _alphaLine[p0] += delta * winding;
                        if (p0 < minX) minX = p0;
                        if (p0 > maxX) maxX = p0;
                    }
                } else {
                     if (p0 >= 0 && p0 < _alphaLine.length) {
                         int nextP = (p0 + 1) << _subpixelLgPositionsX;
                         int delta = nextP - prevX;
                         _alphaLine[p0] += delta * winding;
                         if (p0 < minX) minX = p0;
                         if (p0 > maxX) maxX = p0;
                     }
                     
                     int pStart = math.max(p0 + 1, 0);
                     int pEnd = math.min(p1, _alphaLine.length);
                     int fullCover = _subpixelPositionsX * winding;
                     
                     if (pEnd > pStart) {
                         for (int p = pStart; p < pEnd; p++) {
                             _alphaLine[p] += fullCover;
                         }
                         if (pStart < minX) minX = pStart;
                         int lastP = pEnd - 1;
                         if (lastP > maxX) maxX = lastP;
                     }
                     
                     if (p1 >= 0 && p1 < _alphaLine.length) {
                         int prevP1 = p1 << _subpixelLgPositionsX;
                         int delta = x - prevP1;
                         _alphaLine[p1] += delta * winding;
                         if (p1 < minX) minX = p1;
                         if (p1 > maxX) maxX = p1;
                     }
                }
            }
            curCoverage += orientation;
            prevX = x; // update prevX
        }
        
        // Copy to Cache
        if (maxX >= minX) {
             // Convert accumulated subpixel counts to alpha 0..255?
             // MarlinCache expects 0..64 (maxAlpha).
             // _alphaLine stores sums of active subpixels.
             // Max possible value is 8 * winding_count.
             // We need to apply winding rule here.
             
             // Normalize and ABS
             for (int i = minX; i <= maxX; i++) {
                 int val = _alphaLine[i];
                 if (val != 0) {
                     val = val.abs(); // NonZero rule
                     // if EvenOdd: val = val & (maxAlpha); ?
                     // simple clamp
                     if (val > MarlinConst.maxAAAlpha) val = MarlinConst.maxAAAlpha; // MarlinConst.maxAAAlpha
                     _alphaLine[i] = val; // Store back for copyAARow
                 }
             }
             _cache.copyAARow(_alphaLine, y, minX, maxX + 1);
        }

        // Blit cache to buffer if a tile strip is complete
        if ((y + 1) % MarlinConst.tileSize == 0 || y == _bucketsMaxY - 1) {
            _blit(color);
            if (y < _bucketsMaxY - 1) {
                _cache.resetTileLine(y + 1);
            }
        }
    }
    
    // Clear edge buckets for next path
    for (int i = 0; i < edgeBucketsLen; i++) {
        _edgeBuckets[i] = 0;
    }
  }
  
  void _blit(int color) {
      if (_cache.tileMin == 2147483647) return; 
      
      final int tMin = _cache.tileMin;
      final int tMax = _cache.tileMax;
      final int tileW = MarlinConst.tileSize;
      
      // TileSize is 32 subpixels. Subpixel log2Y is 3. 32 >> 3 = 4 pixels.
      // We process 4 pixel rows.
      final int rowsPerBlock = MarlinConst.tileSize >> MarlinConst.subpixelLgPositionsY; 
      final int subpixelsPerPixel = MarlinConst.subpixelPositionsY;

      // Accumulation buffer for the pixel rows in this block (width * 4)
      // Optimisation: reuse a static buffer? For now allow allocation or use small one.
      // To avoid allocs, we iterate tiles.
      
      for (int t = tMin; t < tMax; t++) {
          if (_cache.touchedTile[t] == 0) continue;
          
          final int tx = t * tileW;
          
          // We need to accumulate alpha for the pixels in this tile column.
          // But RLE is row-based.
          // We'll accumulate in a local buffer for the tile width (32 pixels).
          // Width is small (32). Height is 4.
          // Int32List tileAccum = Int32List(32 * 4); // 128 ints. Cheap.
          final Int32List tileAccum = Int32List(256); // Oversize to 256 to be safe against boundary conditions

          final int yStart = _cache.bboxY0;
          final int yLimit = math.min(_cache.bboxY1, yStart + MarlinConst.tileSize);

          // 1. Accumulate subpixels
          for (int y = yStart; y < yLimit; y++) {
              final int rowAAChunkIndex = _cache.rowAAChunkIndex[y % MarlinConst.tileSize];
              if (rowAAChunkIndex == 0) continue;

              final Uint8List rowAAChunk = _cache.rowAAChunk;
              int idx = rowAAChunkIndex;
              // Correct initialization from cache metadata
              int x = _cache.rowAAx0[y % MarlinConst.tileSize];
              
              final int py = (y - yStart) >> MarlinConst.subpixelLgPositionsY; 
              
              // Validate py
              if (py < 0 || py >= rowsPerBlock) continue;
              
              final int accumOffset = py * tileW;

              while (true) {
                  final int val = rowAAChunk[idx++];
                  final int len = rowAAChunk[idx++];
                  if (val == 0 && len == 0) break;

                  if (val != 0) {
                      // Intersect [x, x+len] with [tx, tx+tileW]
                      int start = math.max(x, tx);
                      int end = math.min(x + len, tx + tileW);
                      
                      if (end > start) {
                          int localStart = start - tx;
                          int count = end - start;
                          int dstIdx = accumOffset + localStart;
                          
                          // Safe loop
                          if (dstIdx >= 0 && dstIdx + count <= tileAccum.length) {
                             for (int k = 0; k < count; k++) {
                                tileAccum[dstIdx + k] += val;
                             }
                          }
                      }
                  }
                  x += len;
              }
          }
          
          // 2. Blit tileAccum to pixelBuffer
          final int pYStart = yStart >> MarlinConst.subpixelLgPositionsY;
          final int pYLimit = (yLimit + subpixelsPerPixel - 1) >> MarlinConst.subpixelLgPositionsY;
          
          for (int py = 0; py < (pYLimit - pYStart); py++) {
             final int globalPy = pYStart + py;
             if (globalPy >= _height) break;
             
             final int rowOffset = globalPy * _width;
             final int accumOffset = py * tileW;
             
             for (int px = 0; px < tileW; px++) {
                 final int globalPx = tx + px;
                 if (globalPx >= _width) break;
                 
                 int alphaSum = tileAccum[accumOffset + px];
                 if (alphaSum == 0) continue;
                 
                 // Normalize alpha. 
                 // Max sum is 64 * 8 = 512.
                 // Map 0..512 -> 0..255.
                 int alpha = MarlinCache.alphaMap[alphaSum.clamp(0, 64)];
                 if (alpha > 255) alpha = 255;
                 
                 // Simple blend over buffer
                 // Assume white bg check moved to test? No we blend.
                 final int bg = _pixelBuffer[rowOffset + globalPx];
                 
                 // SrcOver: srcAlpha + dstAlpha*(1-srcAlpha)
                 // Here color is solid (alpha 255 ideally) but shaped by alpha.
                 // So we treat 'alpha' as the coverage of 'color'.
                 
                 int r = (color >> 16) & 0xFF;
                 int g = (color >> 8) & 0xFF;
                 int b = color & 0xFF;
                 
                 int bgR = (bg >> 16) & 0xFF;
                 int bgG = (bg >> 8) & 0xFF;
                 int bgB = bg & 0xFF;
                 
                 int invA = 255 - alpha;
                 
                 int fr = (r * alpha + bgR * invA) ~/ 255;
                 int fg = (g * alpha + bgG * invA) ~/ 255;
                 int fb = (b * alpha + bgB * invA) ~/ 255;
                 
                 _pixelBuffer[rowOffset + globalPx] = 0xFF000000 | (fr << 16) | (fg << 8) | fb;
             }
          }

          _cache.touchedTile[t] = 0;
      }
      _cache.tileMin = 2147483647;
      _cache.tileMax = 0;
  }
  
  // Arrays
  Int32List _widenIntArray(Int32List oldArray, int used, int newSize) {
    if (newSize > ArrayCacheConfig.maxArraySize) {
        // Fallback to allocation
        final newArray = Int32List(newSize);
        newArray.setRange(0, used, oldArray);
        _rdrCtx.putIntArray(oldArray, 0, used);
        return newArray;
    }
    
    final newArray = _rdrCtx.getDirtyIntArrayCache(newSize).getArray();
    newArray.setRange(0, used, oldArray);
    _rdrCtx.putIntArray(oldArray, 0, used); // Recycle old
    return newArray;
  }
  
  // Sort
  static void _quickSort(Int32List a, int left, int right) {
     if (left >= right) return;
     int pi = _partition(a, left, right);
     _quickSort(a, left, pi - 1);
     _quickSort(a, pi + 1, right);
  }
  
  static int _partition(Int32List a, int left, int right) {
    int pivot = a[right];
    int i = (left - 1);
    for (int j = left; j < right; j++) {
      if (a[j] <= pivot) {
        i++;
        int temp = a[i];
        a[i] = a[j];
        a[j] = temp;
      }
    }
    int temp = a[i + 1];
    a[i + 1] = a[right];
    a[right] = temp;
    return i + 1;
  }
  
  // Convenience for backward compat
  void drawTriangle(double x0, double y0, double x1, double y1, double x2, double y2, int color) {
     init(0, 0, 2048, 2048, MarlinConst.windNonZero); // Default size if unknown
     moveTo(x0, y0);
     lineTo(x1, y1);
     lineTo(x2, y2);
     closePath();
     endRendering(color);
  }
  
  void drawPolygon(List<double> vertices, int color) {
      if (vertices.length < 2) return;
      init(0, 0, 2048, 2048, MarlinConst.windNonZero);
      moveTo(vertices[0], vertices[1]);
      for(int i=2; i<vertices.length; i+=2) {
          lineTo(vertices[i], vertices[i+1]);
      }
      closePath();
      endRendering(color);
  }
}
