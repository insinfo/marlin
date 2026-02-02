
import 'dart:math';
import 'dart:typed_data';
import 'package:marlin/src/marlin/marlin_renderer.dart';
import 'package:marlin/src/marlin/stroker.dart';
import 'package:marlin/src/marlin/dasher.dart';
import 'package:marlin/src/marlin/context/renderer_context.dart';
import 'package:marlin/src/marlin/marlin_const.dart';

void main() {
  final ctx = RendererContext.createContext();
  const int width = 1000;
  const int height = 1000;
  final renderer = MarlinRenderer.withContext(ctx, width, height);
  final stroker = Stroker(ctx);
  final dasher = Dasher(ctx);
  
  // Warmup
  print('Warming up...');
  runBenchmark(renderer, stroker, dasher, 5); // Reduced from 50
  
  // Benchmark
  print('Running benchmark...');
  final stopwatch = Stopwatch()..start();
  int iterations = 10; // Reduced from 100
  runBenchmark(renderer, stroker, dasher, iterations);
  stopwatch.stop();
  
  print('Benchmark completed.');
  print('Total time: ${stopwatch.elapsedMilliseconds} ms');
  print('Average time per frame: ${stopwatch.elapsedMilliseconds / iterations} ms');
  print('FPS: ${1000 / (stopwatch.elapsedMilliseconds / iterations)}');
}

void runBenchmark(MarlinRenderer renderer, Stroker stroker, Dasher dasher, int count) {
  final rand = Random(12345);
  final dashPattern = Float64List.fromList([20.0, 10.0, 5.0, 10.0]);
  
  for (int i = 0; i < count; i++) {
    renderer.clear(0xFFFFFFFF);
    renderer.init(0, 0, 1000, 1000, MarlinConst.windNonZero);
    
    stroker.init(renderer, 2.0, Stroker.CAP_ROUND, Stroker.JOIN_ROUND, 10.0);
    dasher.init(stroker, dashPattern, 4, 0.0, false);
    
    dasher.moveTo(100.0, 100.0);
    for (int j = 0; j < 10; j++) { 
       dasher.curveTo(
           rand.nextDouble() * 1000, rand.nextDouble() * 1000, 
           rand.nextDouble() * 1000, rand.nextDouble() * 1000, 
           rand.nextDouble() * 1000, rand.nextDouble() * 1000);
    }
    dasher.closePath();
    dasher.pathDone();
  }
}
