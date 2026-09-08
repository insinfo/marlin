import 'dart:typed_data';

import 'package:dgfx/dgfx.dart';
import 'package:test/test.dart';

// Monta fontes CFF mínimas em memória, byte a byte, e verifica que a face
// resultante tem geometria concreta: contagem de glifos, unidades por em,
// resolução de nome para GID e a caixa do contorno de um glifo conhecido.
//
// O alvo é o CFF "puro" (bare CFF, também chamado Type1C), que é o que um
// PDF embute em /FontFile3: sem contêiner sfnt, sem `maxp`, sem `head` e sem
// `cmap`. Nada disso existe no arquivo, então tudo tem de sair do próprio CFF.
//
// Nenhum binário entra no repositório: a fonte é construída aqui, e por isso
// a forma esperada de cada glifo é conhecida ao ponto da unidade de fonte.

// ---------------------------------------------------------------------------
// Escrita de bytes
// ---------------------------------------------------------------------------

void _u8(BytesBuilder out, int value) => out.addByte(value & 0xFF);

void _u16(BytesBuilder out, int value) {
  out
    ..addByte((value >> 8) & 0xFF)
    ..addByte(value & 0xFF);
}

void _u32(BytesBuilder out, int value) {
  out
    ..addByte((value >> 24) & 0xFF)
    ..addByte((value >> 16) & 0xFF)
    ..addByte((value >> 8) & 0xFF)
    ..addByte(value & 0xFF);
}

Uint8List _latin1(String text) =>
    Uint8List.fromList(text.codeUnits.map((c) => c & 0xFF).toList());

/// Monta um INDEX do CFF com `offSize` fixo em 2 bytes.
///
/// O tamanho fixo importa: o Top DICT é escrito duas vezes (uma com offsets
/// zerados, só para medir, outra com os offsets reais) e as duas versões
/// precisam ocupar exatamente o mesmo número de bytes.
Uint8List _cffIndex(List<Uint8List> entries) {
  if (entries.isEmpty) return Uint8List.fromList(<int>[0, 0]);
  final out = BytesBuilder();
  _u16(out, entries.length);
  _u8(out, 2); // offSize
  var offset = 1; // offsets do CFF são 1-based
  _u16(out, offset);
  for (final entry in entries) {
    offset += entry.length;
    _u16(out, offset);
  }
  for (final entry in entries) {
    out.add(entry);
  }
  return out.toBytes();
}

Uint8List _cff2Index(List<Uint8List> entries) {
  final out = BytesBuilder();
  _u32(out, entries.length);
  if (entries.isEmpty) return out.toBytes();
  _u8(out, 2);
  var offset = 1;
  _u16(out, offset);
  for (final entry in entries) {
    offset += entry.length;
    _u16(out, offset);
  }
  for (final entry in entries) {
    out.add(entry);
  }
  return out.toBytes();
}

/// Operando inteiro de DICT no formato de 5 bytes (`29` + int32).
///
/// Sempre o mesmo tamanho, o que mantém o Top DICT estável entre as duas
/// passadas de montagem.
void _dictInt(BytesBuilder out, int value) {
  _u8(out, 29);
  _u32(out, value);
}

/// Operando real de DICT (`30` + nibbles BCD).
void _dictReal(BytesBuilder out, String text) {
  final nibbles = <int>[];
  for (final ch in text.split('')) {
    if (ch == '.') {
      nibbles.add(0x0A);
    } else if (ch == '-') {
      nibbles.add(0x0E);
    } else {
      nibbles.add(int.parse(ch));
    }
  }
  nibbles.add(0x0F); // fim
  if (nibbles.length.isOdd) nibbles.add(0x0F);
  _u8(out, 30);
  for (var i = 0; i < nibbles.length; i += 2) {
    _u8(out, (nibbles[i] << 4) | nibbles[i + 1]);
  }
}

/// Operador de DICT. Valores >= 1200 são os de dois bytes (`12 x`).
void _dictOp(BytesBuilder out, int op) {
  if (op >= 1200) {
    _u8(out, 12);
    _u8(out, op - 1200);
  } else {
    _u8(out, op);
  }
}

/// Operando numérico de charstring Type 2.
void _csNum(BytesBuilder out, int value) {
  if (value >= -107 && value <= 107) {
    _u8(out, value + 139);
  } else if (value >= 108 && value <= 1131) {
    final w = value - 108;
    _u8(out, 247 + (w >> 8));
    _u8(out, w & 0xFF);
  } else if (value <= -108 && value >= -1131) {
    final w = -value - 108;
    _u8(out, 251 + (w >> 8));
    _u8(out, w & 0xFF);
  } else {
    // Inteiro de 16 bits com sinal.
    _u8(out, 28);
    _u16(out, value & 0xFFFF);
  }
}

/// Charstring que desenha um retângulo, sem `endchar`.
Uint8List _rectOps(int x0, int y0, int x1, int y1) {
  final out = BytesBuilder();
  _csNum(out, x0);
  _csNum(out, y0);
  _u8(out, 21); // rmoveto
  _csNum(out, x1 - x0);
  _csNum(out, 0);
  _u8(out, 5); // rlineto
  _csNum(out, 0);
  _csNum(out, y1 - y0);
  _u8(out, 5); // rlineto
  _csNum(out, x0 - x1);
  _csNum(out, 0);
  _u8(out, 5); // rlineto
  return out.toBytes();
}

/// Charstring completa de um retângulo.
Uint8List _rectCharstring(int x0, int y0, int x1, int y1) {
  final out = BytesBuilder()..add(_rectOps(x0, y0, x1, y1));
  _u8(out, 14); // endchar
  return out.toBytes();
}

/// Charstring vazia (`.notdef` em branco).
Uint8List _emptyCharstring() => Uint8List.fromList(<int>[14]);

// ---------------------------------------------------------------------------
// Montagem de um CFF puro
// ---------------------------------------------------------------------------

/// Monta um CFF puro completo.
///
/// [charsetSids] traz o SID de cada GID a partir do GID 1 (o GID 0 é sempre
/// `.notdef`, SID 0). [customStrings] alimenta o String INDEX, cujo primeiro
/// item recebe o SID 391.
Uint8List buildBareCFF({
  String name = 'TestCFF',
  required List<Uint8List> charstrings,
  required List<int> charsetSids,
  List<String> customStrings = const <String>[],
  String? fontMatrixScale,
  List<int> fontBBox = const <int>[0, -200, 1000, 800],
  int charsetFormat = 0,
  int? predefinedEncoding,
  List<Uint8List> localSubrs = const <Uint8List>[],
}) {
  final nameIndex = _cffIndex(<Uint8List>[_latin1(name)]);
  final stringIndex =
      _cffIndex(customStrings.map(_latin1).toList(growable: false));
  final gsubrIndex = _cffIndex(const <Uint8List>[]);
  final charStringsIndex = _cffIndex(charstrings);

  // --- charset ---------------------------------------------------------------
  final charsetBuilder = BytesBuilder();
  if (charsetFormat == 0) {
    _u8(charsetBuilder, 0);
    for (final sid in charsetSids) {
      _u16(charsetBuilder, sid);
    }
  } else {
    // Formato 1: intervalos (primeiro SID, quantos vêm depois dele).
    _u8(charsetBuilder, 1);
    var i = 0;
    while (i < charsetSids.length) {
      var run = 1;
      while (i + run < charsetSids.length &&
          charsetSids[i + run] == charsetSids[i] + run &&
          run < 256) {
        run++;
      }
      _u16(charsetBuilder, charsetSids[i]);
      _u8(charsetBuilder, run - 1);
      i += run;
    }
  }
  final charset = charsetBuilder.toBytes();

  // --- Private DICT ----------------------------------------------------------
  final localSubrIndex =
      localSubrs.isEmpty ? Uint8List(0) : _cffIndex(localSubrs);

  Uint8List buildPrivate(int subrsRelativeOffset) {
    final out = BytesBuilder();
    _dictInt(out, 0);
    _dictOp(out, 20); // defaultWidthX
    _dictInt(out, 0);
    _dictOp(out, 21); // nominalWidthX
    if (localSubrs.isNotEmpty) {
      _dictInt(out, subrsRelativeOffset);
      _dictOp(out, 19); // Subrs, relativo ao início do Private DICT
    }
    return out.toBytes();
  }

  final privateProbe = buildPrivate(0);
  final privateDict = buildPrivate(privateProbe.length);

  // --- Top DICT --------------------------------------------------------------
  Uint8List buildTopDict(int charsetOff, int charStringsOff, int privateOff) {
    final out = BytesBuilder();
    for (final v in fontBBox) {
      _dictInt(out, v);
    }
    _dictOp(out, 5); // FontBBox
    if (fontMatrixScale != null) {
      _dictReal(out, fontMatrixScale);
      _dictReal(out, '0');
      _dictReal(out, '0');
      _dictReal(out, fontMatrixScale);
      _dictReal(out, '0');
      _dictReal(out, '0');
      _dictOp(out, 1207); // FontMatrix
    }
    _dictInt(out, charsetOff);
    _dictOp(out, 15); // charset
    if (predefinedEncoding != null) {
      _dictInt(out, predefinedEncoding);
      _dictOp(out, 16); // Encoding (0 = Standard, 1 = Expert)
    }
    _dictInt(out, charStringsOff);
    _dictOp(out, 17); // CharStrings
    _dictInt(out, privateDict.length);
    _dictInt(out, privateOff);
    _dictOp(out, 18); // Private
    return out.toBytes();
  }

  final topDictProbe = _cffIndex(<Uint8List>[buildTopDict(0, 0, 0)]);

  const headerLength = 4;
  final nameOffset = headerLength;
  final topDictOffset = nameOffset + nameIndex.length;
  final stringOffset = topDictOffset + topDictProbe.length;
  final gsubrOffset = stringOffset + stringIndex.length;
  final charsetOffset = gsubrOffset + gsubrIndex.length;
  final charStringsOffset = charsetOffset + charset.length;
  final privateOffset = charStringsOffset + charStringsIndex.length;

  final topDictIndex = _cffIndex(<Uint8List>[
    buildTopDict(charsetOffset, charStringsOffset, privateOffset),
  ]);
  // A segunda passada tem de ocupar exatamente os mesmos bytes da primeira,
  // senao todos os offsets calculados acima estariam deslocados.
  if (topDictIndex.length != topDictProbe.length) {
    throw StateError('Top DICT mudou de tamanho entre as duas passadas');
  }

  final file = BytesBuilder();
  _u8(file, 1); // major
  _u8(file, 0); // minor
  _u8(file, headerLength); // hdrSize
  _u8(file, 2); // offSize
  file
    ..add(nameIndex)
    ..add(topDictIndex)
    ..add(stringIndex)
    ..add(gsubrIndex)
    ..add(charset)
    ..add(charStringsIndex)
    ..add(privateDict)
    ..add(localSubrIndex);
  return file.toBytes();
}

/// CID-keyed CFF mínimo com dois Font DICTs e um subr local em cada um.
Uint8List _buildCidCff({required bool fdSelectFormat3, int? fdSelectSentinel}) {
  final nameIndex = _cffIndex(<Uint8List>[_latin1('TestCID')]);
  final stringIndex = _cffIndex(const <Uint8List>[]);
  final globalSubrs = _cffIndex(const <Uint8List>[]);
  final charset = Uint8List.fromList(<int>[0, 0, 42, 1, 44]);
  final fdSelect = fdSelectFormat3
      ? Uint8List.fromList(<int>[
          3, 0, 2, // formato, nRanges
          0, 0, 0, // GID 0..1 usa FD 0
          0, 2, 1, // GID 2 usa FD 1
          0, fdSelectSentinel ?? 3, // sentinel
        ])
      : Uint8List.fromList(<int>[0, 0, 0, 1]);

  final callSubr = BytesBuilder();
  _csNum(callSubr, -107);
  callSubr
    ..addByte(10)
    ..addByte(14);
  final charStrings = _cffIndex(<Uint8List>[
    _emptyCharstring(),
    callSubr.toBytes(),
    callSubr.toBytes(),
  ]);
  Uint8List privateDict(int relativeSubrs) {
    final out = BytesBuilder();
    _dictInt(out, relativeSubrs);
    _dictOp(out, 19);
    return out.toBytes();
  }

  final privateProbe = privateDict(0);
  final private0 = privateDict(privateProbe.length);
  final private1 = privateDict(privateProbe.length);
  final subr0 = _cffIndex(<Uint8List>[
    (BytesBuilder()
          ..add(_rectOps(10, 20, 110, 220))
          ..addByte(11))
        .toBytes()
  ]);
  final subr1 = _cffIndex(<Uint8List>[
    (BytesBuilder()
          ..add(_rectOps(300, 40, 600, 440))
          ..addByte(11))
        .toBytes()
  ]);

  Uint8List fontDict(int privateOffset, int privateLength) {
    final out = BytesBuilder();
    _dictInt(out, privateLength);
    _dictInt(out, privateOffset);
    _dictOp(out, 18);
    return out.toBytes();
  }

  Uint8List topDict(int charsetOffset, int charStringsOffset, int fdArrayOffset,
      int fdSelectOffset) {
    final out = BytesBuilder();
    _dictInt(out, 0); // Registry SID
    _dictInt(out, 0); // Ordering SID
    _dictInt(out, 0); // Supplement
    _dictOp(out, 1230); // ROS: torna a fonte CID-keyed
    _dictInt(out, charsetOffset);
    _dictOp(out, 15);
    _dictInt(out, charStringsOffset);
    _dictOp(out, 17);
    _dictInt(out, fdArrayOffset);
    _dictOp(out, 1236);
    _dictInt(out, fdSelectOffset);
    _dictOp(out, 1237);
    return out.toBytes();
  }

  final topProbe = _cffIndex(<Uint8List>[topDict(0, 0, 0, 0)]);
  final fdArrayProbe = _cffIndex(<Uint8List>[
    fontDict(0, private0.length),
    fontDict(0, private1.length),
  ]);
  const headerLength = 4;
  final topOffset = headerLength + nameIndex.length;
  final stringOffset = topOffset + topProbe.length;
  final globalOffset = stringOffset + stringIndex.length;
  final charsetOffset = globalOffset + globalSubrs.length;
  final fdSelectOffset = charsetOffset + charset.length;
  final charStringsOffset = fdSelectOffset + fdSelect.length;
  final fdArrayOffset = charStringsOffset + charStrings.length;
  final private0Offset = fdArrayOffset + fdArrayProbe.length;
  final subr0Offset = private0Offset + private0.length;
  final private1Offset = subr0Offset + subr0.length;

  final fdArray = _cffIndex(<Uint8List>[
    fontDict(private0Offset, private0.length),
    fontDict(private1Offset, private1.length),
  ]);
  final top = _cffIndex(<Uint8List>[
    topDict(charsetOffset, charStringsOffset, fdArrayOffset, fdSelectOffset),
  ]);
  if (top.length != topProbe.length || fdArray.length != fdArrayProbe.length) {
    throw StateError('DICT CID mudou de tamanho entre as passadas');
  }

  return (BytesBuilder()
        ..add(<int>[1, 0, headerLength, 2])
        ..add(nameIndex)
        ..add(top)
        ..add(stringIndex)
        ..add(globalSubrs)
        ..add(charset)
        ..add(fdSelect)
        ..add(charStrings)
        ..add(fdArray)
        ..add(private0)
        ..add(subr0)
        ..add(private1)
        ..add(subr1))
      .toBytes();
}

/// Embrulha um CFF num sfnt OpenType mínimo (`OTTO` + `CFF ` + `head` + `maxp`).
Uint8List wrapInOpenType(Uint8List cff, int glyphCount, int unitsPerEm,
    {String cffTag = 'CFF '}) {
  final head = BytesBuilder();
  _u32(head, 0x00010000);
  _u32(head, 0x00010000);
  _u32(head, 0);
  _u32(head, 0x5F0F3CF5);
  _u16(head, 0); // flags
  _u16(head, unitsPerEm); // offset 18
  for (var i = 0; i < 4; i++) {
    _u32(head, 0); // created/modified
  }
  _u16(head, 0); // xMin
  _u16(head, 0); // yMin
  _u16(head, 0); // xMax
  _u16(head, 0); // yMax
  _u16(head, 0); // macStyle
  _u16(head, 8); // lowestRecPPEM
  _u16(head, 2); // fontDirectionHint
  _u16(head, 0); // indexToLocFormat — offset 50
  _u16(head, 0); // glyphDataFormat

  final maxp = BytesBuilder();
  _u32(maxp, 0x00005000); // version 0.5, usada por OpenType/CFF
  _u16(maxp, glyphCount); // offset 4

  final tables = <String, Uint8List>{
    cffTag: cff,
    'head': head.toBytes(),
    'maxp': maxp.toBytes(),
  };

  var offset = 12 + tables.length * 16;
  final directory = BytesBuilder();
  final body = BytesBuilder();
  for (final entry in tables.entries) {
    directory.add(_latin1(entry.key));
    _u32(directory, 0); // checksum: o leitor não valida
    _u32(directory, offset);
    _u32(directory, entry.value.length);
    body.add(entry.value);
    offset += entry.value.length;
    while (offset % 4 != 0) {
      body.addByte(0);
      offset++;
    }
  }

  final file = BytesBuilder();
  _u32(file, 0x4F54544F); // 'OTTO'
  _u16(file, tables.length);
  _u16(file, 0);
  _u16(file, 0);
  _u16(file, 0);
  file
    ..add(directory.toBytes())
    ..add(body.toBytes());
  return file.toBytes();
}

Uint8List _buildCff2(List<Uint8List> charstrings,
    {bool withVariationStore = false}) {
  final globalSubrs = _cff2Index(const <Uint8List>[]);
  final charStrings = _cff2Index(charstrings);
  final variationStore = BytesBuilder();
  if (withVariationStore) {
    _u16(variationStore, 1); // ItemVariationStore format
    _u32(variationStore, 20); // VariationRegionList offset
    _u16(variationStore, 1); // uma ItemVariationData
    _u32(variationStore, 12); // offset da ItemVariationData
    _u16(variationStore, 0); // itemCount (irrelevante para blend)
    _u16(variationStore, 0); // shortDeltaCount
    _u16(variationStore, 1); // regionIndexCount
    _u16(variationStore, 0); // region index
    _u16(variationStore, 1); // axisCount
    _u16(variationStore, 1); // regionCount
    _u16(variationStore, 0); // startCoord
    _u16(variationStore, 0x4000); // peakCoord = 1
    _u16(variationStore, 0x4000); // endCoord = 1
  }
  final variationBytes = variationStore.toBytes();
  Uint8List topDict(int charStringsOffset, int variationOffset) {
    final out = BytesBuilder();
    if (withVariationStore) {
      _dictInt(out, variationOffset);
      _dictOp(out, 24);
    }
    _dictInt(out, charStringsOffset);
    _dictOp(out, 17);
    return out.toBytes();
  }

  final probe = topDict(0, 0);
  const headerSize = 5;
  final variationOffset = headerSize + probe.length + globalSubrs.length;
  final charStringsOffset = variationOffset + variationBytes.length;
  final top = topDict(charStringsOffset, variationOffset);
  final out = BytesBuilder();
  _u8(out, 2);
  _u8(out, 0);
  _u8(out, headerSize);
  _u16(out, top.length);
  return (out
        ..add(top)
        ..add(globalSubrs)
        ..add(variationBytes)
        ..add(charStrings))
      .toBytes();
}

/// Caixa envolvente de um contorno, em unidades de fonte.
({double left, double top, double right, double bottom}) _boxOf(
    BLPathData path) {
  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  for (var i = 0; i < path.vertices.length; i += 2) {
    final x = path.vertices[i];
    final y = path.vertices[i + 1];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return (left: minX, top: minY, right: maxX, bottom: maxY);
}

void main() {
  // SIDs padrão: 34 = 'A', 35 = 'B'. O primeiro item do String INDEX vira o
  // SID 391, logo acima do fim da tabela padrão.
  const sidA = 34;
  const sidB = 35;
  const sidCustom = 391;

  // 'A' é um retângulo de (100,50) a (500,700); 'B', de (0,0) a (200,200).
  // A caixa de 'A' é deliberadamente assimetrica em torno da origem para que
  // uma inversao ou transposicao de eixo apareca.
  final simple = buildBareCFF(
    charstrings: <Uint8List>[
      _emptyCharstring(),
      _rectCharstring(100, 50, 500, 700),
      _rectCharstring(0, 0, 200, 200),
      _rectCharstring(10, 10, 20, 20),
    ],
    charsetSids: const <int>[sidA, sidB, sidCustom],
    customStrings: const <String>['myglyph'],
    fontBBox: const <int>[0, 0, 500, 700],
  );

  group('BLFontFace le um CFF puro', () {
    test('detecta o CFF e nao confunde com um sfnt', () {
      expect(BLCFFDecoder.looksLikeBareCFF(simple), isTrue);

      // Prefixar 'OTTO' quebra o header CFF; a detecção tem de recusar.
      final asOpenType = Uint8List.fromList(<int>[
        0x4F, 0x54, 0x54, 0x4F, //
        ...simple,
      ]);
      expect(BLCFFDecoder.looksLikeBareCFF(asOpenType), isFalse);

      // sfntVersion 1.0 de um TrueType.
      expect(
        BLCFFDecoder.looksLikeBareCFF(
          Uint8List.fromList(<int>[0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0]),
        ),
        isFalse,
      );

      // Header plausível mas sem estrutura por tras: não é um CFF utilizável.
      expect(
        BLCFFDecoder.looksLikeBareCFF(
          Uint8List.fromList(<int>[1, 0, 4, 2, 0, 0, 0, 0]),
        ),
        isFalse,
      );
    });

    test('tira a contagem de glifos do CharStrings INDEX', () {
      final face = BLFontFace.parse(simple);

      // Sem `maxp` nenhum: os 4 glifos são as 4 entradas do CharStrings INDEX.
      expect(face.glyphCount, equals(4));
      expect(face.hasCFFOutlines, isTrue);
      expect(face.hasTrueTypeOutlines, isFalse);
      expect(face.cffOffset, isZero);
      expect(face.cffLength, equals(simple.length));
    });

    test('resolve todos os códigos presentes no Expert Encoding', () {
      final expert = buildBareCFF(
        charstrings: <Uint8List>[
          _emptyCharstring(),
          _rectCharstring(0, 0, 100, 100),
          _rectCharstring(0, 0, 200, 200),
          _rectCharstring(0, 0, 300, 300),
        ],
        // exclamsmall, onequarter e Ydieresissmall.
        charsetSids: const <int>[229, 158, 378],
        predefinedEncoding: 1,
      );
      final encoding = BLFontFace.parse(expert).cffInfo!.codeToGlyphId;

      expect(encoding[33], equals(1));
      expect(encoding[188], equals(2));
      expect(encoding[255], equals(3));
      expect(encoding, isNot(contains(35))); // .notdef na tabela normativa.
    });

    test('usa o FontMatrix padrao como um em de 1000', () {
      final face = BLFontFace.parse(simple);

      expect(face.unitsPerEm, equals(1000));
      expect(face.cffInfo!.fontMatrix.first, closeTo(0.001, 1e-9));
    });

    test('deriva o unitsPerEm de um FontMatrix diferente do padrao', () {
      // 1/2048 = 0.00048828125.
      final scaled = buildBareCFF(
        charstrings: <Uint8List>[
          _emptyCharstring(),
          _rectCharstring(100, 50, 500, 700),
        ],
        charsetSids: const <int>[sidA],
        fontMatrixScale: '0.00048828125',
      );
      final face = BLFontFace.parse(scaled);

      expect(face.unitsPerEm, equals(2048));
      expect(face.glyphCount, equals(2));
    });

    test('le o nome PostScript do Name INDEX', () {
      final named = buildBareCFF(
        name: 'ABCDEF+Helvetica-Bold',
        charstrings: <Uint8List>[_emptyCharstring(), _emptyCharstring()],
        charsetSids: const <int>[sidA],
      );
      final face = BLFontFace.parse(named);

      expect(face.postScriptName, equals('ABCDEF+Helvetica-Bold'));
      // O prefixo de subconjunto "ABCDEF+" e o sufixo de estilo saem da
      // família; são o que um PDF poe no /BaseFont de uma fonte subsetada.
      expect(face.familyName, equals('Helvetica'));
      expect(face.subfamilyName, equals('Bold'));
      expect(face.weightClass, equals(700));
    });

    test('usa a FontBBox como metrica vertical, ja que nao ha hhea', () {
      final face = BLFontFace.parse(simple);

      expect(face.ascender, equals(700));
      expect(face.descender, equals(0));
    });
  });

  group('BLFontFace.glyphIdForName', () {
    test('resolve nomes dos SIDs padrao do CFF', () {
      final face = BLFontFace.parse(simple);

      expect(face.glyphIdForName('A'), equals(1));
      expect(face.glyphIdForName('B'), equals(2));
      expect(face.glyphIdForName('.notdef'), equals(0));
    });

    test('resolve um nome vindo do String INDEX (SID >= 391)', () {
      final face = BLFontFace.parse(simple);

      expect(face.glyphIdForName('myglyph'), equals(3));
      expect(face.glyphNameForId(3), equals('myglyph'));
    });

    test('devolve null para nome ausente', () {
      final face = BLFontFace.parse(simple);

      expect(face.glyphIdForName('Z'), isNull);
      expect(face.glyphIdForName(''), isNull);
    });

    test('funciona com charset no formato de intervalos', () {
      // SIDs 34, 35, 36 = 'A', 'B', 'C' — um intervalo contiguo, que é o
      // formato 1 do charset.
      final ranged = buildBareCFF(
        charstrings: <Uint8List>[
          _emptyCharstring(),
          _rectCharstring(0, 0, 100, 100),
          _rectCharstring(0, 0, 100, 100),
          _rectCharstring(0, 0, 100, 100),
        ],
        charsetSids: const <int>[34, 35, 36],
        charsetFormat: 1,
      );
      final face = BLFontFace.parse(ranged);

      expect(face.glyphIdForName('A'), equals(1));
      expect(face.glyphIdForName('B'), equals(2));
      expect(face.glyphIdForName('C'), equals(3));
    });
  });

  group('BLFontFace.mapCodePoint num CFF puro', () {
    test('mapeia pelo Standard Encoding, na falta de cmap', () {
      final face = BLFontFace.parse(simple);

      // 0x41 = 'A' -> SID 34 -> nome 'A' -> GID 1.
      expect(face.mapCodePoint(0x41), equals(1));
      expect(face.mapCodePoint(0x42), equals(2));
      // 'Z' não esta na fonte: cai no .notdef.
      expect(face.mapCodePoint(0x5A), isZero);
    });
  });

  group('contornos de um CFF puro', () {
    test('devolve o retangulo esperado, com o eixo Y invertido', () {
      final face = BLFontFace.parse(simple);
      final outline = face.glyphOutlineUnits(face.glyphIdForName('A')!);

      expect(outline, isNotNull);
      final box = _boxOf(outline!);
      expect(box.left, closeTo(100, 0.001));
      expect(box.right, closeTo(500, 0.001));
      // O espaco de glifo é y-para-cima e a saida é y-para-baixo: uma caixa
      // de 50 a 700 no arquivo sai de -700 a -50. Mesmo contrato já fixado
      // para os contornos TrueType.
      expect(box.top, closeTo(-700, 0.001));
      expect(box.bottom, closeTo(-50, 0.001));
    });

    test('glifos diferentes tem contornos diferentes', () {
      final face = BLFontFace.parse(simple);
      final b = _boxOf(face.glyphOutlineUnits(face.glyphIdForName('B')!)!);

      expect(b.left, closeTo(0, 0.001));
      expect(b.right, closeTo(200, 0.001));
      expect(b.top, closeTo(-200, 0.001));
      expect(b.bottom, closeTo(0, 0.001));
    });

    test('o .notdef em branco sai sem vertices', () {
      final face = BLFontFace.parse(simple);
      final outline = face.glyphOutlineUnits(0);

      expect(outline, isNotNull);
      expect(outline!.vertices, isEmpty);
    });

    test('coordenadas fora de -1131..1131 usam o operando de 16 bits', () {
      // 2000 não cabe na forma curta de operando; a charstring cai no prefixo
      // 28 (int16), que o interpretador precisa reconhecer.
      final wide = buildBareCFF(
        charstrings: <Uint8List>[
          _emptyCharstring(),
          _rectCharstring(1500, 0, 3500, 2000),
        ],
        charsetSids: const <int>[sidA],
      );
      final face = BLFontFace.parse(wide);
      final box = _boxOf(face.glyphOutlineUnits(1)!);

      expect(box.left, closeTo(1500, 0.001));
      expect(box.right, closeTo(3500, 0.001));
      expect(box.top, closeTo(-2000, 0.001));
      expect(box.bottom, closeTo(0, 0.001));
    });

    test('interpreta uma chamada a subrotina local', () {
      // O contorno vive numa subrotina local; a charstring só a chama. Isso
      // exercita o Private DICT e o offset de Subrs, que é relativo ao início
      // do Private DICT e não ao início do CFF.
      final subr = BytesBuilder()
        ..add(_rectOps(100, 50, 500, 700))
        ..addByte(11); // return

      final main = BytesBuilder();
      _csNum(main, -107); // índice 0 após o bias de 107
      main.addByte(10); // callsubr
      main.addByte(14); // endchar

      final withSubr = buildBareCFF(
        charstrings: <Uint8List>[_emptyCharstring(), main.toBytes()],
        charsetSids: const <int>[sidA],
        localSubrs: <Uint8List>[subr.toBytes()],
      );
      final face = BLFontFace.parse(withSubr);
      final box = _boxOf(face.glyphOutlineUnits(1)!);

      expect(box.left, closeTo(100, 0.001));
      expect(box.right, closeTo(500, 0.001));
      expect(box.top, closeTo(-700, 0.001));
      expect(box.bottom, closeTo(-50, 0.001));
    });

    test('o comparador reprova geometrias diferentes (guarda do teste)', () {
      // Sem isto, um bug que fizesse `_boxOf` devolver sempre a mesma caixa
      // deixaria as afirmações acima passando por vacuidade.
      final face = BLFontFace.parse(simple);
      final a = _boxOf(face.glyphOutlineUnits(1)!);
      final b = _boxOf(face.glyphOutlineUnits(2)!);

      expect(a.right, isNot(closeTo(b.right, 0.001)));
    });
  });

  group('OpenType/CFF (sfnt com tabela CFF )', () {
    final otf = wrapInOpenType(simple, 4, 1000);

    test('continua lendo a contagem de glifos do maxp', () {
      final face = BLFontFace.parse(otf);

      expect(face.hasCFFOutlines, isTrue);
      expect(face.hasTrueTypeOutlines, isFalse);
      expect(face.glyphCount, equals(4));
      expect(face.unitsPerEm, equals(1000));
      // A tabela `CFF ` não começa no offset zero do arquivo.
      expect(face.cffOffset, greaterThan(0));
    });

    test('resolve nome para GID tambem aqui', () {
      final face = BLFontFace.parse(otf);

      expect(face.glyphIdForName('A'), equals(1));
      expect(face.glyphIdForName('myglyph'), equals(3));
    });

    test('decodifica o contorno a partir de uma tabela deslocada', () {
      // Este é o caso que o cálculo de tamanho do INDEX errava: com o CFF
      // fora do offset zero, o String INDEX e o Global Subr INDEX caíam no
      // lugar errado e nenhum contorno saia.
      final face = BLFontFace.parse(otf);
      final box = _boxOf(face.glyphOutlineUnits(1)!);

      expect(box.left, closeTo(100, 0.001));
      expect(box.right, closeTo(500, 0.001));
      expect(box.top, closeTo(-700, 0.001));
      expect(box.bottom, closeTo(-50, 0.001));
    });
  });

  group('OpenType/CFF2', () {
    final cff2 = _buildCff2(<Uint8List>[_rectOps(20, 30, 220, 330)]);
    final otf = wrapInOpenType(cff2, 1, 1000, cffTag: 'CFF2');

    test('reconhece a tabela e o INDEX com contagem de 32 bits', () {
      final face = BLFontFace.parse(otf);

      expect(face.hasCFFOutlines, isTrue);
      expect(face.hasTrueTypeOutlines, isFalse);
      expect(face.glyphCount, 1);
      expect(face.cffInfo?.glyphCount, 1);
    });

    test('decodifica charstring sem endchar', () {
      final face = BLFontFace.parse(otf);
      final box = _boxOf(face.glyphOutlineUnits(0)!);

      expect(box.left, closeTo(20, .001));
      expect(box.right, closeTo(220, .001));
      expect(box.top, closeTo(-330, .001));
      expect(box.bottom, closeTo(-30, .001));
    });

    test('blend conserva valores-base da instância variável padrão', () {
      final program = BytesBuilder();
      _csNum(program, 0);
      _u8(program, 15); // vsindex
      // Dois valores-base, um delta para cada valor, quantidade e blend.
      for (final value in <int>[20, 30, 500, 600, 2]) {
        _csNum(program, value);
      }
      _u8(program, 16); // blend
      _u8(program, 21); // rmoveto usa os dois valores-base
      for (final value in <int>[200, 0, 0, 300, -200, 0]) {
        _csNum(program, value);
      }
      _u8(program, 5); // rlineto
      final variable =
          _buildCff2(<Uint8List>[program.toBytes()], withVariationStore: true);
      final face =
          BLFontFace.parse(wrapInOpenType(variable, 1, 1000, cffTag: 'CFF2'));
      final box = _boxOf(face.glyphOutlineUnits(0)!);

      expect(box.left, closeTo(20, .001));
      expect(box.right, closeTo(220, .001));
      expect(box.top, closeTo(-330, .001));
      expect(box.bottom, closeTo(-30, .001));
    });

    test('blend aplica deltas em coordenadas normalizadas não padrão', () {
      final program = BytesBuilder();
      _csNum(program, 0);
      _u8(program, 15); // vsindex
      for (final value in <int>[20, 30, 500, 600, 2]) {
        _csNum(program, value);
      }
      _u8(program, 16); // blend
      _u8(program, 21); // rmoveto
      for (final value in <int>[200, 0, 0, 300, -200, 0]) {
        _csNum(program, value);
      }
      _u8(program, 5);
      final variable =
          _buildCff2(<Uint8List>[program.toBytes()], withVariationStore: true);
      final face =
          BLFontFace.parse(wrapInOpenType(variable, 1, 1000, cffTag: 'CFF2'));

      final half = _boxOf(BLFont(face, 1000)
          .withVariationCoordinates(const <double>[.5]).glyphOutline(0)!);
      expect(half.left, closeTo(270, .001));
      expect(half.right, closeTo(470, .001));
      expect(half.top, closeTo(-630, .001));
      expect(half.bottom, closeTo(-330, .001));

      final peak = _boxOf(
          face.glyphOutlineUnits(0, variationCoordinates: const <double>[1])!);
      expect(peak.left, closeTo(520, .001));
      expect(peak.right, closeTo(720, .001));
      expect(peak.top, closeTo(-930, .001));
      expect(peak.bottom, closeTo(-630, .001));
    });
  });

  group('CID-keyed CFF escolhe o Font DICT por glifo', () {
    for (final format3 in <bool>[false, true]) {
      test(
          'FDSelect formato ${format3 ? 3 : 0} usa subrotinas locais distintas',
          () {
        final face = BLFontFace.parse(_buildCidCff(fdSelectFormat3: format3));
        expect(face.cffInfo!.isCID, isTrue);
        expect(face.cffInfo!.cidToGlyphId, <int, int>{0: 0, 42: 1, 300: 2});

        final first = _boxOf(face.glyphOutlineUnits(1)!);
        final second = _boxOf(face.glyphOutlineUnits(2)!);
        expect(first.left, closeTo(10, 0.001));
        expect(first.right, closeTo(110, 0.001));
        expect(first.top, closeTo(-220, 0.001));
        expect(second.left, closeTo(300, 0.001));
        expect(second.right, closeTo(600, 0.001));
        expect(second.top, closeTo(-440, 0.001));
      });
    }

    test('FDSelect formato 3 rejeita sentinel diferente de glyphCount', () {
      final face = BLFontFace.parse(
          _buildCidCff(fdSelectFormat3: true, fdSelectSentinel: 2));
      expect(face.glyphOutlineUnits(2), isNull);
    });
  });
}
