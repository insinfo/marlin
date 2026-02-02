/// ============================================================================
/// RASTERIZATION BENCHMARK
/// ============================================================================
///
/// Benchmark comparativo de todos os métodos de rasterização implementados.
///
/// Uso:
///   dart run benchmark/rasterization_benchmark.dart
///


import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:marlin/marlin.dart';

// ─────────────────────────────────────────────────────────────────────────────
// POLÍGONOS DE TESTE
// ─────────────────────────────────────────────────────────────────────────────

/// Triângulo simples
List<double> createTriangle(double cx, double cy, double size) {
  return [
    cx, cy - size, // Topo
    cx - size * 0.866, cy + size * 0.5, // Esquerda inferior
    cx + size * 0.866, cy + size * 0.5, // Direita inferior
  ];
}

/// Quadrado
List<double> createSquare(double cx, double cy, double size) {
  final half = size / 2;
  return [
    cx - half, cy - half,
    cx + half, cy - half,
    cx + half, cy + half,
    cx - half, cy + half,
  ];
}

/// Estrela de 5 pontas
List<double> createStar(double cx, double cy, double outerRadius, double innerRadius) {
  final vertices = <double>[];
  const numPoints = 5;
  const angleStep = 3.14159265 / numPoints;

  for (int i = 0; i < numPoints * 2; i++) {
    final angle = -3.14159265 / 2 + i * angleStep;
    final radius = i.isEven ? outerRadius : innerRadius;
    vertices.add(cx + radius * cos(angle));
    vertices.add(cy + radius * sin(angle));
  }

  return vertices;
}

/// Polígono complexo (hexágono irregular)
List<double> createComplexPolygon(double cx, double cy, double size) {
  return [
    cx + size * 0.8, cy,
    cx + size * 0.4, cy + size * 0.7,
    cx - size * 0.3, cy + size * 0.6,
    cx - size * 0.9, cy,
    cx - size * 0.5, cy - size * 0.5,
    cx + size * 0.2, cy - size * 0.8,
  ];
}

/// Funções trigonométricas simples
double cos(double x) {
  var result = 1.0;
  var term = 1.0;
  for (int i = 1; i <= 10; i++) {
    term *= -x * x / ((2 * i - 1) * (2 * i));
    result += term;
  }
  return result;
}

double sin(double x) => cos(x - 3.14159265 / 2);

// ─────────────────────────────────────────────────────────────────────────────
// BENCHMARK RUNNER
// ─────────────────────────────────────────────────────────────────────────────

class BenchmarkResult {
  final String name;
  final double timeMs;
  final int polygonsPerSecond;

  BenchmarkResult(this.name, this.timeMs, this.polygonsPerSecond);

  @override
  String toString() {
    return '$name: ${timeMs.toStringAsFixed(2)}ms (${polygonsPerSecond} poly/s)';
  }
}

typedef RasterizeFunc = FutureOr<void> Function(List<double> vertices, int color);

Future<BenchmarkResult> runBenchmark(
  String name,
  RasterizeFunc rasterize,
  List<List<double>> polygons,
  int warmupIterations,
  int measureIterations,
  {void Function()? clear}
) async {
  // Warmup
  for (int i = 0; i < warmupIterations; i++) {
    if (clear != null) clear();
    for (final poly in polygons) {
      await rasterize(poly, 0xFFFF0000);
    }
  }

  // Measure
  final stopwatch = Stopwatch()..start();

  for (int i = 0; i < measureIterations; i++) {
    if (clear != null) clear();
    for (final poly in polygons) {
      await rasterize(poly, 0xFFFF0000);
    }
  }

  stopwatch.stop();
  final totalMs = stopwatch.elapsedMicroseconds / 1000.0;
  final totalPolygons = measureIterations * polygons.length;
  final polyPerSec = (totalPolygons / (totalMs / 1000)).round();

  return BenchmarkResult(name, totalMs / measureIterations, polyPerSec);
}

Future<void> saveImage(String name, Uint32List buffer, int width, int height) async {
  final dir = Directory('output/rasterization_benchmark');
  await dir.create(recursive: true);
  
  // Convert 0xAARRGGBB (Uint32) to RGBA bytes
  final rgba = Uint8List(width * height * 4);
  for (int i = 0; i < buffer.length; i++) {
    final pixel = buffer[i];
    // Marlin/Others use 0xAARRGGBB generally
    rgba[i * 4] = (pixel >> 16) & 0xFF;     // R
    rgba[i * 4 + 1] = (pixel >> 8) & 0xFF;  // G
    rgba[i * 4 + 2] = pixel & 0xFF;         // B
    rgba[i * 4 + 3] = (pixel >> 24) & 0xFF; // A
  }
  
  // Try to use PngWriter if available. If not, we might need another way or assume it is exported.
  // The user script `svg_render_benchmark` used PngWriter.saveRgba.
  try {
     await PngWriter.saveRgba('${dir.path}/$name.png', rgba, width, height);
  } catch (e) {
     print("Error saving $name.png: $e");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  const width = 512;
  const height = 512;
  const warmup = 5;
  const iterations = 20;

  print('╔══════════════════════════════════════════════════════════════════╗');
  print('║         MARLIN RASTERIZATION METHODS BENCHMARK                   ║');
  print('║         Resolution: ${width}x${height}, Iterations: $iterations              ║');
  print('╚══════════════════════════════════════════════════════════════════╝');
  print('');

  // Criar polígonos de teste
  final polygons = <List<double>>[
    createTriangle(256, 256, 100),
    createSquare(128, 128, 80),
    createStar(384, 384, 100, 40),
    createComplexPolygon(256, 400, 80),
  ];

  // Adicionar mais polígonos para stress test
  for (int i = 0; i < 10; i++) {
    final x = 50.0 + (i % 5) * 100;
    final y = 50.0 + (i ~/ 5) * 100;
    polygons.add(createTriangle(x, y, 30));
  }

  print('Polygons per iteration: ${polygons.length}');
  print('');

  final results = <BenchmarkResult>[];

  // ─── ACDR ───────────────────────────────────────────────────────────────
  print('Testing ACDR (Accumulated Coverage Derivative)...');
  try {
    final acdr = ACDRRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'ACDR',
      (vertices, color) {
        final verts = <Vec2>[];
        for (int i = 0; i < vertices.length; i += 2) {
          verts.add(Vec2(vertices[i] / width, vertices[i + 1] / height));
        }
        acdr.rasterize(verts);
      },
      polygons,
      warmup,
      iterations,
      clear: () => acdr.clear(),
    ));

    // ACDR coverage (Float64) to ARGB for saving (Red on White)
    final aBuffer = Uint32List(width * height);
    for(int i=0; i<width*height; i++) {
        double cov = acdr.coverageBuffer[i].clamp(0, 1);
        int a = (cov * 255).toInt();
        // Background: FF FF FF, Foreground: FF 00 00
        // Result: R=FF, G=255-a, B=255-a
        aBuffer[i] = 0xFF000000 | (255 << 16) | ((255 - a) << 8) | (255 - a);
    }
    await saveImage('ACDR', aBuffer, width, height);

  } catch (e) {
    print('  ACDR failed: $e');
  }

  // ─── MARLIN ─────────────────────────────────────────────────────────────
  print('Testing Marlin...');
  try {
    final marlin = MarlinRenderer(width, height);
    results.add(await runBenchmark(
      'Marlin',
      (vertices, color) {
         marlin.drawPolygon(vertices, color);
      },
      polygons,
      warmup,
      iterations,
      clear: () { 
          marlin.clear(0xFFFFFFFF);
      },
    ));
    await saveImage('Marlin', marlin.buffer.buffer.asUint32List(), width, height);
  } catch (e) {
    print('  Marlin failed: $e');
  }

  // ─── DAA ────────────────────────────────────────────────────────────────
  print('Testing DAA (Delta-Analytic Approximation)...');
  try {
    final daa = DAARasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'DAA',
      (vertices, color) {
        if (vertices.length >= 6) {
          daa.drawPolygon(vertices, color);
        }
      },
      polygons,
      warmup,
      iterations,
      clear: () => daa.clear(0xFFFFFFFF),
    ));
    await saveImage('DAA', daa.framebuffer, width, height);
  } catch (e) {
    print('  DAA failed: $e');
  }

  // ─── DDFI ───────────────────────────────────────────────────────────────
  print('Testing DDFI (Discrete Differential Flux Integration)...');
  try {
    final ddfi = FluxRenderer(width, height);
    results.add(await runBenchmark(
      'DDFI',
      (vertices, color) => ddfi.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => ddfi.clear(0xFFFFFFFF),
    ));
    await saveImage('DDFI', ddfi.buffer, width, height);
  } catch (e) {
    print('  DDFI failed: $e');
  }

  // ─── DBSR ────────────────────────────────────────────────────────────────
  print('Testing DBSR (Distance-Based Subpixel)...');
  try {
    final dbsr = DBSRRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'DBSR',
      (vertices, color) {
        if (vertices.length >= 6) {
          dbsr.drawTriangle(
            vertices[0], vertices[1],
            vertices[2], vertices[3],
            vertices[4], vertices[5],
            color,
          );
        }
      },
      polygons,
      warmup,
      iterations,
      clear: () => dbsr.clear(0xFFFFFFFF),
    ));
    await saveImage('DBSR', dbsr.pixels, width, height);
  } catch (e) {
    print('  DBSR failed: $e');
  }

  // ─── EPL_AA ─────────────────────────────────────────────────────────────
  print('Testing EPL_AA (EdgePlane Lookup)...');
  try {
    final epl = EPLRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'EPL_AA',
      (vertices, color) => epl.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => epl.clear(0xFFFFFFFF),
    ));
    await saveImage('EPL_AA', epl.buffer, width, height);
  } catch (e) {
    print('  EPL_AA failed: $e');
  }

  // ─── QCS ────────────────────────────────────────────────────────────────
  print('Testing QCS (Quantized Coverage Signature)...');
  try {
    final qcs = QCSRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'QCS',
      (vertices, color) => qcs.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => qcs.clear(0xFFFFFFFF),
    ));
    await saveImage('QCS', qcs.pixels, width, height);
  } catch (e) {
    print('  QCS failed: $e');
  }

  // ─── RHBD ───────────────────────────────────────────────────────────────
  print('Testing RHBD (Hybrid Tiled Rasterization)...');
  try {
    final rhbd = RHBDRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'RHBD',
      (vertices, color) => rhbd.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => rhbd.clear(0xFFFFFFFF),
    ));
    await saveImage('RHBD', rhbd.buffer, width, height);
  } catch (e) {
    print('  RHBD failed: $e');
  }

  // ─── AMCAD ──────────────────────────────────────────────────────────────
  print('Testing AMCAD (Analytic Micro-Cell Adaptive)...');
  try {
    final amcad = AMCADRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'AMCAD',
      (vertices, color) => amcad.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => amcad.clear(0xFFFFFFFF),
    ));
    await saveImage('AMCAD', amcad.buffer, width, height);
  } catch (e) {
    print('  AMCAD failed: $e');
  }

  // ─── HSGR ───────────────────────────────────────────────────────────────
  print('Testing HSGR (Hilbert-Space Guided)...');
  try {
    final hsgr = HSGRRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'HSGR',
      (vertices, color) {
        if (vertices.length >= 6) {
          hsgr.drawTriangle(
            vertices[0], vertices[1],
            vertices[2], vertices[3],
            vertices[4], vertices[5],
            color,
          );
        }
      },
      polygons,
      warmup,
      iterations,
      clear: () => hsgr.clear(0xFFFFFFFF),
    ));
    await saveImage('HSGR', hsgr.buffer, width, height);
  } catch (e) {
    print('  HSGR failed: $e');
  }

  // ─── SWEEP_SDF ──────────────────────────────────────────────────────────
  print('Testing SWEEP_SDF (Scanline with Analytical SDF)...');
  try {
    final sweepSdf = SweepSDFRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SWEEP_SDF',
      (vertices, color) => sweepSdf.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => sweepSdf.clear(0xFFFFFFFF),
    ));
    await saveImage('SWEEP_SDF', sweepSdf.pixels, width, height);
  } catch (e) {
    print('  SWEEP_SDF failed: $e');
  }

  // ─── SCDT ───────────────────────────────────────────────────────────────
  print('Testing SCDT (Spectral Coverage Ternary)...');
  try {
    final scdt = SCDTRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SCDT',
      (vertices, color) => scdt.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => scdt.clear(0xFFFFFFFF),
    ));
    await saveImage('SCDT', scdt.pixels, width, height);
  } catch (e) {
    print('  SCDT failed: $e');
  }

  // ─── SCP_AED ────────────────────────────────────────────────────────────
  print('Testing SCP_AED (Stochastic Coverage Propagation)...');
  try {
    final scp = SCPAEDRasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'SCP_AED',
      (vertices, color) => scp.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => scp.clear(0xFFFFFFFF),
    ));
    await saveImage('SCP_AED', scp.buffer, width, height);
  } catch (e) {
    print('  SCP_AED failed: $e');
  }

  // ─── BLEND2D ────────────────────────────────────────────────────────────
  print('Testing BLEND2D (Various configs)...');
  try {
    // 1. Scalar, No Isolates
    final b2dScalar = Blend2DRasterizer(width, height, 
      config: const RasterizerConfig(useSimd: false, useIsolates: false));
    results.add(await runBenchmark(
      'BLEND2D (Scalar)',
      (vertices, color) => b2dScalar.drawPolygon(vertices, color),
      polygons, warmup, iterations,
      clear: () => b2dScalar.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_Scalar', b2dScalar.buffer, width, height);

    // 2. SIMD, No Isolates
    final b2dSimd = Blend2DRasterizer(width, height, 
      config: const RasterizerConfig(useSimd: true, useIsolates: false));
    results.add(await runBenchmark(
      'BLEND2D (SIMD)',
      (vertices, color) => b2dSimd.drawPolygon(vertices, color),
      polygons, warmup, iterations,
      clear: () => b2dSimd.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_SIMD', b2dSimd.buffer, width, height);

    // 3. Scalar + Isolates (4 slices)
    final b2dScalarParallel = Blend2DRasterizer(width, height, 
      config: RasterizerConfig(useSimd: false, useIsolates: true, tileHeight: height ~/ 4));
    results.add(await runBenchmark(
      'BLEND2D (Scalar+Isolates)',
      (vertices, color) => b2dScalarParallel.drawPolygon(vertices, color),
      polygons, warmup, iterations,
      clear: () => b2dScalarParallel.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_Scalar_Isolates', b2dScalarParallel.buffer, width, height);

    // 4. SIMD + Isolates (4 slices)
    final b2dParallel = Blend2DRasterizer(width, height, 
      config: RasterizerConfig(useSimd: true, useIsolates: true, tileHeight: height ~/ 4));
    results.add(await runBenchmark(
      'BLEND2D (SIMD+Isolates)',
      (vertices, color) => b2dParallel.drawPolygon(vertices, color),
      polygons, warmup, iterations,
      clear: () => b2dParallel.clear(0xFFFFFFFF),
    ));
    await saveImage('BLEND2D_SIMD_Isolates', b2dParallel.buffer, width, height);

  } catch (e) {
    print('  BLEND2D failed: $e');
  }

  // ─── SKIA_SCANLINE ──────────────────────────────────────────────────────
  print('Testing SKIA_SCANLINE (Various configs)...');
  try {
    // 1. No SIMD
    final skiaScalar = SkiaRasterizer(width: width, height: height, useSimd: false);
    results.add(await runBenchmark(
      'SKIA (Scalar)',
      (vertices, color) => skiaScalar.drawPolygon(vertices, color),
      polygons, warmup, iterations,
      clear: () => skiaScalar.clear(0xFFFFFFFF),
    ));
    await saveImage('SKIA_Scalar', skiaScalar.buffer, width, height);

    // 2. SIMD
    final skiaSimd = SkiaRasterizer(width: width, height: height, useSimd: true);
    results.add(await runBenchmark(
      'SKIA (SIMD)',
      (vertices, color) => skiaSimd.drawPolygon(vertices, color),
      polygons, warmup, iterations,
      clear: () => skiaSimd.clear(0xFFFFFFFF),
    ));
    await saveImage('SKIA_SIMD', skiaSimd.buffer, width, height);

  } catch (e) {
    print('  SKIA_SCANLINE failed: $e');
  }

  // ─── EDGE_FLAG_AA ───────────────────────────────────────────────────────
  print('Testing EDGE_FLAG_AA...');
  try {
    final edgeFlag = EdgeFlagAARasterizer(width: width, height: height);
    results.add(await runBenchmark(
      'EDGE_FLAG_AA',
      (vertices, color) => edgeFlag.drawPolygon(vertices, color),
      polygons,
      warmup,
      iterations,
      clear: () => edgeFlag.clear(0xFFFFFFFF),
    ));
    await saveImage('EDGE_FLAG_AA', edgeFlag.buffer, width, height);
  } catch (e) {
    print('  EDGE_FLAG_AA failed: $e');
  }

  // ─── RESULTADOS ─────────────────────────────────────────────────────────
  print('');
  print('╔══════════════════════════════════════════════════════════════════╗');
  print('║                          RESULTS                                  ║');
  print('╠══════════════════════════════════════════════════════════════════╣');

  // Ordenar por velocidade
  results.sort((a, b) => a.timeMs.compareTo(b.timeMs));

  for (final result in results) {
    final name = result.name.padRight(15);
    final time = '${result.timeMs.toStringAsFixed(2)}ms'.padLeft(10);
    final pps = '${result.polygonsPerSecond} poly/s'.padLeft(15);
    print('║ $name │ $time │ $pps ║');
  }

  print('╚══════════════════════════════════════════════════════════════════╝');
}
