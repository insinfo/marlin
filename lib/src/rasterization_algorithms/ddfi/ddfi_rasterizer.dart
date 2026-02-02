/// ============================================================================
/// DDFI — Discrete Differential Flux Integration
/// ============================================================================
///
/// Esta técnica abandona a ideia tradicional de "testar se um ponto está dentro
/// de um triângulo" ou "calcular a interseção exata de arestas".
///
/// Em vez disso, tratamos a renderização como um problema de processamento de
/// sinal unidimensional acumulativo.
///
/// PRINCÍPIO CENTRAL:
///   Pelo Teorema de Green, a área de um polígono fechado pode ser calculada
///   pela integral de linha ao longo de sua borda: Area = ∮xdy
///
///   Discretizamos essa integral de maneira única: em vez de calcular a área
///   pixel a pixel, calculamos a derivada discreta da cobertura (o "Fluxo")
///   apenas onde as arestas cruzam as scanlines.
///
///   A imagem final é reconstruída através de uma operação de Soma de Prefixo
///   (Prefix Sum), que é matematicamente equivalente à integração.
///
/// INOVAÇÃO:
///   - Subpixelização Algébrica sem Supersampling
///   - Codifica posição subpixel e "força" da aresta em um único valor delta
///   - Buffer de Acumulação Linear em vez de buffer 2D tradicional
///   - Sem sorting de arestas — complexidade O(N) na resolução
///
library ddfi;

import 'dart:typed_data';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DE PONTO FIXO
// ─────────────────────────────────────────────────────────────────────────────

const int _shift = 16;
const int _one = 1 << _shift;
// ignore: unused_element
const int _half = 1 << (_shift - 1);
const int _mask = _one - 1;

// ─────────────────────────────────────────────────────────────────────────────
// FLUX RENDERER
// ─────────────────────────────────────────────────────────────────────────────

/// Renderizador DDFI (Discrete Differential Flux Integration).
/// Focado em performance extrema em CPU Single-Thread.
class FluxRenderer {
  final int width;
  final int height;

  /// O Buffer de Fluxo armazena a "derivada" da imagem.
  /// Usamos Int32 para suportar acumulação de múltiplos shapes sem overflow.
  /// Formato: Fixed Point Q16.16 (embora apenas a parte inteira afete a
  /// cobertura final).
  late final Int32List _fluxBuffer;

  /// Buffer final de pixels (ARGB).
  late final Uint32List _pixelBuffer;

  FluxRenderer(this.width, this.height) {
    _fluxBuffer = Int32List(width * height);
    _pixelBuffer = Uint32List(width * height);
  }

  /// Limpa o buffer de fluxo. Deve ser chamado antes de desenhar um novo frame.
  /// (Otimização: Em um cenário real, limparíamos apenas a bounding box suja).
  void clear([int backgroundColor = 0xFF000000]) {
    _fluxBuffer.fillRange(0, _fluxBuffer.length, 0);
    _pixelBuffer.fillRange(0, _pixelBuffer.length, backgroundColor);
  }

  /// A primitiva fundamental: Rasteriza um triângulo usando a técnica de
  /// Fluxo Diferencial.
  void drawTriangle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int color,
  ) {
    // 1. Converter para Ponto Fixo Q16.16
    final fx1 = (x1 * _one).toInt();
    final fy1 = (y1 * _one).toInt();
    final fx2 = (x2 * _one).toInt();
    final fy2 = (y2 * _one).toInt();
    final fx3 = (x3 * _one).toInt();
    final fy3 = (y3 * _one).toInt();

    // 2. Processar as 3 arestas. A ordem não importa para o acumulador,
    // mas a orientação (sentido) define o preenchimento (winding).
    _rasterizeEdge(fx1, fy1, fx2, fy2);
    _rasterizeEdge(fx2, fy2, fx3, fy3);
    _rasterizeEdge(fx3, fy3, fx1, fy1);

    // 3. Resolver (integrar) a área afetada
    final minX = math.min(x1, math.min(x2, x3)).floor().clamp(0, width - 1);
    final maxX = math.max(x1, math.max(x2, x3)).ceil().clamp(0, width - 1);
    final minY = math.min(y1, math.min(y2, y3)).floor().clamp(0, height - 1);
    final maxY = math.max(y1, math.max(y2, y3)).ceil().clamp(0, height - 1);

    _resolveArea(minX, maxX, minY, maxY, color);
  }

  /// O Coração do Algoritmo: Rasterização de Aresta via Diferença de Fluxo.
  /// Matematicamente, projeta a aresta no eixo Y e calcula a contribuição
  /// de área horizontal para cada scanline.
  void _rasterizeEdge(int x1, int y1, int x2, int y2) {
    // Se a aresta for horizontal, ela não contribui para a integral de área
    // vertical (dy = 0).
    if (y1 == y2) return;

    // Garantir varredura de cima para baixo para simplificar o loop,
    // mas mantendo o sinal (winding) correto.
    int dir = 1;
    if (y1 > y2) {
      // Swap
      int tx = x1;
      x1 = x2;
      x2 = tx;
      int ty = y1;
      y1 = y2;
      y2 = ty;
      dir = -1; // Aresta subindo: remove área
    }

    // Deltas de aresta
    final dy = y2 - y1;
    final dx = x2 - x1;

    // Início e Fim (Scanlines inteiras)
    // Otimização: bitwise shift para dividir por _one
    final yStart = (y1 + _mask) >> _shift; // Ceil
    final yEnd = y2 >> _shift; // Floor

    if (yStart > yEnd) return; // Aresta subpixel dentro da mesma linha

    // Declive inverso (dx/dy) em ponto fixo
    // Usamos double para a divisão inicial para precisão, depois voltamos
    // para int
    final xStep = ((dx.toDouble() / dy.toDouble()) * _one).toInt();

    // Coordenada X inicial na primeira scanline yStart
    // Interpolação precisa: x = x1 + (yStart_pixel_coord - y1) * slope
    final currentYFixed = yStart << _shift;
    var currentX = x1 + (((currentYFixed - y1) * xStep) >> _shift);

    // Ponteiro para o buffer (linha atual)
    var rowOffset = yStart * width;

    // Loop Crítico: Executado para cada linha que a aresta cruza.
    // Deve ser o mais leve possível.
    for (int y = yStart; y <= yEnd; y++) {
      if (y >= height) break;
      if (y >= 0) {
        // currentX está em Q16.16.
        // pixelIndex é a parte inteira.
        final pixelX = currentX >> _shift;

        // Parte fracionária determina a cobertura AA.
        // Se x = 10.25 (0x000A4000), cobre 75% do pixel 10 e empurra fluxo
        // para o 11.
        //
        // Mas espere! A matemática do "Fluxo" é diferente.
        // Estamos calculando a derivada da área.
        // A altura da fatia nesta scanline é 1.0 (ou _one em fixed point).
        // Contribuição para pixelX: (1.0 - frac) * dir
        // Contribuição para pixelX+1: (frac) * dir
        // O valor armazenado é a "Altura Acumulada" que será integrada
        // horizontalmente depois.

        final frac = currentX & _mask;

        // Área coberta à esquerda da aresta no pixel X
        // Area = (1.0 - frac) * Height(1) * Direction
        final val = ((_one - frac) * dir);

        if (pixelX >= 0 && pixelX < width) {
          _fluxBuffer[rowOffset + pixelX] += val;
        }

        // A diferença (correção) é aplicada no próximo pixel para manter
        // a integral correta
        if (pixelX + 1 >= 0 && pixelX + 1 < width) {
          // O fluxo total muda em 'dir * _one'.
          // No pixel anterior aplicamos 'val'.
          // No próximo, precisamos completar a diferença.
          // Delta total esperado ao cruzar a borda é 'dir * _one'.
          // Buffer[x] += val
          // Buffer[x+1] += (dir * _one) - val
          _fluxBuffer[rowOffset + pixelX + 1] += (dir * _one) - val;
        }
      }

      // Avançar para a próxima scanline
      currentX += xStep;
      rowOffset += width;
    }
  }

  /// Fase de Resolução: Integração (Prefix Sum) e Blending.
  /// Converte o buffer de derivadas em cores visíveis.
  /// Otimizado para processar apenas a área afetada (Bounding Box).
  void _resolveArea(int minX, int maxX, int minY, int maxY, int colorArgb) {
    // Extrair canais de cor
    final a = (colorArgb >> 24) & 0xFF;
    final r = (colorArgb >> 16) & 0xFF;
    final g = (colorArgb >> 8) & 0xFF;
    final b = colorArgb & 0xFF;

    // Normalização para alpha blending rápido (0..256)
    // alphaBase é o alpha da cor de entrada.
    final alphaBase = a + 1;

    for (int y = minY; y <= maxY; y++) {
      final rowOffset = y * width;
      int accumulatedCoverage = 0; // O integrador começa em 0 na esquerda

      for (int x = minX; x <= maxX; x++) {
        final idx = rowOffset + x;

        // 1. INTEGRAÇÃO (Prefix Sum)
        // Somamos a derivada armazenada no buffer para obter a cobertura
        // atual (Winding Number)
        accumulatedCoverage += _fluxBuffer[idx];

        // A cobertura acumulada está em Q16.16.
        // Winding Rule: Non-Zero. Se != 0, tem preenchimento.
        // Para AA, pegamos o valor absoluto e clampamos em 1.0 (_one).
        // Usamos abs() porque winding pode ser negativo dependendo da
        // orientação.
        var coverage = accumulatedCoverage.abs();
        if (coverage > _one) coverage = _one;

        // Se cobertura é zero, nada a desenhar
        if (coverage == 0) continue;

        // 2. PIXEL SHADING & BLENDING
        // Converter cobertura (0.._one) para alpha (0..255)
        // coverage >> 8 converte Q16 para 0..256 (aprox)
        final pixelAlpha = (coverage * alphaBase) >> _shift; // Alpha final

        if (pixelAlpha > 0) {
          // Ler cor de fundo (destino)
          final bg = _pixelBuffer[idx];
          final bgA = (bg >> 24) & 0xFF;
          final bgR = (bg >> 16) & 0xFF;
          final bgG = (bg >> 8) & 0xFF;
          final bgB = bg & 0xFF;

          // Alpha Blending Padrão (Src over Dst)
          // InvAlpha = 256 - pixelAlpha
          final invAlpha = 256 - pixelAlpha;

          final outR = (r * pixelAlpha + bgR * invAlpha) >> 8;
          final outG = (g * pixelAlpha + bgG * invAlpha) >> 8;
          final outB = (b * pixelAlpha + bgB * invAlpha) >> 8;
          final outA = (255 * pixelAlpha + bgA * invAlpha) >> 8;

          // Reconstruir pixel
          _pixelBuffer[idx] = (outA << 24) | (outR << 16) | (outG << 8) | outB;
        }
      }
    }

    // Limpar o buffer de fluxo na área processada para reutilização
    for (int y = minY; y <= maxY; y++) {
      final rowOffset = y * width;
      for (int x = minX; x <= maxX; x++) {
        _fluxBuffer[rowOffset + x] = 0;
      }
    }
  }

  /// Retorna o buffer de pixels
  Uint32List get buffer => _pixelBuffer;

  /// Desenha um polígono (decomposição em triângulos via fan)
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return; // Mínimo 3 vértices

    final n = vertices.length ~/ 2;
    final x0 = vertices[0];
    final y0 = vertices[1];

    // Fan triangulation
    for (int i = 1; i < n - 1; i++) {
      final x1 = vertices[i * 2];
      final y1 = vertices[i * 2 + 1];
      final x2 = vertices[(i + 1) * 2];
      final y2 = vertices[(i + 1) * 2 + 1];

      drawTriangle(x0, y0, x1, y1, x2, y2, color);
    }
  }

  /// Desenha um retângulo
  void drawRect(double x, double y, double w, double h, int color) {
    drawTriangle(x, y, x + w, y, x + w, y + h, color);
    drawTriangle(x, y, x + w, y + h, x, y + h, color);
  }
}
