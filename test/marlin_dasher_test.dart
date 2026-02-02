
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:marlin/src/marlin/marlin_renderer.dart';
import 'package:marlin/src/marlin/stroker.dart';
import 'package:marlin/src/marlin/dasher.dart';
import 'package:marlin/src/marlin/context/renderer_context.dart';
import 'package:marlin/src/marlin/marlin_const.dart';

void main() {
  test('Marlin Dasher Test', () {
      final ctx = RendererContext.createContext();
      const int size = 400;
      final renderer = MarlinRenderer.withContext(ctx, size, size);
      final stroker = Stroker(ctx);
      final dasher = Dasher(ctx);
      
      renderer.clear(0xFFFFFFFF);
      renderer.init(0, 0, size, size, MarlinConst.windNonZero); 
      
      stroker.init(renderer, 5.0, Stroker.CAP_BUTT, Stroker.JOIN_MITER, 10.0);
      dasher.init(stroker, Float64List.fromList([20.0, 20.0]), 2, 0.0, false);
      
      dasher.moveTo(50.0, 50.0);
      dasher.lineTo(350.0, 50.0);
      dasher.pathDone(); 
      
      // Verify
      int drawn = 0;
      final buffer = renderer.buffer;
      for(int p in buffer) {
          if ((p & 0xFFFFFFFF) != 0xFFFFFFFF) drawn++;
      }
      print('Dashed Pixels: $drawn');
      // 300px long. 5px wide. 1500px area.
      // Dashing: 50% on. 750px area.
      expect(drawn, greaterThan(500));
      expect(drawn, lessThan(size * size)); // Should NOT be full fill
  });
}
