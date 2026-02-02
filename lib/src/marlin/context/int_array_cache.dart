import 'dart:typed_data';

class IntArrayCache {
  final int arraySize;
  final List<Int32List> _arrays = [];
  
  IntArrayCache(this.arraySize);
  
  Int32List getArray() {
    if (_arrays.isNotEmpty) {
      return _arrays.removeLast();
    }
    return Int32List(arraySize);
  }
  
  void putDirtyArray(Int32List array, int length) {
    if (length != arraySize) {
      // System.out.println("bad length = " + length);
      return;
    }
    _arrays.add(array);
  }
  
  void putArray(Int32List array, int length, int fromIndex, int toIndex) {
    if (length != arraySize) {
      return;
    }
    if (toIndex != 0) {
      array.fillRange(fromIndex, toIndex, 0);
    }
    _arrays.add(array);
  }
  
  static void fill(Int32List array, int fromIndex, int toIndex, int value) {
    if (toIndex != 0) {
      array.fillRange(fromIndex, toIndex, value);
    }
  }
}
