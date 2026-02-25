import 'dart:math' as math;

import '../core/bl_image.dart';
import '../core/bl_types.dart';
import '../pipeline/bl_fetch_linear_gradient.dart';
import '../pipeline/bl_fetch_pattern.dart';
import '../pipeline/bl_fetch_radial_gradient.dart';
import '../geometry/bl_dasher.dart';
import '../geometry/bl_path.dart';
import '../geometry/bl_stroker.dart';
import '../pipeline/bl_compop_kernel.dart';
import '../pipeline/bl_fetch_solid.dart';
import '../raster/bl_analytic_rasterizer.dart';
import '../text/bl_font.dart';
import '../text/bl_glyph_run.dart';
import '../text/bl_text_layout.dart';

enum _BLFillStyleType {
  solid,
  linearGradient,
  radialGradient,
  pattern,
}

/// Snapshot of context state for save/restore.
///
/// Port of BLContextCore saved state concept from C++ Blend2D.
class _BLContextState {
  final BLCompOp compOp;
  final BLFillRule fillRule;
  final BLSolidFetcher solidFetcher;
  final BLLinearGradientFetcher? linearGradientFetcher;
  final BLRadialGradientFetcher? radialGradientFetcher;
  final BLPatternFetcher? patternFetcher;
  final _BLFillStyleType fillStyleType;
  final BLStrokeOptions strokeOptions;
  final double globalAlpha;
  final BLRectI? clipRect;
  final BLMatrix2D transform;

  _BLContextState({
    required this.compOp,
    required this.fillRule,
    required this.solidFetcher,
    required this.linearGradientFetcher,
    required this.radialGradientFetcher,
    required this.patternFetcher,
    required this.fillStyleType,
    required this.strokeOptions,
    required this.globalAlpha,
    required this.clipRect,
    required this.transform,
  });
}

/// Contexto de desenho do port Blend2D em Dart.
///
/// Expansão da API de contexto com:
/// - save()/restore() para empilhar/desempilhar estado
/// - clipRect para recorte retangular
/// - globalAlpha para transparência global
/// - transform (BLMatrix2D) para transformações afins
/// - Todos os 28 comp-ops do Blend2D C++
///
/// Inspirado em: `blend2d/core/context.h`, `blend2d/core/context.cpp`
class BLContext {
  final BLImage image;
  final BLAnalyticRasterizer _rasterizer;

  BLCompOp compOp = BLCompOp.srcOver;
  BLFillRule fillRule = BLFillRule.nonZero;
  BLSolidFetcher _solidFetcher = BLSolidFetcher(0xFF000000);
  BLLinearGradientFetcher? _linearGradientFetcher;
  BLRadialGradientFetcher? _radialGradientFetcher;
  BLPatternFetcher? _patternFetcher;
  _BLFillStyleType _fillStyleType = _BLFillStyleType.solid;

  /// Opções de stroke (largura, caps, joins) para [strokePath].
  BLStrokeOptions strokeOptions = const BLStrokeOptions();

  /// Transparência global [0.0..1.0]. Applied on top of fill/stroke alpha.
  double globalAlpha = 1.0;

  /// Clip retangular (null = sem clip, usa imagem inteira).
  BLRectI? _clipRect;

  /// Retorna o clip rect corrente (null = sem clip).
  BLRectI? get clipRect => _clipRect;

  /// Transformação afim corrente (identity por padrão).
  BLMatrix2D _transform = BLMatrix2D.identity;

  /// Pilha de estados salvos via [save()].
  final List<_BLContextState> _stateStack = [];

  BLContext(
    this.image, {
    bool useSimd = false,
    bool useIsolates = false,
    int tileHeight = 64,
    int minParallelDirtyHeight = 256,
    int aaSubsampleY = 2,
  }) : _rasterizer = BLAnalyticRasterizer(
          image.width,
          image.height,
          useSimd: useSimd,
          useIsolates: useIsolates,
          tileHeight: tileHeight,
          minParallelDirtyHeight: minParallelDirtyHeight,
          aaSubsampleY: aaSubsampleY,
        );

  // =========================================================================
  // Clear
  // =========================================================================

  void clear([BLColor argb = 0xFFFFFFFF]) {
    image.clear(argb);
    _rasterizer.clear(argb);
  }

  // =========================================================================
  // State save/restore (inspired by BLContextCore saved state)
  // =========================================================================

  /// Salva o estado atual do contexto na pilha.
  /// Retorna a profundidade da pilha após o save.
  int save() {
    _stateStack.add(_BLContextState(
      compOp: compOp,
      fillRule: fillRule,
      solidFetcher: _solidFetcher,
      linearGradientFetcher: _linearGradientFetcher,
      radialGradientFetcher: _radialGradientFetcher,
      patternFetcher: _patternFetcher,
      fillStyleType: _fillStyleType,
      strokeOptions: strokeOptions,
      globalAlpha: globalAlpha,
      clipRect: _clipRect,
      transform: _transform,
    ));
    return _stateStack.length;
  }

  /// Restaura o último estado salvo da pilha.
  /// Retorna true se o restore foi bem sucedido (pilha não vazia).
  bool restore() {
    if (_stateStack.isEmpty) return false;
    final state = _stateStack.removeLast();
    compOp = state.compOp;
    fillRule = state.fillRule;
    _solidFetcher = state.solidFetcher;
    _linearGradientFetcher = state.linearGradientFetcher;
    _radialGradientFetcher = state.radialGradientFetcher;
    _patternFetcher = state.patternFetcher;
    _fillStyleType = state.fillStyleType;
    strokeOptions = state.strokeOptions;
    globalAlpha = state.globalAlpha;
    _clipRect = state.clipRect;
    _transform = state.transform;
    return true;
  }

  /// Profundidade atual da pilha de save/restore.
  int get savedCount => _stateStack.length;

  // =========================================================================
  // Fill style
  // =========================================================================

  void setFillStyle(BLColor argb) {
    _solidFetcher = BLSolidFetcher(argb);
    _fillStyleType = _BLFillStyleType.solid;
    _linearGradientFetcher = null;
    _radialGradientFetcher = null;
    _patternFetcher = null;
  }

  void setLinearGradient(BLLinearGradient gradient) {
    _linearGradientFetcher = BLLinearGradientFetcher(gradient);
    _radialGradientFetcher = null;
    _patternFetcher = null;
    _fillStyleType = _BLFillStyleType.linearGradient;
  }

  void setRadialGradient(BLRadialGradient gradient) {
    _radialGradientFetcher = BLRadialGradientFetcher(gradient);
    _linearGradientFetcher = null;
    _patternFetcher = null;
    _fillStyleType = _BLFillStyleType.radialGradient;
  }

  void setPattern(BLPattern pattern) {
    _patternFetcher = BLPatternFetcher(pattern);
    _linearGradientFetcher = null;
    _radialGradientFetcher = null;
    _fillStyleType = _BLFillStyleType.pattern;
  }

  void setFillRule(BLFillRule rule) {
    fillRule = rule;
  }

  void setCompOp(BLCompOp op) {
    compOp = op;
  }

  // =========================================================================
  // Global alpha
  // =========================================================================

  /// Define a transparência global [0.0..1.0].
  void setGlobalAlpha(double alpha) {
    globalAlpha = alpha.clamp(0.0, 1.0);
  }

  // =========================================================================
  // Clip rect
  // =========================================================================

  /// Define um clip retangular. Todos os draws são limitados a esta região.
  /// Passa `null` para remover o clip.
  void setClipRect(BLRectI? rect) {
    _clipRect = rect;
  }

  /// Intersecta o clip atual com o retângulo dado.
  void clipToRect(BLRectI rect) {
    if (_clipRect == null) {
      _clipRect = rect;
    } else {
      final c = _clipRect!;
      final x0 = math.max(c.x, rect.x);
      final y0 = math.max(c.y, rect.y);
      final x1 = math.min(c.x + c.width, rect.x + rect.width);
      final y1 = math.min(c.y + c.height, rect.y + rect.height);
      if (x1 <= x0 || y1 <= y0) {
        _clipRect = const BLRectI(0, 0, 0, 0); // degenerate clip
      } else {
        _clipRect = BLRectI(x0, y0, x1 - x0, y1 - y0);
      }
    }
  }

  /// Remove o clip (desenhos usam a imagem inteira).
  void resetClip() {
    _clipRect = null;
  }

  // =========================================================================
  // Transform (affine matrix)
  // =========================================================================

  /// Define a transformação afim corrente.
  void setTransform(BLMatrix2D m) {
    _transform = m;
  }

  /// Retorna a transformação afim corrente.
  BLMatrix2D getTransform() => _transform;

  /// Reseta a transformação para identity.
  void resetTransform() {
    _transform = BLMatrix2D.identity;
  }

  /// Aplica translação à transformação corrente.
  void translate(double tx, double ty) {
    // T * M = [1 0; 0 1; tx ty] * M
    _transform = BLMatrix2D(
      _transform.m00,
      _transform.m01,
      _transform.m10,
      _transform.m11,
      _transform.m20 + tx,
      _transform.m21 + ty,
    );
  }

  /// Aplica escala à transformação corrente.
  void scale(double sx, double sy) {
    _transform = BLMatrix2D(
      _transform.m00 * sx,
      _transform.m01 * sy,
      _transform.m10 * sx,
      _transform.m11 * sy,
      _transform.m20 * sx,
      _transform.m21 * sy,
    );
  }

  /// Aplica rotação (em radianos) à transformação corrente.
  void rotate(double angle) {
    final c = math.cos(angle);
    final s = math.sin(angle);
    final m = _transform;
    _transform = BLMatrix2D(
      m.m00 * c + m.m01 * s,
      m.m01 * c - m.m00 * s,
      m.m10 * c + m.m11 * s,
      m.m11 * c - m.m10 * s,
      m.m20 * c + m.m21 * s,
      m.m21 * c - m.m20 * s,
    );
  }

  /// Transforma um ponto (x, y) pela transformação corrente.
  /// Retorna (x', y') = (m00*x + m10*y + m20, m01*x + m11*y + m21).
  (double, double) transformPoint(double x, double y) {
    final m = _transform;
    return (
      m.m00 * x + m.m10 * y + m.m20,
      m.m01 * x + m.m11 * y + m.m21,
    );
  }

  /// Verifica se a transformação corrente é identity (sem transformação).
  bool get isTransformIdentity =>
      _transform.m00 == 1.0 &&
      _transform.m01 == 0.0 &&
      _transform.m10 == 0.0 &&
      _transform.m11 == 1.0 &&
      _transform.m20 == 0.0 &&
      _transform.m21 == 0.0;

  // =========================================================================
  // Fill polygon
  // =========================================================================

  Future<void> fillPolygon(
    List<double> vertices, {
    List<int>? contourVertexCounts,
    BLColor? color,
    BLFillRule? rule,
  }) async {
    final bool useExplicitColor = color != null;
    final drawRule = rule ?? fillRule;
    final gradientFetcher = _linearGradientFetcher;
    final radialFetcher = _radialGradientFetcher;
    final patternFetcher = _patternFetcher;

    // Apply transform to vertices if not identity
    List<double> drawVerts =
        isTransformIdentity ? vertices : _transformVertices(vertices);

    // Apply clip rect — skip drawing if fully outside, clip if partially inside
    if (_clipRect != null) {
      final cr = _clipRect!;
      if (cr.width <= 0 || cr.height <= 0) return;
      // Quick bounding-box check: if all vertices are outside, skip
      double minX = double.infinity, maxX = double.negativeInfinity;
      double minY = double.infinity, maxY = double.negativeInfinity;
      for (int i = 0; i < drawVerts.length; i += 2) {
        final vx = drawVerts[i], vy = drawVerts[i + 1];
        if (vx < minX) minX = vx;
        if (vx > maxX) maxX = vx;
        if (vy < minY) minY = vy;
        if (vy > maxY) maxY = vy;
      }
      if (maxX < cr.x ||
          minX > cr.x + cr.width ||
          maxY < cr.y ||
          minY > cr.y + cr.height) {
        return; // completely outside clip
      }
    }

    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.linearGradient &&
        gradientFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        drawVerts,
        gradientFetcher.fetch,
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
      );
      _syncFromRasterizer();
      return;
    }

    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.radialGradient &&
        radialFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        drawVerts,
        radialFetcher.fetch,
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
      );
      _syncFromRasterizer();
      return;
    }

    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.pattern &&
        patternFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        drawVerts,
        patternFetcher.fetch,
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
      );
      _syncFromRasterizer();
      return;
    }

    int drawColor = color ?? _solidFetcher.fetch();

    // Apply globalAlpha to the color's alpha channel
    if (globalAlpha < 1.0) {
      final srcA = (drawColor >>> 24) & 0xFF;
      final effA = (srcA * globalAlpha + 0.5).toInt().clamp(0, 255);
      drawColor = (effA << 24) | (drawColor & 0x00FFFFFF);
    }

    await _rasterizer.drawPolygon(
      drawVerts,
      drawColor,
      fillRule: drawRule,
      compOp: compOp,
      contourVertexCounts: contourVertexCounts,
    );

    _syncFromRasterizer();
  }

  Future<void> fillPath(
    BLPath path, {
    BLColor? color,
    BLFillRule? rule,
  }) async {
    final data = path.toPathData();
    if (data.vertices.length < 6) return;
    await fillPolygon(
      data.vertices,
      contourVertexCounts: data.contourVertexCounts,
      color: color,
      rule: rule,
    );
  }

  // =========================================================================
  // Fill rect (convenience)
  // =========================================================================

  /// Preenche um retângulo com a cor / estilo atual.
  Future<void> fillRect(double x, double y, double w, double h,
      {BLColor? color}) async {
    final path = BLPath();
    path.moveTo(x, y);
    path.lineTo(x + w, y);
    path.lineTo(x + w, y + h);
    path.lineTo(x, y + h);
    path.close();
    await fillPath(path, color: color);
  }

  // =========================================================================
  // Geometry convenience APIs
  // =========================================================================

  /// Preenche um círculo centrado em (cx, cy) com raio r.
  Future<void> fillCircle(double cx, double cy, double r,
      {BLColor? color}) async {
    final path = _buildCirclePath(cx, cy, r);
    await fillPath(path, color: color);
  }

  /// Renderiza o stroke de um círculo.
  Future<void> strokeCircle(double cx, double cy, double r,
      {BLColor? color, BLStrokeOptions? options}) async {
    final path = _buildCirclePath(cx, cy, r);
    await strokePath(path, color: color, options: options);
  }

  /// Preenche uma elipse centrada em (cx, cy) com raios rx, ry.
  Future<void> fillEllipse(double cx, double cy, double rx, double ry,
      {BLColor? color}) async {
    final path = _buildEllipsePath(cx, cy, rx, ry);
    await fillPath(path, color: color);
  }

  /// Renderiza o stroke de uma elipse.
  Future<void> strokeEllipse(double cx, double cy, double rx, double ry,
      {BLColor? color, BLStrokeOptions? options}) async {
    final path = _buildEllipsePath(cx, cy, rx, ry);
    await strokePath(path, color: color, options: options);
  }

  /// Builds a circle path using 8-segment cubic approximation.
  static BLPath _buildCirclePath(double cx, double cy, double r) {
    return _buildEllipsePath(cx, cy, r, r);
  }

  /// Builds an ellipse path using 4-quadrant cubic Bézier approximation.
  /// Uses the standard k ≈ 0.5522847498 control-point factor.
  static BLPath _buildEllipsePath(double cx, double cy, double rx, double ry) {
    const double k = 0.5522847498;
    final kx = rx * k, ky = ry * k;
    final path = BLPath();
    // Start at right
    path.moveTo(cx + rx, cy);
    // Top-right quadrant
    path.cubicTo(cx + rx, cy - ky, cx + kx, cy - ry, cx, cy - ry);
    // Top-left quadrant
    path.cubicTo(cx - kx, cy - ry, cx - rx, cy - ky, cx - rx, cy);
    // Bottom-left quadrant
    path.cubicTo(cx - rx, cy + ky, cx - kx, cy + ry, cx, cy + ry);
    // Bottom-right quadrant
    path.cubicTo(cx + kx, cy + ry, cx + rx, cy + ky, cx + rx, cy);
    path.close();
    return path;
  }

  // =========================================================================
  // Stroke API (Fase 5)
  // =========================================================================

  /// Configura as opções de stroke (largura, caps, joins, miter limit).
  void setStrokeOptions(BLStrokeOptions options) {
    strokeOptions = options;
  }

  /// Configura apenas a largura do stroke.
  void setStrokeWidth(double width) {
    strokeOptions = strokeOptions.copyWith(width: width);
  }

  /// Renderiza o stroke de [path] usando [strokeOptions] atuais.
  ///
  /// O stroke é convertido em um outline preenchido com [BLFillRule.nonZero].
  /// A cor / estilo de fill atuais são usados (ou [color] se fornecido).
  Future<void> strokePath(
    BLPath path, {
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final opts = options ?? strokeOptions;
    if (opts.width <= 0) return;

    final outline = BLStroker.strokePath(path, opts);
    await fillPath(
      outline,
      color: color,
      rule: BLFillRule.nonZero,
    );
  }

  /// Renderiza o stroke de um polígono (lista de vértices).
  Future<void> strokePolygon(
    List<double> vertices, {
    List<int>? contourVertexCounts,
    bool closedContours = true,
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final opts = options ?? strokeOptions;
    if (opts.width <= 0) return;

    // Montar BLPath a partir dos vértices
    final path = BLPath();
    final counts = contourVertexCounts ?? [vertices.length ~/ 2];
    int offset = 0;
    for (final cnt in counts) {
      if (cnt < 2) {
        offset += cnt;
        continue;
      }
      path.moveTo(vertices[offset * 2], vertices[offset * 2 + 1]);
      for (int i = 1; i < cnt; i++) {
        path.lineTo(vertices[(offset + i) * 2], vertices[(offset + i) * 2 + 1]);
      }
      if (closedContours) path.close();
      offset += cnt;
    }

    await strokePath(path, color: color, options: opts);
  }

  // =========================================================================
  // Stroke rect (convenience)
  // =========================================================================

  /// Stroked rectangle.
  Future<void> strokeRect(
    double x,
    double y,
    double w,
    double h, {
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final path = BLPath();
    path.moveTo(x, y);
    path.lineTo(x + w, y);
    path.lineTo(x + w, y + h);
    path.lineTo(x, y + h);
    path.close();
    await strokePath(path, color: color, options: options);
  }

  // =========================================================================
  // Dashed stroke (Fase 5+)
  // =========================================================================

  /// Stroke com dash pattern.
  ///
  /// [dashArray] define o padrão alternado dash/gap (ex: `[10, 5]`).
  /// [dashOffset] desloca o início do padrão.
  Future<void> strokeDashedPath(
    BLPath path, {
    required List<double> dashArray,
    double dashOffset = 0.0,
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    final dashed = BLDasher.dashPath(path, dashArray, dashOffset: dashOffset);
    await strokePath(dashed, color: color, options: options);
  }

  // =========================================================================
  // Image blitting (drawImage)
  // =========================================================================

  /// Compõe [src] sobre o contexto na posição (dx, dy).
  ///
  /// Itera pixel a pixel e aplica o comp-op corrente.
  /// Respeita globalAlpha e clipRect.
  void drawImage(BLImage src, {int dx = 0, int dy = 0}) {
    final dstBuf = _rasterizer.buffer;
    final srcPx = src.pixels;
    final dstW = image.width, dstH = image.height;
    final srcW = src.width, srcH = src.height;

    // Determine visible region
    int x0 = dx, y0 = dy;
    int x1 = dx + srcW, y1 = dy + srcH;
    if (_clipRect != null) {
      final cr = _clipRect!;
      x0 = math.max(x0, cr.x);
      y0 = math.max(y0, cr.y);
      x1 = math.min(x1, cr.x + cr.width);
      y1 = math.min(y1, cr.y + cr.height);
    }
    x0 = math.max(0, x0);
    y0 = math.max(0, y0);
    x1 = math.min(dstW, x1);
    y1 = math.min(dstH, y1);

    if (x0 >= x1 || y0 >= y1) return;

    final alphaScale = globalAlpha < 1.0;

    for (int py = y0; py < y1; py++) {
      final srcRow = (py - dy) * srcW;
      final dstRow = py * dstW;
      for (int px = x0; px < x1; px++) {
        int sp = srcPx[srcRow + (px - dx)];
        if (alphaScale) {
          final a = ((sp >>> 24) & 0xFF);
          final effA = (a * globalAlpha + 0.5).toInt().clamp(0, 255);
          sp = (effA << 24) | (sp & 0x00FFFFFF);
        }
        dstBuf[dstRow + px] =
            BLCompOpKernel.compose(compOp, dstBuf[dstRow + px], sp);
      }
    }
    _syncFromRasterizer();
  }

  // =========================================================================
  // Text API (Fase 11 — port de fillText/strokeText/drawGlyphRun)
  // =========================================================================

  /// Renderiza [text] preenchido na posição (x, y) usando [font].
  ///
  /// Usa [BLTextLayout.shapeSimple] para mapear codepoints → glyph IDs e
  /// posicionar os glifos com advance/kerning.
  /// Cada glifo é renderizado como path via [fillPath].
  Future<void> fillText(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
    BLColor? color,
  }) async {
    if (text.isEmpty) return;
    const layout = BLTextLayout();
    final run = layout.shapeSimple(text, font, x: x, y: y);
    await fillGlyphRun(run, font, color: color);
  }

  /// Renderiza [text] com stroke na posição (x, y) usando [font].
  Future<void> strokeText(
    String text,
    BLFont font, {
    double x = 0.0,
    double y = 0.0,
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    if (text.isEmpty) return;
    const layout = BLTextLayout();
    final run = layout.shapeSimple(text, font, x: x, y: y);
    await strokeGlyphRun(run, font, color: color, options: options);
  }

  /// Renderiza um [BLGlyphRun] preenchido.
  ///
  /// Para cada glifo no run, obtém o outline escalado e o preenche na
  /// posição (placement.x, placement.y).
  Future<void> fillGlyphRun(
    BLGlyphRun run,
    BLFont font, {
    BLColor? color,
  }) async {
    for (final glyph in run.glyphs) {
      final outline = font.glyphOutline(glyph.glyphId);
      if (outline == null || outline.vertices.length < 6) continue;

      // Translate vertices to glyph position
      final verts = outline.vertices;
      final translated = List<double>.filled(verts.length, 0.0);
      for (int i = 0; i < verts.length; i += 2) {
        translated[i] = verts[i] + glyph.x;
        translated[i + 1] = verts[i + 1] + glyph.y;
      }

      await fillPolygon(
        translated,
        contourVertexCounts: outline.contourVertexCounts,
        color: color,
        rule: BLFillRule.nonZero,
      );
    }
  }

  /// Renderiza um [BLGlyphRun] com stroke.
  Future<void> strokeGlyphRun(
    BLGlyphRun run,
    BLFont font, {
    BLColor? color,
    BLStrokeOptions? options,
  }) async {
    for (final glyph in run.glyphs) {
      final outline = font.glyphOutline(glyph.glyphId);
      if (outline == null || outline.vertices.length < 6) continue;

      // build a BLPath translated to glyph position
      final path = BLPath();
      final verts = outline.vertices;
      final counts = outline.contourVertexCounts ?? [verts.length ~/ 2];
      int offset = 0;
      for (final cnt in counts) {
        if (cnt < 2) {
          offset += cnt;
          continue;
        }
        path.moveTo(
            verts[offset * 2] + glyph.x, verts[offset * 2 + 1] + glyph.y);
        for (int i = 1; i < cnt; i++) {
          path.lineTo(
            verts[(offset + i) * 2] + glyph.x,
            verts[(offset + i) * 2 + 1] + glyph.y,
          );
        }
        path.close();
        offset += cnt;
      }

      await strokePath(path, color: color, options: options);
    }
  }

  // =========================================================================
  // Dispose
  // =========================================================================

  Future<void> dispose() => _rasterizer.dispose();

  // =========================================================================
  // Internal
  // =========================================================================

  void _syncFromRasterizer() {
    // Nesta etapa do port o backend compoe internamente no proprio framebuffer.
    // Por isso sincronizamos a superficie publica por copia direta.
    image.copyFrom(_rasterizer.buffer);
  }

  /// Aplica a transformação corrente a todos os vértices.
  List<double> _transformVertices(List<double> verts) {
    final m = _transform;
    final result = List<double>.filled(verts.length, 0.0);
    for (int i = 0; i < verts.length; i += 2) {
      final x = verts[i], y = verts[i + 1];
      result[i] = m.m00 * x + m.m10 * y + m.m20;
      result[i + 1] = m.m01 * x + m.m11 * y + m.m21;
    }
    return result;
  }
}
