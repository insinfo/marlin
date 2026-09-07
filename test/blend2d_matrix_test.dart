import 'dart:math' as math;

import 'package:test/test.dart';

import 'package:dgfx/dgfx.dart';

void _expectPoint((double, double) actual, double x, double y,
    {double tolerance = 1e-9}) {
  expect(actual.$1, closeTo(x, tolerance));
  expect(actual.$2, closeTo(y, tolerance));
}

void main() {
  group('BLMatrix2D construtores', () {
    test('translation move o ponto', () {
      _expectPoint(BLMatrix2D.translation(10, -4).mapPoint(1, 2), 11, -2);
    });

    test('scaling escala o ponto', () {
      _expectPoint(BLMatrix2D.scaling(2, 3).mapPoint(4, 5), 8, 15);
    });

    test('rotation de 90 graus leva (1,0) para (0,1)', () {
      // Convencao do Blend2D C++ / operador `cm` do PDF: (cos, sin, -sin, cos).
      _expectPoint(
        BLMatrix2D.rotation(math.pi / 2).mapPoint(1, 0),
        0,
        1,
        tolerance: 1e-12,
      );
    });

    test('identity nao altera o ponto', () {
      _expectPoint(BLMatrix2D.identity.mapPoint(3, 7), 3, 7);
      expect(BLMatrix2D.identity.isIdentity, isTrue);
      expect(BLMatrix2D.scaling(2, 2).isIdentity, isFalse);
    });
  });

  group('BLMatrix2D.multiply', () {
    test('this e aplicada primeiro, other depois', () {
      final t = BLMatrix2D.translation(10, 0);
      final s = BLMatrix2D.scaling(2, 2);

      // t.multiply(s): transladar e depois escalar => (1+10)*2 = 22.
      _expectPoint(t.multiply(s).mapPoint(1, 0), 22, 0);
      // s.multiply(t): escalar e depois transladar => 1*2+10 = 12.
      _expectPoint(s.multiply(t).mapPoint(1, 0), 12, 0);
    });

    test('equivale a compor mapPoint na mesma ordem', () {
      final a = BLMatrix2D.rotation(0.7).multiply(BLMatrix2D.scaling(1.5, 2.0));
      final b = BLMatrix2D.translation(-3, 8);

      final composed = a.multiply(b).mapPoint(2.5, -1.25);
      final manual = a.mapPoint(2.5, -1.25);
      final stepwise = b.mapPoint(manual.$1, manual.$2);

      _expectPoint(composed, stepwise.$1, stepwise.$2);
    });

    test('identity e neutro dos dois lados', () {
      final m = BLMatrix2D(2, 3, 4, 5, 6, 7);
      final left = BLMatrix2D.identity.multiply(m);
      final right = m.multiply(BLMatrix2D.identity);
      for (final result in [left, right]) {
        _expectPoint(
            result.mapPoint(1, 1), m.mapPoint(1, 1).$1, m.mapPoint(1, 1).$2);
      }
    });
  });

  group('BLMatrix2D.invert / determinant', () {
    test('determinant da parte linear', () {
      expect(BLMatrix2D.scaling(3, 4).determinant, closeTo(12, 1e-12));
      expect(BLMatrix2D.translation(9, 9).determinant, closeTo(1, 1e-12));
      expect(BLMatrix2D.rotation(1.2).determinant, closeTo(1, 1e-12));
    });

    test('m * m.invert() == identity', () {
      final m = BLMatrix2D.rotation(0.4)
          .multiply(BLMatrix2D.scaling(3, -2))
          .multiply(BLMatrix2D.translation(17, -5));
      final inv = m.invert();
      expect(inv, isNotNull);

      final product = m.multiply(inv!);
      _expectPoint(product.mapPoint(1, 0), 1, 0, tolerance: 1e-9);
      _expectPoint(product.mapPoint(0, 1), 0, 1, tolerance: 1e-9);
      _expectPoint(product.mapPoint(0, 0), 0, 0, tolerance: 1e-9);
    });

    test('invert desfaz mapPoint (device -> espaco do padrao)', () {
      final m = BLMatrix2D.scaling(2, 4).multiply(BLMatrix2D.translation(5, 6));
      final mapped = m.mapPoint(3, -7);
      final back = m.invert()!.mapPoint(mapped.$1, mapped.$2);
      _expectPoint(back, 3, -7, tolerance: 1e-9);
    });

    test('matriz singular devolve null', () {
      expect(BLMatrix2D.scaling(0, 5).invert(), isNull);
      expect(BLMatrix2D.scaling(5, 0).invert(), isNull);
      // Duas linhas colineares: determinante zero.
      expect(const BLMatrix2D(1, 2, 2, 4, 0, 0).invert(), isNull);
    });
  });

  group('BLContext transform', () {
    test('transform() pre-concatena como o `cm` do PDF', () {
      final ctx = BLContext(BLImage(8, 8));
      ctx.transform(BLMatrix2D.translation(10, 10));
      ctx.transform(BLMatrix2D.scaling(2, 2));

      // Sequencia PDF: a matriz mais recente age primeiro sobre o ponto do
      // usuario, entao (1,1) -> escala -> (2,2) -> translacao -> (12,12).
      _expectPoint(ctx.transformPoint(1, 1), 12, 12);
    });

    test('translate()/scale() continuam pos-concatenando em device', () {
      final ctx = BLContext(BLImage(8, 8));
      ctx.translate(10, 0);
      ctx.scale(2, 1);

      // Pos-concatenacao: translada primeiro (11,0) e a escala age no
      // resultado em espaco de device => (22,0).
      _expectPoint(ctx.transformPoint(1, 0), 22, 0);
    });

    test('transform() com a inversa volta para a identidade', () {
      final ctx = BLContext(BLImage(8, 8));
      final m = BLMatrix2D.rotation(0.9).multiply(BLMatrix2D.scaling(3, 3));
      ctx.transform(m);
      expect(ctx.isTransformIdentity, isFalse);
      ctx.transform(m.invert()!);
      _expectPoint(ctx.transformPoint(4, 9), 4, 9, tolerance: 1e-9);
    });

    test('save/restore preserva a transformacao', () {
      final ctx = BLContext(BLImage(8, 8));
      ctx.transform(BLMatrix2D.translation(5, 5));
      ctx.save();
      ctx.transform(BLMatrix2D.scaling(10, 10));
      _expectPoint(ctx.transformPoint(1, 1), 15, 15);
      ctx.restore();
      _expectPoint(ctx.transformPoint(1, 1), 6, 6);
    });
  });
}
