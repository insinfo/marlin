/// =============================================================================
/// SVG PARSER - Robust Implementation
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
  final int fillColor;
  final int strokeColor;
  final double strokeWidth;
  final bool evenOdd;

  SvgPolygon({
    required this.vertices,
    this.fillColor = 0xFF000000,
    this.strokeColor = 0x00000000,
    this.strokeWidth = 0.0,
    this.evenOdd = true,
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
      : a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;

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

  _ParseContext({
    Matrix2D? transform,
    this.fillColor = 0xFF000000,
    this.strokeColor = 0x00000000,
    this.strokeWidth = 1.0,
    this.fillRule = 'nonzero',
  }) : transform = transform ?? Matrix2D.identity();

  _ParseContext copy() {
    return _ParseContext(
      transform: transform.copy(),
      fillColor: fillColor,
      strokeColor: strokeColor,
      strokeWidth: strokeWidth,
      fillRule: fillRule,
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

    // Parse viewBox or width/height
    final viewBoxMatch = RegExp(r'viewBox="([^"]+)"').firstMatch(svgContent);
    if (viewBoxMatch != null) {
      final parts = viewBoxMatch.group(1)!.split(RegExp(r'[\s,]+'));
      if (parts.length >= 4) {
        width = double.tryParse(parts[2]) ?? width;
        height = double.tryParse(parts[3]) ?? height;
      }
    } else {
      final widthMatch = RegExp(r'width="([0-9.]+)').firstMatch(svgContent);
      final heightMatch = RegExp(r'height="([0-9.]+)').firstMatch(svgContent);
      if (widthMatch != null) width = double.tryParse(widthMatch.group(1)!) ?? width;
      if (heightMatch != null) height = double.tryParse(heightMatch.group(1)!) ?? height;
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
  void _parseHierarchy(String content, _ParseContext ctx, List<SvgPolygon> polygons) {
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
                if (nextChar == ' ' || nextChar == '>' || nextChar == '\t' || nextChar == '\n' || nextChar == '/') {
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
        // Path element
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);
        
        final dMatch = RegExp(r'd="([^"]+)"').firstMatch(tagContent);
        if (dMatch != null && childCtx.fillColor != 0x00000000) {
          final vertices = _parsePathData(dMatch.group(1)!, childCtx.transform);
          if (vertices.isNotEmpty) {
            polygons.add(SvgPolygon(
              vertices: vertices,
              fillColor: childCtx.fillColor,
              strokeColor: childCtx.strokeColor,
              strokeWidth: childCtx.strokeWidth,
              evenOdd: childCtx.fillRule == 'evenodd',
            ));
          }
        }
      } else if (tagName == 'polygon' || tagName == 'polyline') {
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);
        
        final pointsMatch = RegExp(r'points="([^"]+)"').firstMatch(tagContent);
        if (pointsMatch != null && childCtx.fillColor != 0x00000000) {
          final vertices = _parsePoints(pointsMatch.group(1)!, childCtx.transform);
          if (vertices.isNotEmpty) {
            polygons.add(SvgPolygon(
              vertices: vertices,
              fillColor: childCtx.fillColor,
            ));
          }
        }
      } else if (tagName == 'rect') {
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);
        
        if (childCtx.fillColor != 0x00000000) {
          final vertices = _parseRect(tagContent, childCtx.transform);
          if (vertices.isNotEmpty) {
            polygons.add(SvgPolygon(
              vertices: vertices,
              fillColor: childCtx.fillColor,
            ));
          }
        }
      } else if (tagName == 'circle' || tagName == 'ellipse') {
        final childCtx = ctx.copy();
        _applyAttributes(tagContent, childCtx);
        
        if (childCtx.fillColor != 0x00000000) {
          final vertices = _parseEllipse(tagContent, childCtx.transform, tagName == 'circle');
          if (vertices.isNotEmpty) {
            polygons.add(SvgPolygon(
              vertices: vertices,
              fillColor: childCtx.fillColor,
            ));
          }
        }
      }
      
      pos = tagEnd + 1;
    }
  }

  /// Apply attributes from tag to context
  void _applyAttributes(String tagContent, _ParseContext ctx) {
    // Transform
    final transformMatch = RegExp(r'transform="([^"]+)"').firstMatch(tagContent);
    if (transformMatch != null) {
      final localTransform = _parseTransform(transformMatch.group(1)!);
      ctx.transform = ctx.transform.multiply(localTransform);
    }
    
    // Fill
    final fillMatch = RegExp(r'fill="([^"]+)"').firstMatch(tagContent);
    if (fillMatch != null) {
      final color = _parseColor(fillMatch.group(1)!);
      if (color != -1) ctx.fillColor = color;
    }
    
    // Stroke
    final strokeMatch = RegExp(r'stroke="([^"]+)"').firstMatch(tagContent);
    if (strokeMatch != null) {
      final color = _parseColor(strokeMatch.group(1)!);
      if (color != -1) ctx.strokeColor = color;
    }
    
    // Stroke width
    final strokeWidthMatch = RegExp(r'stroke-width="([^"]+)"').firstMatch(tagContent);
    if (strokeWidthMatch != null) {
      ctx.strokeWidth = double.tryParse(strokeWidthMatch.group(1)!) ?? ctx.strokeWidth;
    }
    
    // Fill rule
    final fillRuleMatch = RegExp(r'fill-rule="([^"]+)"').firstMatch(tagContent);
    if (fillRuleMatch != null) {
      ctx.fillRule = fillRuleMatch.group(1)!;
    }
    
    // Style attribute (inline CSS)
    final styleMatch = RegExp(r'style="([^"]+)"').firstMatch(tagContent);
    if (styleMatch != null) {
      _parseStyle(styleMatch.group(1)!, ctx);
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
          if (color != -1) ctx.fillColor = color;
          break;
        case 'stroke':
          final color = _parseColor(value);
          if (color != -1) ctx.strokeColor = color;
          break;
        case 'stroke-width':
          ctx.strokeWidth = double.tryParse(value) ?? ctx.strokeWidth;
          break;
        case 'fill-rule':
          ctx.fillRule = value;
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
      'black': 0xFF000000, 'white': 0xFFFFFFFF, 'red': 0xFFFF0000,
      'green': 0xFF008000, 'blue': 0xFF0000FF, 'yellow': 0xFFFFFF00,
      'cyan': 0xFF00FFFF, 'magenta': 0xFFFF00FF, 'gray': 0xFF808080,
      'grey': 0xFF808080, 'orange': 0xFFFFA500, 'pink': 0xFFFFC0CB,
      'purple': 0xFF800080, 'brown': 0xFFA52A2A, 'lime': 0xFF00FF00,
      'navy': 0xFF000080, 'teal': 0xFF008080, 'silver': 0xFFC0C0C0,
      'maroon': 0xFF800000, 'olive': 0xFF808000, 'aqua': 0xFF00FFFF,
      'fuchsia': 0xFFFF00FF,
    };
    
    if (namedColors.containsKey(color)) return namedColors[color]!;
    
    if (color.startsWith('#')) {
      color = color.substring(1);
      if (color.length == 3) {
        color = '${color[0]}${color[0]}${color[1]}${color[1]}${color[2]}${color[2]}';
      }
      if (color.length == 6) {
        final value = int.tryParse(color, radix: 16);
        if (value != null) return 0xFF000000 | value;
      }
    }
    
    final rgbMatch = RegExp(r'rgb\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)').firstMatch(color);
    if (rgbMatch != null) {
      final r = int.parse(rgbMatch.group(1)!).clamp(0, 255);
      final g = int.parse(rgbMatch.group(2)!).clamp(0, 255);
      final b = int.parse(rgbMatch.group(3)!).clamp(0, 255);
      return 0xFF000000 | (r << 16) | (g << 8) | b;
    }
    
    return 0xFF000000;
  }

  /// Parse SVG transformation
  Matrix2D _parseTransform(String transform) {
    Matrix2D result = Matrix2D.identity();
    
    // Parse all transforms in sequence
    final transforms = RegExp(r'(\w+)\s*\(([^)]+)\)').allMatches(transform);
    for (final match in transforms) {
      final type = match.group(1)!.toLowerCase();
      final argsStr = match.group(2)!;
      final args = argsStr.split(RegExp(r'[\s,]+'))
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

  /// Parse path data
  List<double> _parsePathData(String pathData, Matrix2D transform) {
    final vertices = <double>[];
    final tokens = _tokenizePathData(pathData);
    if (tokens.isEmpty) return vertices;
    
    double currentX = 0, currentY = 0;
    double startX = 0, startY = 0;
    double lastControlX = 0, lastControlY = 0;
    String lastCommand = '';
    
    int i = 0;
    while (i < tokens.length) {
      String command = tokens[i];
      
      if (_isNumber(command)) {
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
            startX = currentX;
            startY = currentY;
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'm':
          if (_hasNumericTokens(tokens, i, 2)) {
            currentX += _parseDouble(tokens, i++);
            currentY += _parseDouble(tokens, i++);
            startX = currentX;
            startY = currentY;
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'L':
          if (_hasNumericTokens(tokens, i, 2)) {
            currentX = _parseDouble(tokens, i++);
            currentY = _parseDouble(tokens, i++);
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'l':
          if (_hasNumericTokens(tokens, i, 2)) {
            currentX += _parseDouble(tokens, i++);
            currentY += _parseDouble(tokens, i++);
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'H':
          if (_hasNumericTokens(tokens, i, 1)) {
            currentX = _parseDouble(tokens, i++);
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'h':
          if (_hasNumericTokens(tokens, i, 1)) {
            currentX += _parseDouble(tokens, i++);
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'V':
          if (_hasNumericTokens(tokens, i, 1)) {
            currentY = _parseDouble(tokens, i++);
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'v':
          if (_hasNumericTokens(tokens, i, 1)) {
            currentY += _parseDouble(tokens, i++);
            vertices.addAll(transform.transform(currentX, currentY));
          }
          break;
        case 'C':
          if (_hasNumericTokens(tokens, i, 6)) {
            final x1 = _parseDouble(tokens, i++);
            final y1 = _parseDouble(tokens, i++);
            final x2 = _parseDouble(tokens, i++);
            final y2 = _parseDouble(tokens, i++);
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addCubicBezier(vertices, currentX, currentY, x1, y1, x2, y2, x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 'c':
          if (_hasNumericTokens(tokens, i, 6)) {
            final x1 = currentX + _parseDouble(tokens, i++);
            final y1 = currentY + _parseDouble(tokens, i++);
            final x2 = currentX + _parseDouble(tokens, i++);
            final y2 = currentY + _parseDouble(tokens, i++);
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addCubicBezier(vertices, currentX, currentY, x1, y1, x2, y2, x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 'S':
          if (_hasNumericTokens(tokens, i, 4)) {
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x2 = _parseDouble(tokens, i++);
            final y2 = _parseDouble(tokens, i++);
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addCubicBezier(vertices, currentX, currentY, x1, y1, x2, y2, x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 's':
          if (_hasNumericTokens(tokens, i, 4)) {
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x2 = currentX + _parseDouble(tokens, i++);
            final y2 = currentY + _parseDouble(tokens, i++);
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addCubicBezier(vertices, currentX, currentY, x1, y1, x2, y2, x, y, transform);
            lastControlX = x2;
            lastControlY = y2;
            currentX = x;
            currentY = y;
          }
          break;
        case 'Q':
          if (_hasNumericTokens(tokens, i, 4)) {
            final x1 = _parseDouble(tokens, i++);
            final y1 = _parseDouble(tokens, i++);
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addQuadraticBezier(vertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 'q':
          if (_hasNumericTokens(tokens, i, 4)) {
            final x1 = currentX + _parseDouble(tokens, i++);
            final y1 = currentY + _parseDouble(tokens, i++);
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addQuadraticBezier(vertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 'T':
          if (_hasNumericTokens(tokens, i, 2)) {
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x = _parseDouble(tokens, i++);
            final y = _parseDouble(tokens, i++);
            _addQuadraticBezier(vertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 't':
          if (_hasNumericTokens(tokens, i, 2)) {
            final x1 = 2 * currentX - lastControlX;
            final y1 = 2 * currentY - lastControlY;
            final x = currentX + _parseDouble(tokens, i++);
            final y = currentY + _parseDouble(tokens, i++);
            _addQuadraticBezier(vertices, currentX, currentY, x1, y1, x, y, transform);
            lastControlX = x1;
            lastControlY = y1;
            currentX = x;
            currentY = y;
          }
          break;
        case 'A':
        case 'a':
          // Arc - simplified approximation
          if (_hasNumericTokens(tokens, i, 7)) {
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
            _addArc(vertices, currentX, currentY, rx, ry, xRotation, largeArc, sweep, x, y, transform);
            currentX = x;
            currentY = y;
          }
          break;
        case 'Z':
        case 'z':
          currentX = startX;
          currentY = startY;
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
    
    return vertices;
  }

  /// Tokenize path data
  List<String> _tokenizePathData(String pathData) {
    final tokens = <String>[];
    final regex = RegExp(r'([MmLlHhVvCcSsQqTtAaZz])|(-?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)');
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
  void _addCubicBezier(List<double> vertices, double x0, double y0,
      double x1, double y1, double x2, double y2, double x3, double y3,
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
  void _addArc(List<double> vertices, double x0, double y0,
      double rx, double ry, double xRotation, bool largeArc, bool sweep,
      double x1, double y1, Matrix2D transform) {
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
    final nums = points.split(RegExp(r'[\s,]+'))
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
    
    final xMatch = RegExp(r'(?:^|\s)x="([^"]+)"').firstMatch(tagContent);
    final yMatch = RegExp(r'(?:^|\s)y="([^"]+)"').firstMatch(tagContent);
    final wMatch = RegExp(r'width="([^"]+)"').firstMatch(tagContent);
    final hMatch = RegExp(r'height="([^"]+)"').firstMatch(tagContent);
    
    if (xMatch != null) x = double.tryParse(xMatch.group(1)!) ?? 0;
    if (yMatch != null) y = double.tryParse(yMatch.group(1)!) ?? 0;
    if (wMatch != null) w = double.tryParse(wMatch.group(1)!) ?? 0;
    if (hMatch != null) h = double.tryParse(hMatch.group(1)!) ?? 0;
    
    if (w <= 0 || h <= 0) return vertices;
    
    vertices.addAll(transform.transform(x, y));
    vertices.addAll(transform.transform(x + w, y));
    vertices.addAll(transform.transform(x + w, y + h));
    vertices.addAll(transform.transform(x, y + h));
    
    return vertices;
  }

  /// Parse circle/ellipse element
  List<double> _parseEllipse(String tagContent, Matrix2D transform, bool isCircle) {
    final vertices = <double>[];
    
    double cx = 0, cy = 0, rx = 0, ry = 0;
    
    final cxMatch = RegExp(r'cx="([^"]+)"').firstMatch(tagContent);
    final cyMatch = RegExp(r'cy="([^"]+)"').firstMatch(tagContent);
    
    if (cxMatch != null) cx = double.tryParse(cxMatch.group(1)!) ?? 0;
    if (cyMatch != null) cy = double.tryParse(cyMatch.group(1)!) ?? 0;
    
    if (isCircle) {
      final rMatch = RegExp(r'(?:^|\s)r="([^"]+)"').firstMatch(tagContent);
      if (rMatch != null) rx = ry = double.tryParse(rMatch.group(1)!) ?? 0;
    } else {
      final rxMatch = RegExp(r'rx="([^"]+)"').firstMatch(tagContent);
      final ryMatch = RegExp(r'ry="([^"]+)"').firstMatch(tagContent);
      if (rxMatch != null) rx = double.tryParse(rxMatch.group(1)!) ?? 0;
      if (ryMatch != null) ry = double.tryParse(ryMatch.group(1)!) ?? 0;
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