import '../core/bl_image.dart';
import '../core/bl_types.dart';
import '../pipeline/bl_fetch_linear_gradient.dart';
import '../pipeline/bl_fetch_pattern.dart';
import '../pipeline/bl_fetch_radial_gradient.dart';
import '../geometry/bl_path.dart';
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

  Future<void> dispose() => _rasterizer.dispose();

  void _syncFromRasterizer() {
    // Nesta etapa do port o backend compoe internamente no proprio framebuffer.
    // Por isso sincronizamos a superficie publica por copia direta.
    image.copyFrom(_rasterizer.buffer);
  }
}
