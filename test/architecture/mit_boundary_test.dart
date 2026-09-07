import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// O pacote publicado é MIT; `third_party/` guarda código sob outras licenças.
/// A separação só vale se for verificável, então este teste falha se qualquer
/// coisa em `lib/` passar a referenciar aquele diretório.
///
/// Sem isto, a fronteira seria apenas uma promessa num README, e um único
/// import distraído tornaria falsa a licença declarada do pacote.
void main() {
  group('fronteira de licença entre lib/ e third_party/', () {
    test('nenhum arquivo de lib/ referencia third_party/', () {
      final offenders = <String, String>{};

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line
            in const LineSplitter().convert(entity.readAsStringSync())) {
          final trimmed = line.trimLeft();
          if (!trimmed.startsWith('import ') &&
              !trimmed.startsWith('export ') &&
              !trimmed.startsWith('part ')) {
            continue;
          }
          if (trimmed.contains('third_party') ||
              trimmed.contains('marlin_openjdk')) {
            offenders[entity.path] = trimmed;
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'lib/ é distribuído sob MIT e não pode depender de '
              'third_party/, que está sob GPL. Encontrado: $offenders');
    });

    test('o port do OpenJDK mantém o aviso de copyright da Oracle', () {
      final files = Directory('third_party/marlin_openjdk')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      expect(files, isNotEmpty,
          reason: 'se o diretório sumiu, este teste vira um falso positivo');

      for (final file in files) {
        final source = file.readAsStringSync();
        expect(source, contains('Oracle'),
            reason: '${file.path} perdeu o aviso de copyright, que o próprio '
                'cabeçalho original proíbe remover');
        expect(source, contains('General Public License'),
            reason: '${file.path} perdeu a declaração de licença');
      }
    });

    test('a licença MIT da raiz declara a exclusão de third_party/', () {
      final license = File('LICENSE').readAsStringSync();
      expect(license, contains('MIT License'));
      expect(license, contains('third_party/'),
          reason: 'a MIT da raiz precisa dizer que não cobre third_party/, '
              'senão declara licença errada para aquele código');
    });

    test('o .pubignore exclui third_party/ do pacote publicado', () {
      final ignore = File('.pubignore').readAsStringSync();
      expect(const LineSplitter().convert(ignore).map((l) => l.trim()),
          contains('third_party/'));
    });
  });
}
