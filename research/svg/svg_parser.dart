/// =============================================================================
/// SVG PARSER - Robust otimized Implementation
/// =============================================================================
///
/// A proper SVG parser using a state machine approach for correct handling
/// of nested groups and transformations.
///
library;

import 'dart:math' as math;

/// Represents a polygon extracted from SVG
class SvgPolygon {
  final List<double> vertices;
  // Number of vertices (points, not doubles) for each subpath contour.
  // Null means a single contour using all vertices.
  final List<int>? contourVertexCounts;
  final int fillColor;
  final int strokeColor;
  final double strokeWidth;
  final bool evenOdd;
  final bool fillSpecified;

  SvgPolygon({
    required this.vertices,
    this.contourVertexCounts,
    this.fillColor = 0xFF000000,
    this.strokeColor = 0x00000000,
    this.strokeWidth = 0.0,
    this.evenOdd = true,
    this.fillSpecified = false,
  });
}

/// Result of parsing an SVG document
class SvgDocument {
  final double width;
  final double height;
  final List<SvgPolygon> polygons;

  SvgDocument({
    required this.width,
    required this.height,
    required this.polygons,
  });
}

/// 2D transformation matrix
class Matrix2D {
  double a, b, c, d, e, f;

  Matrix2D.identity()
      : a = 1,
        b = 0,
        c = 0,
        d = 1,
        e = 0,
        f = 0;

  Matrix2D(this.a, this.b, this.c, this.d, this.e, this.f);

  Matrix2D copy() => Matrix2D(a, b, c, d, e, f);

  Matrix2D multiply(Matrix2D other) {
    return Matrix2D(
      a * other.a + c * other.b,
      b * other.a + d * other.b,
      a * other.c + c * other.d,
      b * other.c + d * other.d,
      a * other.e + c * other.f + e,
      b * other.e + d * other.f + f,
    );
  }

  List<double> transform(double x, double y) {
    return [a * x + c * y + e, b * x + d * y + f];
  }

  static Matrix2D translate(double tx, double ty) {
    return Matrix2D(1, 0, 0, 1, tx, ty);
  }

  static Matrix2D scale(double sx, double sy) {
    return Matrix2D(sx, 0, 0, sy, 0, 0);
  }

  static Matrix2D rotate(double angleRad) {
    final cos = math.cos(angleRad);
    final sin = math.sin(angleRad);
    return Matrix2D(cos, sin, -sin, cos, 0, 0);
  }
}

/// Parsing context maintaining state during SVG parsing
class _ParseContext {
  Matrix2D transform;
  int fillColor;
  int strokeColor;
  double strokeWidth;
  String fillRule;
  double opacity;
  double fillOpacity;
  bool fillSpecified;

  _ParseContext({
    Matrix2D? transform,
    this.fillColor = 0xFF000000,
    this.strokeColor = 0x00000000,
    this.strokeWidth = 1.0,
    this.fillRule = 'nonzero',
    this.opacity = 1.0,
    this.fillOpacity = 1.0,
    this.fillSpecified = false,
  }) : transform = transform ?? Matrix2D.identity();

  _ParseContext copy() {
    return _ParseContext(
      transform: transform.copy(),
      fillColor: fillColor,
      strokeColor: strokeColor,
      strokeWidth: strokeWidth,
      fillRule: fillRule,
      opacity: opacity,
      fillOpacity: fillOpacity,
      fillSpecified: fillSpecified,
    );
  }
}

/// Robust SVG Parser
class SvgParser {
  /// Parse SVG content and extract polygons
  SvgDocument parse(String svgContent) {
    double width = 512;
    double height = 512;
    final polygons = <SvgPolygon>[];

    // Parse dimensions from root SVG element.
    final svgTagMatch =
        RegExp(r'<svg\b[^>]*>', caseSensitive: false).firstMatch(svgContent);
    final svgTag = svgTagMatch?.group(0);
    if (svgTag != null) {
      final viewBox = _extractAttr(svgTag, 'viewBox');
      if (viewBox != null) {
        final parts = viewBox.split(RegExp(r'[\s,]+'));
        if (parts.length >= 4) {
          width = _parseLength(parts[2], width);
          height = _parseLength(parts[3], height);
        }
      } else {
        final svgWidth = _extractAttr(svgTag, 'width');
        final svgHeight = _extractAttr(svgTag, 'height');
        if (svgWidth != null) width = _parseLength(svgWidth, width);
        if (svgHeight != null) height = _parseLength(svgHeight, height);
      }
    } else {
      // Fallback for malformed SVGs that still expose a viewBox.
      final viewBoxMatch = RegExp(r'viewBox="([^"]+)"').firstMatch(svgContent);
      if (viewBoxMatch != null) {
        final parts = viewBoxMatch.group(1)!.split(RegExp(r'[\s,]+'));
        if (parts.length >= 4) {
          width = _parseLength(parts[2], width);
          height = _parseLength(parts[3], height);
        }
      }
    }

    // Use a hierarchical parser approach
    _parseHierarchy(svgContent, _ParseContext(), polygons);

    return SvgDocument(
      width: width,
      height: height,
      polygons: polygons,
    );
  }

  /// Parse SVG content hierarchically, handling nested groups
  void _parseHierarchy(
      String content, _ParseContext ctx, List<SvgPolygon> polygons) {
    int pos = 0;

    while (pos < content.length) {
      // Find next tag
      int tagStart = content.indexOf('<', pos);
      if (tagStart == -1) break;

      // Skip comments
      if (content.substring(tagStart).startsWith('<!--')) {
        int commentEnd = content.indexOf('-->', tagStart);
        if (commentEnd != -1) {
          pos = commentEnd + 3;
          continue;
        }
      }

      // Find tag name
      int tagNameEnd = tagStart + 1;
      while (tagNameEnd < content.length &&
          !RegExp(r'[\s/>]').hasMatch(content[tagNameEnd])) {
        tagNameEnd++;
      }

      final tagName = content.substring(tagStart + 1, tagNameEnd).toLowerCase();

      // Skip closing tags
      if (tagName.startsWith('/')) {
        pos = content.indexOf('>', tagStart) + 1;
        continue;
      }

      // Find tag end
      int tagEnd = tagStart;
      bool inQuote = false;
      String quoteChar = '';
      while (tagEnd < content.length) {
        if (!inQuote && (content[tagEnd] == '"' || content[tagEnd] == "'")) {
          inQuote = true;
          quoteChar = content[tagEnd];
        } else if (inQuote && content[tagEnd] == quoteChar) {
          inQuote = false;
        } else if (!inQuote && content[tagEnd] == '>') {
          break;
        }
        tagEnd++;
      }

      if (tagEnd >= content.length) break;

      final tagContent = content.substring(tagStart, tagEnd + 1);
      final isSelfClosing = tagContent.endsWith('/>');

      // Handle different elements
      if (tagName == 'g') {
        // Group - create child context
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);

        if (!isSelfClosing) {
          // Find matching </g>
          int depth = 1;
          int searchPos = tagEnd + 1;
          int groupEnd = searchPos;

          while (depth > 0 && searchPos < content.length) {
            int nextOpen = content.indexOf('<g', searchPos);
            int nextClose = content.indexOf('</g>', searchPos);

            if (nextClose == -1) break;

            if (nextOpen != -1 && nextOpen < nextClose) {
              // Check if it's really a <g> tag (not <gradient, etc.)
              if (nextOpen + 2 < content.length) {
                final nextChar = content[nextOpen + 2];
                if (nextChar == ' ' ||
                    nextChar == '>' ||
                    nextChar == '\t' ||
                    nextChar == '\n' ||
                    nextChar == '/') {
                  depth++;
                }
              }
              searchPos = nextOpen + 2;
            } else {
              depth--;
              if (depth == 0) {
                groupEnd = nextClose;
              }
              searchPos = nextClose + 4;
            }
          }

          // Parse group content
          final groupContent = content.substring(tagEnd + 1, groupEnd);
          _parseHierarchy(groupContent, childCtx, polygons);

          pos = groupEnd + 4;
          continue;
        }
      } else if (tagName == 'path') {
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);

        final d = _extractAttr(tagContent, 'd');
        final effectiveFill = _applyOpacity(
          childCtx.fillColor,
          childCtx.opacity * childCtx.fillOpacity,
        );
        if (d != null && (effectiveFill >> 24) != 0) {
          var subpaths = _parsePathData(d, childCtx.transform);
          // NOTE:
          // Reordering/reversing contours by area may change original path
          // topology and create artificial bridges in complex SVGs (e.g. froggy).
          // Keep source contour order here and let rasterizers apply fill-rule.
          // Merge all subpaths into a single polygon so that even-odd /
          // non-zero winding rules work correctly via scanline crossing
          // counts.  Splitting them into separate SvgPolygons would lose
          // the hole information and paint solid fills everywhere.
          final allVertices = <double>[];
          final contourVertexCounts = <int>[];
          for (final sp in subpaths) {
            allVertices.addAll(sp);
            contourVertexCounts.add(sp.length ~/ 2);
          }
          if (allVertices.length >= 6) {
            polygons.add(SvgPolygon(
              vertices: allVertices,
              contourVertexCounts:
                  contourVertexCounts.length > 1 ? contourVertexCounts : null,
              fillColor: effectiveFill,
              strokeColor: childCtx.strokeColor,
              strokeWidth: childCtx.strokeWidth,
              evenOdd: childCtx.fillRule == 'evenodd',
              fillSpecified: childCtx.fillSpecified,
            ));
          }
        }
      } else if (tagName == 'polygon' || tagName == 'polyline') {
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);

        final points = _extractAttr(tagContent, 'points');
        final effectiveFill = _applyOpacity(
          childCtx.fillColor,
          childCtx.opacity * childCtx.fillOpacity,
        );
        if (points != null && (effectiveFill >> 24) != 0) {
          final vertices = _parsePoints(points, childCtx.transform);
          if (vertices.length >= 6) {
            polygons.add(SvgPolygon(
              vertices: vertices,
              fillColor: effectiveFill,
              fillSpecified: childCtx.fillSpecified,
            ));
          }
        }
      } else if (tagName == 'rect') {
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);

        final effectiveFill = _applyOpacity(
          childCtx.fillColor,
          childCtx.opacity * childCtx.fillOpacity,
        );
        if ((effectiveFill >> 24) != 0) {
          final vertices = _parseRect(tagContent, childCtx.transform);
          if (vertices.length >= 6) {
            polygons.add(SvgPolygon(
              vertices: vertices,
              fillColor: effectiveFill,
              fillSpecified: childCtx.fillSpecified,
            ));
          }
        }
      } else if (tagName == 'circle' || tagName == 'ellipse') {
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);

        final effectiveFill = _applyOpacity(
          childCtx.fillColor,
          childCtx.opacity * childCtx.fillOpacity,
        );
        if ((effectiveFill >> 24) != 0) {
          final vertices = _parseEllipse(
              tagContent, childCtx.transform, tagName == 'circle');
          if (vertices.length >= 6) {
            polygons.add(SvgPolygon(
              vertices: vertices,
              fillColor: effectiveFill,
              fillSpecified: childCtx.fillSpecified,
            ));
          }
        }
      }

      pos = tagEnd + 1;
    }
  }

  String? _extractAttr(String tagContent, String attrName) {
    final name = RegExp.escape(attrName);
    final re = RegExp(
      '(?:^|\\s)$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
      caseSensitive: false,
    );
    final m = re.firstMatch(tagContent);
    if (m == null) return null;
    return m.group(1) ?? m.group(2) ?? m.group(3);
  }

  double _parseLength(String value, double fallback) {
    final m = RegExp(r'[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?')
        .firstMatch(value.trim());
    if (m == null) return fallback;
    return double.tryParse(m.group(0)!) ?? fallback;
  }

  int _applyOpacity(int color, double opacity) {
    final clamped = opacity.clamp(0.0, 1.0);
    final srcA = (color >> 24) & 0xFF;
    final outA = (srcA * clamped).round().clamp(0, 255);
    return (outA << 24) | (color & 0x00FFFFFF);
  }

  /// Apply attributes from tag to context
  void _applyAttributes(String tagContent, _ParseContext ctx) {
    final transformValue = _extractAttr(tagContent, 'transform');
    if (transformValue != null && transformValue.isNotEmpty) {
      final localTransform = _parseTransform(transformValue);
      ctx.transform = ctx.transform.multiply(localTransform);
    }

    final fillValue = _extractAttr(tagContent, 'fill');
    if (fillValue != null) {
      final color = _parseColor(fillValue);
      if (color != -1) {
        ctx.fillColor = color;
      } else {
        ctx.fillColor = 0x00000000;
      }
      ctx.fillSpecified = true;
    }

    final strokeValue = _extractAttr(tagContent, 'stroke');
    if (strokeValue != null) {
      final color = _parseColor(strokeValue);
      if (color != -1) ctx.strokeColor = color;
    }

    final strokeWidthValue = _extractAttr(tagContent, 'stroke-width');
    if (strokeWidthValue != null) {
      ctx.strokeWidth = _parseLength(strokeWidthValue, ctx.strokeWidth);
    }

    final fillRuleValue = _extractAttr(tagContent, 'fill-rule');
    if (fillRuleValue != null && fillRuleValue.isNotEmpty) {
      ctx.fillRule = fillRuleValue.trim().toLowerCase();
    }

    final opacityValue = _extractAttr(tagContent, 'opacity');
    if (opacityValue != null) {
      ctx.opacity = _parseLength(opacityValue, ctx.opacity).clamp(0.0, 1.0);
    }

    final fillOpacityValue = _extractAttr(tagContent, 'fill-opacity');
    if (fillOpacityValue != null) {
      ctx.fillOpacity =
          _parseLength(fillOpacityValue, ctx.fillOpacity).clamp(0.0, 1.0);
    }

    final styleValue = _extractAttr(tagContent, 'style');
    if (styleValue != null) {
      _parseStyle(styleValue, ctx);
    }
  }

  /// Parse inline style attribute
  void _parseStyle(String style, _ParseContext ctx) {
    final pairs = style.split(';');
    for (final pair in pairs) {
      final kv = pair.split(':');
      if (kv.length != 2) continue;
      final key = kv[0].trim().toLowerCase();
      final value = kv[1].trim();

      switch (key) {
        case 'fill':
          final color = _parseColor(value);
          if (color != -1) {
            ctx.fillColor = color;
          } else {
            ctx.fillColor = 0x00000000;
          }
          ctx.fillSpecified = true;
          break;
        case 'stroke':
          final color = _parseColor(value);
          if (color != -1) ctx.strokeColor = color;
          break;
        case 'stroke-width':
          ctx.strokeWidth = _parseLength(value, ctx.strokeWidth);
          break;
        case 'fill-rule':
          ctx.fillRule = value.toLowerCase();
          break;
        case 'opacity':
          ctx.opacity = _parseLength(value, ctx.opacity).clamp(0.0, 1.0);
          break;
        case 'fill-opacity':
          ctx.fillOpacity =
              _parseLength(value, ctx.fillOpacity).clamp(0.0, 1.0);
          break;
      }
    }
  }

  /// Parse SVG color
  int _parseColor(String color) {
    color = color.trim().toLowerCase();

    if (color == 'none' || color == 'transparent') return 0x00000000;
    if (color.startsWith('url(')) return -1; // Gradients not supported

    const namedColors = {
      'black': 0xFF000000,
      'white': 0xFFFFFFFF,
      'red': 0xFFFF0000,
      'green': 0xFF008000,
      'blue': 0xFF0000FF,
      'yellow': 0xFFFFFF00,
      'cyan': 0xFF00FFFF,
      'magenta': 0xFFFF00FF,
      'gray': 0xFF808080,
      'grey': 0xFF808080,
      'orange': 0xFFFFA500,
      'pink': 0xFFFFC0CB,
      'purple': 0xFF800080,
      'brown': 0xFFA52A2A,
      'lime': 0xFF00FF00,
      'navy': 0xFF000080,
      'teal': 0xFF008080,
      'silver': 0xFFC0C0C0,
      'maroon': 0xFF800000,
      'olive': 0xFF808000,
      'aqua': 0xFF00FFFF,
      'fuchsia': 0xFFFF00FF,
    };

    if (namedColors.containsKey(color)) return namedColors[color]!;

    if (color.startsWith('#')) {
      color = color.substring(1);
      if (color.length == 3) {
        color =
            '${color[0]}${color[0]}${color[1]}${color[1]}${color[2]}${color[2]}';
      } else if (color.length == 4) {
        color =
            '${color[0]}${color[0]}${color[1]}${color[1]}${color[2]}${color[2]}${color[3]}${color[3]}';
      }

      if (color.length == 6) {
        final value = int.tryParse(color, radix: 16);
        if (value != null) return 0xFF000000 | value;
      } else if (color.length == 8) {
        final value = int.tryParse(color, radix: 16);
        if (value != null) {
          final rgb = (value >> 8) & 0x00FFFFFF;
          final alpha = value & 0xFF;
          return (alpha << 24) | rgb;
        }
      }
    }

    final rgbMatch = RegExp(
      r'rgb\s*\(\s*([0-9.]+%?)\s*,\s*([0-9.]+%?)\s*,\s*([0-9.]+%?)\s*\)',
    ).firstMatch(color);
    if (rgbMatch != null) {
      final r = _parseRgbChannel(rgbMatch.group(1)!);
      final g = _parseRgbChannel(rgbMatch.group(2)!);
      final b = _parseRgbChannel(rgbMatch.group(3)!);
      return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    final rgbaMatch = RegExp(
      r'rgba\s*\(\s*([0-9.]+%?)\s*,\s*([0-9.]+%?)\s*,\s*([0-9.]+%?)\s*,\s*([0-9.]+%?)\s*\)',
    ).firstMatch(color);
    if (rgbaMatch != null) {
      final r = _parseRgbChannel(rgbaMatch.group(1)!);
      final g = _parseRgbChannel(rgbaMatch.group(2)!);
      final b = _parseRgbChannel(rgbaMatch.group(3)!);
      final a = _parseAlphaChannel(rgbaMatch.group(4)!);
      return (a << 24) | (r << 16) | (g << 8) | b;
    }

    return 0xFF000000;
  }

  int _parseRgbChannel(String input) {
    final value = input.trim();
    if (value.endsWith('%')) {
      final p = double.tryParse(value.substring(0, value.length - 1)) ?? 0.0;
      return ((p * 2.55).round()).clamp(0, 255);
    }
    return (double.tryParse(value)?.round() ?? 0).clamp(0, 255);
  }

  int _parseAlphaChannel(String input) {
    final value = input.trim();
    if (value.endsWith('%')) {
      final p = double.tryParse(value.substring(0, value.length - 1)) ?? 0.0;
      return ((p * 2.55).round()).clamp(0, 255);
    }
    final d = double.tryParse(value) ?? 1.0;
    if (d <= 1.0) return (d * 255).round().clamp(0, 255);
    return d.round().clamp(0, 255);
  }

  /// Parse SVG transformation
  Matrix2D _parseTransform(String transform) {
    Matrix2D result = Matrix2D.identity();

    // Parse all transforms in sequence
    final transforms = RegExp(r'(\w+)\s*\(([^)]+)\)').allMatches(transform);
    for (final match in transforms) {
      final type = match.group(1)!.toLowerCase();
      final argsStr = match.group(2)!;
      final args = argsStr
          .split(RegExp(r'[\s,]+'))
          .where((s) => s.isNotEmpty)
          .map((s) => double.tryParse(s) ?? 0.0)
          .toList();

      Matrix2D t;
      switch (type) {
        case 'matrix':
          if (args.length >= 6) {
            t = Matrix2D(args[0], args[1], args[2], args[3], args[4], args[5]);
            result = result.multiply(t);
          }
          break;
        case 'translate':
          final double tx = args.isNotEmpty ? args[0] : 0.0;
          final double ty = args.length > 1 ? args[1] : 0.0;
          result = result.multiply(Matrix2D.translate(tx, ty));
          break;
        case 'scale':
          final double sx = args.isNotEmpty ? args[0] : 1.0;
          final double sy = args.length > 1 ? args[1] : sx;
          result = result.multiply(Matrix2D.scale(sx, sy));
          break;
        case 'rotate':
          if (args.isNotEmpty) {
            final angle = args[0] * math.pi / 180;
            if (args.length >= 3) {
              // rotate(angle, cx, cy)
              final cx = args[1];
              final cy = args[2];
              result = result.multiply(Matrix2D.translate(cx, cy));
              result = result.multiply(Matrix2D.rotate(angle));
              result = result.multiply(Matrix2D.translate(-cx, -cy));
            } else {
              result = result.multiply(Matrix2D.rotate(angle));
            }
          }
          break;
        case 'skewx':
          if (args.isNotEmpty) {
            final angle = args[0] * math.pi / 180;
            result = result.multiply(Matrix2D(1, 0, math.tan(angle), 1, 0, 0));
          }
          break;
        case 'skewy':
          if (args.isNotEmpty) {
            final angle = args[0] * math.pi / 180;
            result = result.multiply(Matrix2D(1, math.tan(angle), 0, 1, 0, 0));
          }
          break;
      }
    }

    return result;
  }

  /// Parse path data, splitting each subpath into an independent polygon.
  List<List<double>> _parsePathData(String pathData, Matrix2D transform) {
    final subpaths = <List<double>>[];
    final tokens = _tokenizePathData(pathData);
    if (tokens.isEmpty) return subpaths;

    var currentVertices = <double>[];
    double currentX = 0, currentY = 0;
    double startX = 0, startY = 0;
    double lastControlX = 0, lastControlY = 0;
    String lastCommand = '';

    void ensureSubpathStarted() {
      if (currentVertices.isNotEmpty) return;
      currentVertices.addAll(transform.transform(currentX, currentY));
    }

    void startSubpath(double x, double y) {
      _commitSubpath(currentVertices, subpaths);
      currentVertices = <double>[];
      startX = x;
      startY = y;
      currentVertices.addAll(transform.transform(x, y));
    }

    int i = 0;
    while (i < tokens.length) {
      String command = tokens[i];

      if (_isNumber(command)) {
        if (lastCommand.isEmpty) {
          i++;
          continue;
        }
        command = lastCommand;
        if (command == 'M') command = 'L';
        if (command == 'm') command = 'l';
      } else {
        i++;
      }

      switch (command) {
        case 'M':
          if (_hasNumericTokens(tokens, i, 2)) {
            currentX = _parseDouble(tokens, i++);
            currentY = _parseDouble(tokens, i++);
            startSubpath(currentX, currentY);
          }
          break;
        case 'm':
          if (_hasNumericTokens(tokens, i, 2)) {
            currentX += _parseDouble(tokens, i++);
            currentY += _parseDouble(tokens, i++);
            startSubpath(currentX, currentY);
          }
          break;
        case 'L':
          if (_hasNumericTokens(tokens, i, 2)) {
            ensureSubpathStarted();
            currentX = _parseDouble(tokens, i++);
            currentY = _parseDouble(tokens, i++);
            currentVertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'l':
          if (_hasNumericTokens(tokens, i, 2)) {
            ensureSubpathStarted();
            currentX += _parseDouble(tokens, i++);
            currentY += _parseDouble(tokens, i++);
            currentVertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'H':
          if (_hasNumericTokens(tokens, i, 1)) {
            ensureSubpathStarted();
            currentX = _parseDouble(tokens, i++);
            currentVertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'h':
          if (_hasNumericTokens(tokens, i, 1)) {
            ensureSubpathStarted();
            currentX += _parseDouble(tokens, i++);
            currentVertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'V':
          if (_hasNumericTokens(tokens, i, 1)) {
            ensureSubpathStarted();
            currentY = _parseDouble(tokens, i++);
            currentVertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'v':
          if (_hasNumericTokens(tokens, i, 1)) {
            ensureSubpathStarted();
            currentY += _parseDouble(tokens, i++);
            currentVertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'C':
          if (_hasNumericTokens(tokens, i, 6)) {
            ensureSubpathStarted();
            final x1 = _parseDouble(tokens, i++);
            final y1 = _parseDouble(tokens, i++);
            final x2 = _parseDouble(tokens, i++);
            final y2 = _parseDouble(tokens, i++);
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addCubicBezier(currentVertices, currentX, currentY, x1, y1, x2, y2,
                x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 'c':
          if (_hasNumericTokens(tokens, i, 6)) {
            ensureSubpathStarted();
            final x1 = currentX + _parseDouble(tokens, i++);
            final y1 = currentY + _parseDouble(tokens, i++);
            final x2 = currentX + _parseDouble(tokens, i++);
            final y2 = currentY + _parseDouble(tokens, i++);
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addCubicBezier(currentVertices, currentX, currentY, x1, y1, x2, y2,
                x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 'S':
          if (_hasNumericTokens(tokens, i, 4)) {
            ensureSubpathStarted();
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x2 = _parseDouble(tokens, i++);
            final y2 = _parseDouble(tokens, i++);
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addCubicBezier(currentVertices, currentX, currentY, x1, y1, x2, y2,
                x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 's':
          if (_hasNumericTokens(tokens, i, 4)) {
            ensureSubpathStarted();
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x2 = currentX + _parseDouble(tokens, i++);
            final y2 = currentY + _parseDouble(tokens, i++);
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addCubicBezier(currentVertices, currentX, currentY, x1, y1, x2, y2,
                x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 'Q':
          if (_hasNumericTokens(tokens, i, 4)) {
            ensureSubpathStarted();
            final x1 = _parseDouble(tokens, i++);
            final y1 = _parseDouble(tokens, i++);
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addQuadraticBezier(
                currentVertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 'q':
          if (_hasNumericTokens(tokens, i, 4)) {
            ensureSubpathStarted();
            final x1 = currentX + _parseDouble(tokens, i++);
            final y1 = currentY + _parseDouble(tokens, i++);
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addQuadraticBezier(
                currentVertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 'T':
          if (_hasNumericTokens(tokens, i, 2)) {
            ensureSubpathStarted();
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addQuadraticBezier(
                currentVertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 't':
          if (_hasNumericTokens(tokens, i, 2)) {
            ensureSubpathStarted();
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addQuadraticBezier(
                currentVertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 'A':
        case 'a':
          if (_hasNumericTokens(tokens, i, 7)) {
            ensureSubpathStarted();
            final rx = _parseDouble(tokens, i++).abs();
            final ry = _parseDouble(tokens, i++).abs();
            final xRotation = _parseDouble(tokens, i++);
            final largeArc = _parseDouble(tokens, i++) != 0;
            final sweep = _parseDouble(tokens, i++) != 0;
            double x, y;
            if (command == 'A') {
              x = _parseDouble(tokens, i++);
              y = _parseDouble(tokens, i++);
            } else {
              x = currentX + _parseDouble(tokens, i++);
              y = currentY + _parseDouble(tokens, i++);
            }
            _addArc(currentVertices, currentX, currentY, rx, ry, xRotation,
                largeArc, sweep, x, y, transform);
            currentX = x;
            currentY = y;
          }
          break;
        case 'Z':
        case 'z':
          currentX = startX;
          currentY = startY;
          _commitSubpath(currentVertices, subpaths);
          currentVertices = <double>[];
          break;
        default:
          break;
      }

      if (!['C', 'c', 'S', 's', 'Q', 'q', 'T', 't'].contains(command)) {
        lastControlX = currentX;
        lastControlY = currentY;
      }

      lastCommand = command;
    }

    _commitSubpath(currentVertices, subpaths);
    return subpaths;
  }

  void _commitSubpath(List<double> raw, List<List<double>> out) {
    if (raw.length < 6) return;

    final cleaned = <double>[];
    for (int i = 0; i + 1 < raw.length; i += 2) {
      final x = raw[i];
      final y = raw[i + 1];
      if (!x.isFinite || !y.isFinite) continue;

      if (cleaned.length >= 2) {
        final lastX = cleaned[cleaned.length - 2];
        final lastY = cleaned[cleaned.length - 1];
        if ((x - lastX).abs() <= 1e-9 && (y - lastY).abs() <= 1e-9) {
          continue;
        }
      }
      cleaned.add(x);
      cleaned.add(y);
    }

    if (cleaned.length < 6) return;

    final firstX = cleaned[0];
    final firstY = cleaned[1];
    final lastX = cleaned[cleaned.length - 2];
    final lastY = cleaned[cleaned.length - 1];
    if ((firstX - lastX).abs() <= 1e-9 && (firstY - lastY).abs() <= 1e-9) {
      cleaned.removeRange(cleaned.length - 2, cleaned.length);
    }

    if (cleaned.length < 6) return;

    double area2 = 0.0;
    final n = cleaned.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = cleaned[i * 2];
      final y0 = cleaned[i * 2 + 1];
      final x1 = cleaned[j * 2];
      final y1 = cleaned[j * 2 + 1];
      area2 += (x0 * y1) - (y0 * x1);
    }
    if (area2.abs() <= 1e-9) return;

    out.add(cleaned);
  }

  /// Tokenize path data
  List<String> _tokenizePathData(String pathData) {
    final tokens = <String>[];
    final regex = RegExp(
      r'([MmLlHhVvCcSsQqTtAaZz])|([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)',
    );
    for (final match in regex.allMatches(pathData)) {
      tokens.add(match.group(0)!);
    }
    return tokens;
  }

  bool _isNumber(String s) => double.tryParse(s) != null;

  /// Check if there are enough numeric tokens starting at position i
  bool _hasNumericTokens(List<String> tokens, int i, int count) {
    if (i + count > tokens.length) return false;
    for (int j = 0; j < count; j++) {
      if (!_isNumber(tokens[i + j])) return false;
    }
    return true;
  }

  /// Safely parse a double, returning 0 if parse fails
  double _parseDouble(List<String> tokens, int index) {
    if (index >= tokens.length) return 0;
    return double.tryParse(tokens[index]) ?? 0;
  }

  /// Add cubic bezier as line segments
  void _addCubicBezier(
      List<double> vertices,
      double x0,
      double y0,
      double x1,
      double y1,
      double x2,
      double y2,
      double x3,
      double y3,
      Matrix2D transform) {
    const steps = 16;
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final t2 = t * t;
      final t3 = t2 * t;
      final mt = 1 - t;
      final mt2 = mt * mt;
      final mt3 = mt2 * mt;
      final x = mt3 * x0 + 3 * mt2 * t * x1 + 3 * mt * t2 * x2 + t3 * x3;
      final y = mt3 * y0 + 3 * mt2 * t * y1 + 3 * mt * t2 * y2 + t3 * y3;
      vertices.addAll(transform.transform(x, y));
    }
  }

  /// Add quadratic bezier as line segments
  void _addQuadraticBezier(List<double> vertices, double x0, double y0,
      double x1, double y1, double x2, double y2, Matrix2D transform) {
    const steps = 8;
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final mt = 1 - t;
      final x = mt * mt * x0 + 2 * mt * t * x1 + t * t * x2;
      final y = mt * mt * y0 + 2 * mt * t * y1 + t * t * y2;
      vertices.addAll(transform.transform(x, y));
    }
  }

  /// Add arc approximation
  void _addArc(
      List<double> vertices,
      double x0,
      double y0,
      double rx,
      double ry,
      double xRotation,
      bool largeArc,
      bool sweep,
      double x1,
      double y1,
      Matrix2D transform) {
    // Simple line approximation for arcs
    // A full implementation would use the endpoint parameterization
    const steps = 16;
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final x = x0 + t * (x1 - x0);
      final y = y0 + t * (y1 - y0);
      vertices.addAll(transform.transform(x, y));
    }
  }

  /// Parse points attribute
  List<double> _parsePoints(String points, Matrix2D transform) {
    final vertices = <double>[];
    final nums = points
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => double.tryParse(s))
        .toList();

    for (int i = 0; i < nums.length - 1; i += 2) {
      if (nums[i] != null && nums[i + 1] != null) {
        vertices.addAll(transform.transform(nums[i]!, nums[i + 1]!));
      }
    }
    return vertices;
  }

  /// Parse rect element
  List<double> _parseRect(String tagContent, Matrix2D transform) {
    final vertices = <double>[];

    double x = 0, y = 0, w = 0, h = 0;

    final xValue = _extractAttr(tagContent, 'x');
    final yValue = _extractAttr(tagContent, 'y');
    final wValue = _extractAttr(tagContent, 'width');
    final hValue = _extractAttr(tagContent, 'height');

    if (xValue != null) x = _parseLength(xValue, 0);
    if (yValue != null) y = _parseLength(yValue, 0);
    if (wValue != null) w = _parseLength(wValue, 0);
    if (hValue != null) h = _parseLength(hValue, 0);

    if (w <= 0 || h <= 0) return vertices;

    vertices.addAll(transform.transform(x, y));
    vertices.addAll(transform.transform(x + w, y));
    vertices.addAll(transform.transform(x + w, y + h));
    vertices.addAll(transform.transform(x, y + h));

    return vertices;
  }

  /// Parse circle/ellipse element
  List<double> _parseEllipse(
      String tagContent, Matrix2D transform, bool isCircle) {
    final vertices = <double>[];

    double cx = 0, cy = 0, rx = 0, ry = 0;

    final cxValue = _extractAttr(tagContent, 'cx');
    final cyValue = _extractAttr(tagContent, 'cy');
    if (cxValue != null) cx = _parseLength(cxValue, 0);
    if (cyValue != null) cy = _parseLength(cyValue, 0);

    if (isCircle) {
      final rValue = _extractAttr(tagContent, 'r');
      if (rValue != null) rx = ry = _parseLength(rValue, 0);
    } else {
      final rxValue = _extractAttr(tagContent, 'rx');
      final ryValue = _extractAttr(tagContent, 'ry');
      if (rxValue != null) rx = _parseLength(rxValue, 0);
      if (ryValue != null) ry = _parseLength(ryValue, 0);
    }

    if (rx <= 0 || ry <= 0) return vertices;

    const steps = 32;
    for (int i = 0; i < steps; i++) {
      final angle = 2 * math.pi * i / steps;
      final x = cx + rx * math.cos(angle);
      final y = cy + ry * math.sin(angle);
      vertices.addAll(transform.transform(x, y));
    }

    return vertices;
  }
}
