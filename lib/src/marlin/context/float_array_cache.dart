import 'dart:typed_data';

class FloatArrayCache {
  final int arraySize;
  final List<Float32List> _arrays = [];
  
  FloatArrayCache(this.arraySize);
  
  Float32List getArray() {
    if (_arrays.isNotEmpty) {
      return _arrays.removeLast();
    }
    return Float32List(arraySize);
  }
  
  void putDirtyArray(Float32List array, int length) {
    if (length != arraySize) return;
    _arrays.add(array);
  }
  
  void putArray(Float32List array, int length, int fromIndex, int toIndex) {
    if (length != arraySize) return;
    if (toIndex != 0) {
      array.fillRange(fromIndex, toIndex, 0.0);
    }
    _arrays.add(array);
  }
}
