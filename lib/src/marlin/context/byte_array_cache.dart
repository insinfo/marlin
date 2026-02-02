import 'dart:typed_data';

class ByteArrayCache {
  final int arraySize;
  final List<Uint8List> _arrays = [];
  
  ByteArrayCache(this.arraySize);
  
  Uint8List getArray() {
    if (_arrays.isNotEmpty) {
      return _arrays.removeLast();
    }
    return Uint8List(arraySize);
  }
  
  void putDirtyArray(Uint8List array, int length) {
    if (length != arraySize) return;
    _arrays.add(array);
  }
  
  void putArray(Uint8List array, int length, int fromIndex, int toIndex) {
    if (length != arraySize) return;
    if (toIndex != 0) {
      array.fillRange(fromIndex, toIndex, 0);
    }
    _arrays.add(array);
  }
}
