// C:\MyDartProjects\marlin\lib\src\rasterization_algorithms\blend2d\blend2d_rasterizer2.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io' show Platform;

/// BLEND2D-like Rasterizer for Dart (CPU, console/desktop/server)
///
/// Principais mudanças (estilo Blend2D):
/// - Batch/Flush: addPolygon() acumula; flush() resolve uma vez (ou por dirty-tiles).
/// - Tiling por Y: cada tile guarda covers/areas/fb próprios (boa localidade).
/// - Isolate pool persistente: nada de Isolate.run por slice.
/// - Resolve só nos tiles sujos; limpeza acontece durante resolve.
///
/// Observações:
/// - Isolates NÃO compartilham memória diretamente. Aqui evitamos overhead de spawn
///   usando pool persistente, e reduzimos trabalho processando apenas tiles sujos.
/// - Para "zero-copy real" estilo C++ (Blend2D), o próximo passo é FFI/shared memory.
///   Mas este design já remove os maiores gargalos do seu benchmark atual.

class RasterizerConfig2 {
  /// Usa caminho SIMD (quando possível).
  final bool useSimd;

  /// Usa isolates para acelerar o resolve em tiles.
  final bool useIsolates;

  /// Altura do tile (faixas horizontais). 64/128 costuma ser bom.
  /// Em imagens grandes (ex 1080p/4K), 64 ou 128 normalmente dá boa localidade.
  final int tileHeight;

  /// Quantos isolates no pool.
  /// Se <= 0, usa (numProc - 1) com mínimo 1.
  final int isolateCount;

  /// Não vale a pena paralelizar se a região suja for muito pequena.
  /// Ex: 256 linhas.
  final int minParallelDirtyHeight;

  const RasterizerConfig2({
    this.useSimd = true,
    this.useIsolates = true,
    this.tileHeight = 64,
    this.isolateCount = 0,
    this.minParallelDirtyHeight = 256,
  });
}

class Blend2DRasterizer2 {
  final int width;
  final int height;
  final RasterizerConfig2 config;

  /// Regra de preenchimento: 0 = Even-Odd, 1 = Non-Zero
  int fillRule = 1;

  /// Constantes de ponto fixo (cobertura)
  static const int kCovShift = 8;
  static const int kCovOne = 1 << kCovShift;

  late final List<_Tile> _tiles;

  // Buffer composto (apenas para exportar/ler).
  // Internamente o desenho fica nos framebuffers por-tile.
  Uint32List? _compositedBuffer;

  // Dirty tracking
  bool _hasDirty = false;
  int _dirtyMinY = 1 << 30;
  int _dirtyMaxY = -1;

  // Pool de isolates
  _IsolatePool? _pool;
  bool _poolInitTried = false;

  Blend2DRasterizer2(
    this.width,
    this.height, {
    this.config = const RasterizerConfig2(),
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height inválidos: $width x $height');
    }

    final int th = math.max(1, config.tileHeight);
    _tiles = <_Tile>[];

    for (int startY = 0; startY < height; startY += th) {
      final int tileH = math.min(th, height - startY);
      _tiles.add(_Tile(
        startY: startY,
        height: tileH,
        width: width,
      ));
    }

    clear(0xFFFFFFFF);
  }

  /// Limpa framebuffer e buffers de cobertura/área.
  void clear([int backgroundColor = 0xFFFFFFFF]) {
    for (final t in _tiles) {
      t.fb.fillRange(0, t.fb.length, backgroundColor);
      t.covers.fillRange(0, t.covers.length, 0);
      t.areas.fillRange(0, t.areas.length, 0);
      t.dirty = false;
    }
    _hasDirty = false;
    _dirtyMinY = 1 << 30;
    _dirtyMaxY = -1;
    _compositedBuffer = null;
  }

  /// API estilo Blend2D: acumula geometria, não faz resolve.
  void addPolygon(List<double> vertices) {
    if (vertices.length < 6) return;

    final n = vertices.length ~/ 2;
    double area2 = 0.0;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      area2 += vertices[i * 2] * vertices[j * 2 + 1] -
          vertices[j * 2] * vertices[i * 2 + 1];
    }

    // Normaliza winding para evitar cancelamento entre polígonos sobrepostos
    // no modo batch (os testes usam composição "over" com mesma cor).
    final reverse = area2 > 0.0;

    if (!reverse) {
      for (int i = 0; i < n; i++) {
        final j = (i + 1) % n;
        _rasterizeEdge(
          vertices[i * 2],
          vertices[i * 2 + 1],
          vertices[j * 2],
          vertices[j * 2 + 1],
        );
      }
    } else {
      for (int i = 0; i < n; i++) {
        final idx = n - 1 - i;
        final jdx = (idx - 1 + n) % n;
        _rasterizeEdge(
          vertices[idx * 2],
          vertices[idx * 2 + 1],
          vertices[jdx * 2],
          vertices[jdx * 2 + 1],
        );
      }
    }
  }

  /// Compatibilidade: opcionalmente faz flush imediato.
  /// Para estilo Blend2D, use flushNow=false e chame flush() uma vez no final.
  Future<void> drawPolygon(
    List<double> vertices,
    int color, {
    bool flushNow = true,
  }) async {
    addPolygon(vertices);
    if (flushNow) {
      await flush(color);
    }
  }

  /// Resolve (composição) apenas a região suja acumulada desde o último flush.
  Future<void> flush(int color) async {
    if (!_hasDirty) return;

    final int dirtyH = (_dirtyMaxY - _dirtyMinY + 1).clamp(0, height);
    if (dirtyH <= 0) {
      _resetDirty();
      return;
    }

    // Determina tiles afetados
    final int th = math.max(1, config.tileHeight);
    final int minTile = (_dirtyMinY ~/ th).clamp(0, _tiles.length - 1);
    final int maxTile = (_dirtyMaxY ~/ th).clamp(0, _tiles.length - 1);

    // SIMD com even-odd fica caro/complexo; aqui garantimos correção.
    final bool canUseSimd = config.useSimd && (fillRule == 1);

    // Decide serial vs parallel
    final bool shouldParallel = config.useIsolates &&
        dirtyH >= config.minParallelDirtyHeight &&
        (maxTile - minTile + 1) >= 2;

    if (!shouldParallel) {
      for (int i = minTile; i <= maxTile; i++) {
        final tile = _tiles[i];
        if (!tile.dirty) continue;

        _resolveTileSerial(
          tile: tile,
          color: color,
          fillRule: fillRule,
          useSimd: canUseSimd,
        );

        tile.dirty = false;
      }
      _resetDirty();
      _compositedBuffer = null;
      return;
    }

    // Paralelo com pool persistente
    await _ensurePool();
    final pool = _pool;
    if (pool == null) {
      // fallback serial se pool não puder ser criado
      for (int i = minTile; i <= maxTile; i++) {
        final tile = _tiles[i];
        if (!tile.dirty) continue;

        _resolveTileSerial(
          tile: tile,
          color: color,
          fillRule: fillRule,
          useSimd: canUseSimd,
        );

        tile.dirty = false;
      }
      _resetDirty();
      _compositedBuffer = null;
      return;
    }

    final futures = <Future<_TileResult>>[];
    for (int i = minTile; i <= maxTile; i++) {
      final tile = _tiles[i];
      if (!tile.dirty) continue;

      futures.add(pool.runTile(_TileJob(
        tileIndex: i,
        width: width,
        height: tile.height,
        color: color,
        fillRule: fillRule,
        useSimd: canUseSimd,
        covers: tile.covers,
        areas: tile.areas,
        fb: tile.fb,
      )));
    }

    final results = await Future.wait(futures);

    // Aplica resultados (buffers retornam “novos” após transferência)
    for (final r in results) {
      final tile = _tiles[r.tileIndex];
      tile.covers = r.covers;
      tile.areas = r.areas;
      tile.fb = r.fb;
      tile.dirty = false;
    }

    _resetDirty();
    _compositedBuffer = null;
  }

  /// Libera isolates do pool.
  Future<void> dispose() async {
    final p = _pool;
    _pool = null;
    if (p != null) {
      await p.close();
    }
  }

  /// Buffer final composto 0xAARRGGBB (ARGB).
  /// (Composição é feita sob demanda a partir dos tiles.)
  Uint32List get buffer {
    final out = _compositedBuffer ??= Uint32List(width * height);
    int offset = 0;
    for (final t in _tiles) {
      out.setAll(offset, t.fb);
      offset += t.fb.length;
    }
    return out;
  }

  // ===========================================================================
  // Rasterização de arestas (acumula covers/areas por tile)
  // ===========================================================================

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

    final double invDy = 1.0 / (y1 - y0);
    final double dxdy = (x1 - x0) * invDy;

    if (y0 < yClip0) {
      x0 += dxdy * (yClip0 - y0);
      y0 = yClip0;
    }

    int yStart = y0.floor();
    int yEnd = (yClip1 - 0.00001).floor();

    double currentX = x0;

    for (int y = yStart; y <= yEnd; y++) {
      final double nextY = math.min((y + 1).toDouble(), yClip1);
      final double dy = nextY - y0;
      final double nextX = currentX + dxdy * dy;

      _addSegment(y, currentX, y0 - y, nextX, nextY - y, dir);

      currentX = nextX;
      y0 = nextY;
    }
  }

  void _addSegment(int y, double x0, double y0, double x1, double y1, int dir) {
    if (y < 0 || y >= height) return;

    final double dy = (y1 - y0);
    final int distY = (dy * kCovOne).toInt() * dir;
    if (distY == 0) return;

    _markDirtyLine(y);

    int ix0 = x0.floor();
    int ix1 = x1.floor();

    if (ix0 < 0) ix0 = 0;
    if (ix0 >= width) ix0 = width - 1;
    if (ix1 < 0) ix1 = 0;
    if (ix1 >= width) ix1 = width - 1;

    final _Tile tile = _tileForY(y);
    final int localY = y - tile.startY;
    final int rowOffset = localY * width;

    if (ix0 == ix1) {
      final double xAvg = (x0 + x1) * 0.5 - ix0;
      final int areaVal = (distY * (xAvg * kCovOne)).toInt() >> kCovShift;

      final int idx = rowOffset + ix0;
      tile.covers[idx] += distY;
      tile.areas[idx] += areaVal;
      return;
    }

    final double dx = x1 - x0;
    final int step = ix1 > ix0 ? 1 : -1;
    double borderX = (step > 0) ? (ix0 + 1).toDouble() : ix0.toDouble();

    double currX0 = x0;
    int currIX = ix0;

    int currYFixed =
        ((y0) * kCovOne).toInt(); // y0 já é relativo à linha (0..1)

    while (currIX != ix1) {
      final double t = (borderX - x0) / dx;
      final double nextY = y0 + t * (y1 - y0);

      final int nextYFixed = ((nextY) * kCovOne).toInt();
      final int distYLocal = (nextYFixed - currYFixed) * dir;
      currYFixed = nextYFixed;

      final double xAvgLocal = (currX0 + borderX) * 0.5 - currIX;
      final int areaValLocal =
          (distYLocal * (xAvgLocal * kCovOne)).toInt() >> kCovShift;

      final int idx = rowOffset + currIX;
      tile.covers[idx] += distYLocal;
      tile.areas[idx] += areaValLocal;

      currX0 = borderX;
      currIX += step;
      borderX += step;
    }

    final int lastYFixed = ((y1) * kCovOne).toInt();
    final int distYLocal = (lastYFixed - currYFixed) * dir;
    final double xAvgLocal = (currX0 + x1) * 0.5 - ix1;
    final int areaValLocal =
        (distYLocal * (xAvgLocal * kCovOne)).toInt() >> kCovShift;

    final int lastIdx = rowOffset + ix1;
    tile.covers[lastIdx] += distYLocal;
    tile.areas[lastIdx] += areaValLocal;
  }

  _Tile _tileForY(int y) {
    final int th = math.max(1, config.tileHeight);
    final int idx = (y ~/ th).clamp(0, _tiles.length - 1);
    return _tiles[idx];
  }

  void _markDirtyLine(int y) {
    _hasDirty = true;
    if (y < _dirtyMinY) _dirtyMinY = y;
    if (y > _dirtyMaxY) _dirtyMaxY = y;

    final tile = _tileForY(y);
    tile.dirty = true;
  }

  void _resetDirty() {
    _hasDirty = false;
    _dirtyMinY = 1 << 30;
    _dirtyMaxY = -1;
  }

  Future<void> _ensurePool() async {
    if (_pool != null) return;
    if (_poolInitTried) return;

    _poolInitTried = true;

    // Heurística: numProc - 1 (mínimo 1), ou config.isolateCount.
    int count = config.isolateCount;
    if (count <= 0) {
      final int np = Platform.numberOfProcessors;
      count = math.max(1, np - 1);
    }
    // Evita pool maior que tiles
    count = math.min(count, math.max(1, _tiles.length));

    try {
      _pool = await _IsolatePool.spawn(count);
    } catch (_) {
      _pool = null;
    }
  }

  // ===========================================================================
  // Resolve (Serial)
  // ===========================================================================

  static void _resolveTileSerial({
    required _Tile tile,
    required int color,
    required int fillRule,
    required bool useSimd,
  }) {
    final dto = _ResolveDTO(
      width: tile.width,
      height: tile.height,
      covers: tile.covers,
      areas: tile.areas,
      framebuffer: tile.fb,
      color: color,
      fillRule: fillRule,
      useSimd: useSimd,
    );

    if (dto.useSimd) {
      resolveSimd(dto);
    } else {
      resolveScalar(dto);
    }
  }

  // DTO interno para resolve.
  // fillRule vem do "dono" (Blend2DRasterizer), então cada tile precisa saber.
  // Para simplificar, setamos no getter do tile.
  static void resolveScalar(_ResolveDTO dto) {
    final int width = dto.width;
    final int height = dto.height;
    final Int32List covers = dto.covers;
    final Int32List areas = dto.areas;
    final Uint32List fb = dto.framebuffer;
    final int fillRule = dto.fillRule;

    final int r = (dto.color >> 16) & 0xFF;
    final int g = (dto.color >> 8) & 0xFF;
    final int b = dto.color & 0xFF;
    final int a = (dto.color >> 24) & 0xFF;

    final int simdLimit = width & ~3;

    for (int y = 0; y < height; y++) {
      int coverAcc = 0;
      final int rowOffset = y * width;

      int x = 0;
      for (; x < simdLimit; x += 4) {
        // unroll 4 pixels (igual seu estilo anterior)
        for (int k = 0; k < 4; k++) {
          final int idx = rowOffset + x + k;
          final int cv = covers[idx];
          final int ar = areas[idx];

          // limpa aqui mesmo (sem fillRange global)
          covers[idx] = 0;
          areas[idx] = 0;

          final int coverage = coverAcc + cv - ar;
          coverAcc += cv;

          if (coverage == 0 && ar == 0) continue;

          int absCover = coverage;
          final int mask = absCover >> 31;
          absCover = (absCover ^ mask) - mask;

          if (fillRule == 0) {
            absCover &= (kCovOne * 2) - 1;
            if (absCover > kCovOne) absCover = (kCovOne * 2) - absCover;
          }

          int alpha = (absCover * 255) >> kCovShift;
          if (alpha <= 0) continue;
          if (alpha > 255) alpha = 255;

          final int fAlpha = (a == 255) ? alpha : (alpha * a) >> 8;
          if (fAlpha <= 0) continue;

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

      for (; x < width; x++) {
        final int idx = rowOffset + x;
        final int cv = covers[idx];
        final int ar = areas[idx];

        covers[idx] = 0;
        areas[idx] = 0;

        final int coverage = coverAcc + cv - ar;
        coverAcc += cv;

        if (coverage == 0 && ar == 0) continue;

        int absCover = coverage;
        final int mask = absCover >> 31;
        absCover = (absCover ^ mask) - mask;

        if (fillRule == 0) {
          absCover &= (kCovOne * 2) - 1;
          if (absCover > kCovOne) absCover = (kCovOne * 2) - absCover;
        }

        int alpha = (absCover * 255) >> kCovShift;
        if (alpha <= 0) continue;
        if (alpha > 255) alpha = 255;

        final int fAlpha = (a == 255) ? alpha : (alpha * a) >> 8;
        if (fAlpha <= 0) continue;

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

  // SIMD: mantemos apenas para fillRule Non-Zero (correto e rápido).
  static void resolveSimd(_ResolveDTO dto) {
    final int stride = dto.width;

    final int r = (dto.color >> 16) & 0xFF;
    final int g = (dto.color >> 8) & 0xFF;
    final int b = dto.color & 0xFF;
    final int a = (dto.color >> 24) & 0xFF;

    final v255F = Float32x4.splat(255.0);
    final vScaleF = Float32x4.splat(255.0 / 256.0);
    final vZeroF = Float32x4.zero();

    final int simdLimit = stride & ~3;

    final coverView = dto.covers.buffer.asInt32x4List(
      dto.covers.offsetInBytes,
      dto.covers.lengthInBytes ~/ 16,
    );
    final areaView = dto.areas.buffer.asInt32x4List(
      dto.areas.offsetInBytes,
      dto.areas.lengthInBytes ~/ 16,
    );
    final fb = dto.framebuffer;

    for (int y = 0; y < dto.height; y++) {
      int coverAcc = 0;
      final int rowOffset = y * stride;
      int rowSimdIdx = rowOffset >> 2;

      for (int x = 0; x < simdLimit; x += 4) {
        final Int32x4 vCov = coverView[rowSimdIdx];
        final Int32x4 vArea = areaView[rowSimdIdx];

        // limpa 4 por vez
        coverView[rowSimdIdx] = Int32x4(0, 0, 0, 0);
        areaView[rowSimdIdx] = Int32x4(0, 0, 0, 0);

        final int c0 = vCov.x;
        final int c1 = vCov.y;
        final int c2 = vCov.z;
        final int c3 = vCov.w;

        final int cov0 = coverAcc + c0;
        final int cov1 = cov0 + c1;
        final int cov2 = cov1 + c2;
        final int cov3 = cov2 + c3;
        coverAcc = cov3;

        final Float32x4 vCoverageF = Float32x4(
          (cov0 - vArea.x).toDouble(),
          (cov1 - vArea.y).toDouble(),
          (cov2 - vArea.z).toDouble(),
          (cov3 - vArea.w).toDouble(),
        );

        var vAlphaF = vCoverageF.abs() * vScaleF; // (abs * 255 / 256)
        vAlphaF = vAlphaF.min(v255F).max(vZeroF);

        if (vAlphaF.x < 1.0 &&
            vAlphaF.y < 1.0 &&
            vAlphaF.z < 1.0 &&
            vAlphaF.w < 1.0) {
          rowSimdIdx++;
          continue;
        }

        // blend (serial inlined)
        int alphaInt = vAlphaF.x.toInt();
        if (alphaInt > 0) {
          final int idx = rowOffset + x;
          final int bg = fb[idx];
          final int finalAlpha = (alphaInt * a) >> 8;
          final int invAlpha = 255 - finalAlpha;
          final int outR =
              (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          final int outG =
              (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          final int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;
          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        alphaInt = vAlphaF.y.toInt();
        if (alphaInt > 0) {
          final int idx = rowOffset + x + 1;
          final int bg = fb[idx];
          final int finalAlpha = (alphaInt * a) >> 8;
          final int invAlpha = 255 - finalAlpha;
          final int outR =
              (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          final int outG =
              (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          final int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;
          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        alphaInt = vAlphaF.z.toInt();
        if (alphaInt > 0) {
          final int idx = rowOffset + x + 2;
          final int bg = fb[idx];
          final int finalAlpha = (alphaInt * a) >> 8;
          final int invAlpha = 255 - finalAlpha;
          final int outR =
              (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          final int outG =
              (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          final int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;
          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        alphaInt = vAlphaF.w.toInt();
        if (alphaInt > 0) {
          final int idx = rowOffset + x + 3;
          final int bg = fb[idx];
          final int finalAlpha = (alphaInt * a) >> 8;
          final int invAlpha = 255 - finalAlpha;
          final int outR =
              (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
          final int outG =
              (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
          final int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;
          fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
        }

        rowSimdIdx++;
      }

      // resto escalar (limpa e resolve)
      for (int x = simdLimit; x < stride; x++) {
        final int idx = rowOffset + x;
        final int cv = dto.covers[idx];
        final int ar = dto.areas[idx];
        dto.covers[idx] = 0;
        dto.areas[idx] = 0;

        final int coverage = coverAcc + cv - ar;
        coverAcc += cv;

        int absCover = coverage;
        final int mask = absCover >> 31;
        absCover = (absCover ^ mask) - mask;

        int alpha = (absCover * 255) >> kCovShift;
        if (alpha <= 0) continue;
        if (alpha > 255) alpha = 255;

        _blendPixel(fb, idx, r, g, b, a, alpha);
      }
    }
  }

  static void _blendPixel(
    Uint32List fb,
    int idx,
    int r,
    int g,
    int b,
    int a,
    int alpha,
  ) {
    final int bg = fb[idx];
    final int finalAlpha = (alpha * a) >> 8;
    final int invAlpha = 255 - finalAlpha;

    final int outR = (r * finalAlpha + ((bg >> 16) & 0xFF) * invAlpha) >> 8;
    final int outG = (g * finalAlpha + ((bg >> 8) & 0xFF) * invAlpha) >> 8;
    final int outB = (b * finalAlpha + (bg & 0xFF) * invAlpha) >> 8;

    fb[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
  }
}

// ============================================================================
// Tile + DTOs
// ============================================================================

class _Tile {
  final int startY;
  final int width;
  final int height;

  bool dirty = false;

  // buffers (podem ser substituídos ao voltar do isolate)
  Int32List covers;
  Int32List areas;
  Uint32List fb;

  _Tile({
    required this.startY,
    required this.height,
    required this.width,
  })  : covers = Int32List(width * height),
        areas = Int32List(width * height),
        fb = Uint32List(width * height);
}

class _ResolveDTO {
  final int width;
  final int height;
  final Int32List covers;
  final Int32List areas;
  final Uint32List framebuffer;
  final int color;
  final int fillRule;
  final bool useSimd;

  _ResolveDTO({
    required this.width,
    required this.height,
    required this.covers,
    required this.areas,
    required this.framebuffer,
    required this.color,
    required this.fillRule,
    required this.useSimd,
  });
}

class _TileJob {
  final int tileIndex;
  final int width;
  final int height;
  final int color;
  final int fillRule;
  final bool useSimd;
  final Int32List covers;
  final Int32List areas;
  final Uint32List fb;

  _TileJob({
    required this.tileIndex,
    required this.width,
    required this.height,
    required this.color,
    required this.fillRule,
    required this.useSimd,
    required this.covers,
    required this.areas,
    required this.fb,
  });
}

class _TileResult {
  final int tileIndex;
  final Int32List covers;
  final Int32List areas;
  final Uint32List fb;

  _TileResult({
    required this.tileIndex,
    required this.covers,
    required this.areas,
    required this.fb,
  });
}

// ============================================================================
// Isolate Pool (persistente)
// ============================================================================

class _IsolatePool {
  final List<_Worker> _workers;
  final ReceivePort _rx;
  int _next = 0;
  int _seq = 1;

  final Map<int, Completer<_TileResult>> _pending = {};

  _IsolatePool._(this._workers, this._rx) {
    _rx.listen((msg) {
      if (msg is Map) {
        final int id = msg['id'] as int;
        final completer = _pending.remove(id);
        if (completer == null) return;

        final String? err = msg['err'] as String?;
        if (err != null) {
          // Lança exceção se o worker falhou (melhor que gerar PNG errado)
          completer.completeError(StateError('Tile resolve falhou: $err'));
          return;
        }

        final int tileIndex = msg['tileIndex'] as int;

        final TransferableTypedData tC = msg['covers'] as TransferableTypedData;
        final TransferableTypedData tA = msg['areas'] as TransferableTypedData;
        final TransferableTypedData tF = msg['fb'] as TransferableTypedData;

        final covers = _materializeInt32List(tC);
        final areas = _materializeInt32List(tA);
        final fb = _materializeUint32List(tF);

        completer.complete(_TileResult(
          tileIndex: tileIndex,
          covers: covers,
          areas: areas,
          fb: fb,
        ));
      }
    });
  }

  static Future<_IsolatePool> spawn(int count) async {
    final rx = ReceivePort();
    final workers = <_Worker>[];

    for (int i = 0; i < count; i++) {
      final ready = ReceivePort();
      final isolate = await Isolate.spawn(_workerMain, ready.sendPort);

      final sendPort = await ready.first as SendPort;
      ready.close();

      workers.add(_Worker(isolate, sendPort, rx.sendPort));
    }

    return _IsolatePool._(workers, rx);
  }

  Future<_TileResult> runTile(_TileJob job) {
    final id = _seq++;
    final c = Completer<_TileResult>();
    _pending[id] = c;

    final worker = _workers[_next];
    _next = (_next + 1) % _workers.length;

    worker.send(id, job);
    return c.future;
  }

  Future<void> close() async {
    for (final w in _workers) {
      w.sendControl('close');
    }
    for (final w in _workers) {
      w.isolate.kill(priority: Isolate.immediate);
    }
    _rx.close();
  }

  static Int32List _materializeInt32List(TransferableTypedData t) {
    // materialize() é síncrono no Dart core, mas o await é inofensivo
    // e segue a recomendação do usuário para evitar problemas de race / timing.
    final bd = ByteData.view(t.materialize());
    return bd.buffer.asInt32List(bd.offsetInBytes, bd.lengthInBytes ~/ 4);
  }

  static Uint32List _materializeUint32List(TransferableTypedData t) {
    final bd = ByteData.view(t.materialize());
    return bd.buffer.asUint32List(bd.offsetInBytes, bd.lengthInBytes ~/ 4);
  }
}

TransferableTypedData _ttdFromInt32List(Int32List list) {
  return TransferableTypedData.fromList(<Uint8List>[
    list.buffer.asUint8List(list.offsetInBytes, list.lengthInBytes),
  ]);
}

TransferableTypedData _ttdFromUint32List(Uint32List list) {
  return TransferableTypedData.fromList(<Uint8List>[
    list.buffer.asUint8List(list.offsetInBytes, list.lengthInBytes),
  ]);
}

class _Worker {
  final Isolate isolate;
  final SendPort tx;
  final SendPort replyTo;

  _Worker(this.isolate, this.tx, this.replyTo);

  void send(int id, _TileJob job) {
    tx.send(<String, Object?>{
      'cmd': 'tile',
      'id': id,
      'replyTo': replyTo,
      'tileIndex': job.tileIndex,
      'width': job.width,
      'height': job.height,
      'color': job.color,
      'fillRule': job.fillRule,
      'useSimd': job.useSimd,
      'covers': TransferableTypedData.fromList([
        job.covers.buffer
            .asUint8List(job.covers.offsetInBytes, job.covers.lengthInBytes)
      ]),
      'areas': TransferableTypedData.fromList([
        job.areas.buffer
            .asUint8List(job.areas.offsetInBytes, job.areas.lengthInBytes)
      ]),
      'fb': TransferableTypedData.fromList([
        job.fb.buffer.asUint8List(job.fb.offsetInBytes, job.fb.lengthInBytes)
      ]),
    });
  }

  void sendControl(String cmd) {
    tx.send(<String, Object?>{
      'cmd': cmd,
      'replyTo': replyTo,
      'id': 0,
    });
  }
}

// entrypoint do isolate worker
void _workerMain(SendPort readyPort) {
  final rx = ReceivePort();
  readyPort.send(rx.sendPort);

  rx.listen((msg) async {
    if (msg is! Map) return;

    final String cmd = msg['cmd'] as String? ?? '';
    final SendPort replyTo = msg['replyTo'] as SendPort;

    if (cmd == 'close') {
      rx.close();
      return;
    }

    if (cmd != 'tile') return;

    final int id = msg['id'] as int;
    final int tileIndex = msg['tileIndex'] as int;
    final int width = msg['width'] as int;
    final int height = msg['height'] as int;
    final int color = msg['color'] as int;
    final int fillRule = msg['fillRule'] as int;
    final bool useSimd = msg['useSimd'] as bool;

    try {
      final TransferableTypedData tC = msg['covers'] as TransferableTypedData;
      final TransferableTypedData tA = msg['areas'] as TransferableTypedData;
      final TransferableTypedData tF = msg['fb'] as TransferableTypedData;

      // ✅ Materialize com await conforme solicitado para garantir integridade
      final ByteBuffer coversBuffer = await (tC.materialize() as dynamic);
      final ByteBuffer areasBuffer = await (tA.materialize() as dynamic);
      final ByteBuffer fbBuffer = await (tF.materialize() as dynamic);

      final ByteData coversBd = ByteData.view(coversBuffer);
      final ByteData areasBd = ByteData.view(areasBuffer);
      final ByteData fbBd = ByteData.view(fbBuffer);

      final Int32List covers = coversBd.buffer.asInt32List(
        coversBd.offsetInBytes,
        coversBd.lengthInBytes ~/ 4,
      );
      final Int32List areas = areasBd.buffer.asInt32List(
        areasBd.offsetInBytes,
        areasBd.lengthInBytes ~/ 4,
      );
      final Uint32List fb = fbBd.buffer.asUint32List(
        fbBd.offsetInBytes,
        fbBd.lengthInBytes ~/ 4,
      );

      final bool canSimd = useSimd && (fillRule == 1);

      final dto = _ResolveDTO(
        width: width,
        height: height,
        covers: covers,
        areas: areas,
        framebuffer: fb,
        color: color,
        fillRule: fillRule,
        useSimd: canSimd,
      );

      if (dto.useSimd) {
        Blend2DRasterizer2.resolveSimd(dto);
      } else {
        Blend2DRasterizer2.resolveScalar(dto);
      }

      replyTo.send(<String, Object?>{
        'id': id,
        'tileIndex': tileIndex,
        'covers': _ttdFromInt32List(covers),
        'areas': _ttdFromInt32List(areas),
        'fb': _ttdFromUint32List(fb),
        'err': null,
      });
    } catch (e) {
      replyTo.send(<String, Object?>{
        'id': id,
        'tileIndex': tileIndex,
        'err': 'Worker error: $e',
      });
    }
  });
}
