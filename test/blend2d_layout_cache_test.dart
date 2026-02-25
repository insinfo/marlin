import 'dart:typed_data';
import 'package:test/test.dart';
import '../lib/src/blend2d/text/bl_opentype_layout.dart';
import '../lib/src/blend2d/text/bl_glyph_cache.dart';

// ============================================================================
// Helper: build minimal GSUB SingleSubst Format 1 (delta)
// ============================================================================

/// Builds a minimal GSUB table with a SingleSubst Format 1 lookup.
/// Maps glyphId → glyphId + delta for glyphs in [coveredGlyphs].
ByteData _buildGsubSingleSubstF1(List<int> coveredGlyphs, int delta) {
  // Structure:
  // GSUB Header (10 bytes): version, scriptListOff, featureListOff, lookupListOff
  // ScriptList (6 bytes): count=1, tag='latn', offset=6
  //   ScriptTable (4 bytes): defaultLangSys=0, count=0
  //   LangSysTable (6 bytes): lookupOrder=0, requiredFeature=FFFF, featureCount=1, featureIndex=0
  // FeatureList: count=1, tag='liga', offset
  //   FeatureTable: featureParams=0, lookupCount=1, lookupIndex=0
  // LookupList: count=1, lookupOffset
  //   LookupTable: type=1, flags=0, subtableCount=1, subtableOffset
  //     SingleSubst1: format=1, coverageOffset, delta
  //       Coverage Format 1: format=1, count, glyphs...

  // For simplicity, build raw bytes manually

  // We'll build coverage + subtable first, then wrap
  final covGlyphs = List<int>.from(coveredGlyphs)..sort();

  // Coverage table (format 1)
  final covBytes = BytesBuilder();
  _w16(covBytes, 1); // format
  _w16(covBytes, covGlyphs.length); // count
  for (final g in covGlyphs) {
    _w16(covBytes, g);
  }
  final covData = covBytes.toBytes();

  // SingleSubst1 subtable
  final ssBytes = BytesBuilder();
  _w16(ssBytes, 1); // format
  _w16(ssBytes,
      6); // coverageOffset (relative to subtable start), after 6 bytes of subtable header
  _w16(ssBytes, delta & 0xFFFF); // delta
  ssBytes.add(covData);
  final ssData = ssBytes.toBytes();

  // LookupTable
  final lookupBytes = BytesBuilder();
  _w16(lookupBytes, 1); // lookupType = SingleSubst
  _w16(lookupBytes, 0); // lookupFlags
  _w16(lookupBytes, 1); // subtableCount
  _w16(lookupBytes, 8); // subtableOffset (relative to lookup start)
  lookupBytes.add(ssData);
  final lookupData = lookupBytes.toBytes();

  // LookupList
  final lookupListBytes = BytesBuilder();
  _w16(lookupListBytes, 1); // count
  _w16(lookupListBytes, 4); // offset to lookup (relative to lookupList start)
  lookupListBytes.add(lookupData);
  final lookupListData = lookupListBytes.toBytes();

  // FeatureTable
  final featureTableBytes = BytesBuilder();
  _w16(featureTableBytes, 0); // featureParamsOffset
  _w16(featureTableBytes, 1); // lookupCount
  _w16(featureTableBytes, 0); // lookupIndex 0
  final featureTableData = featureTableBytes.toBytes();

  // FeatureList
  final featureListBytes = BytesBuilder();
  _w16(featureListBytes, 1); // featureCount
  featureListBytes.add([0x6C, 0x69, 0x67, 0x61]); // 'liga'
  // offset = 2(count) + 6(1 record: 4 tag + 2 offset) = 8
  _w16(featureListBytes, 8);
  featureListBytes.add(featureTableData);
  final featureListData = featureListBytes.toBytes();

  // ScriptList (minimal: empty)
  final scriptListBytes = BytesBuilder();
  _w16(scriptListBytes, 0); // scriptCount = 0
  final scriptListData = scriptListBytes.toBytes();

  // GSUB Header
  final headerSize = 10;
  final scriptListOffset = headerSize;
  final featureListOffset = scriptListOffset + scriptListData.length;
  final lookupListOffset = featureListOffset + featureListData.length;

  final gsubBytes = BytesBuilder();
  _w16(gsubBytes, 0x0001); // major version
  _w16(gsubBytes, 0x0000); // minor version
  _w16(gsubBytes, scriptListOffset);
  _w16(gsubBytes, featureListOffset);
  _w16(gsubBytes, lookupListOffset);
  gsubBytes.add(scriptListData);
  gsubBytes.add(featureListData);
  gsubBytes.add(lookupListData);

  final raw = gsubBytes.toBytes();
  return ByteData.sublistView(Uint8List.fromList(raw));
}

void _w16(BytesBuilder b, int value) {
  b.addByte((value >> 8) & 0xFF);
  b.addByte(value & 0xFF);
}

void main() {
  // =========================================================================
  // BLLayoutEngine tests
  // =========================================================================
  group('BLLayoutEngine', () {
    test('parses GSUB SingleSubst Format 1 and applies delta', () {
      // Build a GSUB table that maps glyph 65 → 65+1=66
      final gsubData = _buildGsubSingleSubstF1([65, 66, 67], 1);

      final engine = BLLayoutEngine(
        gsubData,
        gsubOffset: 0,
        gsubLength: gsubData.lengthInBytes,
        gposOffset: 0,
        gposLength: 0,
      );

      expect(engine.hasGSUB, isTrue);
      expect(engine.hasGPOS, isFalse);
      expect(engine.gsubLookupCount, 1);

      // Apply GSUB: glyph 65 should become 66
      final result = engine.applyGSUB([65, 70, 67], features: {'liga'});
      expect(result[0], 66); // 65 + 1
      expect(result[1], 70); // not in coverage, unchanged
      expect(result[2], 68); // 67 + 1
    });

    test('GSUB with no matching features leaves glyphs unchanged', () {
      final gsubData = _buildGsubSingleSubstF1([65], 5);

      final engine = BLLayoutEngine(
        gsubData,
        gsubOffset: 0,
        gsubLength: gsubData.lengthInBytes,
        gposOffset: 0,
        gposLength: 0,
      );

      // Request a feature that doesn't exist
      final result = engine.applyGSUB([65], features: {'smcp'});
      expect(result[0], 65); // unchanged
    });

    test('empty GSUB returns glyphs unchanged', () {
      final engine = BLLayoutEngine(
        ByteData(0),
        gsubOffset: 0,
        gsubLength: 0,
        gposOffset: 0,
        gposLength: 0,
      );

      expect(engine.hasGSUB, isFalse);
      final result = engine.applyGSUB([1, 2, 3]);
      expect(result, [1, 2, 3]);
    });

    test('empty GPOS returns zero adjustments', () {
      final engine = BLLayoutEngine(
        ByteData(0),
        gsubOffset: 0,
        gsubLength: 0,
        gposOffset: 0,
        gposLength: 0,
      );

      final adj = engine.applyGPOS([1, 2, 3]);
      expect(adj, [0, 0, 0]);
    });
  });

  // =========================================================================
  // BLGlyphCache tests
  // =========================================================================
  group('BLGlyphCache', () {
    test('get returns null for uncached glyph', () {
      final cache = BLGlyphCache(maxEntries: 100);
      expect(cache.get(1, 65, 12.0), isNull);
      expect(cache.length, 0);
    });

    test('put and get return the same entry', () {
      final cache = BLGlyphCache(maxEntries: 100);
      final entry = BLGlyphCacheEntry(
        glyphId: 65,
        fontSize: 12.0,
        width: 8,
        height: 10,
        bearingX: 1,
        bearingY: -9,
        bitmap: Uint8List(80),
      );

      cache.put(1, 65, 12.0, entry);
      expect(cache.length, 1);

      final retrieved = cache.get(1, 65, 12.0);
      expect(retrieved, isNotNull);
      expect(retrieved!.glyphId, 65);
      expect(retrieved.width, 8);
    });

    test('LRU eviction removes oldest entry', () {
      final cache = BLGlyphCache(maxEntries: 3);

      for (int i = 0; i < 3; i++) {
        cache.put(
            1,
            i,
            12.0,
            BLGlyphCacheEntry(
              glyphId: i,
              fontSize: 12.0,
              width: 1,
              height: 1,
              bearingX: 0,
              bearingY: 0,
              bitmap: Uint8List(1),
            ));
      }
      expect(cache.length, 3);

      // Access glyph 1 to make it recent
      cache.get(1, 1, 12.0);

      // Add a 4th entry, should evict glyph 0 (LRU)
      cache.put(
          1,
          99,
          12.0,
          BLGlyphCacheEntry(
            glyphId: 99,
            fontSize: 12.0,
            width: 1,
            height: 1,
            bearingX: 0,
            bearingY: 0,
            bitmap: Uint8List(1),
          ));

      expect(cache.length, 3);
      expect(cache.get(1, 0, 12.0), isNull); // evicted
      expect(cache.get(1, 1, 12.0), isNotNull); // still present
      expect(cache.get(1, 99, 12.0), isNotNull); // newly added
    });

    test('evictFont removes only that font', () {
      final cache = BLGlyphCache(maxEntries: 100);
      cache.put(
          1,
          65,
          12.0,
          BLGlyphCacheEntry(
            glyphId: 65,
            fontSize: 12.0,
            width: 1,
            height: 1,
            bearingX: 0,
            bearingY: 0,
            bitmap: Uint8List(1),
          ));
      cache.put(
          2,
          65,
          12.0,
          BLGlyphCacheEntry(
            glyphId: 65,
            fontSize: 12.0,
            width: 1,
            height: 1,
            bearingX: 0,
            bearingY: 0,
            bitmap: Uint8List(1),
          ));

      expect(cache.length, 2);
      cache.evictFont(1);
      expect(cache.length, 1);
      expect(cache.get(1, 65, 12.0), isNull);
      expect(cache.get(2, 65, 12.0), isNotNull);
    });

    test('hit rate tracking works', () {
      final cache = BLGlyphCache(maxEntries: 100);
      cache.put(
          1,
          65,
          12.0,
          BLGlyphCacheEntry(
            glyphId: 65,
            fontSize: 12.0,
            width: 1,
            height: 1,
            bearingX: 0,
            bearingY: 0,
            bitmap: Uint8List(1),
          ));

      cache.get(1, 65, 12.0); // hit
      cache.get(1, 66, 12.0); // miss
      cache.get(1, 65, 12.0); // hit

      expect(cache.hitRate, closeTo(2 / 3, 0.01));
    });

    test('clear resets everything', () {
      final cache = BLGlyphCache(maxEntries: 100);
      cache.put(
          1,
          65,
          12.0,
          BLGlyphCacheEntry(
            glyphId: 65,
            fontSize: 12.0,
            width: 10,
            height: 10,
            bearingX: 0,
            bearingY: 0,
            bitmap: Uint8List(100),
          ));

      cache.clear();
      expect(cache.length, 0);
      expect(cache.memoryUsed, 0);
      expect(cache.hitRate, 0.0);
    });

    test('stats returns map with expected keys', () {
      final cache = BLGlyphCache(maxEntries: 100);
      final stats = cache.stats;
      expect(stats.containsKey('entries'), isTrue);
      expect(stats.containsKey('memoryBytes'), isTrue);
      expect(stats.containsKey('hits'), isTrue);
      expect(stats.containsKey('misses'), isTrue);
      expect(stats.containsKey('hitRate'), isTrue);
    });

    test('different font sizes are cached separately', () {
      final cache = BLGlyphCache(maxEntries: 100);
      cache.put(
          1,
          65,
          12.0,
          BLGlyphCacheEntry(
            glyphId: 65,
            fontSize: 12.0,
            width: 8,
            height: 10,
            bearingX: 0,
            bearingY: 0,
            bitmap: Uint8List(80),
          ));
      cache.put(
          1,
          65,
          24.0,
          BLGlyphCacheEntry(
            glyphId: 65,
            fontSize: 24.0,
            width: 16,
            height: 20,
            bearingX: 0,
            bearingY: 0,
            bitmap: Uint8List(320),
          ));

      expect(cache.length, 2);
      expect(cache.get(1, 65, 12.0)!.width, 8);
      expect(cache.get(1, 65, 24.0)!.width, 16);
    });
  });
}
