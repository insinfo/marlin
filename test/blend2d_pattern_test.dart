import 'package:test/test.dart';
import '../lib/src/blend2d/pipeline/bl_fetch_pattern.dart';
import '../lib/src/blend2d/core/bl_types.dart';
import '../lib/src/blend2d/core/bl_image.dart';

/// Helper to create a small test image with known pixels.
BLImage _createTestImage(int w, int h) {
  final img = BLImage(w, h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      // Each pixel encodes its position: ARGB = (0xFF, x*17, y*17, (x+y)*13)
      final r = (x * 17) & 0xFF;
      final g = (y * 17) & 0xFF;
      final b = ((x + y) * 13) & 0xFF;
      img.pixels[y * w + x] = (0xFF << 24) | (r << 16) | (g << 8) | b;
    }
  }
  return img;
}

/// Helper to create a uniform solid-color image.
BLImage _createSolidImage(int w, int h, int argb) {
  final img = BLImage(w, h);
  img.pixels.fillRange(0, w * h, argb);
  return img;
}

void main() {
  group('BLPatternFetcher - Nearest', () {
    test('identity transform returns pixel at (x,y)', () {
      final img = _createTestImage(8, 8);
      final pat = BLPattern(image: img);
      final fetcher = BLPatternFetcher(pat);

      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          expect(fetcher.fetch(x, y), img.pixels[y * 8 + x],
              reason: 'Pixel at ($x,$y)');
        }
      }
    });

    test('pad extend clamps to border', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.pad,
        extendModeY: BLGradientExtendMode.pad,
      );
      final fetcher = BLPatternFetcher(pat);

      // Beyond right edge: should clamp to x=3
      expect(fetcher.fetch(10, 0), img.pixels[0 * 4 + 3]);
      // Beyond bottom: should clamp to y=3
      expect(fetcher.fetch(0, 10), img.pixels[3 * 4 + 0]);
      // Before left: should clamp to x=0
      expect(fetcher.fetch(-5, 2), img.pixels[2 * 4 + 0]);
    });

    test('repeat extend wraps around', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
      );
      final fetcher = BLPatternFetcher(pat);

      // x=4 wraps to x=0, x=5 wraps to x=1
      expect(fetcher.fetch(4, 0), img.pixels[0 * 4 + 0]);
      expect(fetcher.fetch(5, 0), img.pixels[0 * 4 + 1]);
      // Negative wraps: x=-1 wraps to x=3
      expect(fetcher.fetch(-1, 0), img.pixels[0 * 4 + 3]);
    });

    test('reflect extend mirrors at boundary', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.reflect,
        extendModeY: BLGradientExtendMode.pad,
      );
      final fetcher = BLPatternFetcher(pat);

      // Within tile: normal
      expect(fetcher.fetch(0, 0), img.pixels[0]);
      expect(fetcher.fetch(3, 0), img.pixels[3]);
      // Reflected: x=4 -> period=8, x=4 -> 8-1-4=3
      expect(fetcher.fetch(4, 0), img.pixels[3]);
      // x=5 -> 8-1-5=2
      expect(fetcher.fetch(5, 0), img.pixels[2]);
      // x=7 -> 8-1-7=0
      expect(fetcher.fetch(7, 0), img.pixels[0]);
      // x=8 -> wraps to 0 (new period)
      expect(fetcher.fetch(8, 0), img.pixels[0]);
    });

    test('offset shifts sampling origin', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        offset: const BLPoint(2.0, 1.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // fetch(2,1) should sample pixel (0,0) due to offset
      expect(fetcher.fetch(2, 1), img.pixels[0]);
    });

    test('sequential affine fetch with repeat is consistent', () {
      final img = _createTestImage(8, 8);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(0.5, 0.0, 0.0, 0.5, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetch a row sequentially, then fetch same row non-sequentially
      // Results should match
      final sequential = <int>[];
      for (int x = 0; x < 32; x++) {
        sequential.add(fetcher.fetch(x, 5));
      }

      // Create fresh fetcher for random access
      final fetcher2 = BLPatternFetcher(pat);
      for (int x = 0; x < 32; x++) {
        expect(fetcher2.fetch(x, 5), sequential[x],
            reason: 'Sequential vs random at x=$x');
      }
    });

    test('affine transform with repeat wraps correctly', () {
      final img = _createSolidImage(4, 4, 0xFFFF0000); // Red
      // Set pixel (0,0) to green for detection
      img.pixels[0] = 0xFF00FF00;

      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        // Scale 2x: every 2 canvas pixels = 1 texture pixel
        transform: const BLMatrix2D(0.5, 0.0, 0.0, 0.5, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // At canvas (0,0), tex = (0,0) -> green
      expect(fetcher.fetch(0, 0), 0xFF00FF00);
      // At canvas (2,0), tex = (1,0) -> red
      expect(fetcher.fetch(2, 0), 0xFFFF0000);
    });
  });

  group('BLPatternFetcher - Bilinear', () {
    test('bilinear at integer coords matches nearest', () {
      final img = _createTestImage(8, 8);
      final patNearest = BLPattern(
        image: img,
        filter: BLPatternFilter.nearest,
      );
      final patBilinear = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
      );
      final fetcherN = BLPatternFetcher(patNearest);
      final fetcherB = BLPatternFetcher(patBilinear);

      // At exact integer coordinates, bilinear should closely match nearest
      // (may differ slightly due to weight rounding)
      for (int y = 0; y < 7; y++) {
        for (int x = 0; x < 7; x++) {
          final n = fetcherN.fetch(x, y);
          final b = fetcherB.fetch(x, y);
          // Check that channels are close (within 2 due to rounding)
          final nA = (n >> 24) & 0xFF;
          final bA = (b >> 24) & 0xFF;
          final nR = (n >> 16) & 0xFF;
          final bR = (b >> 16) & 0xFF;
          expect((nA - bA).abs(), lessThan(3),
              reason: 'Alpha at ($x,$y)');
          expect((nR - bR).abs(), lessThan(3),
              reason: 'Red at ($x,$y)');
        }
      }
    });

    test('bilinear produces smooth interpolation', () {
      // Create a 2x1 image: black and white
      final img = BLImage(2, 1);
      img.pixels[0] = 0xFF000000; // black
      img.pixels[1] = 0xFFFFFFFF; // white

      final pat = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
        extendModeX: BLGradientExtendMode.pad,
        extendModeY: BLGradientExtendMode.pad,
        // Half-pixel offset to sample between the two pixels
        offset: const BLPoint(0.5, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // At x=1 (shifted by +0.5 -> samples at 0.5), should be ~middle gray
      final mid = fetcher.fetch(1, 0);
      final r = (mid >> 16) & 0xFF;
      // Should be approximately 128 (halfway between 0 and 255)
      expect(r, greaterThan(100));
      expect(r, lessThan(160));
    });

    test('bilinear repeat wraps at tile boundary', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetching beyond the image should produce valid results (wrap)
      for (int x = 0; x < 16; x++) {
        final pixel = fetcher.fetch(x, 0);
        expect(pixel & 0xFF000000, 0xFF000000,
            reason: 'Alpha should be opaque at x=$x');
      }
    });

    test('bilinear affine sequential consistency', () {
      final img = _createTestImage(8, 8);
      final pat = BLPattern(
        image: img,
        filter: BLPatternFilter.bilinear,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(0.7, 0.3, -0.3, 0.7, 2.0, 1.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetch row sequentially
      final row = <int>[];
      for (int x = 0; x < 20; x++) {
        row.add(fetcher.fetch(x, 3));
      }

      // Verify random access against sequential results.
      for (int x = 0; x < 20; x += 3) {
        // Force non-sequential access by creating new fetcher each time
        final fetcherSingle = BLPatternFetcher(pat);
        final a = fetcherSingle.fetch(x, 3);
        final b = row[x];
        final aA = (a >>> 24) & 0xFF;
        final bA = (b >>> 24) & 0xFF;
        final aR = (a >>> 16) & 0xFF;
        final bR = (b >>> 16) & 0xFF;
        final aG = (a >>> 8) & 0xFF;
        final bG = (b >>> 8) & 0xFF;
        final aB = a & 0xFF;
        final bB = b & 0xFF;
        expect((aA - bA).abs(), lessThanOrEqualTo(2), reason: 'A random vs sequential at x=$x');
        expect((aR - bR).abs(), lessThanOrEqualTo(2), reason: 'R random vs sequential at x=$x');
        expect((aG - bG).abs(), lessThanOrEqualTo(2), reason: 'G random vs sequential at x=$x');
        expect((aB - bB).abs(), lessThanOrEqualTo(2), reason: 'B random vs sequential at x=$x');
      }
    });
  });

  group('BLPatternFetcher - Affine Context (C++ ox/oy/rx/ry port)', () {
    test('repeat mode avoids modulo in sequential path', () {
      // This tests the C++ affine context optimization:
      // sequential pixels use branchless subtraction instead of modulo
      final img = _createTestImage(8, 8);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        transform: const BLMatrix2D(1.5, 0.0, 0.0, 1.5, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Sequential fetch across multiple tile periods
      final results = <int>[];
      for (int x = 0; x < 40; x++) {
        results.add(fetcher.fetch(x, 0));
      }

      // Verify wrap-around: pixels should be periodic
      // With scale 1.5x and tile width 8, period in canvas space = 8/1.5 ≈ 5.33
      // Within one row, all fetched pixels should be valid (non-zero alpha)
      for (int i = 0; i < results.length; i++) {
        expect(results[i] & 0xFF000000, 0xFF000000,
            reason: 'Alpha should be opaque at x=$i');
      }
    });

    test('reflect mode handles mirror correctly in sequential path', () {
      // Create a gradient-like image for easy visual verification
      final img = BLImage(4, 1);
      img.pixels[0] = 0xFF000000; // 0
      img.pixels[1] = 0xFF555555; // 1
      img.pixels[2] = 0xFFAAAAAA; // 2
      img.pixels[3] = 0xFFFFFFFF; // 3

      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.reflect,
        extendModeY: BLGradientExtendMode.pad,
      );
      final fetcher = BLPatternFetcher(pat);

      // Expected pattern: 0,1,2,3, 3,2,1,0, 0,1,2,3, ...
      expect(fetcher.fetch(0, 0), 0xFF000000); // 0
      expect(fetcher.fetch(1, 0), 0xFF555555); // 1
      expect(fetcher.fetch(2, 0), 0xFFAAAAAA); // 2
      expect(fetcher.fetch(3, 0), 0xFFFFFFFF); // 3
      expect(fetcher.fetch(4, 0), 0xFFFFFFFF); // 3 (reflected)
      expect(fetcher.fetch(5, 0), 0xFFAAAAAA); // 2 (reflected)
      expect(fetcher.fetch(6, 0), 0xFF555555); // 1 (reflected)
      expect(fetcher.fetch(7, 0), 0xFF000000); // 0 (reflected)
      expect(fetcher.fetch(8, 0), 0xFF000000); // 0 (new period)
    });

    test('large affine rotation with repeat produces valid pixels', () {
      final img = _createTestImage(16, 16);
      // 45-degree rotation
      final cos45 = 0.7071;
      final sin45 = 0.7071;
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.repeat,
        extendModeY: BLGradientExtendMode.repeat,
        filter: BLPatternFilter.nearest,
        transform: BLMatrix2D(cos45, sin45, -sin45, cos45, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Fetch a full scanline
      for (int x = 0; x < 64; x++) {
        final pixel = fetcher.fetch(x, 10);
        // Should always produce valid opaque pixels
        expect(pixel & 0xFF000000, 0xFF000000,
            reason: 'Alpha at x=$x should be opaque');
      }
    });

    test('pad mode leaves coordinates unnormalized', () {
      final img = _createTestImage(4, 4);
      final pat = BLPattern(
        image: img,
        extendModeX: BLGradientExtendMode.pad,
        extendModeY: BLGradientExtendMode.pad,
        transform: const BLMatrix2D(2.0, 0.0, 0.0, 2.0, 0.0, 0.0),
      );
      final fetcher = BLPatternFetcher(pat);

      // Far outside: should clamp to border
      expect(fetcher.fetch(100, 0), img.pixels[0 * 4 + 3]);
      expect(fetcher.fetch(0, 100), img.pixels[3 * 4 + 0]);
    });
  });
}
