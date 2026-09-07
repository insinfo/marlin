import 'dart:io';
import 'dart:typed_data';

import 'package:dgfx/dgfx_io.dart';
import 'package:test/test.dart';

import 'blend2d_cff_font_test.dart' show buildBareCFF;

Uint8List _font(String name) => buildBareCFF(
      name: name,
      charstrings: <Uint8List>[
        Uint8List.fromList(const <int>[14]),
      ],
      charsetSids: const <int>[],
    );

void main() {
  group('BLFontCollection', () {
    test('respeita ordem de famílias, peso e inclinação', () {
      final collection = BLFontCollection()
        ..addBytes(_font('Alpha-Regular'))
        ..addBytes(_font('Alpha-Bold'))
        ..addBytes(_font('Beta-Italic'));

      expect(
        collection
            .resolveLocal(const BLFontQuery(['Alpha'], weight: 700))!
            .weightClass,
        700,
      );
      expect(
        collection
            .resolveLocal(const BLFontQuery(
              ['Missing', 'Beta'],
              slant: BLFontSlant.italic,
            ))!
            .postScriptName,
        'Beta-Italic',
      );
    });

    test('consulta provedor uma vez e guarda a face no catálogo', () async {
      var calls = 0;
      final bytes = _font('Remote-Regular');
      final collection = BLFontCollection()
        ..addProvider(BLCallbackFontProvider((query) async {
          calls++;
          return Uint8List.fromList(bytes);
        }));

      final query = const BLFontQuery(['Remote']);
      expect((await collection.resolve(query))!.familyName, 'Remote');
      expect((await collection.resolve(query))!.familyName, 'Remote');
      expect(calls, 1);
    });
  });

  test('descoberta nativa filtra extensões e ordena sem seguir links',
      () async {
    final root = await Directory.systemTemp.createTemp('dgfx-fonts-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/nested').create();
    await File('${root.path}/z.otf').writeAsBytes(const [0]);
    await File('${root.path}/nested/a.TTF').writeAsBytes(const [0]);
    await File('${root.path}/font.ttc').writeAsBytes(const [0]);
    await File('${root.path}/ignore.woff2').writeAsBytes(const [0]);

    final files = await const BLFontLoader()
        .discoverSystemFontFiles(directories: [root.path]);

    expect(files, orderedEquals(files.toList()..sort()));
    expect(
      files.map((p) => p.split(Platform.pathSeparator).last),
      unorderedEquals(['a.TTF', 'font.ttc', 'z.otf']),
    );
  });
}
