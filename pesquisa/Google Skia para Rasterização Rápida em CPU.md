Técnicas Usadas no Google Skia para Rasterização Rápida em CPU
O Skia do Google é uma biblioteca gráfica 2D de código aberto poderosa que impulsiona a renderização em diversas aplicações. Uma de suas características principais é a rasterização eficiente baseada em CPU, que converte gráficos vetoriais em dados de pixels sem depender de GPU. Isso é essencial em ambientes sem aceleração gráfica ou para renderização em servidores. O backend de CPU do Skia atinge alto desempenho por meio de algoritmos otimizados, como o de scanline, arquitetura modular e uso de instruções SIMD. A seguir, detalhamos o algoritmo principal usado na renderização 2D, sua implementação no Skia e como portá-lo para Dart puro, incluindo informações sobre a implementação de SIMD no Dart e otimizações recentes em Isolates para compartilhamento de memória.
Visão Geral da Arquitetura Principal
A rasterização em CPU do Skia segue um pipeline que inicia com comandos de desenho de alto nível e termina na manipulação de pixels. A classe SkCanvas gerencia comandos como drawPath, encaminhados para SkBitmapDevice, que lida com o bitmap alvo. Para operações complexas, o desenho é dividido em tiles para eficiência de memória. O SkDraw orquestra o processo, passando caminhos, tintas, transformações e recortes para o rasterizador.
O Algoritmo de Rasterização: Scanline com Sweep-Line
O algoritmo central para renderização 2D no Skia é o de scanline baseado em sweep-line, um método clássico para preencher polígonos e caminhos vetoriais. Ele converte formas vetoriais em linhas horizontais de pixels (scanlines), calculando interseções com bordas da forma e preenchendo os intervalos entre elas.
Detalhes do Algoritmo

Preparação das Bordas (Edges): O caminho vetorial (path) é decomposto em segmentos de linha (edges). Cada edge é representada por pontos iniciais e finais, com coordenadas fixas para precisão (usando fixed-point arithmetic no Skia para evitar erros de flutuação).
Ordenação das Bordas: Cria-se uma lista global de edges ordenada pela coordenada Y inicial (de cima para baixo). Isso permite processar as bordas à medida que a linha de varredura (sweep-line) desce pela imagem.
Lista de Bordas Ativas (Active Edge Table - AET): Para cada scanline (linha Y), mantém-se uma lista de edges que intersectam aquela linha, ordenada pela coordenada X de interseção. À medida que a sweep-line avança:
Adicionam-se edges que começam na Y atual da lista global.
Removem-se edges que terminam na Y atual.
Atualizam-se as interseções X para a próxima scanline, incrementando com a inclinação (slope) da edge: deltaX = (x2 - x1) / (y2 - y1).

Cálculo de Cobertura e Preenchimento: Para cada scanline, itera-se pela AET em pares de interseções (entrada/saída). Preenche-se os pixels entre X esquerdo e direito. Para non-winding ou even-odd rules, alterna o preenchimento. No modo não-antialiased, pixels são preenchidos integralmente; no antialiased, calcula-se cobertura fracionária baseada na distância ao centro do pixel.
Tratamento de Casos Especiais:
Bordas horizontais são ignoradas ou tratadas separadamente para evitar divisões por zero.
Para triângulos ou polígonos simples, divide-se em triângulos flat-bottom e flat-top para simplificar o preenchimento, calculando slopes inversos e varrendo linha por linha.
Supersampling pode ser usado para melhor anti-aliasing, amostrando múltiplos pontos por pixel.


Esse algoritmo é eficiente porque processa apenas as regiões afetadas, evitando varreduras completas na imagem, e é linear no número de pixels preenchidos.
Rasterização com SkScan
No Skia, o algoritmo é implementado no módulo SkScan, dividido em arquivos como SkScan.cpp, SkScan_AA.cpp (para anti-aliasing) e SkScan_Path.cpp. Aqui vai um resumo baseado no código fonte:

FillPath: Função principal que recebe o path, clip e blitter. Converte o path em edges usando SkEdgeBuilder, que constrói uma lista de edges lineares (aproximando curvas Bézier em linhas).
Processamento de Edges: As edges são inseridas em uma estrutura sorted (por Y, depois X). Para cada Y, SkScan::FillIRect ou SkScan::FillPath gerencia a AET. Usa SkEdge para representar cada edge com campos como fX, fDX (slope), fFirstY, fLastY.
Blitting: Para cada scanline, calcula máscaras de cobertura e chama o blitter (SkBlitter) para mesclar nos pixels. No modo AA, usa SkAlphaRuns para armazenar runs de alphas. Funções como blitH preenchem runs horizontais rapidamente, e blitAntiH aplica alphas fracionários.
Otimização com SIMD: Integra com SkRasterPipeline para processar batches de pixels usando SSE/NEON, acelerando blends e stores.

Exemplo pseudocódigo simplificado do processo em SkScan:
textvoid FillPath(const SkPath& path, const SkIRect& clip, SkBlitter* blitter) {
    // Build edges from path
    SkEdgeBuilder builder;
    builder.addPath(path);
    SkEdge* edges = builder.edges();
    int edgeCount = builder.edgeCount();

    // Sort edges by Y
    sortEdgesByY(edges, edgeCount);

    // For each scanline in clip
    for (int y = clip.top(); y < clip.bottom(); ++y) {
        // Update active edges
        addNewEdgesForY(y, edges);
        removeEndedEdgesForY(y);

        // Sort active edges by X
        sortActiveEdgesByX();

        // Compute coverage and blit
        computeCoverageMask();
        blitter->blitMask(x, y, mask);
    }
}
Essa implementação garante precisão com fixed-point (SkFixed) e lida com clipping via SkRasterClip.
Gerenciamento de Memória e Otimizações
O Skia usa SkPixmap para acesso direto a pixels e STArray para arrays inline, reduzindo alocações. Otimizado para compiladores como Clang, com caminhos SIMD para arquiteturas x86 e ARM.
Comparações e Desempenho no Mundo Real
O Skia supera bibliotecas como CoreGraphics em threads únicas, graças ao scanline otimizado, mas pode ser complementado por backends GPU para cargas pesadas.
Implementação de SIMD no Dart
O Dart suporta SIMD (Single Instruction Multiple Data) via tipos como Float32x4 e Int32x4 da biblioteca dart:typed_data, permitindo operações paralelas em 4 números de 32 bits. Isso acelera algoritmos como gráficos 3D, processamento de imagens e áudio, com ganhos de 150-400% em cenários como multiplicação de matrizes 4x4.
Tipos Principais

Float32x4: 4 floats de precisão simples. Suporta operações aritméticas (+, -, *, /), min/max, shuffle.
Int32x4: 4 inteiros de 32 bits. Útil para comparações e seleções (máscaras).
Float32x4List: Armazenamento contíguo para eficiência.

Pensando em SIMD

Valores são imutáveis, com lanes (x, y, z, w).
Operações verticais: Adição paralela em lanes.
Evite operações horizontais (lentas); organize dados uniformes.

Exemplo de média:
Dartdouble computeAverage(Float32x4List list) {
  Float32x4 sum = Float32x4.zero();
  for (int i = 0; i < list.length; i++) {
    sum += list[i];
  }
  double average = sum.x + sum.y + sum.z + sum.w;
  return average / (list.length * 4);
}
Desafios e Surpresas de Desempenho
De acordo com discussões recentes (2025), SIMD no Dart apresenta surpresas:

Em JIT, SIMD é ~3x mais rápido que alternativas em alguns testes.
Em AOT, pode ser 56x mais lento devido a otimizações ausentes.
Truques como acessar lanes via buffers (Uint32List) melhoram, mas indicam inconsistências.

Exemplo de teste mostrando discrepâncias entre JIT e AOT.
Aplicações Modernas
Pacotes como eneural_net usam SIMD para redes neurais, acelerando ativações (e.g., Sigmoid) em 1.5-2x.
Otimizações Recentes em Isolates para Compartilhamento de Memória
Isolates no Dart são threads leves isolados, sem memória compartilhada por padrão, comunicando via mensagens (cópia de dados). Otimizações recentes melhoram isso:

Isolate.run(): Cria isolates de curta duração para tarefas concorrentes, capturando exceções e retornando resultados. Evita bloqueios no main isolate.
Portas de Longa Duração: Usando ReceivePort e SendPort para comunicação bidirecional, com otimizações para transferência de objetos (e.g., TypedData sem cópia).
Compartilhamento de Memória: Em Dart 3+, suporte a objetos transferíveis (transfer ownership) reduz cópias. Para memória compartilhada real, use dart:ffi ou Wasm, mas isolates agora otimizam mensagens grandes.

Exemplo de isolate para servidor (de otimização em Flutter): Extrair servidor Shelf para isolate separa loops de eventos, evitando quedas de FPS ao processar arquivos grandes.
Exemplo simples:
Dartconst String filename = 'data.json';

void main() async {
  final jsonData = await Isolate.run(_readAndParseJson);
  print('Keys: ${jsonData.length}');
}

Future<Map<String, dynamic>> _readAndParseJson() async {
  final fileData = await File(filename).readAsString();
  return jsonDecode(fileData);
}
Para longos: Use Isolate.spawn com portas para comunicação.
Portando para Dart Puro
Portar o algoritmo de scanline do Skia para Dart puro (sem frameworks) envolve implementar o sweep-line em código Dart, usando bibliotecas nativas como dart:typed_data para manipular buffers de pixels. Dart não tem acesso direto a SIMD sem extensões, mas pode ser eficiente para rasterização simples. A ideia é criar um rasterizador que recebe paths (listas de pontos) e gera um Uint8List representando um bitmap RGBA.
Passos para Implementação

Representação de Dados: Use classes para Edge (com x, y1, y2, slope) e Path (lista de pontos). Para bitmap, use Uint8List com largura e altura fixas.
Algoritmo Principal: Implemente o sweep-line: Ordene edges por Y, mantenha AET, calcule interseções e preencha pixels.
Anti-Aliasing Simples: Calcule cobertura fracionária adicionando sub-pixel precision.

Exemplo de código Dart puro para rasterizar um polígono simples (triângulo):
Dartimport 'dart:typed_data';
import 'dart:math';

class Edge {
  double x;
  final double minY, maxY, slope;
  Edge(Point<double> p1, Point<double> p2)
      : minY = min(p1.y, p2.y),
        maxY = max(p1.y, p2.y),
        slope = (p2.x - p1.x) / (p2.y - p1.y),
        x = p1.y < p2.y ? p1.x : p2.x;
}

class Rasterizer {
  final int width, height;
  final Uint8List pixels; // RGBA, 4 bytes por pixel

  Rasterizer(this.width, this.height)
      : pixels = Uint8List(width * height * 4);

  void fillPolygon(List<Point<double>> points, int color) {
    // Crie edges do polígono
    List<Edge> edges = [];
    for (int i = 0; i < points.length; i++) {
      Point p1 = points[i];
      Point p2 = points[(i + 1) % points.length];
      if (p1.y != p2.y) edges.add(Edge(p1, p2));
    }

    // Ordene edges por minY
    edges.sort((a, b) => a.minY.compareTo(b.minY));

    int edgeIndex = 0;
    List<Edge> activeEdges = [];

    for (int y = 0; y < height; y++) {
      // Adicione novas edges
      while (edgeIndex < edges.length && edges[edgeIndex].minY <= y) {
        activeEdges.add(edges[edgeIndex++]);
      }

      // Remova edges terminadas
      activeEdges.removeWhere((e) => e.maxY <= y);

      // Ordene active por x
      activeEdges.sort((a, b) => a.x.compareTo(b.x));

      // Preencha entre pares
      for (int i = 0; i < activeEdges.length; i += 2) {
        if (i + 1 >= activeEdges.length) break;
        int x1 = activeEdges[i].x.ceil();
        int x2 = activeEdges[i + 1].x.floor();
        for (int x = max(0, x1); x < min(width, x2); x++) {
          int index = (y * width + x) * 4;
          pixels[index] = color >> 16 & 0xFF; // R
          pixels[index + 1] = color >> 8 & 0xFF; // G
          pixels[index + 2] = color & 0xFF; // B
          pixels[index + 3] = 255; // A
        }
      }

      // Atualize x para próxima scanline
      for (var e in activeEdges) {
        e.x += e.slope;
      }
    }
  }
}

// Uso exemplo:
void main() {
  var raster = Rasterizer(200, 200);
  var points = [Point(50.0, 50.0), Point(150.0, 50.0), Point(100.0, 150.0)];
  raster.fillPolygon(points, 0x0000FF); // Azul
  // Salve pixels em arquivo ou use em outro contexto
}
Essa porta é básica e pode ser expandida para paths complexos (aproximando curvas em linhas), clipping e anti-aliasing. Para desempenho, otimize com loops eficientes e evite alocações desnecessárias. Em Dart, para exportar o bitmap, use pacotes como image (disponível via pub), mas para puro, manipule manualmente para PPM ou similar.
Para portar o SkScan completo, estude o código C++ e traduza estruturas como SkEdge para classes Dart, ajustando para garbage collection.
Conclusão
A velocidade do Skia na rasterização em CPU vem de seu núcleo baseado em scanline, pipeline modular com aceleração SIMD, tiling para eficiência de memória e otimizações cuidadosas para minimizar alocações e overhead. Essas técnicas o tornam uma base essencial para engines de renderização modernos. Para mergulhos mais profundos, consulte a documentação de arquitetura oficial do Skia.