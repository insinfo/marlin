
/// Constants and configuration for ArrayCache
class ArrayCacheConfig {
  static const int buckets = 4;
  static const int minArraySize = 4096;
  static late final int maxArraySize;
  static final List<int> arraySizes = List<int>.filled(buckets, 0);
  
  static const int minDirtyByteArraySize = 32 * 2048;
  static late final int maxDirtyByteArraySize;
  static final List<int> dirtyByteArraySizes = List<int>.filled(buckets, 0);
  
  // threshold to grow arrays only by (3/2) instead of 2
  static late final int thresholdArraySize;

  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;

    int arraySize = minArraySize;
    for (int i = 0; i < buckets; i++, arraySize <<= 2) {
      arraySizes[i] = arraySize;
    }
    maxArraySize = arraySize >> 2;
    
    arraySize = minDirtyByteArraySize;
    for (int i = 0; i < buckets; i++, arraySize <<= 1) {
      dirtyByteArraySizes[i] = arraySize;
    }
    maxDirtyByteArraySize = arraySize >> 1;
    
    int t = 2 * 1024 * 1024;
    thresholdArraySize = t > maxArraySize ? t : maxArraySize; 
  }
  
  static int getBucket(int length) {
    if (!_initialized) init();
    for (int i = 0; i < arraySizes.length; i++) {
        if (length <= arraySizes[i]) {
            return i;
        }
    }
    return -1;
  }
  
  static int getBucketDirtyBytes(int length) {
    if (!_initialized) init();
    for (int i = 0; i < dirtyByteArraySizes.length; i++) {
        if (length <= dirtyByteArraySizes[i]) {
            return i;
        }
    }
    return -1;
  }
  
  static int getNewSize(int curSize, int needSize) {
    if (!_initialized) init();
    // initial = (curSize & MASK_CLR_1) -> simply curSize here as we don't assume bits
    int size;
    if (curSize > thresholdArraySize) {
        size = (curSize * 3) >> 1; // 1.5x
    } else {
        size = curSize << 1; // 2x
    }
    if (size < needSize) {
        size = needSize;
    }
    return size;
  }
}
