import 'dart:typed_data';

import 'package:dgfx/dgfx_io.dart';
import 'package:test/test.dart';

// Monta uma fonte TrueType mínima em memória, com glifos de geometria
// conhecida, e verifica que o pipeline inteiro — leitura do sfnt, cmap,
// contornos `glyf`, avanço e rasterização — coloca tinta exatamente onde a
// geometria manda.
//
// A fonte é construída aqui em vez de vir de um arquivo: nenhum binário entra
// no repositório, não há licença de terceiros envolvida, e a forma esperada de
// cada glifo é conhecida ao ponto do pixel, o que permite afirmações exatas em
// vez de "desenhou alguma coisa".

const int _unitsPerEm = 1000;

/// Um contorno retangular em unidades de fonte, no sentido horário.
class _Rect {
  final int left;
  final int bottom;
  final int right;
  final int top;
  const _Rect(this.left, this.bottom, this.right, this.top);
}

/// Um glifo: um retângulo preenchido e a largura de avanço.
class _Glyph {
  final _Rect? box;
  final int advance;
  const _Glyph(this.box, this.advance);
}

void _u16(BytesBuilder out, int value) {
  out
    ..addByte((value >> 8) & 0xFF)
    ..addByte(value & 0xFF);
}

void _i16(BytesBuilder out, int value) => _u16(out, value & 0xFFFF);

void _u32(BytesBuilder out, int value) {
  out
    ..addByte((value >> 24) & 0xFF)
    ..addByte((value >> 16) & 0xFF)
    ..addByte((value >> 8) & 0xFF)
    ..addByte(value & 0xFF);
}

Uint8List _pad4(Uint8List bytes) {
  final remainder = bytes.length % 4;
  if (remainder == 0) return bytes;
  return Uint8List.fromList([...bytes, ...List.filled(4 - remainder, 0)]);
}

/// Contorno simples de um retângulo: quatro pontos, todos on-curve.
Uint8List _glyphOutline(_Rect box) {
  final out = BytesBuilder();
  _i16(out, 1); // numberOfContours
  _i16(out, box.left);
  _i16(out, box.bottom);
  _i16(out, box.right);
  _i16(out, box.top);
  _u16(out, 3); // endPtsOfContours: último ponto é o índice 3
  _u16(out, 0); // instructionLength

  // Flags: on-curve, sem repetição, coordenadas em dois bytes com sinal.
  for (var i = 0; i < 4; i++) {
    out.addByte(0x01);
  }

  // Coordenadas x, como deltas a partir de (0,0).
  final xs = [box.left, box.right, box.right, box.left];
  final ys = [box.bottom, box.bottom, box.top, box.top];
  var previous = 0;
  for (final x in xs) {
    _i16(out, x - previous);
    previous = x;
  }
  previous = 0;
  for (final y in ys) {
    _i16(out, y - previous);
    previous = y;
  }
  return out.toBytes();
}

/// Monta um arquivo sfnt com as tabelas mínimas e os glifos dados.
///
/// `glyphs[0]` é sempre o `.notdef`; o caractere de código
/// `firstChar + i` mapeia para o glifo `i`.
Uint8List _buildFont(List<_Glyph> glyphs, {int firstChar = 0x41}) {
  final glyphCount = glyphs.length;

  // --- glyf e loca -----------------------------------------------------------
  final glyf = BytesBuilder();
  final offsets = <int>[];
  for (final glyph in glyphs) {
    offsets.add(glyf.length);
    if (glyph.box != null) {
      // Cada glifo alinhado a 4 bytes, como o formato pede.
      glyf.add(_pad4(_glyphOutline(glyph.box!)));
    }
  }
  offsets.add(glyf.length);

  final loca = BytesBuilder();
  for (final offset in offsets) {
    _u32(loca, offset); // formato longo, indexToLocFormat = 1
  }

  // --- head ------------------------------------------------------------------
  final head = BytesBuilder();
  _u32(head, 0x00010000); // version
  _u32(head, 0x00010000); // fontRevision
  _u32(head, 0); // checkSumAdjustment
  _u32(head, 0x5F0F3CF5); // magicNumber
  _u16(head, 0); // flags
  _u16(head, _unitsPerEm); // offset 18
  for (var i = 0; i < 4; i++) {
    _u32(head, 0); // created e modified
  }
  _i16(head, 0); // xMin
  _i16(head, 0); // yMin
  _i16(head, _unitsPerEm); // xMax
  _i16(head, _unitsPerEm); // yMax
  _u16(head, 0); // macStyle
  _u16(head, 8); // lowestRecPPEM
  _i16(head, 2); // fontDirectionHint
  _i16(head, 1); // indexToLocFormat: longo — offset 50
  _i16(head, 0); // glyphDataFormat

  // --- maxp ------------------------------------------------------------------
  final maxp = BytesBuilder();
  _u32(maxp, 0x00010000);
  _u16(maxp, glyphCount); // offset 4
  for (var i = 0; i < 13; i++) {
    _u16(maxp, 0);
  }

  // --- hhea ------------------------------------------------------------------
  final hhea = BytesBuilder();
  _u32(hhea, 0x00010000);
  _i16(hhea, 800); // ascender
  _i16(hhea, -200); // descender
  _i16(hhea, 0); // lineGap
  _u16(hhea, _unitsPerEm); // advanceWidthMax
  _i16(hhea, 0); // minLeftSideBearing
  _i16(hhea, 0); // minRightSideBearing
  _i16(hhea, _unitsPerEm); // xMaxExtent
  _i16(hhea, 1); // caretSlopeRise
  _i16(hhea, 0); // caretSlopeRun
  _i16(hhea, 0); // caretOffset
  for (var i = 0; i < 4; i++) {
    _i16(hhea, 0); // reservados
  }
  _i16(hhea, 0); // metricDataFormat
  _u16(hhea, glyphCount); // numberOfHMetrics — offset 34

  // --- hmtx ------------------------------------------------------------------
  final hmtx = BytesBuilder();
  for (final glyph in glyphs) {
    _u16(hmtx, glyph.advance);
    _i16(hmtx, glyph.box?.left ?? 0); // leftSideBearing
  }

  // --- cmap, formato 6 (intervalo contíguo) ----------------------------------
  final subtable = BytesBuilder();
  _u16(subtable, 6); // format
  _u16(subtable, 10 + (glyphCount - 1) * 2); // length
  _u16(subtable, 0); // language
  _u16(subtable, firstChar);
  _u16(subtable, glyphCount - 1); // entryCount, sem o .notdef
  for (var i = 1; i < glyphCount; i++) {
    _u16(subtable, i);
  }
  final subtableBytes = subtable.toBytes();

  final cmap = BytesBuilder();
  _u16(cmap, 0); // version
  _u16(cmap, 1); // numTables
  _u16(cmap, 3); // platformID: Windows
  _u16(cmap, 1); // encodingID: Unicode BMP
  _u32(cmap, 12); // offset da subtabela
  cmap.add(subtableBytes);

  // --- diretório de tabelas --------------------------------------------------
  final tables = <String, Uint8List>{
    'cmap': _pad4(cmap.toBytes()),
    'glyf': _pad4(glyf.toBytes()),
    'head': _pad4(head.toBytes()),
    'hhea': _pad4(hhea.toBytes()),
    'hmtx': _pad4(hmtx.toBytes()),
    'loca': _pad4(loca.toBytes()),
    'maxp': _pad4(maxp.toBytes()),
  };

  final numTables = tables.length;
  var offset = 12 + numTables * 16;
  final directory = BytesBuilder();
  final body = BytesBuilder();
  for (final entry in tables.entries) {
    directory.add(Uint8List.fromList(entry.key.codeUnits));
    _u32(directory, 0); // checksum: o leitor não o valida
    _u32(directory, offset);
    _u32(directory, entry.value.length);
    body.add(entry.value);
    offset += entry.value.length;
  }

  final file = BytesBuilder();
  _u32(file, 0x00010000); // sfntVersion
  _u16(file, numTables);
  _u16(file, 0); // searchRange
  _u16(file, 0); // entrySelector
  _u16(file, 0); // rangeShift
  file.add(directory.toBytes());
  file.add(body.toBytes());
  return file.toBytes();
}

Uint8List _buildCollection(List<Uint8List> fonts) {
  final headerLength = 12 + fonts.length * 4;
  final offsets = <int>[];
  var offset = headerLength;
  final relocated = <Uint8List>[];
  for (final font in fonts) {
    offsets.add(offset);
    final copy = Uint8List.fromList(font);
    final view = ByteData.sublistView(copy);
    final tables = view.getUint16(4, Endian.big);
    for (var i = 0; i < tables; i++) {
      final record = 12 + i * 16;
      view.setUint32(record + 8,
          view.getUint32(record + 8, Endian.big) + offset, Endian.big);
    }
    relocated.add(copy);
    offset += copy.length;
  }
  final out = BytesBuilder();
  out.add('ttcf'.codeUnits);
  _u32(out, 0x00010000);
  _u32(out, fonts.length);
  for (final faceOffset in offsets) {
    _u32(out, faceOffset);
  }
  for (final font in relocated) {
    out.add(font);
  }
  return out.toBytes();
}

/// Retângulo envolvente da tinta, ou null se nada foi desenhado.
({int left, int top, int right, int bottom})? _inkBounds(BLImage image) {
  int? left, top, right, bottom;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if ((image.pixels[y * image.width + x] & 0xFF) >= 128) continue;
      if (left == null || x < left) left = x;
      if (right == null || x > right) right = x;
      if (top == null || y < top) top = y;
      if (bottom == null || y > bottom) bottom = y;
    }
  }
  return left == null
      ? null
      : (left: left, top: top!, right: right!, bottom: bottom!);
}

int _inkCount(BLImage image) {
  var count = 0;
  for (final pixel in image.pixels) {
    if ((pixel & 0xFF) < 128) count++;
  }
  return count;
}

void main() {
  // 'A' é um retângulo de (200,100) a (600,700) em unidades de em, com avanço
  // 800. A caixa é deliberadamente assimétrica em torno da origem para que uma
  // inversão ou transposição de eixo apareça.
  const boxA = _Rect(200, 100, 600, 700);
  final font2 = _buildFont(const [
    _Glyph(null, 500), // .notdef
    _Glyph(boxA, 800), // 'A'
  ]);

  group('BLFontFace lê um sfnt mínimo', () {
    test('lê todas as faces de uma coleção TrueType', () {
      final second = _buildFont(const [
        _Glyph(null, 500),
        _Glyph(_Rect(100, 100, 700, 800), 900),
      ], firstChar: 0x42);
      final collection = _buildCollection([font2, second]);

      final faces = BLFontFace.parseCollection(collection);
      expect(faces, hasLength(2));
      expect(faces[0].mapCodePoint(0x41), 1);
      expect(faces[1].mapCodePoint(0x42), 1);
      expect(const BLFontLoader().loadFaces(collection), hasLength(2));
      expect(
          () => BLFontFace.parse(collection, faceIndex: 2), throwsRangeError);
    });

    test('extrai as métricas do cabeçalho', () {
      final face = BLFontFace.parse(font2);

      expect(face.unitsPerEm, equals(_unitsPerEm));
      expect(face.glyphCount, equals(2));
      expect(face.hasTrueTypeOutlines, isTrue);
    });

    test('mapeia o ponto de código pelo cmap', () {
      final face = BLFontFace.parse(font2);

      expect(face.mapCodePoint(0x41), equals(1), reason: "'A' é o glifo 1");
      expect(face.mapCodePoint(0x5A), equals(0),
          reason: 'um código fora da tabela cai no .notdef');
    });

    test('lê o avanço declarado em hmtx', () {
      final face = BLFontFace.parse(font2);

      expect(face.glyphAdvanceUnits(1), equals(800));
      // A 100pt num em de 1000, o avanço de 800 unidades vale 80 pontos.
      expect(face.glyphAdvance(100, 1), closeTo(80, 0.001));
    });

    test('devolve o contorno do glifo em unidades de fonte', () {
      final face = BLFontFace.parse(font2);
      final outline = face.glyphOutlineUnits(1);

      expect(outline, isNotNull);
      final xs = <double>[];
      final ys = <double>[];
      for (var i = 0; i < outline!.vertices.length; i += 2) {
        xs.add(outline.vertices[i]);
        ys.add(outline.vertices[i + 1]);
      }
      expect(xs.reduce((a, b) => a < b ? a : b), closeTo(boxA.left, 0.5));
      expect(xs.reduce((a, b) => a > b ? a : b), closeTo(boxA.right, 0.5));
      // O eixo vertical sai invertido: o espaço de glifo é y-para-cima e o
      // rasterizador é y-para-baixo. Uma caixa de 100 a 700 no arquivo sai de
      // -700 a -100. Este teste fixa esse contrato, que consumidores como o
      // renderizador de PDF precisam conhecer.
      expect(ys.reduce((a, b) => a < b ? a : b), closeTo(-boxA.top, 0.5));
      expect(ys.reduce((a, b) => a > b ? a : b), closeTo(-boxA.bottom, 0.5));
    });
  });

  group('BLContext.fillText desenha na geometria certa', () {
    test('põe a tinta exatamente onde a caixa do glifo manda', () async {
      final face = BLFontFace.parse(font2);
      final font = BLFont(face, 100);

      final image = BLImage(200, 200);
      final ctx = BLContext(image)..clear(0xFFFFFFFF);
      ctx.setFillStyle(0xFF000000);
      // Origem em (20, 150): x cresce para a direita, y para baixo, e a caixa
      // do glifo é medida para cima a partir da linha de base.
      await ctx.fillText('A', font, x: 20, y: 150);
      ctx.flush();

      final ink = _inkBounds(image);
      expect(ink, isNotNull, reason: 'o glifo tem de deixar tinta');

      // A 100pt num em de 1000, uma unidade de fonte vale 0,1 pixel.
      // x: 20 + 200*0,1 = 40 até 20 + 600*0,1 = 80
      // y: 150 - 700*0,1 = 80 até 150 - 100*0,1 = 140
      expect(ink!.left, closeTo(40, 1.5));
      expect(ink.right, closeTo(80, 1.5));
      expect(ink.top, closeTo(80, 1.5));
      expect(ink.bottom, closeTo(140, 1.5));
    });

    test('escala com o tamanho da fonte', () async {
      final face = BLFontFace.parse(font2);

      Future<int> inkAt(double size) async {
        final image = BLImage(400, 400);
        final ctx = BLContext(image)..clear(0xFFFFFFFF);
        ctx.setFillStyle(0xFF000000);
        await ctx.fillText('A', BLFont(face, size), x: 10, y: 350);
        ctx.flush();
        return _inkCount(image);
      }

      final small = await inkAt(50);
      final large = await inkAt(100);
      // Área cresce com o quadrado do tamanho; o anti-aliasing na borda
      // impede a razão exata de 4.
      expect(large / small, closeTo(4, 0.4));
    });

    test('avança entre glifos em vez de empilhá-los', () async {
      final face = BLFontFace.parse(font2);
      final font = BLFont(face, 100);

      Future<({int left, int top, int right, int bottom})?> boundsOf(
          String text) async {
        final image = BLImage(500, 200);
        final ctx = BLContext(image)..clear(0xFFFFFFFF);
        ctx.setFillStyle(0xFF000000);
        await ctx.fillText(text, font, x: 20, y: 150);
        ctx.flush();
        return _inkBounds(image);
      }

      final one = (await boundsOf('A'))!;
      final three = (await boundsOf('AAA'))!;

      expect(three.left, equals(one.left),
          reason: 'o primeiro glifo não se move');
      // Cada avanço de 800 unidades vale 80 pixels a 100pt, então o terceiro
      // glifo termina 160 pixels adiante do primeiro.
      expect(three.right - one.right, closeTo(160, 2));
    });

    test('não desenha nada para uma cadeia vazia', () async {
      final face = BLFontFace.parse(font2);
      final image = BLImage(100, 100);
      final ctx = BLContext(image)..clear(0xFFFFFFFF);
      ctx.setFillStyle(0xFF000000);
      await ctx.fillText('', BLFont(face, 40), x: 10, y: 60);
      ctx.flush();

      expect(_inkCount(image), isZero);
    });

    test('o comparador reprova posições diferentes (guarda do teste)',
        () async {
      // Sem isto, um bug que fizesse `_inkBounds` devolver sempre o mesmo
      // deixaria as afirmações acima passando por vacuidade.
      final face = BLFontFace.parse(font2);
      final font = BLFont(face, 100);

      Future<int> leftAt(double x) async {
        final image = BLImage(300, 200);
        final ctx = BLContext(image)..clear(0xFFFFFFFF);
        ctx.setFillStyle(0xFF000000);
        await ctx.fillText('A', font, x: x, y: 150);
        ctx.flush();
        return _inkBounds(image)!.left;
      }

      expect(await leftAt(100), greaterThan(await leftAt(20)));
    });
  });
}
