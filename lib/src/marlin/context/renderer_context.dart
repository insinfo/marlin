import 'dart:typed_data';
import 'array_cache_config.dart';
import 'int_array_cache.dart';
import 'float_array_cache.dart';
import 'byte_array_cache.dart';
// import 'package:marlin/src/marlin/marlin_renderer.dart';

class RendererContext {
  static final RendererContext _instance = RendererContext("ctx0");

  static RendererContext createContext() {
    return _instance;
  }

  final String name;
  final ArrayCachesHolder _holder;
  // MarlinRenderer? renderer; // circular dependency handling
  
  RendererContext(this.name) : _holder = ArrayCachesHolder();

  ArrayCachesHolder getArrayCachesHolder() => _holder;

  // IntArrayCache
  IntArrayCache getIntArrayCache(int length) {
    final bucket = ArrayCacheConfig.getBucket(length);
    return _holder.intArrayCaches[bucket];
  }
  
  List<int> getIntArray(int length) { // returns Int32List but type as List for flexibility
    if (length <= ArrayCacheConfig.maxArraySize) {
      return getIntArrayCache(length).getArray();
    }
    return List<int>.filled(length, 0); // fallback, though Int32List preferred
  }
  
  // Dirty Int
  IntArrayCache getDirtyIntArrayCache(int length) {
    final bucket = ArrayCacheConfig.getBucket(length);
    return _holder.dirtyIntArrayCaches[bucket];
  }
  
  // Float
  FloatArrayCache getDirtyFloatArrayCache(int length) {
     final bucket = ArrayCacheConfig.getBucket(length);
     return _holder.dirtyFloatArrayCaches[bucket];
  }
  
  // Byte
  ByteArrayCache getDirtyByteArrayCache(int length) {
    final bucket = ArrayCacheConfig.getBucketDirtyBytes(length);
    return _holder.dirtyByteArrayCaches[bucket];
  }

  // Int32List Reuse
  void putIntArray(Int32List array, int fromIndex, int toIndex) {
      if (array.length <= ArrayCacheConfig.maxArraySize) {
          final bucket = ArrayCacheConfig.getBucket(array.length);
          _holder.intArrayCaches[bucket].putArray(array, array.length, fromIndex, toIndex);
      }
  }

  void putDirtyIntArray(Int32List array) {
      if (array.length <= ArrayCacheConfig.maxArraySize) {
          final bucket = ArrayCacheConfig.getBucket(array.length);
          _holder.dirtyIntArrayCaches[bucket].putDirtyArray(array, array.length);
      }
  }
  
  void putDirtyByteArray(Uint8List array) {
      if (array.length <= ArrayCacheConfig.maxArraySize) {
          final bucket = ArrayCacheConfig.getBucketDirtyBytes(array.length);
          _holder.dirtyByteArrayCaches[bucket].putDirtyArray(array, array.length);
      }
  }
}

class ArrayCachesHolder {
  late final List<IntArrayCache> intArrayCaches;
  late final List<IntArrayCache> dirtyIntArrayCaches;
  late final List<FloatArrayCache> dirtyFloatArrayCaches;
  late final List<ByteArrayCache> dirtyByteArrayCaches;

  ArrayCachesHolder() {
    ArrayCacheConfig.init();
    final buckets = ArrayCacheConfig.buckets;
    
    intArrayCaches = List.generate(buckets, (i) => IntArrayCache(ArrayCacheConfig.arraySizes[i]));
    dirtyIntArrayCaches = List.generate(buckets, (i) => IntArrayCache(ArrayCacheConfig.arraySizes[i]));
    dirtyFloatArrayCaches = List.generate(buckets, (i) => FloatArrayCache(ArrayCacheConfig.arraySizes[i]));
    dirtyByteArrayCaches = List.generate(buckets, (i) => ByteArrayCache(ArrayCacheConfig.dirtyByteArraySizes[i]));
  }
}
