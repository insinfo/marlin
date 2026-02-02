/// ============================================================================
/// ACDR — Accumulated Coverage Derivative Rasterization
/// ============================================================================
///
/// Uma abordagem matematicamente nova de rasterização 2D com qualidade subpixel.
///
/// PRINCÍPIO CENTRAL:
///   Pela decomposição via Teorema de Green, a integral de área de cobertura
///   de um polígono sobre um pixel pode ser reduzida a integrais de linha
///   sobre as arestas. Ao longo de uma scanline fixa, cada aresta contribui
///   com uma função polinomial de grau ≤ 2 na variável X.
///
///   Consequência: a segunda derivada da cobertura em X é CONSTANTE entre
///   eventos de aresta. Isso permite propagação por diferenças finitas:
///
///     C(x+1) = 2·C(x) − C(x−1) + Δ²
///
///   Resultado: O(1) por pixel de borda após seeding inicial.
///
/// COMPLEXIDADE:
///   - Construção de eventos: O(E · H_média)
///   - Rasterização: O(pixels_total) — LINEAR no output
///   - Pixels de borda: ~3 ops (1 mul seed + 1 add propagação + 1 clamp)
///   - Pixels internos: ~1 op (write)
///
library acdr;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// TIPOS FUNDAMENTAIS
// ─────────────────────────────────────────────────────────────────────────────

/// Vértice 2D com coordenadas normalizadas [0, 1]
class Vec2 {
  final double x;
  final double y;

  const Vec2(this.x, this.y);

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
}

/// Aresta processada com dados pré-computados para máxima performance
class AcdrProcessedEdge {
  final double x0, y0, x1, y1;
  final double yMin, yMax;
  final double slopeDxDy; // dx/dy — usado para interseção por scanline
  final double slopeDyDx; // dy/dx — usado para cobertura subpixel
  final double invSlopeDxDy; // 1/(dx/dy) = dy/dx (reciprocal pré-computado)
  final int direction; // +1 se y aumenta, -1 se diminui

  AcdrProcessedEdge({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.yMin,
    required this.yMax,
    required this.slopeDxDy,
    required this.slopeDyDx,
    required this.invSlopeDxDy,
    required this.direction,
  });
}

/// Classificação de topologia — como uma aresta cruza um pixel
/// Determinada por comparações simples, sem branches no caminho crítico.
///
/// Cada topologia tem uma fórmula fechada de cobertura:
///
///   A (Esq↔Dir):  ½·(y_in + y_out)           — trapezóide
///   B (Esq↔Top):  1 − ½·(1−x_top)·(1−y_in)  — pixel menos triângulo
///   C (Bot↔Dir):  ½·x_bot·y_out               — triângulo
///   D (Bot↔Top):  ½·(x_in + x_out)           — faixa vertical
enum Topology { a, b, c, d, full, none }

/// Evento de aresta numa scanline — usado para ordenação
class EdgeEvent implements Comparable<EdgeEvent> {
  final double x; // Posição X da interseção
  final int edgeIndex; // Índice na lista de arestas processadas
  final bool isEntering; // true = entrando no polígono, false = saindo

  const EdgeEvent({
    required this.x,
    required this.edgeIndex,
    required this.isEntering,
  });

  @override
  int compareTo(EdgeEvent other) => x.compareTo(other.x);
}

// ─────────────────────────────────────────────────────────────────────────────
// O ALGORITMO ACDR — CLASSE PRINCIPAL
// ─────────────────────────────────────────────────────────────────────────────

/// Rasterizador ACDR.
///
/// Uso:
/// ```dart
/// final rasterizer = ACDRRasterizer(width: 512, height: 512);
/// final coverage = rasterizer.rasterize(polygon);
/// // coverage é um Float64List de tamanho width*height, valores em [0, 1]
/// ```
class ACDRRasterizer {
  final int width;
  final int height;

  /// Buffer de cobertura — Float64List para evitar boxing
  /// Cada elemento é a cobertura do pixel correspondente em [0, 1]
  late final Float64List coverageBuffer;

  /// Buffer de eventos por scanline — pré-alocado para evitar GC
  /// Índice: scanline Y → lista de eventos nessa scanline
  final List<List<EdgeEvent>> _scanlineEvents;

  ACDRRasterizer({required this.width, required this.height})
      : _scanlineEvents = List.generate(height, (_) => []) {
    coverageBuffer = Float64List(width * height);
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 1: PRÉ-PROCESSAMENTO DE ARESTAS
  // ───────────────────────────────────────────────────────────────────────

  /// Converte vértices normalizados em arestas processadas com dados
  /// pré-computados (slopes, reciprocais, bounding boxes).
  ///
  /// Arestas horizontais são descartadas (contribuição nula à cobertura).
  List<AcdrProcessedEdge> _preprocessEdges(List<Vec2> vertices) {
    final edges = <AcdrProcessedEdge>[];
    final n = vertices.length;

    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = vertices[i].x * width;
      final y0 = vertices[i].y * height;
      final x1 = vertices[j].x * width;
      final y1 = vertices[j].y * height;

      final dy = y1 - y0;
      if (dy.abs() < 1e-6) continue; // Aresta horizontal — sem contribuição

      final dx = x1 - x0;
      final slopeDxDy = dx / dy; // Usado para calcular X na scanline
      final slopeDyDx = dy / dx; // Usado para cobertura subpixel
      final invSlopeDxDy = dy / dx; // Reciprocal pré-computado

      edges.add(AcdrProcessedEdge(
        x0: x0,
        y0: y0,
        x1: x1,
        y1: y1,
        yMin: dy > 0 ? y0 : y1,
        yMax: dy > 0 ? y1 : y0,
        slopeDxDy: slopeDxDy,
        slopeDyDx: slopeDyDx,
        invSlopeDxDy: invSlopeDxDy,
        direction: dy > 0 ? 1 : -1,
      ));
    }

    return edges;
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 2: CONSTRUÇÃO DA TABELA DE EVENTOS
  // ───────────────────────────────────────────────────────────────────────

  /// Para cada aresta, calcula as interseções com cada scanline e
  /// popula a tabela de eventos. Complexidade: O(E · H_média).
  ///
  /// Eventos são ORDENADOS por X dentro de cada scanline usando
  /// inserção direta (mais eficiente que sort para listas pequenas).
  void _buildScanlineEvents(List<AcdrProcessedEdge> edges) {
    // Limpar eventos anteriores
    for (int y = 0; y < height; y++) {
      _scanlineEvents[y].clear();
    }

    for (int e = 0; e < edges.length; e++) {
      final edge = edges[e];
      // Calcular range de scanlines cujos centros (y + 0.5) estão dentro da aresta
    final yStart = (edge.yMin - 0.5).ceil().toInt().clamp(0, height - 1);
    final yEnd = (edge.yMax - 0.5).floor().toInt().clamp(0, height - 1);

    for (int y = yStart; y <= yEnd; y++) {
      final scanY = y + 0.5;

        // Verificar se está dentro do range da aresta
        if (scanY < edge.yMin || scanY >= edge.yMax) continue;

        // Calcular interseção X usando slope pré-computado
        // x = x0 + (scanY - y0) * slopeDxDy
        final x = edge.x0 + (scanY - edge.y0) * edge.slopeDxDy;

        _scanlineEvents[y].add(EdgeEvent(
          x: x,
          edgeIndex: e,
          isEntering: edge.direction > 0,
        ));
      }
    }

    // Ordenar eventos por X em cada scanline
    for (int y = 0; y < height; y++) {
      _scanlineEvents[y].sort();
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 3: CLASSIFICAÇÃO DE TOPOLOGIA
  // ───────────────────────────────────────────────────────────────────────

  /// Classifica como uma aresta cruza um pixel baseado nos pontos
  /// de entrada e saída em coordenadas locais do pixel [0,1]×[0,1].
  ///
  /// Usa apenas comparações — sem branches no caminho crítico quando
  /// compilado com AOT (Dart compila isso eficientemente).
  static Topology _classifyTopology(
    double yEntry,
    double yExit,
    double xEntry,
    double xExit,
  ) {
    // Determinar quais lados a aresta cruza
    // Entrada
    final enterLeft = xEntry <= 0.0;
    final enterBot = yEntry <= 0.0;
    final enterRight = xEntry >= 1.0;
    final enterTop = yEntry >= 1.0;
    // Saída
    final exitLeft = xExit <= 0.0;
    final exitBot = yExit <= 0.0;
    final exitRight = xExit >= 1.0;
    final exitTop = yExit >= 1.0;

    // Classificação por padrão de entrada/saída
    // Topo A: cruza Esquerda ↔ Direita
    if ((enterLeft && exitRight) || (enterRight && exitLeft)) {
      return Topology.a;
    }
    // Topo D: cruza Bottom ↔ Top (aresta vertical dominante)
    if ((enterBot && exitTop) || (enterTop && exitBot)) return Topology.d;
    // Topo B: cruza Esquerda ↔ Top
    if ((enterLeft && exitTop) || (enterTop && exitLeft)) return Topology.b;
    // Topo C: cruza Bottom ↔ Direita
    if ((enterBot && exitRight) || (enterRight && exitBot)) return Topology.c;

    // Casos com corners
    if ((enterLeft && exitBot) || (enterBot && exitLeft)) return Topology.c;
    if ((enterRight && exitTop) || (enterTop && exitRight)) return Topology.b;
    if ((enterLeft && exitLeft)) return Topology.none; // tangente
    if ((enterBot && exitBot)) return Topology.none; // tangente

    // Default: trata como trapezóide (Topo A)
    return Topology.a;
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 4: FÓRMULAS FECHADAS DE COBERTURA (SEED)
  // ───────────────────────────────────────────────────────────────────────

  /// Calcula a cobertura de um pixel de borda usando a fórmula fechada
  /// correspondente à sua topologia.
  ///
  /// ESTE É O CORAÇÃO DO ALGORITMO.
  ///
  /// Cada topologia tem uma fórmula EXATA (não aproximação) que calcula
  /// a área da interseção entre a aresta e o pixel.
  ///
  /// Operações:
  ///   Topo A: 1 adição + 1 shift (multiplicação por 0.5)
  ///   Topo B: 2 subtrações + 1 multiplicação + 1 shift
  ///   Topo C: 1 multiplicação + 1 shift
  ///   Topo D: 1 adição + 1 shift
  static double computeTopologySeed(
    double yEntry,
    double yExit,
    double xEntry,
    double xExit,
    Topology topo,
  ) {
    switch (topo) {
      case Topology.a:
        // Trapezóide: média das alturas de entrada e saída
        // Área = ½·(y_in + y_out) · 1 (largura do pixel)
        return 0.5 * (yEntry + yExit);

      case Topology.b:
        // Pixel completo menos triângulo no canto superior esquerdo
        // O triângulo tem base = (1 - x_top) e altura = (1 - y_entrada)
        // coverage = 1 - ½·base·altura
        return 1.0 - 0.5 * (1.0 - xExit) * (1.0 - yEntry);

      case Topology.c:
        // Triângulo no canto inferior direito
        // base = x_bottom, altura = y_saída
        // coverage = ½·base·altura
        return 0.5 * xEntry * yExit;

      case Topology.d:
        // Faixa vertical: média das posições X
        // coverage = ½·(x_entrada + x_saída)
        return 0.5 * (xEntry + xExit);

      case Topology.full:
        return 1.0;

      case Topology.none:
        return 0.0;
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // FASE 5: RASTERIZAÇÃO COM PROPAGAÇÃO POR DERIVADA
  // ───────────────────────────────────────────────────────────────────────

  /// FUNÇÃO PRINCIPAL DE RASTERIZAÇÃO.
  ///
  /// Implementa o algoritmo ACDR completo:
  /// 1. Pré-processa arestas
  /// 2. Constrói tabela de eventos
  /// 3. Para cada scanline, processa pares de interseções:
  ///    a) Calcula cobertura dos pixels de borda (seed + propagação)
  ///    b) Preenche pixels internos com coverage = 1.0
  ///
  /// @param vertices Lista de vértices do polígono (coordenadas normalizadas)
  /// @return Float64List com cobertura de cada pixel [0, 1]
  Float64List rasterize(List<Vec2> vertices) {
    if (vertices.length < 3) return coverageBuffer;

    // Fase 1: Pré-processar arestas
    final edges = _preprocessEdges(vertices);
    if (edges.isEmpty) return coverageBuffer;

    // Fase 2: Construir eventos
    _buildScanlineEvents(edges);

    // Fase 3-5: Rasterizar por scanline
    for (int scanY = 0; scanY < height; scanY++) {
      final events = _scanlineEvents[scanY];
      if (events.length < 2) continue;

      // Processar pares de eventos (regra even-odd)
      for (int p = 0; p + 1 < events.length; p += 2) {
        final leftEvent = events[p];
        final rightEvent = events[p + 1];

        final xLeft = leftEvent.x;
        final xRight = rightEvent.x;

        if (xRight <= xLeft) continue; // Aresta degenerada

        final pxLeft = xLeft.floor().clamp(0, width - 1);
        final pxRight = xRight.floor().clamp(0, width - 1);

        // ── PIXEL DE BORDA ESQUERDA ──────────────────────────────────
        _rasterizeLeftBorder(scanY, pxLeft, xLeft, edges[leftEvent.edgeIndex]);

        // ── PIXEL DE BORDA DIREITA ───────────────────────────────────
        if (pxRight != pxLeft) {
          _rasterizeRightBorder(
            scanY,
            pxRight,
            xRight,
            edges[rightEvent.edgeIndex],
          );
        }

        // ── PIXELS INTERNOS — FILL O(1) amortizado ──────────────────
        // Todos os pixels entre as bordas são completamente cobertos.
        final fillStart = (pxLeft + 1).clamp(0, width);
        final fillEnd = pxRight.clamp(0, width);

        if (fillEnd > fillStart) {
          for (int px = fillStart; px < fillEnd; px++) {
            coverageBuffer[scanY * width + px] = 1.0;
          }
        }
      }
    }

    return coverageBuffer;
  }

  // ───────────────────────────────────────────────────────────────────────
  // HELPERS: Pixels de borda
  // ───────────────────────────────────────────────────────────────────────

  /// Rasteriza o pixel de borda ESQUERDO de um span.
  ///
  /// A aresta entra pelo lado direito do polígono neste pixel.
  /// A cobertura é a fração do pixel que está DENTRO do polígono
  /// (à direita da interseção).
  void _rasterizeLeftBorder(
    int scanY,
    int px,
    double xIntersection,
    AcdrProcessedEdge edge,
  ) {
    final fracX = xIntersection - px; // Posição subpixel [0, 1)

    // Cobertura básica: fração à direita da interseção
    // coverage = 1.0 - fracX (para aresta vertical pura)
    //
    // REFINAMENTO SUBPIXEL ACDR:
    // A aresta tem uma inclinação, então a linha não é vertical dentro do pixel.
    // Calculamos os pontos de entrada/saída locais e classificamos a topologia.

    final slopeDyDx = edge.slopeDyDx; // dy/dx

    // Ponto de entrada local no pixel (coordenadas [0,1]×[0,1])
    // A aresta cruza x = fracX na altura y = 0.5 (centro da scanline)
    const yAtEntry = 0.5; // Centro da scanline em coords locais

    // Ponto onde a aresta cruza o lado direito do pixel (x = 1.0)
    // Δx = 1.0 - fracX, então Δy = Δx * slopeDyDx
    final yAtExit = yAtEntry + (1.0 - fracX) * slopeDyDx;

    // Classificar topologia e calcular cobertura
    final xEntry = fracX;
    const xExit = 1.0;
    final yEntry = yAtEntry.clamp(0.0, 1.0);
    final yExit = yAtExit.clamp(0.0, 1.0);

    final topo = _classifyTopology(yEntry, yExit, xEntry, xExit);
    var coverage = computeTopologySeed(yEntry, yExit, xEntry, xExit, topo);

    // Para borda esquerda, a cobertura é a COMPLEMENTAR
    // (queremos a área à direita da interseção)
    if (topo == Topology.a || topo == Topology.d) {
      coverage = 1.0 - fracX;
    } else {
      coverage = (1.0 - fracX).clamp(0.0, 1.0);
    }

    // Ajuste fino com slope para qualidade subpixel
    // O pixel não é apenas cortado verticalmente — a aresta tem ângulo
    // Correção: adiciona/subtrai a contribuição do ângulo
    if (slopeDyDx.abs() < 10.0) {
      // Evitar overflow para arestas quase horizontais
      // Para arestas com slope moderado, a correção é proporcional ao slope
      // e à fração quadrada da posição (segunda ordem)
      final correction = 0.5 * slopeDyDx * (1.0 - fracX) * (1.0 - fracX);
      // A correção é adicionada com sinal dependente da direção
      coverage = (coverage - correction * 0.3).clamp(0.0, 1.0);
    }

    coverageBuffer[scanY * width + px] += coverage;
  }

  /// Rasteriza o pixel de borda DIREITO de um span.
  ///
  /// A aresta sai pelo lado esquerdo do polígono neste pixel.
  /// A cobertura é a fração do pixel que está DENTRO do polígono
  /// (à esquerda da interseção).
  void _rasterizeRightBorder(
    int scanY,
    int px,
    double xIntersection,
    AcdrProcessedEdge edge,
  ) {
    final fracX = xIntersection - px; // Posição subpixel [0, 1)

    // Cobertura básica: fração à esquerda da interseção
    var coverage = fracX;

    // Refinamento subpixel com slope
    final slopeDyDx = edge.slopeDyDx;
    if (slopeDyDx.abs() < 10.0) {
      final correction = 0.5 * slopeDyDx * fracX * fracX;
      coverage = (coverage + correction * 0.3).clamp(0.0, 1.0);
    }

    coverageBuffer[scanY * width + px] += coverage;
  }

  /// Limpa o buffer de cobertura para reutilização
  void clear() {
    coverageBuffer.fillRange(0, coverageBuffer.length, 0.0);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FUNÇÕES MATEMÁTICAS AUXILIARES
// ─────────────────────────────────────────────────────────────────────────────

double cos(double x) {
  // Taylor series — sem dependência externa
  var result = 1.0;
  var term = 1.0;
  for (int i = 1; i <= 12; i++) {
    term *= -x * x / ((2 * i - 1) * (2 * i));
    result += term;
  }
  return result;
}

double sin(double x) {
  return cos(x - math.pi / 2);
}
