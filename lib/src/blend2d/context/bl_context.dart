import '../core/bl_image.dart';
import '../core/bl_types.dart';
import '../pipeline/bl_fetch_linear_gradient.dart';
import '../pipeline/bl_fetch_pattern.dart';
import '../pipeline/bl_fetch_radial_gradient.dart';
import '../geometry/bl_path.dart';
import '../geometry/bl_stroker.dart';
import '../pipeline/bl_fetch_solid.dart';
import '../raster/bl_analytic_rasterizer.dart';

enum _BLFillStyleType {
  solid,
  linearGradient,
  radialGradient,
  pattern,
}

/// Contexto de desenho do port Blend2D em Dart.
///
/// Etapa atual:
/// - API minima de preenchimento de poligonos e paths.
/// - FillRule funcional (even-odd/non-zero).
/// - CompOp operacional com `srcOver` (padrao).
/// - `srcCopy` entra como fallback seguro para casos opacos simples.
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

  void clear([BLColor argb = 0xFFFFFFFF]) {
    image.clear(argb);
    _rasterizer.clear(argb);
  }

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

    if (!useExplicitColor &&
        _fillStyleType == _BLFillStyleType.linearGradient &&
        gradientFetcher != null) {
      await _rasterizer.drawPolygonFetched(
        vertices,
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
        vertices,
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
        vertices,
        patternFetcher.fetch,
        fillRule: drawRule,
        compOp: compOp,
        contourVertexCounts: contourVertexCounts,
      );
      _syncFromRasterizer();
      return;
    }

    final drawColor = color ?? _solidFetcher.fetch();

    await _rasterizer.drawPolygon(
      vertices,
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

  // ---------------------------------------------------------------------------
  // Stroke API (Fase 5)
  // ---------------------------------------------------------------------------

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
      if (cnt < 2) { offset += cnt; continue; }
      path.moveTo(vertices[offset * 2], vertices[offset * 2 + 1]);
      for (int i = 1; i < cnt; i++) {
        path.lineTo(vertices[(offset + i) * 2], vertices[(offset + i) * 2 + 1]);
      }
      if (closedContours) path.close();
      offset += cnt;
    }

    await strokePath(path, color: color, options: opts);
  }

  Future<void> dispose() => _rasterizer.dispose();

  void _syncFromRasterizer() {
    // Nesta etapa do port o backend compoe internamente no proprio framebuffer.
    // Por isso sincronizamos a superficie publica por copia direta.
    image.copyFrom(_rasterizer.buffer);
  }
}
