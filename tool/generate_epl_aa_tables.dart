import 'dart:io';
import 'dart:math' as math;

const int thetaBins = 256;
const int distBins = 256;
const double distMin = -1.25;
const double distMax = 1.25;
const double distSpan = distMax - distMin;

double _computeCoverage(double nx, double ny, double s) {
  final polygon = <List<double>>[
    <double>[-0.5, -0.5],
    <double>[0.5, -0.5],
    <double>[0.5, 0.5],
    <double>[-0.5, 0.5],
  ];

  final clipped = _clipPolygon(polygon, nx, ny, s);
  return _polygonArea(clipped);
}

List<List<double>> _clipPolygon(
    List<List<double>> poly, double nx, double ny, double s) {
  if (poly.isEmpty) {
    return <List<double>>[];
  }

  final result = <List<double>>[];
  for (int i = 0; i < poly.length; i++) {
    final current = poly[i];
    final next = poly[(i + 1) % poly.length];

    final currentDist = nx * current[0] + ny * current[1] + s;
    final nextDist = nx * next[0] + ny * next[1] + s;

    if (currentDist <= 0.0) {
      result.add(current);
      if (nextDist > 0.0) {
        final t = currentDist / (currentDist - nextDist);
        result.add(<double>[
          current[0] + t * (next[0] - current[0]),
          current[1] + t * (next[1] - current[1]),
        ]);
      }
    } else if (nextDist <= 0.0) {
      final t = currentDist / (currentDist - nextDist);
      result.add(<double>[
        current[0] + t * (next[0] - current[0]),
        current[1] + t * (next[1] - current[1]),
      ]);
    }
  }

  return result;
}

double _polygonArea(List<List<double>> poly) {
  if (poly.length < 3) {
    return 0.0;
  }

  double area = 0.0;
  for (int i = 0; i < poly.length; i++) {
    final j = (i + 1) % poly.length;
    area += poly[i][0] * poly[j][1];
    area -= poly[j][0] * poly[i][1];
  }
  return area.abs() * 0.5;
}

void main(List<String> args) {
  final outPath = args.isNotEmpty
      ? args.first
      : 'lib/src/rasterization_algorithms/epl_aa/epl_aa_tables.dart';

  final values = List<int>.filled(thetaBins * distBins, 0);

  for (int t = 0; t < thetaBins; t++) {
    final theta = (t / thetaBins) * (math.pi / 2.0);
    final nx = math.cos(theta);
    final ny = math.sin(theta);

    for (int d = 0; d < distBins; d++) {
      final s = ((d / distBins) * distSpan) + distMin;
      final coverage = _computeCoverage(nx, ny, s);
      values[t * distBins + d] = (coverage * 255.0).round().clamp(0, 255);
    }
  }

  final sb = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT EDIT BY HAND.')
    ..writeln('// Run: dart run tool/generate_epl_aa_tables.dart')
    ..writeln()
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln('const int kEplThetaBins = $thetaBins;')
    ..writeln('const int kEplDistBins = $distBins;')
    ..writeln('const double kEplDistMin = $distMin;')
    ..writeln('const double kEplDistMax = $distMax;')
    ..writeln()
    ..writeln('final Uint8List kEplCoverageTable = Uint8List.fromList(<int>[');

  const perLine = 32;
  for (int i = 0; i < values.length; i += perLine) {
    final end = (i + perLine < values.length) ? i + perLine : values.length;
    sb.writeln('  ${values.sublist(i, end).join(', ')},');
  }

  sb.writeln(']);');

  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(sb.toString());
  stdout.writeln('Generated $outPath (${values.length} entries)');
}
