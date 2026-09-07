import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:dgfx/dgfx.dart';

const int _kWhite = 0xFFFFFFFF;
const int _kBlack = 0xFF000000;

int _countDrawn(BLImage image) {
  int count = 0;
  for (int i = 0; i < image.pixels.length; i++) {
    if (image.pixels[i] != _kWhite) count++;
  }
  return count;
}

bool _isDrawn(BLImage image, int x, int y) =>
    image.pixels[y * image.width + x] != _kWhite;

BLPath _rectPath(double x, double y, double w, double h) {
  final path = BLPath();
  path.moveTo(x, y);
  path.lineTo(x + w, y);
  path.lineTo(x + w, y + h);
  path.lineTo(x, y + h);
  path.close();
  return path;
}

BLPath _circlePath(double cx, double cy, double r) {
  const k = 0.5522847498;
  final kr = r * k;
  final path = BLPath();
  path.moveTo(cx + r, cy);
  path.cubicTo(cx + r, cy - kr, cx + kr, cy - r, cx, cy - r);
  path.cubicTo(cx - kr, cy - r, cx - r, cy - kr, cx - r, cy);
  path.cubicTo(cx - r, cy + kr, cx - kr, cy + r, cx, cy + r);
  path.cubicTo(cx + kr, cy + r, cx + r, cy + kr, cx + r, cy);
  path.close();
  return path;
}

/// Preenche a imagem inteira com preto respeitando o clip corrente.
Future<void> _fillEverything(BLContext ctx, BLImage image) {
  return ctx.fillPolygon(
    [
      0.0,
      0.0,
      image.width.toDouble(),
      0.0,
      image.width.toDouble(),
      image.height.toDouble(),
      0.0,
      image.height.toDouble(),
    ],
    color: _kBlack,
  );
}

void main() {
  group('clipRect recorta de verdade (nao so rejeita por bbox)', () {
    test('forma que atravessa a borda do clip e cortada exatamente nela',
        () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);
      ctx.setClipRect(const BLRectI(10, 10, 20, 20)); // x,y em [10,30)

      // Retangulo 0..40 nos dois eixos: atravessa as quatro bordas do clip.
      await ctx.fillPolygon([0, 0, 40, 0, 40, 40, 0, 40], color: _kBlack);

      expect(_countDrawn(image), 20 * 20);
      expect(_isDrawn(image, 10, 10), isTrue);
      expect(_isDrawn(image, 29, 29), isTrue);
      expect(_isDrawn(image, 9, 15), isFalse);
      expect(_isDrawn(image, 30, 15), isFalse);
      expect(_isDrawn(image, 15, 9), isFalse);
      expect(_isDrawn(image, 15, 30), isFalse);

      await ctx.dispose();
    });

    test('stroke que atravessa a borda do clip tambem e cortado', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);
      ctx.setClipRect(const BLRectI(20, 0, 10, 64));

      final path = BLPath();
      path.moveTo(0, 32);
      path.lineTo(64, 32);
      await ctx.strokePath(
        path,
        color: _kBlack,
        options: const BLStrokeOptions(width: 4.0),
      );

      expect(_isDrawn(image, 25, 32), isTrue);
      expect(_isDrawn(image, 10, 32), isFalse);
      expect(_isDrawn(image, 40, 32), isFalse);

      await ctx.dispose();
    });
  });

  group('clipToPath', () {
    test('intersectClipMask combina cobertura e participa de save/restore', () {
      final image = BLImage(2, 2);
      final ctx = BLContext(image);
      ctx.intersectClipMask(Uint8List.fromList([255, 128, 64, 0]));
      expect(ctx.clipMask, [255, 128, 64, 0]);

      final original = ctx.clipMask;
      ctx.save();
      ctx.intersectClipMask(Uint8List.fromList([128, 128, 255, 255]));
      expect(ctx.clipMask, [128, 64, 64, 0]);
      ctx.restore();
      expect(identical(ctx.clipMask, original), isTrue);
    });

    test('intersectClipMask rejeita dimensão diferente da imagem', () {
      final ctx = BLContext(BLImage(2, 2));
      expect(() => ctx.intersectClipMask(Uint8List(3)), throwsArgumentError);
    });
    test('clip circular transforma um retangulo em disco', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(_circlePath(32, 32, 16));
      await _fillEverything(ctx, image);

      // Area do disco ~ pi*16^2 ~ 804; a borda antialiased entra na contagem.
      final drawn = _countDrawn(image);
      expect(drawn, greaterThan(750));
      expect(drawn, lessThan(950));

      expect(_isDrawn(image, 32, 32), isTrue); // centro
      expect(_isDrawn(image, 32, 18), isTrue); // dentro, perto da borda
      expect(_isDrawn(image, 32, 12), isFalse); // fora (dist 20 > 16)
      expect(_isDrawn(image, 2, 2), isFalse); // canto
      expect(_isDrawn(image, 61, 61), isFalse);

      await ctx.dispose();
    });

    test('a borda do clip e antialiased, nao binaria', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(_circlePath(32, 32, 16));
      await _fillEverything(ctx, image);

      // Deve existir pelo menos um pixel parcialmente coberto (cinza) na
      // borda do disco: clip multiplicativo preserva a cobertura fracionaria.
      int partial = 0;
      for (final px in image.pixels) {
        if (px != _kWhite && px != _kBlack) partial++;
      }
      expect(partial, greaterThan(20));

      await ctx.dispose();
    });

    test('clips aninhados se intersectam', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(_rectPath(10, 10, 30, 30)); // [10,40)
      ctx.clipToPath(_rectPath(25, 25, 30, 30)); // [25,55)
      await _fillEverything(ctx, image);

      // Intersecao: [25,40) x [25,40) = 15x15.
      expect(_countDrawn(image), 15 * 15);
      expect(_isDrawn(image, 30, 30), isTrue);
      expect(_isDrawn(image, 20, 30), isFalse);
      expect(_isDrawn(image, 45, 30), isFalse);

      await ctx.dispose();
    });

    test('clip degenerado (caminho vazio) bloqueia tudo', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(BLPath()..moveTo(5, 5));
      await _fillEverything(ctx, image);

      expect(_countDrawn(image), 0);

      await ctx.dispose();
    });

    test('clipToPath respeita a transformacao corrente', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.transform(BLMatrix2D.scaling(2, 2));
      ctx.clipToPath(_rectPath(5, 5, 10, 10)); // device: [10,30)
      ctx.resetTransform();
      await _fillEverything(ctx, image);

      expect(_countDrawn(image), 20 * 20);
      expect(_isDrawn(image, 10, 10), isTrue);
      expect(_isDrawn(image, 29, 29), isTrue);
      expect(_isDrawn(image, 30, 30), isFalse);

      await ctx.dispose();
    });

    test('clipToRectPath recorta pelo retangulo em espaco do usuario',
        () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.transform(BLMatrix2D.scaling(2, 2));
      ctx.clipToRectPath(4, 4, 8, 8); // device: [8,24)
      ctx.resetTransform();
      await _fillEverything(ctx, image);

      expect(_countDrawn(image), 16 * 16);
      expect(_isDrawn(image, 8, 8), isTrue);
      expect(_isDrawn(image, 24, 24), isFalse);

      await ctx.dispose();
    });

    test('clipToPath combina com clipRect', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.setClipRect(const BLRectI(0, 0, 32, 64));
      ctx.clipToPath(_rectPath(20, 20, 30, 30)); // [20,50)
      await _fillEverything(ctx, image);

      // [20,32) x [20,50) = 12 x 30.
      expect(_countDrawn(image), 12 * 30);
      expect(_isDrawn(image, 25, 25), isTrue);
      expect(_isDrawn(image, 35, 25), isFalse);

      await ctx.dispose();
    });
  });

  group('pilha de clip (save/restore)', () {
    test('restore devolve o clip anterior', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(_rectPath(10, 10, 30, 30)); // [10,40)
      final outer = ctx.clipMask;

      ctx.save();
      ctx.clipToPath(_rectPath(12, 12, 6, 6)); // [12,18)
      await _fillEverything(ctx, image);
      expect(_countDrawn(image), 6 * 6);

      ctx.restore();
      // A mascara restaurada e exatamente o objeto de antes: clipToPath nunca
      // escreve numa mascara ja publicada.
      expect(identical(ctx.clipMask, outer), isTrue);

      ctx.clear(_kWhite);
      await _fillEverything(ctx, image);
      expect(_countDrawn(image), 30 * 30);

      await ctx.dispose();
    });

    test('restore em contexto sem clip volta para sem clip', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.save();
      ctx.clipToPath(_rectPath(4, 4, 8, 8));
      ctx.restore();
      expect(ctx.clipMask, isNull);

      await _fillEverything(ctx, image);
      expect(_countDrawn(image), 32 * 32);

      await ctx.dispose();
    });

    test('resetClip limpa mascara e retangulo', () async {
      final image = BLImage(32, 32);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.setClipRect(const BLRectI(0, 0, 4, 4));
      ctx.clipToPath(_rectPath(0, 0, 4, 4));
      ctx.resetClip();
      expect(ctx.clipMask, isNull);
      expect(ctx.clipRect, isNull);

      await _fillEverything(ctx, image);
      expect(_countDrawn(image), 32 * 32);

      await ctx.dispose();
    });
  });

  group('todas as primitivas honram a mascara', () {
    test('drawImage e cortado pela mascara', () {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(_rectPath(20, 20, 10, 10)); // [20,30)

      final src = BLImage(40, 40);
      src.clear(0xFF00FF00);
      ctx.drawImage(src, dx: 10, dy: 10);

      expect(image.pixels[25 * 64 + 25], 0xFF00FF00);
      expect(image.pixels[15 * 64 + 15], _kWhite);
      expect(image.pixels[35 * 64 + 35], _kWhite);
      expect(_countDrawn(image), 10 * 10);
    });

    test('fill com gradiente e cortado pela mascara', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.setLinearGradient(const BLLinearGradient(
        p0: BLPoint(0, 0),
        p1: BLPoint(63, 0),
        stops: [
          BLGradientStop(0.0, 0xFFFF0000),
          BLGradientStop(1.0, 0xFF0000FF),
        ],
      ));
      ctx.clipToPath(_rectPath(16, 16, 16, 16)); // [16,32)
      await _fillEverything(ctx, image);

      expect(_countDrawn(image), 16 * 16);
      expect(_isDrawn(image, 20, 20), isTrue);
      expect(_isDrawn(image, 40, 20), isFalse);

      await ctx.dispose();
    });

    test('strokePath e cortado pela mascara', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(_rectPath(0, 0, 32, 64));

      final path = BLPath();
      path.moveTo(0, 32);
      path.lineTo(64, 32);
      await ctx.strokePath(
        path,
        color: _kBlack,
        options: const BLStrokeOptions(width: 4.0),
      );

      expect(_isDrawn(image, 10, 32), isTrue);
      expect(_isDrawn(image, 40, 32), isFalse);

      await ctx.dispose();
    });

    test('fillPath e cortado pela mascara', () async {
      final image = BLImage(64, 64);
      final ctx = BLContext(image);
      ctx.clear(_kWhite);

      ctx.clipToPath(_circlePath(32, 32, 10));
      await ctx.fillPath(_rectPath(0, 0, 64, 64), color: _kBlack);

      expect(_isDrawn(image, 32, 32), isTrue);
      expect(_isDrawn(image, 32, 5), isFalse);

      await ctx.dispose();
    });
  });
}
