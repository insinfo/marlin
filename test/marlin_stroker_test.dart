
import 'package:test/test.dart';
import 'package:marlin/src/marlin/marlin_renderer.dart';
import 'package:marlin/src/marlin/stroker.dart';
import 'package:marlin/src/marlin/context/renderer_context.dart';
import 'package:marlin/src/marlin/marlin_const.dart';

void main() {
  test('Marlin Stroker Test', () {
      final ctx = RendererContext.createContext();
      const int size = 400;
      final renderer = MarlinRenderer.withContext(ctx, size, size);
      final stroker = Stroker(ctx);
      
      renderer.clear(0xFFFFFFFF);
      
      // Init Stroker with Renderer as output
      // Note: Renderer must be initialized to accept path commands.
      // MarlinRenderer.init() resets state for rasterization.
      renderer.init(0, 0, size, size, MarlinConst.windNonZero); 
      
      stroker.init(renderer, 10.0, Stroker.CAP_ROUND, Stroker.JOIN_ROUND, 10.0);
      
      stroker.moveTo(50.0, 50.0);
      stroker.lineTo(350.0, 350.0);
      stroker.pathDone(); 
      
      // Verify
      int drawn = 0;
      final buffer = renderer.buffer;
      for(int p in buffer) {
          // Fix signed/unsigned mismatch: Int32List elements are signed. 0xFFFFFFFF is -1.
          // Comparing to literal 0xFFFFFFFF (4294967295) fails.
          if ((p & 0xFFFFFFFF) != 0xFFFFFFFF) drawn++;
      }
      print('Stroked Pixels: $drawn');
      // ~300 * 10 = 3000 + Caps. Expect reasonable count.
      expect(drawn, greaterThan(1000));
      expect(drawn, lessThan(15000)); 
  });
  
  test('Marlin Stroker Curve Test', () {
      final ctx = RendererContext.createContext();
      const int size = 400;
      final renderer = MarlinRenderer.withContext(ctx, size, size);
      final stroker = Stroker(ctx);
      
      renderer.clear(0xFFFFFFFF);
      renderer.init(0, 0, size, size, MarlinConst.windNonZero); 
      
      stroker.init(renderer, 10.0, Stroker.CAP_ROUND, Stroker.JOIN_ROUND, 10.0);
      
      stroker.moveTo(50.0, 200.0);
      stroker.curveTo(150.0, 50.0, 250.0, 350.0, 350.0, 200.0);
      stroker.pathDone(); 
      
      // Verify
      int drawn = 0;
      final buffer = renderer.buffer;
      for(int p in buffer) {
          if ((p & 0xFFFFFFFF) != 0xFFFFFFFF) drawn++;
      }
      print('Stroked Curve Pixels: $drawn');
      expect(drawn, greaterThan(1000));
      expect(drawn, lessThan(15000));
  });
}
