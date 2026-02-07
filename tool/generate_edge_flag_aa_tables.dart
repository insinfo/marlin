import 'dart:io';

const List<int> _rooks8XFixed = <int>[
  16384,
  57344,
  32768,
  8192,
  49152,
  24576,
  0,
  40960,
];

int _popCount(int v) {
  var x = v;
  var count = 0;
  while (x != 0) {
    count += x & 1;
    x >>= 1;
  }
  return count;
}

String _formatList(List<int> values, {int perLine = 16}) {
  final sb = StringBuffer();
  for (int i = 0; i < values.length; i += perLine) {
    final end = (i + perLine < values.length) ? i + perLine : values.length;
    final chunk = values.sublist(i, end).join(', ');
    sb.writeln('  $chunk,');
  }
  return sb.toString();
}

void main(List<String> args) {
  final outPath = args.isNotEmpty
      ? args.first
      : 'lib/src/rasterization_algorithms/edge_flag_aa/edge_flag_aa_tables.dart';

  final popAlpha = List<int>.generate(256, (i) => (_popCount(i) * 255) ~/ 8,
      growable: false);

  final sb = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT EDIT BY HAND.')
    ..writeln('// Run: dart run tool/generate_edge_flag_aa_tables.dart')
    ..writeln()
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln('final Int32List kRooks8XFixed = Int32List.fromList(<int>[')
    ..write(_formatList(_rooks8XFixed, perLine: 8))
    ..writeln(']);')
    ..writeln()
    ..writeln('final Uint8List kPopCountAlpha8 = Uint8List.fromList(<int>[')
    ..write(_formatList(popAlpha))
    ..writeln(']);');

  final file = File(outPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(sb.toString());

  stdout.writeln('Generated $outPath');
}
