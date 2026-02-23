import 'package:test/test.dart';
import '../lib/src/blend2d/pipeline/bl_fetch_linear_gradient.dart';
import '../lib/src/blend2d/pipeline/bl_fetch_radial_gradient.dart';
import '../lib/src/blend2d/core/bl_types.dart';

void main() {
  group('BLLinearGradientFetcher', () {
    test('horizontal gradient interpolates correctly', () {
      final grad = BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(100, 0),
        stops: const [
          BLGradientStop(0.0, 0xFF000000), // black
          BLGradientStop(1.0, 0xFFFFFFFF), // white
        ],
      );
      final fetcher = BLLinearGradientFetcher(grad);

      // At x=0 (start): should be close to black
      final start = fetcher.fetch(0, 50);
      final rStart = (start >> 16) & 0xFF;
      expect(rStart, lessThan(20));

      // At x=99 (end): should be close to white
      final end = fetcher.fetch(99, 50);
      final rEnd = (end >> 16) & 0xFF;
      expect(rEnd, greaterThan(235));

      // At x=50 (middle): should be approximately gray
      final mid = fetcher.fetch(50, 50);
      final rMid = (mid >> 16) & 0xFF;
      expect(rMid, greaterThan(100));
      expect(rMid, lessThan(160));
    });

    test('vertical gradient interpolates correctly', () {
      final grad = BLLinearGradient(
        p0: const BLPoint(50, 0),
        p1: const BLPoint(50, 100),
        stops: const [
          BLGradientStop(0.0, 0xFFFF0000), // red
          BLGradientStop(1.0, 0xFF0000FF), // blue
        ],
      );
      final fetcher = BLLinearGradientFetcher(grad);

      // At y=0: should be mostly red
      final top = fetcher.fetch(50, 0);
      expect((top >> 16) & 0xFF, greaterThan(200)); // R high
      expect(top & 0xFF, lessThan(50)); // B low

      // At y=99: should be mostly blue
      final bottom = fetcher.fetch(50, 99);
      expect((bottom >> 16) & 0xFF, lessThan(30)); // R low
      expect(bottom & 0xFF, greaterThan(200)); // B high
    });

    test('pad extend clamps at boundaries', () {
      final grad = BLLinearGradient(
        p0: const BLPoint(20, 0),
        p1: const BLPoint(80, 0),
        stops: const [
          BLGradientStop(0.0, 0xFF000000),
          BLGradientStop(1.0, 0xFFFFFFFF),
        ],
        extendMode: BLGradientExtendMode.pad,
      );
      final fetcher = BLLinearGradientFetcher(grad);

      // Before gradient start: should be the start color (black)
      final before = fetcher.fetch(0, 0);
      expect((before >> 16) & 0xFF, lessThan(10));

      // After gradient end: should be the end color (white)
      final after = fetcher.fetch(200, 0);
      expect((after >> 16) & 0xFF, greaterThan(245));
    });

    test('repeat extend creates periodic pattern', () {
      final grad = BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(50, 0),
        stops: const [
          BLGradientStop(0.0, 0xFF000000),
          BLGradientStop(1.0, 0xFFFFFFFF),
        ],
        extendMode: BLGradientExtendMode.repeat,
      );
      final fetcher = BLLinearGradientFetcher(grad);

      // Fetch at start of first period
      final p0 = fetcher.fetch(0, 0);
      // Fetch at start of second period
      final p1 = fetcher.fetch(50, 0);

      // Should be similar (both near start of gradient = dark)
      final r0 = (p0 >> 16) & 0xFF;
      final r1 = (p1 >> 16) & 0xFF;
      expect((r0 - r1).abs(), lessThan(10));
    });

    test('multi-stop gradient', () {
      final grad = BLLinearGradient(
        p0: const BLPoint(0, 0),
        p1: const BLPoint(100, 0),
        stops: const [
          BLGradientStop(0.0, 0xFFFF0000), // red
          BLGradientStop(0.5, 0xFF00FF00), // green
          BLGradientStop(1.0, 0xFF0000FF), // blue
        ],
      );
      final fetcher = BLLinearGradientFetcher(grad);

      // At start: red
      final start = fetcher.fetch(0, 0);
      expect((start >> 16) & 0xFF, greaterThan(200));

      // At middle: green
      final mid = fetcher.fetch(50, 0);
      expect((mid >> 8) & 0xFF, greaterThan(150));

      // At end: blue
      final end = fetcher.fetch(99, 0);
      expect(end & 0xFF, greaterThan(200));
    });
  });

  group('BLRadialGradientFetcher', () {
    test('radial gradient: center is start color', () {
      final grad = BLRadialGradient(
        c0: const BLPoint(50, 50),
        c1: const BLPoint(50, 50),
        r0: 0.0,
        r1: 50.0,
        stops: const [
          BLGradientStop(0.0, 0xFFFF0000), // red at center
          BLGradientStop(1.0, 0xFF0000FF), // blue at edge
        ],
      );
      final fetcher = BLRadialGradientFetcher(grad);

      // At center: should be red
      final center = fetcher.fetch(50, 50);
      expect((center >> 16) & 0xFF, greaterThan(200));
      expect(center & 0xFF, lessThan(50));
    });

    test('radial gradient: edge is end color', () {
      final grad = BLRadialGradient(
        c0: const BLPoint(50, 50),
        c1: const BLPoint(50, 50),
        r0: 0.0,
        r1: 50.0,
        stops: const [
          BLGradientStop(0.0, 0xFFFF0000),
          BLGradientStop(1.0, 0xFF0000FF),
        ],
      );
      final fetcher = BLRadialGradientFetcher(grad);

      // At edge (50 pixels away from center): should be blue
      final edge = fetcher.fetch(100, 50);
      expect(edge & 0xFF, greaterThan(200));
    });

    test('radial gradient: symmetric around center', () {
      final grad = BLRadialGradient(
        c0: const BLPoint(50, 50),
        c1: const BLPoint(50, 50),
        r0: 0.0,
        r1: 40.0,
        stops: const [
          BLGradientStop(0.0, 0xFF000000),
          BLGradientStop(1.0, 0xFFFFFFFF),
        ],
      );
      final fetcher = BLRadialGradientFetcher(grad);

      // Points at same distance from center should have same color
      final left = fetcher.fetch(30, 50); // 20 px from center
      final right = fetcher.fetch(70, 50); // 20 px from center
      final top = fetcher.fetch(50, 30); // 20 px from center

      final rL = (left >> 16) & 0xFF;
      final rR = (right >> 16) & 0xFF;
      final rT = (top >> 16) & 0xFF;

      expect((rL - rR).abs(), lessThan(10));
      expect((rL - rT).abs(), lessThan(10));
    });

    test('radial gradient: pad extend clamps beyond radius', () {
      final grad = BLRadialGradient(
        c0: const BLPoint(50, 50),
        c1: const BLPoint(50, 50),
        r0: 0.0,
        r1: 30.0,
        stops: const [
          BLGradientStop(0.0, 0xFF000000),
          BLGradientStop(1.0, 0xFFFFFFFF),
        ],
        extendMode: BLGradientExtendMode.pad,
      );
      final fetcher = BLRadialGradientFetcher(grad);

      // Far from center (well beyond radius): should be clamped to white
      final far = fetcher.fetch(200, 200);
      expect((far >> 16) & 0xFF, greaterThan(240));
    });
  });
}
