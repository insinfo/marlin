import 'package:dgfx/dgfx.dart';
import 'package:test/test.dart';

/// Prova que a facade e utilizavel de fora: um consumidor (o renderizador
/// PDF do dpdf) so importa `package:dgfx/dgfx.dart` e ja tem contexto,
/// superficie, caminhos, matriz e clip.
void main() {
  test('dgfx.dart expoe o suficiente para renderizar uma pagina', () async {
    final image = BLImage(32, 32);
    final ctx = BLContext(image);
    ctx.clear(0xFFFFFFFF);

    ctx.transform(BLMatrix2D.scaling(2, 2));
    ctx.clipToPath(BLPath()
      ..moveTo(2, 2)
      ..lineTo(10, 2)
      ..lineTo(10, 10)
      ..lineTo(2, 10)
      ..close());
    ctx.resetTransform();

    await ctx.fillRect(0, 0, 32, 32, color: 0xFF000000);
    await ctx.strokeRect(
      0,
      0,
      32,
      32,
      color: 0xFF00FF00,
      options: const BLStrokeOptions(width: 0.0),
    );
    ctx.flush();

    // Clip em device: [4,20) nos dois eixos.
    expect(image.pixels[10 * 32 + 10], 0xFF000000);
    expect(image.pixels[2 * 32 + 2], 0xFFFFFFFF);
    expect(image.pixels[25 * 32 + 25], 0xFFFFFFFF);

    await ctx.dispose();
  });
}
