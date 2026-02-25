/// Glyph cache/atlas for efficient text rendering (Fase 10).
///
/// Caches rasterized glyph bitmaps (A8 coverage masks) keyed by
/// (fontFaceId, glyphId, fontSize). Uses LRU eviction when the cache
/// exceeds a configurable entry limit.
///
/// Inspired by: Blend2D's glyph cache design and SDF atlas concepts.
library blend2d_glyph_cache;

import 'dart:typed_data';

/// A single cached glyph bitmap entry.
class BLGlyphCacheEntry {
  /// Glyph ID.
  final int glyphId;

  /// Font size this entry was rasterized at.
  final double fontSize;

  /// Width of the glyph bitmap in pixels.
  final int width;

  /// Height of the glyph bitmap in pixels.
  final int height;

  /// X offset from glyph origin to bitmap left edge.
  final int bearingX;

  /// Y offset from glyph origin (baseline) to bitmap top edge.
  final int bearingY;

  /// A8 coverage bitmap (width * height bytes).
  final Uint8List bitmap;

  /// Timestamp for LRU eviction.
  int lastAccessTime;

  BLGlyphCacheEntry({
    required this.glyphId,
    required this.fontSize,
    required this.width,
    required this.height,
    required this.bearingX,
    required this.bearingY,
    required this.bitmap,
    this.lastAccessTime = 0,
  });

  /// Returns total memory used by this entry (approximate).
  int get memorySize => bitmap.length + 64; // bitmap + overhead
}

/// Cache key for glyph lookup.
class _GlyphCacheKey {
  final int fontFaceId;
  final int glyphId;
  final int sizeKey; // fontSize * 64, rounded to int for hashing

  const _GlyphCacheKey(this.fontFaceId, this.glyphId, this.sizeKey);

  @override
  bool operator ==(Object other) =>
      other is _GlyphCacheKey &&
      fontFaceId == other.fontFaceId &&
      glyphId == other.glyphId &&
      sizeKey == other.sizeKey;

  @override
  int get hashCode => Object.hash(fontFaceId, glyphId, sizeKey);
}

/// LRU glyph cache with configurable entry and memory limits.
///
/// Usage:
/// ```dart
/// final cache = BLGlyphCache(maxEntries: 4096);
/// final entry = cache.get(fontFaceId, glyphId, fontSize);
/// if (entry == null) {
///   // Rasterize glyph and store
///   cache.put(fontFaceId, glyphId, fontSize, newEntry);
/// }
/// ```
class BLGlyphCache {
  /// Maximum number of cached entries.
  final int maxEntries;

  /// Maximum total memory in bytes (0 = unlimited).
  final int maxMemoryBytes;

  final Map<_GlyphCacheKey, BLGlyphCacheEntry> _cache = {};
  int _accessCounter = 0;
  int _totalMemory = 0;

  BLGlyphCache({
    this.maxEntries = 4096,
    this.maxMemoryBytes = 16 * 1024 * 1024, // 16 MB default
  });

  /// Number of entries currently cached.
  int get length => _cache.length;

  /// Total memory used by cached bitmaps.
  int get memoryUsed => _totalMemory;

  /// Cache hit rate tracking.
  int _hits = 0;
  int _misses = 0;

  /// Hit rate since creation (0.0 to 1.0).
  double get hitRate {
    final total = _hits + _misses;
    return total > 0 ? _hits / total : 0.0;
  }

  /// Looks up a cached glyph entry.
  BLGlyphCacheEntry? get(int fontFaceId, int glyphId, double fontSize) {
    final key = _GlyphCacheKey(fontFaceId, glyphId, (fontSize * 64).round());
    final entry = _cache[key];
    if (entry != null) {
      entry.lastAccessTime = ++_accessCounter;
      _hits++;
      return entry;
    }
    _misses++;
    return null;
  }

  /// Stores a glyph entry in the cache, evicting old entries if needed.
  void put(
    int fontFaceId,
    int glyphId,
    double fontSize,
    BLGlyphCacheEntry entry,
  ) {
    final key = _GlyphCacheKey(fontFaceId, glyphId, (fontSize * 64).round());

    // Remove existing entry if present
    final existing = _cache[key];
    if (existing != null) {
      _totalMemory -= existing.memorySize;
    }

    // Evict if needed
    while (_cache.length >= maxEntries ||
        (maxMemoryBytes > 0 &&
            _totalMemory + entry.memorySize > maxMemoryBytes)) {
      if (_cache.isEmpty) break;
      _evictLRU();
    }

    entry.lastAccessTime = ++_accessCounter;
    _cache[key] = entry;
    _totalMemory += entry.memorySize;
  }

  /// Evicts the least recently used entry.
  void _evictLRU() {
    _GlyphCacheKey? lruKey;
    int lruTime = _accessCounter + 1;

    for (final entry in _cache.entries) {
      if (entry.value.lastAccessTime < lruTime) {
        lruTime = entry.value.lastAccessTime;
        lruKey = entry.key;
      }
    }

    if (lruKey != null) {
      final removed = _cache.remove(lruKey);
      if (removed != null) {
        _totalMemory -= removed.memorySize;
      }
    }
  }

  /// Clears the entire cache.
  void clear() {
    _cache.clear();
    _totalMemory = 0;
    _hits = 0;
    _misses = 0;
    _accessCounter = 0;
  }

  /// Evicts all entries for a specific font face.
  void evictFont(int fontFaceId) {
    _cache.removeWhere((key, value) {
      if (key.fontFaceId == fontFaceId) {
        _totalMemory -= value.memorySize;
        return true;
      }
      return false;
    });
  }

  /// Returns cache statistics as a map.
  Map<String, dynamic> get stats => {
        'entries': _cache.length,
        'memoryBytes': _totalMemory,
        'hits': _hits,
        'misses': _misses,
        'hitRate': hitRate,
      };
}
