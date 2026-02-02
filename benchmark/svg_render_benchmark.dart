/// =============================================================================
/// SVG RENDERING BENCHMARK
/// =============================================================================
///
/// Renderiza arquivos SVG complexos usando cada implementação de rasterização
/// e gera arquivos PNG para visualização.
///
/// Uso:
///   dart run benchmark/svg_render_benchmark.dart
///
library benchmark;


import 'dart:io';
import 'dart:typed_data';
import 'package:marlin/marlin.dart'; // Importar os rasterizadores via marlin



/// Diretório de saída para os PNGs
const outputDir = 'output/svg_renders';

/// Arquivos SVG para renderizar
const svgFiles = [
  'assets/svg/Ghostscript_Tiger.svg',
  'assets/svg/froggy-simple.svg',
];

/// Tamanho de renderização
const renderWidth = 512;
const renderHeight = 512;

/// Interface para renderizadores
abstract class RasterizerAdapter {
  String get name;
  Uint8List render(List<SvgPolygon> polygons, double svgWidth, double svgHeight);
}

/// Adaptador para DAA
class DAAAdapter implements RasterizerAdapter {
  @override
  String get name => 'DAA';
  
  @override
  Uint8List render(List<SvgPolygon> polygons, double svgWidth, double svgHeight) {
    final rasterizer = DAARasterizer(width: renderWidth, height: renderHeight);
    rasterizer.clear(0xFFFFFFFF); // Fundo branco
    final scaleX = renderWidth / svgWidth;
    final scaleY = renderHeight / svgHeight;
    
    for (final poly in polygons) {
      if (poly.vertices.length >= 6) {
        final scaled = _scaleVertices(poly.vertices, scaleX, scaleY);
        rasterizer.drawPolygon(scaled, poly.fillColor);
      }
    }
    
    return _uint32ToRGBA(rasterizer.framebuffer);
  }
}

/// Adaptador para DDFI
class DDFIAdapter implements RasterizerAdapter {
  @override
  String get name => 'DDFI';
  
  @override
  Uint8List render(List<SvgPolygon> polygons, double svgWidth, double svgHeight) {
    final rasterizer = FluxRenderer(renderWidth, renderHeight);
    rasterizer.clear(0xFFFFFFFF); // Fundo branco
    final scaleX = renderWidth / svgWidth;
    final scaleY = renderHeight / svgHeight;
    
    for (final poly in polygons) {
      if (poly.vertices.length >= 6) {
        final scaled = _scaleVertices(poly.vertices, scaleX, scaleY);
        rasterizer.drawPolygon(scaled, poly.fillColor);
      }
    }
    
    return _uint32ToRGBA(rasterizer.buffer);
  }
}

/// Adaptador para Marlin
class MarlinAdapter implements RasterizerAdapter {
  @override
  String get name => 'Marlin';

  @override
  Uint8List render(List<SvgPolygon> polygons, double svgWidth, double svgHeight) {
    final renderer = MarlinRenderer(renderWidth, renderHeight);
    renderer.clear(0xFFFFFFFF);
    renderer.init(0, 0, renderWidth, renderHeight, MarlinConst.windEvenOdd);

    final scaleX = renderWidth / svgWidth;
    final scaleY = renderHeight / svgHeight;

    for (final poly in polygons) {
      if (poly.vertices.length >= 6) {
        final scaled = _scaleVertices(poly.vertices, scaleX, scaleY);
        renderer.drawPolygon(scaled, poly.fillColor);
      }
    }
    
    // Uint32List view of Int32List buffer for helper
    return _uint32ToRGBA(renderer.buffer.buffer.asUint32List());
  }
}

/// Escala vértices
List<double> _scaleVertices(List<double> vertices, double scaleX, double scaleY) {
  final result = <double>[];
  for (int i = 0; i < vertices.length; i += 2) {
    result.add(vertices[i] * scaleX);
    result.add(vertices[i + 1] * scaleY);
  }
  return result;
}

/// Converte buffer Uint32 (ARGB) para RGBA bytes
Uint8List _uint32ToRGBA(Uint32List argbData) {
  final rgba = Uint8List(argbData.length * 4);
  for (int i = 0; i < argbData.length; i++) {
    final pixel = argbData[i];
    rgba[i * 4] = (pixel >> 16) & 0xFF;     // R
    rgba[i * 4 + 1] = (pixel >> 8) & 0xFF;  // G
    rgba[i * 4 + 2] = pixel & 0xFF;         // B
    rgba[i * 4 + 3] = (pixel >> 24) & 0xFF; // A
  }
  return rgba;
}

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════════════╗');
  print('║         SVG RENDERING BENCHMARK                                  ║');
  print('║         Renderiza SVGs complexos com cada rasterizador           ║');
  print('╚══════════════════════════════════════════════════════════════════╝');
  print('');

  // Criar diretório de saída
  await Directory(outputDir).create(recursive: true);

  final parser = SvgParser();
  
  // Lista de adaptadores funcionais
  final adapters = <RasterizerAdapter>[
    DAAAdapter(),
    DDFIAdapter(),
    MarlinAdapter(),
  ];

  for (final svgPath in svgFiles) {
    print('');
    print('═' * 70);
    print('Processing: $svgPath');
    print('═' * 70);
    
    // Carregar e parsear SVG
    final file = File(svgPath);
    if (!await file.exists()) {
      print('  File not found: $svgPath');
      continue;
    }
    
    final svgContent = await file.readAsString();
    late SvgDocument doc;
    
    try {
      doc = parser.parse(svgContent);
      print('  SVG size: ${doc.width.toStringAsFixed(0)}x${doc.height.toStringAsFixed(0)}');
      print('  Polygons parsed: ${doc.polygons.length}');
    } catch (e) {
      print('  Failed to parse SVG: $e');
      continue;
    }
    
    if (doc.polygons.isEmpty) {
      print('  No polygons found in SVG');
      continue;
    }
    
    // Nome base do arquivo
    final baseName = svgPath.split('/').last.replaceAll('.svg', '');
    
    // Renderizar com cada adaptador
    for (final adapter in adapters) {
      print('');
      print('  Rendering with ${adapter.name}...');
      
      try {
        final stopwatch = Stopwatch()..start();
        final pixels = adapter.render(doc.polygons, doc.width, doc.height);
        stopwatch.stop();
        
        final outputPath = '$outputDir/${baseName}_${adapter.name.toLowerCase()}.png';
        await PngWriter.saveRgba(outputPath, pixels, renderWidth, renderHeight);
        
        print('    ✓ Saved: $outputPath (${stopwatch.elapsedMilliseconds}ms)');
      } catch (e, st) {
        print('    ✗ Failed: $e');
        print('      $st');
      }
    }
  }
  
  print('');
  print('═' * 70);
  print('Done! Check $outputDir for output files.');
  print('═' * 70);
}
