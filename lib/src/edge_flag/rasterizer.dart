import 'dart:typed_data';
import 'dart:math' as math;
import 'common.dart';
import 'edge.dart';
import 'edge_table.dart';
import 'patterns.dart';
import 'scanline_buffer.dart';

enum FillRule {
  evenOdd,
  nonZero,
}

class ScanlineEdgeFlagRasterizer {
  final int width;
  final int height;
  final ScanlineBuffer bufferEvenOdd;
  final ScanlineBuffer bufferNonZero;
  
  // Cache for Active Edge Table
  Edge? activeEdges;
  
  ScanlineEdgeFlagRasterizer(this.width, this.height)
      : bufferEvenOdd = ScanlineBufferEvenOdd8(width),
        bufferNonZero = ScanlineBufferNonZero8(width);

  // Output buffer (alpha)
  Uint8List? _outputBuffer;
  Uint8List get outputBuffer {
    _outputBuffer ??= Uint8List(width * height);
    return _outputBuffer!;
  }

  void rasterize(List<double> vertices, FillRule rule) {
    if (_outputBuffer == null) _outputBuffer = Uint8List(width * height);
    else _outputBuffer!.fillRange(0, _outputBuffer!.length, 0); // Clear output

    // 1. Create Edge Table
    // ET is indexed by scanline (not subpixel)
    EdgeTable et = EdgeTable(0, height);
    
    // Scale factor for subpixels
    int subpixelShift = SamplingPatterns.shift8;
    int subpixelCount = SamplingPatterns.count8;
    
    _buildEdgeTable(et, vertices, subpixelShift, subpixelCount);
    
    // 2. Process Scanlines
    ScanlineBuffer scanlineBuffer = (rule == FillRule.evenOdd) ? bufferEvenOdd : bufferNonZero;
    
    activeEdges = null;
    
    for (int y = 0; y < height; y++) {
      // Clear scanline buffer
      scanlineBuffer.clear();
      
      // We process sub-scanlines?
      // No, "The algorithm works ... by mapping n-samples to sub-pixels".
      // But the loop in the article (Algorithm 1) iterates y from y0 to y1 (subpixels).
      // Wait. The Edge Table should ideally be bucketed by *scanline* if we use the scanline-oriented approach.
      // But the DDA runs on sub-pixels?
      // Let's re-read the article section 3.6 Scanline-oriented approach.
      // "Each edge is inserted to the edge table at a slot determined by starting y. The value of starting y is divided by the sub-pixel count."
      // So ET buckets are SCANLINES (pixels).
      
      // Add edges from ET to AET
      Edge? newEdges = et.getEdgesForScanline(y);
      if (newEdges != null) {
        _insertActiveEdges(newEdges);
      }
      
      if (activeEdges != null) {
        // Sort AET by X? No, Edge Flag doesn't need sorted edges! 
        // We just iterate all active edges and plot them into the mask.
        // That's the beauty of Edge Flag. Unordered edges.
        
        _plotActiveEdges(y, subpixelCount, scanlineBuffer);
        
        // Remove finished edges
        _updateActiveEdges(y, subpixelCount);
      }
      
      // Resolve scanline to alpha
      // We need to write to the correct row in output buffer
      Uint8List targetRow = _outputBuffer!.sublist(y * width, (y + 1) * width); 
      // Note: sublist creates a copy? Yes. view is better.
      // In Dart, Uint8List.view needs exact offset alignment?
      // buffer.asTypedList? 
      // Optimization: use a shared scratch buffer for resolve, then copy?
      // Or pass offset to resolveToAlpha?
      // Let's assume resolveToAlpha writes to a passed buffer.
      // ScanlineBuffer.resolveToAlpha takes Uint8List.
      // I can pass a view if possible.
      // width is usually aligned enough.
      
      // Actually standard Uint8List view:
      var bufferView = Uint8List.view(_outputBuffer!.buffer, y * width, width);
      scanlineBuffer.resolveToAlpha(bufferView);
    }
  }

  void _buildEdgeTable(EdgeTable et, List<double> vertices, int subScope, int subCount) {
    int count = vertices.length ~/ 2;
    if (count < 3) return;
    
    double prevX = vertices[(count - 1) * 2];
    double prevY = vertices[(count - 1) * 2 + 1];
    
    for (int i = 0; i < count; i++) {
        double currX = vertices[i * 2];
        double currY = vertices[i * 2 + 1];
        
        _addEdge(et, prevX, prevY, currX, currY, subScope, subCount);
        
        prevX = currX;
        prevY = currY;
    }
  }

  void _addEdge(EdgeTable et, double x0, double y0, double x1, double y1, int subShift, int subCount) {
      // Convert to fixed point (scaled by subCount?)
      // The article says: "coordinates in the y direction need to be scaled by the amount of samples."
      // Actually, if we use sub-scanlines, Y is in sub-pixels.
      // The Edge class uses yStart/yEnd as integers.
      // If buckets are scanlines, yStarts should include subpixel info.
      // "getEdgesForScanline(y)" uses index = y.
      
      // Let's convert input coordinates to sub-pixel fixed point.
      // Wait, standard DDA uses X in fixed point, Y stepping by 1 scanline?
      // In this algorithm, we step in Y by *1 subpixel* or *1 scanline*?
      // "The edges in AET are plotted to the sub-scanlines of the scanline."
      // So for each scanline, we run a loop of 8 sub-scanlines.
      
      // Coordinates:
      // Y is float. y0, y1.
      // subY0 = floor(y0 * subCount)
      // subY1 = floor(y1 * subCount)
      
      double sy0 = y0 * subCount;
      double sy1 = y1 * subCount;
      
      int iy0 = sy0.floor();
      int iy1 = sy1.floor();
      
      if (iy0 == iy1) return; // Horizontal (in subpixels) or very short
      
      double sx0 = x0;
      double sx1 = x1;
      
      int dir = 1;
      if (iy0 > iy1) {
          // Swap
          int t = iy0; iy0 = iy1; iy1 = t;
          double td = sx0; sx0 = sx1; sx1 = td;
          double tyd = sy0; sy0 = sy1; sy1 = tyd;
          dir = -1;
      }
      
      double dx = (sx1 - sx0) / (sy1 - sy0);
      
      // Edge spans from iy0 to iy1 (sub-scanlines).
      
      // We verify if it crosses any scanline boundaries? 
      // The algorithm plots into a temporary buffer (scanline buffer).
      // The buffer represents ONE pixel row.
      // It has subpixels rows implicitly? 
      // No, the algorithm says: 
      // "Algorithm 1: Plotting an edge with supersampling... for y <- y0, y < y1 ... xi <- FLOOR(x + offset[y mod 8]) ... bits[y][xi] <- XOR"
      // Wait, "bits" in Algorithm 1 is 2D array?
      // "This can be a temporary canvas of the size of the filled area, OR preferably a one pixel high buffer..."
      // If we use one pixel high buffer (Scanline Buffer), we are doing it scanline by scanline.
      
      // In "Scanline-oriented approach":
      // "The edge table consists of an array of slots, one slot per scanline...
      // Each edge is inserted to the edge table at a slot determined by starting y.
      // The value of starting y is divided by the sub-pixel count to get the correct slot."
      
      int scanlineStart = iy0 >> subShift; // iy0 ~/ 8
      
      // Initial X at iy0
      int fixedX = floatToFixed(sx0);
      int fixedSlope = floatToFixed(dx);
      
      // Correction for sub-pixel start?
      // We need x at scanlineStart?
      // No, we need x at iy0. 
      // But when we process scanline `y`, we iterate subpixels `s` from 0 to 7.
      // The actual sub-pixel Y is `y * 8 + s`.
      // The edge starts at `iy0 = yStartSub`.
      // So if `y * 8 + s < iy0`, we skip.
      
      // We add the edge to `scanlineStart`.
      
      Edge edge = Edge(
        yStart: iy0,  // Sub-pixel Y start
        yEnd: iy1,    // Sub-pixel Y end
        x: fixedX,    // Fixed point X at yStart
        slope: fixedSlope,
        dir: dir,
      );
      
      // But `EdgeTable` expects `yStart` to be scanline index?
      // I implemented `EdgeTable.addEdge` as `index = edge.yStart - minY`.
      // So I should pass `scanlineStart` to `EdgeTable`?
      // But `Edge` struct needs to store the actual sub-pixel start/end for the loop.
      // I'll add `scanlineY` to `Edge` or just use `yStart >> subShift` when adding to table.
      // The `Edge` struct in `edge.dart` has `yStart`. I'll assume that's the sub-pixel Y.
      // But I need to modify `EdgeTable` to bucket by `yStart >> shift`.
      // Or I handle it in `_buildEdgeTable`.
      
      // Let's modify EdgeTable usage.
      // I will wrapper the `Edge` adding.
      // `et.buckets` is indexed by scanline.
      
      // Store the Next Scanline index in the Edge? No.
      // We just put it in the bucket `iy0 >> subShift`.
      
      // Wait, `edge.dart` has `yStart`. Let's use `yStart` as sub-pixel coordinate.
      // But `EdgeTable` logic: `index = edge.yStart - minY`.
      // If `minY` is 0 (scanlines), and `edge.yStart` is subpixels, index will be wrong.
      // I should subclass `EdgeTable` or change logic? 
      // "Edge Table" usually buckets by scanline.
      // So `et.addEdge` should take `(edge, scanlineIndex)`.
      
      // I'll fix `_addEdge` to insert into `et` manually or fix `EdgeTable`.
      // Let's use `et.buckets[scanlineStart].add(edge)`.
      
      if (scanlineStart < height) { // Bound check
          // Handle linking
          Edge? existing = et.buckets[scanlineStart];
          edge.next = existing;
          et.buckets[scanlineStart] = edge;
      }
  }

  void _insertActiveEdges(Edge edgeList) {
      // Just prepend to activeEdges
      Edge? curr = edgeList;
      while (curr != null) {
          Edge? next = curr.next;
          curr.next = activeEdges;
          activeEdges = curr;
          curr = next;
      }
  }

  void _plotActiveEdges(int y, int subCount, ScanlineBuffer buffer) {
      Edge? prev = null;
      Edge? curr = activeEdges;
      
      // We process 8 sub-scanlines per scanline
      int scanlineBase = y << SamplingPatterns.shift8; // y * 8
      
      // Precomputed fixed point offsets (should be static/cached)
      // 0.25, 0.875, 0.5, 0.125, 0.75, 0.375, 0, 0.625
      // Converted to fixed point (12 bits)
      // We can use a small array.
      // (val * 4096).floor()
      const List<int> fixedOffsets = [ // for 8 samples
         2560, // 5/8 * 4096
         0,    // 0/8
         1536, // 3/8
         3072, // 6/8
         512,  // 1/8
         2048, // 4/8
         3584, // 7/8
         1024  // 2/8
      ];
      // Note: The order corresponds to subpixel Y index (0..7).
      // The article says: offset[y mod 8].
      // Since we iterate s=0..7, we access fixedOffsets[s].
      
      while (curr != null) {
          int startSub = curr.yStart - scanlineBase;
          if (startSub < 0) startSub = 0;
          
          int endSub = curr.yEnd - scanlineBase;
          if (endSub > subCount) endSub = subCount;
          
          if (startSub < endSub) {
              // Iterate subpixels
             for (int s = startSub; s < endSub; s++) {
                 // Calculate pixel X
                 // X is fixed point.
                 // We add n-rooks offset.
                 // The offset shifts the sampling point within the pixel.
                 // Ideally: pixelX = floor(curr.x + offset)
                 // curr.x includes sub-pixel precision.
                 // offsets are within [0, 1) pixel.
                 // So we add offset in fixed point then shift down integer part.
                 
                 int px = (curr.x + fixedOffsets[s]) >> fixedPointShift;
                 
                 // Debug active
                 // if (y == 50 && s == 4) print('Plotting at y=$y s=$s x=$px dir=${curr.dir} xFixed=${curr.x}');
                 
                 if (buffer is ScanlineBufferEvenOdd8) {
                     buffer.toggle(px, s);
                 } else {
                     buffer.add(px, s, curr.dir);
                 }
                 
                 curr.x += curr.slope;
             }
          }
           
          // If the edge continues beyond this scanline, x is now correct for next scanline?
          // We advanced x by (endSub - startSub) steps.
          // If endSub=8, we reached end of scanline.
          // If startSub > 0, we started late.
          // But for NEXT scanline, startSub will be 0 (since scanlineBase increases by 8).
          // And we want x to constitute full 8 steps from previous scanlineBase+8.
          // The issue is: if we skipped steps at the beginning (startSub > 0), 
          // we didn't add slope for those steps.
          // But `x` was initialized at `yStart`.
          // So `x` corresponds to `yStart`.
          // We added slope (endSub - startSub) times.
          // New `x` corresponds to `yStart + (endSub - startSub)`.
          // If endSub = 8, then `yEndThisScanline = scanlineBase + 8`.
          // New `x` corresponds to `yStart + 8 - startSub` = `scanlineBase + startSub + 8 - startSub` = `scanlineBase + 8`.
          // So `x` is correctly positioned at the start of NEXT scanline (scanlineBase+8).
          // CORRECT.
          
          // Edge case: gaps?
          // If `startSub >= endSub`, we do nothing.
          // e.g. edge starts at subpixel 10. scanlineBase=0. startSub=10. endSub=8. Loop doesn't run.
          // This edge shouldn't be in AET?
          // `_addEdge` inserts into `scanlineStart = iy0 >> shift`.
          // So an edge starting at 10 (scanline 1, sub 2) will be in bucket 1.
          // When processing scanline 0, it's not in AET.
          // So `startSub` will never be > 8 if logic is correct.
          // `startSub = 10 - 0 = 10`. Loop doesn't run.
          // `curr` moves to next.
          // This edge will remain in AET? 
          // No, AET only contains edges that *started* or *continue*.
          // Edges are added from `et` at `y`.
          // So `startSub` will be usually >= 0.
          
          // What about `endSub`.
          // If `curr.yEnd < scanlineBase`, edge is dead.
          // It should be removed.
          
          curr = curr.next;
      }
  }

  void _updateActiveEdges(int y, int subCount) {
      // Remove edges that end before the START of the NEXT scanline.
      // Next scanline starts at (y+1) * 8.
      // If curr.yEnd <= (y+1) * 8, it is finished.
      
      int nextScanlineStart = (y + 1) << SamplingPatterns.shift8;
      
      Edge? prev = null;
      Edge? curr = activeEdges;
      
      while (curr != null) {
          if (curr.yEnd <= nextScanlineStart) {
              // Remove
              if (prev == null) {
                  activeEdges = curr.next;
              } else {
                  prev.next = curr.next;
              }
          } else {
              prev = curr;
          }
          curr = curr.next;
      }
  }
}

