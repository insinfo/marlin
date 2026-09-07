// Confere o rasterizador do dgfx contra um oráculo INDEPENDENTE: o port em
// Dart do Marlin renderer do OpenJDK, em `third_party/marlin_openjdk/`.
//
// O valor deste teste está em serem duas implementações sem parentesco. O dgfx
// deriva do Blend2D e acumula cobertura analítica por célula; o Marlin vem do
// OpenJDK e faz amostragem numa grade 8x8 de subpixels. Um erro de geometria
// que existisse nos dois ao mesmo tempo é muito improvável — enquanto um
// golden gerado pelo próprio dgfx só detectaria mudanças, jamais um bug que já
// estivesse lá desde o começo.
//
// Este arquivo importa código GPL e por isso é excluído do pacote publicado
// (veja `.pubignore`). A Classpath Exception permite exatamente este uso:
// linkar um módulo independente contra a biblioteca, sem contaminá-lo.
import 'dart:math' as math;

import 'package:dgfx/dgfx.dart';
import 'package:test/test.dart';

import '../third_party/marlin_openjdk/marlin_const.dart';
import '../third_party/marlin_openjdk/marlin_renderer.dart';

const int _width = 120;
const int _height = 120;

/// Cobertura por pixel, em 0..255, extraída de um buffer ARGB onde a forma foi
/// pintada de preto opaco sobre branco opaco.
///
/// Comparar cobertura em vez de cor é o que torna as duas implementações
/// comparáveis: elas concordam sobre *quanta* área do pixel a forma ocupa,
/// mesmo escrevendo o resultado com aritmética de composição diferente.
List<int> _coverage(List<int> argb) =>
    [for (final pixel in argb) 255 - (pixel & 0xFF)];

Future<List<int>> _renderWithDgfx(
  List<double> vertices, {
  required BLFillRule rule,
  List<int>? contours,
}) async {
  final image = BLImage(_width, _height);
  final ctx = BLContext(image)..clear(0xFFFFFFFF);
  ctx.setFillStyle(0xFF000000);
  await ctx.fillPolygon(vertices, rule: rule, contourVertexCounts: contours);
  ctx.flush();
  return _coverage(image.pixels);
}

List<int> _renderWithMarlin(
  List<double> vertices, {
  required int windingRule,
  List<int>? contours,
}) {
  final renderer = MarlinRenderer(_width, _height)..clear(0xFFFFFFFF);
  renderer.drawPolygon(vertices, 0xFF000000,
      windingRule: windingRule, contourVertexCounts: contours);
  return _coverage(renderer.buffer);
}

/// Resultado da comparação entre os dois rasterizadores.
class _Comparison {
  /// Pixels em que um diz "totalmente dentro" e o outro "totalmente fora".
  /// Isso é discordância de geometria, não de anti-aliasing, e deve ser zero.
  final int contradictions;

  /// Diferença média absoluta de cobertura, em níveis de 0..255.
  final double meanDelta;

  /// Área total coberta, somando a cobertura de todos os pixels.
  final int areaA;
  final int areaB;

  const _Comparison(
      this.contradictions, this.meanDelta, this.areaA, this.areaB);

  double get areaRatio => areaB == 0 ? 0 : areaA / areaB;
}

_Comparison _compare(List<int> a, List<int> b) {
  var contradictions = 0;
  var sumDelta = 0;
  var areaA = 0;
  var areaB = 0;

  for (var i = 0; i < a.length; i++) {
    final ca = a[i];
    final cb = b[i];
    areaA += ca;
    areaB += cb;
    sumDelta += (ca - cb).abs();
    // Saturado num, zerado no outro: os dois discordam sobre de que lado da
    // aresta o pixel está, o que nenhuma diferença de AA explica.
    if ((ca == 255 && cb == 0) || (ca == 0 && cb == 255)) contradictions++;
  }

  return _Comparison(contradictions, sumDelta / a.length, areaA, areaB);
}

Future<void> _expectAgreement(
  String what,
  List<double> vertices, {
  BLFillRule rule = BLFillRule.nonZero,
  List<int>? contours,
  double maxMeanDelta = 0.3,
  double areaTolerance = 0.005,
  bool pixelIdentical = false,
}) async {
  final mine = await _renderWithDgfx(vertices, rule: rule, contours: contours);
  final theirs = _renderWithMarlin(
    vertices,
    windingRule: rule == BLFillRule.evenOdd
        ? MarlinConst.windEvenOdd
        : MarlinConst.windNonZero,
    contours: contours,
  );

  final result = _compare(mine, theirs);

  expect(result.areaA, greaterThan(0),
      reason: '$what: o dgfx não desenhou nada');
  expect(result.areaB, greaterThan(0),
      reason: '$what: o oráculo não desenhou nada — assim o caso de teste é '
          'inútil e passaria por acidente');

  expect(result.contradictions, isZero,
      reason: '$what: ${result.contradictions} pixels estão totalmente '
          'preenchidos num rasterizador e totalmente vazios no outro. Isso é '
          'discordância de geometria, não de anti-aliasing');

  expect(result.meanDelta, lessThan(maxMeanDelta),
      reason: '$what: cobertura média difere em '
          '${result.meanDelta.toStringAsFixed(2)} níveis, limite $maxMeanDelta');

  expect(result.areaRatio, closeTo(1.0, areaTolerance),
      reason: '$what: área coberta difere em '
          '${((result.areaRatio - 1) * 100).abs().toStringAsFixed(3)}%');

  if (pixelIdentical) {
    // Onde toda aresta cai sobre a grade de pixels não sobra anti-aliasing
    // para justificar diferença nenhuma: os dois têm que produzir exatamente
    // os mesmos bytes. Afrouxar isto esconderia erro de meio pixel.
    expect(mine, orderedEquals(theirs),
        reason: '$what: as arestas são todas inteiras, então a saída dos dois '
            'rasterizadores deveria ser byte a byte idêntica');
  }
}

void main() {
  group('dgfx concorda com o Marlin do OpenJDK', () {
    test('triângulo', () async {
      await _expectAgreement('triângulo', [20, 20, 100, 35, 55, 100]);
    });

    test('retângulo alinhado ao pixel, onde não há AA para justificar erro',
        () async {
      await _expectAgreement(
        'retângulo',
        [20, 20, 100, 20, 100, 100, 20, 100],
        pixelIdentical: true,
      );
    });

    test('losango com arestas a 45 graus', () async {
      await _expectAgreement('losango', [60, 15, 105, 60, 60, 105, 15, 60]);
    });

    test('anel: quadrado com furo, regra even-odd', () async {
      await _expectAgreement(
        'anel even-odd',
        [
          10, 10, 110, 10, 110, 110, 10, 110, //
          40, 40, 80, 40, 80, 80, 40, 80,
        ],
        rule: BLFillRule.evenOdd,
        contours: const [4, 4],
        pixelIdentical: true,
      );
    });

    test('a mesma forma sob non-zero preenche o furo', () async {
      // Os dois contornos têm a mesma orientação, então o non-zero deve
      // preencher sólido. Se os dois discordassem aqui, um estaria errando o
      // sinal do winding.
      await _expectAgreement(
        'anel non-zero',
        [
          10, 10, 110, 10, 110, 110, 10, 110, //
          40, 40, 80, 40, 80, 80, 40, 80,
        ],
        contours: const [4, 4],
        pixelIdentical: true,
      );
    });

    test('estrela que se auto-intersecta, nas duas regras de winding',
        () async {
      // O caso em que even-odd e non-zero realmente divergem uma da outra.
      final star = <double>[];
      const cx = 60.0;
      const cy = 60.0;
      for (var i = 0; i < 10; i++) {
        final angle = -math.pi / 2 + i * math.pi / 5;
        final radius = i.isEven ? 48.0 : 20.0;
        star
          ..add(cx + radius * math.cos(angle))
          ..add(cy + radius * math.sin(angle));
      }

      await _expectAgreement('estrela even-odd', star,
          rule: BLFillRule.evenOdd);
      await _expectAgreement('estrela non-zero', star);
    });

    test('sliver: triângulo quase degenerado', () async {
      // Formas muito finas são onde rasterizadores costumam divergir, porque
      // nenhum pixel fica totalmente coberto e tudo vira anti-aliasing.
      await _expectAgreement(
        'sliver',
        [10, 58, 110, 60, 10, 62],
        areaTolerance: 0.01,
      );
    });

    test('o comparador reprova formas diferentes (guarda do próprio teste)',
        () async {
      // Sem isto, um bug que fizesse `_compare` sempre concordar deixaria
      // todos os casos acima passando por vacuidade.
      final triangle = await _renderWithDgfx(
        [20, 20, 100, 35, 55, 100],
        rule: BLFillRule.nonZero,
      );
      final shifted = _renderWithMarlin(
        [40, 20, 120, 35, 75, 100],
        windingRule: MarlinConst.windNonZero,
      );

      final result = _compare(triangle, shifted);
      expect(result.contradictions, greaterThan(0),
          reason: 'duas formas deslocadas têm que produzir contradições');
    });
  });
}
