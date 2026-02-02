//C:\MyDartProjects\marlin\lib\src\rasterization_algorithms\blend2d\blend2d_rasterizer.dart
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:async';
import 'dart:isolate';

/// BLEND2D — Optimized Rasterizer for Dart
/// Baseado nos conceitos de performance e amostragem analítica.
///
/// SoA (Structure of Arrays):
// Antes: _cellBuffer continha [cover, area, cover, area...]. Isso atrapalha o SIMD, pois carregar um registrador Int32x4 pegaria dados misturados.
// Agora: Temos _covers e _areas separados. Um load SIMD em _covers pega 4 coberturas adjacentes (x, x+1, x+2, x+3).
// Lógica Híbrida no SIMD:
// O cálculo de coverAcc (acumulação prefixada) é inerentemente serial. Fazer isso puramente em SIMD requer muitos "shuffles" que são lentos.
// A solução foi extrair os valores x,y,z,w para somar o acumulador serialmente (cov0, cov1...), mas usar o poder do SIMD para fazer a matemática pesada (abs, multiply, blend) em 4 pixels de uma vez, evitando ramificações condicionais (if alpha > 0) pixel a pixel.
// Gerenciamento de Isolates:
// A função _resolveParallel divide a imagem em faixas horizontais (tileHeight).
// Ela usa Int32List.sublistView. Ao passar para Isolate.run, o Dart tenta otimizar a transferência. Mesmo com cópia, para resoluções grandes (ex: 1080p), o ganho de usar 4-8 cores compensa o custo da cópia do buffer de células.
// O resultado volta como Uint32List (os pixels prontos), que são montados no buffer principal.
// Configuração:
// Basta alterar RasterizerConfig(useSimd: false, useIsolates: false) para voltar ao comportamento serial escalar puro, facilitando testes A/B de performance.

/// Configuração para controlar otimizações.
class RasterizerConfig {
  final bool useSimd;
  final bool useIsolates;
  final int tileHeight; // Altura da fatia para processamento paralelo

  const RasterizerConfig({
    this.useSimd = true,
    this.useIsolates = true,
    this.tileHeight = 64, // Ajuste conforme necessário
  });
}

class Blend2DRasterizer {
  final int width;
  final int height;
  final RasterizerConfig config;

  // Structure of Arrays (SoA) para facilitar SIMD
  // Ao invés de intercalar [cover, area], separamos.
  late final Int32List _covers;
  late final Int32List _areas;

  // Framebuffer final
  late final Uint32List _framebuffer;

  // Regra de preenchimento: 0 = Even-Odd, 1 = Non-Zero
  int fillRule = 1;

  // Constantes de ponto fixo
  static const int kCovShift =
      8; // Reduzido para 8 para caber melhor em mul 32bit
  static const int kCovOne = 1 << kCovShift;

  Blend2DRasterizer(this.width, this.height,
      {this.config = const RasterizerConfig()}) {
    int size = width * height;
    _covers = Int32List(size);
    _areas = Int32List(size);
    _framebuffer = Uint32List(size);
  }

  void clear([int backgroundColor = 0xFFFFFFFF]) {
    // FillRange é altamente otimizado na VM
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
    _covers.fillRange(0, _covers.length, 0);
    _areas.fillRange(0, _areas.length, 0);
  }

  Future<void> drawPolygon(List<double> vertices, int color) async {
    if (vertices.length < 6) return;

    // Fase 1: Geometria (Rápida, mantida na thread principal)
    // Paralelizar isso é complexo devido à natureza sequencial das arestas
    final n = vertices.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      _rasterizeEdge(
        vertices[i * 2],
        vertices[i * 2 + 1],
        vertices[j * 2],
        vertices[j * 2 + 1],
      );
    }

    // Fase 2: Resolução (O gargalo, onde aplicamos SIMD e Isolates)
    await _resolve(color);
  }

  void _rasterizeEdge(double x0, double y0, double x1, double y1) {
    if (math.max(y0, y1) < 0 || math.min(y0, y1) >= height) return;

    int dir = 1;
    if (y0 > y1) {
      double t = x0;
      x0 = x1;
      x1 = t;
      t = y0;
      y0 = y1;
      y1 = t;
      dir = -1;
    }

    double yClip0 = math.max(0.0, y0);
    double yClip1 = math.min(height.toDouble(), y1);
    if (yClip0 >= yClip1) return;

    double dxdy = (x1 - x0) / (y1 - y0);
    if (y0 < yClip0) {
      x0 += dxdy * (yClip0 - y0);
      y0 = yClip0;
    }

    int yStart = y0.floor();
    int yEnd = (yClip1 - 0.00001).floor(); // Evita arredondamento excessivo

    double currentX = x0;

    for (int y = yStart; y <= yEnd; y++) {
      double nextY = math.min((y + 1).toDouble(), yClip1);
      double dy = nextY - y0;
      double nextX = currentX + dxdy * dy;

      _addSegment(y, currentX, y0 - y, nextX, nextY - y, dir);

      currentX = nextX;
      y0 = nextY;
    }
  }

  void _addSegment(int y, double x0, double y0, double x1, double y1, int dir) {
    double dy = (y1 - y0);
    int distY = (dy * kCovOne).toInt() * dir;
    if (distY == 0) return;

    // Otimização: Aresta vertical simples alinhada
    int ix0 = x0.floor();
    int ix1 = x1.floor();

    // Clipping horizontal simples
    if (ix0 < 0) ix0 = 0;
    if (ix0 >= width) ix0 = width - 1;
    if (ix1 < 0) ix1 = 0;
    if (ix1 >= width) ix1 = width - 1;

    int rowOffset = y * width;

    if (ix0 == ix1) {
      // Mesmo pixel
      double xAvg = (x0 + x1) * 0.5 - ix0; // Local x [0..1]
      // Área trapezoidal: Altura * LarguraMédia
      // Aqui usamos a fórmula simplificada do Blend2D: Area += dy * (x0 + x1 - 2*ix) * 0.5
      // Mas para manter compatibilidade com sua lógica anterior:
      int areaVal =
          (distY * (xAvg * kCovOne)).toInt() >> kCovShift; // Ajuste de escala

      _covers[rowOffset + ix0] += distY;
      _areas[rowOffset + ix0] += areaVal;
    } else {
      // Cruza múltiplos pixels: algoritmo de atravessamento de células para evitar artefatos (serrilhados)
      final double dx = x1 - x0;
      final int step = ix1 > ix0 ? 1 : -1;
      double borderX = (step > 0) ? (ix0 + 1).toDouble() : ix0.toDouble();

      double currX0 = x0;
      int currIX = ix0;

      // Usamos acumuladores de ponto fixo para evitar erro de arredondamento (winding error)
      int currYFixed = ((y0 - y) * kCovOne).toInt();

      while (currIX != ix1) {
        // Intersecção com a próxima borda vertical
        final double t = (borderX - x0) / dx;
        final double nextY = y0 + t * (y1 - y0);

        final int nextYFixed = ((nextY - y) * kCovOne).toInt();
        final int distYLocal = (nextYFixed - currYFixed) * dir;
        currYFixed = nextYFixed;

        final double xAvgLocal = (currX0 + borderX) * 0.5 - currIX;
        final int areaValLocal =
            (distYLocal * (xAvgLocal * kCovOne)).toInt() >> kCovShift;

        _covers[rowOffset + currIX] += distYLocal;
        _areas[rowOffset + currIX] += areaValLocal;

        currX0 = borderX;
        currIX += step;
        borderX += step;
      }

      // Último pixel da série
      final int lastYFixed = ((y1 - y) * kCovOne).toInt();
      final int distYLocal = (lastYFixed - currYFixed) * dir;
      final double xAvgLocal = (currX0 + x1) * 0.5 - ix1;
      final int areaValLocal =
          (distYLocal * (xAvgLocal * kCovOne)).toInt() >> kCovShift;

      _covers[rowOffset + ix1] += distYLocal;
      _areas[rowOffset + ix1] += areaValLocal;
    }
  }

  /// Orquestrador da renderização final
  Future<void> _resolve(int color) async {
    if (config.useIsolates && height > config.tileHeight) {
      await _resolveParallel(color);
    } else {
      _resolveSerial(color);
    }
  }

  void _resolveSerial(int color) {
    _resolveSlice(ResolveSliceDTO(
      width: width,
      startLine: 0,
      endLine: height,
      covers: _covers,
      areas: _areas,
      framebuffer: _framebuffer, // Passa referência direta no serial
      color: color,
      fillRule: fillRule,
      useSimd: config.useSimd,
    ));
  }

  Future<void> _resolveParallel(int color) async {
    List<Future<Uint32List>> futures = [];
    int numSlices = (height + config.tileHeight - 1) ~/ config.tileHeight;

    for (int i = 0; i < numSlices; i++) {
      int startY = i * config.tileHeight;
      int endY = math.min(startY + config.tileHeight, height);
      int length = (endY - startY) * width;
      int startOffset = startY * width;

      // Cria cópias das fatias.
      // Nota: Em Dart Isolate.run, a cópia é inevitável a menos que usemos ponteiros externos (FFI).
      // Porém, Isolate.run com tipos básicos é altamente otimizado.
      var sliceCovers =
          Int32List.sublistView(_covers, startOffset, startOffset + length);
      var sliceAreas =
          Int32List.sublistView(_areas, startOffset, startOffset + length);

      // Prepara a fatia do framebuffer atual para blending
      var sliceFb = Uint32List.sublistView(_framebuffer, startOffset, startOffset + length);

      // Dispara o Isolate
    futures.add(Isolate.run(() {
      // Criar uma cópia local para o Isolate trabalhar.
      // Usamos Uint32List.fromList para manter o que já foi desenhado (composição).
      final localFb = Uint32List.fromList(sliceFb);

      _resolveSlice(ResolveSliceDTO(
        width: width,
        startLine: 0,
        endLine: endY - startY,
        covers: sliceCovers,
        areas: sliceAreas,
        framebuffer: localFb,
        color: color,
        fillRule: fillRule,
        useSimd: config.useSimd,
      ));
      return localFb;
    }));
  }

  final results = await Future.wait(futures);

  // Remonta o framebuffer principal
  int currentOffset = 0;
  for (var chunk in results) {
    _framebuffer.setAll(currentOffset, chunk);
    currentOffset += chunk.length;
  }

  // CORREÇÃO: Limpeza dos Buffers Originais (Corrige o "Retângulo Furado")
  // .fillRange é extremamente rápido.
  _covers.fillRange(0, _covers.length, 0);
  _areas.fillRange(0, _areas.length, 0);
}

  /// Função estática que executa a lógica de resolve.
  /// Pode rodar na main thread ou em um Isolate.
  static void _resolveSlice(ResolveSliceDTO dto) {
    if (dto.useSimd) {
      _resolveSimd(dto);
    } else {
      _resolveScalar(dto);
    }
  }

  // --- IMPLEMENTAÇÃO ESCALAR ALTAMENTE OTIMIZADA ---
  static void _resolveScalar(ResolveSliceDTO dto) {
    final int width = dto.width;
    final int height = dto.endLine; // endLine aqui é o número de linhas na fatia
    final Int32List covers = dto.covers;
    final Int32List areas = dto.areas;
    final Uint32List fb = dto.framebuffer;
    final int color = dto.color;
    final int fillRule = dto.fillRule;

    final int r = (color >> 16) & 0xFF;
    final int g = (color >> 8) & 0xFF;
    final int b = color & 0xFF;
    final int a = (color >> 24) & 0xFF;

    final int simdLimit = width & ~3;

    for (int y = 0; y < height; y++) {
      int coverAcc = 0;
      final int rowOffset = y * width;

      int x = 0;
      for (; x < simdLimit; x += 4) {
        // Pixel 0
        {
          final int idx = rowOffset + x;
          final int cv = covers[idx];
          final int ar = areas[idx];
          // Limpa o buffer para a próxima chamada de drawPolygon
          covers[idx] = 0;
          areas[idx] = 0;

          final int coverage = coverAcc + cv - ar;
          coverAcc += cv;
          if (coverage != 0 || ar != 0) {
            final int mask = coverage >> 31;
            int absCover = (coverage ^ mask) - mask;
            if (fillRule == 0) {
              absCover &= (kCovOne * 2) - 1;
              if (absCover > kCovOne) absCover = (kCovOne * 2) - absCover;
            }
            int alpha = (absCover * 255) >> kCovShift;
            if (alpha > 0) {
              if (alpha > 255) alpha = 255;
              final int fAlpha = (a == 255) ? alpha : (alpha * a) >> 8;
              if (fAlpha > 0) {
                final int bg = fb[idx];
                final int bgR = (bg >> 16) & 0xFF;
                final int bgG = (bg >> 8) & 0xFF;
                final int bgB = bg & 0xFF;
                fb[idx] = 0xFF000000 |
                    (((bgR + (((r - bgR) * fAlpha) >> 8)) & 0xFF) << 16) |
                    (((bgG + (((g - bgG) * fAlpha) >> 8)) & 0xFF) << 8) |
                    ((bgB + (((b - bgB) * fAlpha) >> 8)) & 0xFF);
              }
            }
          }
        }
        // Pixel 1
        {
          final int idx = rowOffset + x + 1;
          final int cv = covers[idx];
          final int ar = areas[idx];
          // Limpa o buffer
          covers[idx] = 0;
          areas[idx] = 0;

          final int coverage = coverAcc + cv - ar;
          coverAcc += cv;
          if (coverage != 0 || ar != 0) {
            final int mask = coverage >> 31;
            int absCover = (coverage ^ mask) - mask;
            if (fillRule == 0) {
              absCover &= (kCovOne * 2) - 1;
              if (absCover > kCovOne) absCover = (kCovOne * 2) - absCover;
            }
            int alpha = (absCover * 255) >> kCovShift;
            if (alpha > 0) {
              if (alpha > 255) alpha = 255;
              final int fAlpha = (a == 255) ? alpha : (alpha * a) >> 8;
              if (fAlpha > 0) {
                final int bg = fb[idx];
                final int bgR = (bg >> 16) & 0xFF;
                final int bgG = (bg >> 8) & 0xFF;
                final int bgB = bg & 0xFF;
                fb[idx] = 0xFF000000 |
                    (((bgR + (((r - bgR) * fAlpha) >> 8)) & 0xFF) << 16) |
                    (((bgG + (((g - bgG) * fAlpha) >> 8)) & 0xFF) << 8) |
                    ((bgB + (((b - bgB) * fAlpha) >> 8)) & 0xFF);
              }
            }
          }
        }
        // Pixel 2
        {
          final int idx = rowOffset + x + 2;
          final int cv = covers[idx];
          final int ar = areas[idx];
          // Limpa o buffer
          covers[idx] = 0;
          areas[idx] = 0;

          final int coverage = coverAcc + cv - ar;
          coverAcc += cv;
          if (coverage != 0 || ar != 0) {
            final int mask = coverage >> 31;
            int absCover = (coverage ^ mask) - mask;
            if (fillRule == 0) {
              absCover &= (kCovOne * 2) - 1;
              if (absCover > kCovOne) absCover = (kCovOne * 2) - absCover;
            }
            int alpha = (absCover * 255) >> kCovShift;
            if (alpha > 0) {
              if (alpha > 255) alpha = 255;
              final int fAlpha = (a == 255) ? alpha : (alpha * a) >> 8;
              if (fAlpha > 0) {
                final int bg = fb[idx];
                final int bgR = (bg >> 16) & 0xFF;
                final int bgG = (bg >> 8) & 0xFF;
                final int bgB = bg & 0xFF;
                fb[idx] = 0xFF000000 |
                    (((bgR + (((r - bgR) * fAlpha) >> 8)) & 0xFF) << 16) |
                    (((bgG + (((g - bgG) * fAlpha) >> 8)) & 0xFF) << 8) |
                    ((bgB + (((b - bgB) * fAlpha) >> 8)) & 0xFF);
              }
            }
          }
        }
        // Pixel 3
        {
          final int idx = rowOffset + x + 3;
          final int cv = covers[idx];
          final int ar = areas[idx];
          // Limpa o buffer
          covers[idx] = 0;
          areas[idx] = 0;

          final int coverage = coverAcc + cv - ar;
          coverAcc += cv;
          if (coverage != 0 || ar != 0) {
            final int mask = coverage >> 31;
            int absCover = (coverage ^ mask) - mask;
            if (fillRule == 0) {
              absCover &= (kCovOne * 2) - 1;
              if (absCover > kCovOne) absCover = (kCovOne * 2) - absCover;
            }
            int alpha = (absCover * 255) >> kCovShift;
            if (alpha > 0) {
              if (alpha > 255) alpha = 255;
              final int fAlpha = (a == 255) ? alpha : (alpha * a) >> 8;
              if (fAlpha > 0) {
                final int bg = fb[idx];
                final int bgR = (bg >> 16) & 0xFF;
                final int bgG = (bg >> 8) & 0xFF;
                final int bgB = bg & 0xFF;
                fb[idx] = 0xFF000000 |
                    (((bgR + (((r - bgR) * fAlpha) >> 8)) & 0xFF) << 16) |
                    (((bgG + (((g - bgG) * fAlpha) >> 8)) & 0xFF) << 8) |
                    ((bgB + (((b - bgB) * fAlpha) >> 8)) & 0xFF);
              }
            }
          }
        }
      }

      for (; x < width; x++) {
        final int idx = rowOffset + x;
        final int cv = covers[idx];
        final int ar = areas[idx];
        // Limpa o buffer
        covers[idx] = 0;
        areas[idx] = 0;

        final int coverage = coverAcc + cv - ar;
        coverAcc += cv;
        if (coverage != 0 || ar != 0) {
          final int mask = coverage >> 31;
          int absCover = (coverage ^ mask) - mask;
          if (fillRule == 0) {
            absCover &= (kCovOne * 2) - 1;
            if (absCover > kCovOne) absCover = (kCovOne * 2) - absCover;
          }
          int alpha = (absCover * 255) >> kCovShift;
          if (alpha > 0) {
            if (alpha > 255) alpha = 255;
            final int fAlpha = (a == 255) ? alpha : (alpha * a) >> 8;
            if (fAlpha > 0) {
              final int bg = fb[idx];
              final int bgR = (bg >> 16) & 0xFF;
              final int bgG = (bg >> 8) & 0xFF;
              final int bgB = bg & 0xFF;
              fb[idx] = 0xFF000000 |
                  (((bgR + (((r - bgR) * fAlpha) >> 8)) & 0xFF) << 16) |
                  (((bgG + (((g - bgG) * fAlpha) >> 8)) & 0xFF) << 8) |
                  ((bgB + (((b - bgB) * fAlpha) >> 8)) & 0xFF);
            }
          }
        }
      }
    }
  }

  // --- IMPLEMENTAÇÃO SIMD ---
  static void _resolveSimd(ResolveSliceDTO dto) {
    final int stride = dto.width;

    // Extração de canais de cor (Fonte)
    final int r = (dto.color >> 16) & 0xFF;
    final int g = (dto.color >> 8) & 0xFF;
    final int b = dto.color & 0xFF;
    final int a = (dto.color >> 24) & 0xFF;

    // Constantes SIMD
    final v255F = Float32x4.splat(255.0);
    final vInv256F = Float32x4.splat(1.0 / 256.0); // Pré-calculado
    final vZeroF = Float32x4.zero();

    final int simdLimit = stride & ~3;

    // Views
    final coverView = dto.covers.buffer.asInt32x4List(
        dto.covers.offsetInBytes, dto.covers.lengthInBytes ~/ 16);
    final areaView = dto.areas.buffer.asInt32x4List(
        dto.areas.offsetInBytes, dto.areas.lengthInBytes ~/ 16);
    // Acesso direto ao array de pixels para evitar getters/setters repetidos
    final fb = dto.framebuffer;

    for (int y = 0; y < dto.endLine; y++) {
      int coverAcc = 0;
      int rowOffset = y * stride;
      int rowSimdIdx = rowOffset >> 2;

      for (int x = 0; x < simdLimit; x += 4) {
        Int32x4 vCov = coverView[rowSimdIdx];
        Int32x4 vArea = areaView[rowSimdIdx];

        // Limpa o buffer original para a próxima chamada de drawPolygon
        // Como o coverView é uma view do Int32List, isso limpa os dados na memória central
        coverView[rowSimdIdx] = Int32x4(0, 0, 0, 0);
        areaView[rowSimdIdx] = Int32x4(0, 0, 0, 0);

        // 1. Acumulação Serial (Inevitável)
        // Extração manual é rápida em Dart (JIT/AOT otimizam bem)
        int c0 = vCov.x;
        int c1 = vCov.y;
        int c2 = vCov.z;
        int c3 = vCov.w;

        int cov0 = coverAcc + c0;
        int cov1 = cov0 + c1;
        int cov2 = cov1 + c2;
        int cov3 = cov2 + c3;

        coverAcc = cov3;

        // 2. Cálculo Paralelo do Alpha (Usando Float32x4)
        // Subtração da área
        final vCoverageF = Float32x4(
            (cov0 - vArea.x).toDouble(),
            (cov1 - vArea.y).toDouble(),
            (cov2 - vArea.z).toDouble(),
            (cov3 - vArea.w).toDouble());

        // Regra Non-Zero e Escala
        // Usa .abs() nativo da API
        var vAlphaF = vCoverageF.abs() * v255F * vInv256F;

        // Clamp 0..255
        vAlphaF = vAlphaF.min(v255F).max(vZeroF);

        // Otimização "Early Exit": Se todos os alphas forem quase zero, pula
        // Verificamos a "signMask" ou comparação manual.
        // Como convertemos para double, verificação manual é segura.
        if (vAlphaF.x < 1.0 &&
            vAlphaF.y < 1.0 &&
            vAlphaF.z < 1.0 &&
            vAlphaF.w < 1.0) {
          rowSimdIdx++;
          continue;
        }

        // 3. Blending (Serial Inlined)
        // Inlined para evitar overhead de chamada de método _blendIf/_blendPixel
        // O compilador Dart fará Loop Unrolling aqui.

        // Pixel 0
        int alphaInt = vAlphaF.x.toInt();
        if (alphaInt > 0) {
          int idx = rowOffset + x;
          int bg = fb[idx];
          // alphaInt * a -> combina opacidade do pixel com opacidade da cor
          int finalAlpha = (alphaInt * a) >> 8;
          int invAlpha = 255 - finalAlpha;

          // Mistura
          int outR = (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          int outG = (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;

          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        // Pixel 1
        alphaInt = vAlphaF.y.toInt();
        if (alphaInt > 0) {
          int idx = rowOffset + x + 1;
          int bg = fb[idx];
          int finalAlpha = (alphaInt * a) >> 8;
          int invAlpha = 255 - finalAlpha;
          int outR = (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          int outG = (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;
          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        // Pixel 2
        alphaInt = vAlphaF.z.toInt();
        if (alphaInt > 0) {
          int idx = rowOffset + x + 2;
          int bg = fb[idx];
          int finalAlpha = (alphaInt * a) >> 8;
          int invAlpha = 255 - finalAlpha;
          int outR = (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          int outG = (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;
          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        // Pixel 3
        alphaInt = vAlphaF.w.toInt();
        if (alphaInt > 0) {
          int idx = rowOffset + x + 3;
          int bg = fb[idx];
          int finalAlpha = (alphaInt * a) >> 8;
          int invAlpha = 255 - finalAlpha;
          int outR = (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          int outG = (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;
          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        rowSimdIdx++;
      }

      // Cleanup de pixels restantes
      for (int x = simdLimit; x < stride; x++) {
        int idx = rowOffset + x;
        int cv = dto.covers[idx];
        int ar = dto.areas[idx];

        // Limpa o buffer
        dto.covers[idx] = 0;
        dto.areas[idx] = 0;

        int coverage = coverAcc + cv - ar;
        coverAcc += cv;

        int alpha = (coverage.abs() * 255) >> kCovShift;
        if (alpha > 255) alpha = 255;
        if (alpha > 0) {
          _blendPixel(dto.framebuffer, idx, r, g, b, a, alpha);
        }
      }
    }
  }

  static void _blendPixel(
      Uint32List fb, int idx, int r, int g, int b, int a, int alpha) {
    int bg = fb[idx];
    int finalAlpha = (alpha * a) >> 8;
    int invAlpha = 255 - finalAlpha;

    int outR = (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
    int outG = (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
    int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;

    fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
  }

  Uint32List get buffer => _framebuffer;
}

/// DTO para passar dados aos Isolates de forma eficiente
class ResolveSliceDTO {
  final int width;
  final int startLine;
  final int endLine;
  final Int32List covers;
  final Int32List areas;
  final Uint32List framebuffer;
  final int color;
  final int fillRule;
  final bool useSimd;

  ResolveSliceDTO({
    required this.width,
    required this.startLine,
    required this.endLine,
    required this.covers,
    required this.areas,
    required this.framebuffer,
    required this.color,
    required this.fillRule,
    required this.useSimd,
  });
}
