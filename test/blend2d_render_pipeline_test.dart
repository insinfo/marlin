import 'package:test/test.dart';

import 'package:dgfx/dgfx.dart';

const int _kWhite = 0xFFFFFFFF;
const int _kBlack = 0xFF000000;

bool _isDrawn(BLImage image, int x, int y) =>
    image.pixels[y * image.width + x] != _kWhite;

int _countDrawn(BLImage image) {
  int count = 0;
  for (int i = 0; i < image.pixels.length; i++) {
    if (image.pixels[i] != _kWhite) count++;
  }
  return count;
}

/// Conta linhas desenhadas na coluna [x] — a espessura do traco em device.
int _drawnRowsInColumn(BLImage image, int x) {
  int count = 0;
  for (int y = 0; y < image.height; y++) {
    if (_isDrawn(image, x, y)) count++;
  }
  return count;
}

void main() {
  // =========================================================================
  // Item 4 — nenhuma copia de superficie por draw
  // =========================================================================
  group('sincronizacao da superficie', () {
    test('N draws produzem O(1) copias de superficie (zero)', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      // Baseline: antes, cada draw terminava com image.copyFrom(buffer), ou
      // seja 200 copias de 64x64 aqui. Agora o rasterizador compoe direto no
      // buffer da imagem e a contagem nao depende de N.
      //
      // Medido numa pagina de 1224x1584 (A4 a 144dpi): 2000 fills pequenos
      // levam ~55 ms; as 2000 copias de superficie que os acompanhavam
      // custariam ~1404 ms sozinhas — 25x o proprio desenho.
      for (int i = 0; i < 200; i++) {
        await ctx.fillRect(i % 32, i % 32, 4, 4, color: _kBlack);
      }
      expect(ctx.surfaceCopyCount, 0);

      ctx.flush();
      expect(ctx.surfaceCopyCount, 0);

      await ctx.dispose();
    });

    test('pixels ficam visiveis na imagem sem flush explicito', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      await ctx.fillRect(8, 8, 16, 16, color: _kBlack);
      expect(image.pixels[16 * 32 + 16], _kBlack);

      await ctx.dispose();
    });

    test('flush e idempotente e nao altera pixels', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);
      await ctx.fillRect(4, 4, 8, 8, color: _kBlack);

      final before = List<int>.from(image.pixels);
      ctx.flush();
      ctx.flush();
      expect(image.pixels, before);
      expect(ctx.surfaceCopyCount, 0);

      await ctx.dispose();
    });

    test('drawImage tambem escreve direto na superficie', () {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      final src = BLImage(8, 8);
      src.clear(0xFF0000FF);
      ctx.drawImage(src, dx: 4, dy: 4);

      expect(image.pixels[8 * 32 + 8], 0xFF0000FF);
      expect(ctx.surfaceCopyCount, 0);
    });
  });

  // =========================================================================
  // Item 5 — linhas de largura zero (hairlines)
  // =========================================================================
  group('linha de largura zero (PDF "0 w")', () {
    test('BLStrokeOptions.effectiveWidth cai para minimumWidth', () {
      const zero = BLStrokeOptions(width: 0.0);
      expect(zero.minimumWidth, 1.0);
      expect(zero.effectiveWidth, 1.0);
      expect(const BLStrokeOptions(width: 3.0).effectiveWidth, 3.0);
      expect(
        const BLStrokeOptions(width: 0.0, minimumWidth: 0.25).effectiveWidth,
        0.25,
      );
    });

    test('copyWith preserva minimumWidth', () {
      const opts = BLStrokeOptions(width: 0.0, minimumWidth: 0.5);
      expect(opts.copyWith(width: 2.0).minimumWidth, 0.5);
      expect(opts.copyWith(minimumWidth: 0.125).minimumWidth, 0.125);
    });

    test('largura 0 desenha uma linha de 1 pixel, nao nada', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      final path = BLPath();
      path.moveTo(8, 32);
      path.lineTo(56, 32);
      await ctx.strokePath(
        path,
        color: _kBlack,
        options: const BLStrokeOptions(width: 0.0),
      );

      expect(_countDrawn(image), greaterThan(0));
      // Traco centrado em y=32 com meia largura 0.5: cobre as linhas 31 e 32.
      expect(_drawnRowsInColumn(image, 32), 2);
      expect(_isDrawn(image, 32, 30), isFalse);
      expect(_isDrawn(image, 32, 33), isFalse);

      await ctx.dispose();
    });

    test('largura 0 continua com 1 pixel sob escala de device', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      // A CTM leva o espaco do usuario a 8x; a hairline precisa continuar com
      // um pixel de device, nao virar 8 pixels.
      ctx.scale(8.0, 8.0);
      final path = BLPath();
      path.moveTo(1, 4); // device: (8, 32)
      path.lineTo(7, 4); // device: (56, 32)
      await ctx.strokePath(
        path,
        color: _kBlack,
        options: const BLStrokeOptions(width: 0.0),
      );

      expect(_countDrawn(image), greaterThan(0));
      expect(_drawnRowsInColumn(image, 32), lessThanOrEqualTo(2));

      await ctx.dispose();
    });

    test('largura positiva escala normalmente com a CTM', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.scale(8.0, 8.0);
      final path = BLPath();
      path.moveTo(1, 4);
      path.lineTo(7, 4);
      await ctx.strokePath(
        path,
        color: _kBlack,
        options: const BLStrokeOptions(width: 1.0),
      );

      // 1 unidade de usuario * escala 8 = 8 pixels de device.
      expect(_drawnRowsInColumn(image, 32), 8);

      await ctx.dispose();
    });

    test('BLStroker aceita largura 0 e produz outline de 1 unidade', () {
      final path = BLPath();
      path.moveTo(0, 0);
      path.lineTo(10, 0);

      final outline =
          BLStroker.strokePath(path, const BLStrokeOptions(width: 0.0));
      final verts = outline.toPathData().vertices;
      expect(verts.isEmpty, isFalse);

      double minY = double.infinity, maxY = double.negativeInfinity;
      for (int i = 1; i < verts.length; i += 2) {
        if (verts[i] < minY) minY = verts[i];
        if (verts[i] > maxY) maxY = verts[i];
      }
      expect(maxY - minY, closeTo(1.0, 1e-9));
    });
  });

  // =========================================================================
  // globalAlpha (ca / CA do PDF) em todos os tipos de fill
  // =========================================================================
  group('globalAlpha vale para todo tipo de fill', () {
    Future<int> fillWholeImage(BLContext ctx, BLImage image) async {
      await ctx.fillPolygon([
        0.0,
        0.0,
        image.width.toDouble(),
        0.0,
        image.width.toDouble(),
        image.height.toDouble(),
        0.0,
        image.height.toDouble(),
      ]);
      return image.pixels[(image.height ~/ 2) * image.width + image.width ~/ 2];
    }

    const redGradient = BLLinearGradient(
      p0: BLPoint(0, 0),
      p1: BLPoint(31, 0),
      stops: [
        BLGradientStop(0.0, 0xFFFF0000),
        BLGradientStop(1.0, 0xFFFF0000),
      ],
    );

    test('gradiente linear opaco sem globalAlpha continua opaco', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);
      ctx.setLinearGradient(redGradient);

      expect(await fillWholeImage(ctx, image), 0xFFFF0000);

      await ctx.dispose();
    });

    test('globalAlpha 0.5 reduz a opacidade do gradiente', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);
      ctx.setLinearGradient(redGradient);
      ctx.setGlobalAlpha(0.5);

      final pixel = await fillWholeImage(ctx, image);
      final r = (pixel >> 16) & 0xFF;
      final g = (pixel >> 8) & 0xFF;
      final b = pixel & 0xFF;

      expect(pixel, isNot(0xFFFF0000));
      expect(r, greaterThan(g)); // continua avermelhado
      expect(g, greaterThan(100)); // branco do fundo aparece
      expect(g, lessThan(160));
      expect(b, g); // canal azul acompanha o verde no blend com branco

      await ctx.dispose();
    });

    test('globalAlpha 0 torna o gradiente invisivel', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);
      ctx.setLinearGradient(redGradient);
      ctx.setGlobalAlpha(0.0);

      expect(await fillWholeImage(ctx, image), _kWhite);

      await ctx.dispose();
    });

    test('globalAlpha 0.5 reduz a opacidade do padrao (pattern)', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      final tile = BLImage(8, 8);
      tile.clear(0xFFFF0000);
      ctx.setPattern(BLPattern(image: tile));
      ctx.setGlobalAlpha(0.5);

      final pixel = await fillWholeImage(ctx, image);
      expect(pixel, isNot(0xFFFF0000));
      expect((pixel >> 8) & 0xFF, greaterThan(0));

      await ctx.dispose();
    });

    test('globalAlpha do fill solido segue igual (nao regrediu)', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);
      ctx.setFillStyle(0xFFFF0000);
      ctx.setGlobalAlpha(0.5);

      final pixel = await fillWholeImage(ctx, image);
      final r = (pixel >> 16) & 0xFF;
      final g = (pixel >> 8) & 0xFF;
      expect(r, greaterThan(g));
      expect(g, greaterThan(0));

      await ctx.dispose();
    });
  });
}
