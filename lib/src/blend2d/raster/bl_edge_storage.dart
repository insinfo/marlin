import 'dart:typed_data';

/// Estrutura de edges inspirada no `edgestorage` do Blend2D.
///
/// Mantem arrays SoA e buckets por scanline para reduzir alocacoes no hot-path.
class BLEdgeStorage {
  final int height;
  final Int32List bucketHead;

  Int32List _next;
  Int32List _yEnd;
  Int32List _winding;
  Int32List _x;
  Int32List _xLift;
  Int32List _xRem;
  Int32List _xErr;
  Int32List _dy;
  Float64List _dxF;

  int _edgeCount = 0;

  BLEdgeStorage(this.height, {int initialCapacity = 256})
      : assert(height > 0),
        bucketHead = Int32List(height),
        _next = Int32List(initialCapacity),
        _yEnd = Int32List(initialCapacity),
        _winding = Int32List(initialCapacity),
        _x = Int32List(initialCapacity),
        _xLift = Int32List(initialCapacity),
        _xRem = Int32List(initialCapacity),
        _xErr = Int32List(initialCapacity),
        _dy = Int32List(initialCapacity),
        _dxF = Float64List(initialCapacity) {
    beginFrame();
  }

  int get edgeCount => _edgeCount;

  Int32List get next => _next;
  Int32List get yEnd => _yEnd;
  Int32List get winding => _winding;
  Int32List get x => _x;
  Int32List get xLift => _xLift;
  Int32List get xRem => _xRem;
  Int32List get xErr => _xErr;
  Int32List get dy => _dy;
  Float64List get dxF => _dxF;

  void beginFrame() {
    bucketHead.fillRange(0, bucketHead.length, -1);
    _edgeCount = 0;
  }

  void addEdge({
    required int yStart,
    required int yEnd,
    required int xAtStart,
    required int xLiftPerRow,
    required int xRemPerRow,
    required int xErrStart,
    required int dy,
    required double dxPerRowF,
    required int edgeWinding,
  }) {
    final idx = _edgeCount++;
    _ensureCapacity(_edgeCount);

    _yEnd[idx] = yEnd;
    _x[idx] = xAtStart;
    _xLift[idx] = xLiftPerRow;
    _xRem[idx] = xRemPerRow;
    _xErr[idx] = xErrStart;
    _dy[idx] = dy;
    _dxF[idx] = dxPerRowF;
    _winding[idx] = edgeWinding;
    _next[idx] = bucketHead[yStart];
    bucketHead[yStart] = idx;
  }

  void _ensureCapacity(int required) {
    if (required <= _next.length) return;
    int newCap = _next.length * 2;
    while (newCap < required) {
      newCap *= 2;
    }

    final newNext = Int32List(newCap)..setAll(0, _next);
    final newYEnd = Int32List(newCap)..setAll(0, _yEnd);
    final newWinding = Int32List(newCap)..setAll(0, _winding);
    final newX = Int32List(newCap)..setAll(0, _x);
    final newXLift = Int32List(newCap)..setAll(0, _xLift);
    final newXRem = Int32List(newCap)..setAll(0, _xRem);
    final newXErr = Int32List(newCap)..setAll(0, _xErr);
    final newDy = Int32List(newCap)..setAll(0, _dy);
    final newDxF = Float64List(newCap)..setAll(0, _dxF);

    _next = newNext;
    _yEnd = newYEnd;
    _winding = newWinding;
    _x = newX;
    _xLift = newXLift;
    _xRem = newXRem;
    _xErr = newXErr;
    _dy = newDy;
    _dxF = newDxF;
  }
}
