import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/bl_path.dart';
import 'bl_cff.dart';
import 'bl_opentype_layout.dart';

/// Face de fonte carregada em memoria.
class BLFontFace {
  final String familyName;
  final String subfamilyName;
  final String fullName;
  final String postScriptName;
  final Uint8List data;
  final int unitsPerEm;
  final int glyphCount;
  final int ascender;
  final int descender;
  final int lineGap;
  final int xHeight;
  final int capHeight;
  final int weightClass;
  final int widthClass;
  final bool useTypographicMetrics;
  final int indexToLocFormat;
  final int locaOffset;
  final int locaLength;
  final int glyfOffset;
  final int glyfLength;
  final bool hasTrueTypeOutlines;
  final bool hasCFFOutlines;
  final int cffOffset;
  final int cffLength;
  final int numHMetrics;
  final int hmtxOffset;
  final int hmtxLength;
  final bool isSymbolFont;
  final int gsubOffset;
  final int gsubLength;
  final int gposOffset;
  final int gposLength;
  final Map<int, int> _kernPairUnits;

  final ByteData _view;
  final _BLCmapMapper _cmapMapper;
  final Map<int, BLPathData> _glyphOutlineUnitsCache = <int, BLPathData>{};

  static const int _ttOnCurvePoint = 0x01;
  static const int _ttXIsByte = 0x02;
  static const int _ttYIsByte = 0x04;
  static const int _ttRepeatFlag = 0x08;
  static const int _ttXIsSameOrPositive = 0x10;
  static const int _ttYIsSameOrPositive = 0x20;

  static const int _ttCompoundArgsAreWords = 0x0001;
  static const int _ttCompoundArgsAreXYValues = 0x0002;
  static const int _ttCompoundWeHaveScale = 0x0008;
  static const int _ttCompoundMoreComponents = 0x0020;
  static const int _ttCompoundWeHaveScaleXY = 0x0040;
  static const int _ttCompoundWeHave2x2 = 0x0080;
  static const int _ttCompoundWeHaveInstructions = 0x0100;
  static const int _ttCompoundScaledComponentOffset = 0x0800;
  static const int _ttCompoundUnscaledComponentOffset = 0x1000;
  static const int _ttCompoundAnyOffset =
      _ttCompoundScaledComponentOffset | _ttCompoundUnscaledComponentOffset;

  BLFontFace({
    required this.familyName,
    required this.subfamilyName,
    required this.fullName,
    required this.postScriptName,
    required this.data,
    required this.unitsPerEm,
    required this.glyphCount,
    required this.ascender,
    required this.descender,
    required this.lineGap,
    required this.xHeight,
    required this.capHeight,
    required this.weightClass,
    required this.widthClass,
    required this.useTypographicMetrics,
    required this.indexToLocFormat,
    required this.locaOffset,
    required this.locaLength,
    required this.glyfOffset,
    required this.glyfLength,
    required this.hasTrueTypeOutlines,
    required this.hasCFFOutlines,
    required this.cffOffset,
    required this.cffLength,
    required this.numHMetrics,
    required this.hmtxOffset,
    required this.hmtxLength,
    required this.isSymbolFont,
    required this.gsubOffset,
    required this.gsubLength,
    required this.gposOffset,
    required this.gposLength,
    required Map<int, int> kernPairUnits,
    required _BLCmapMapper cmapMapper,
  })  : _kernPairUnits = kernPairUnits,
        _cmapMapper = cmapMapper,
        _view = ByteData.sublistView(data);

  /// Lazy-initialized layout engine for GSUB/GPOS.
  BLLayoutEngine? _layoutEngine;

  /// Returns the GSUB/GPOS layout engine, creating it on first access.
  BLLayoutEngine? get layoutEngine {
    if (_layoutEngine != null) return _layoutEngine;
    if (gsubLength == 0 && gposLength == 0) return null;
    _layoutEngine = BLLayoutEngine(
      _view,
      gsubOffset: gsubOffset,
      gsubLength: gsubLength,
      gposOffset: gposOffset,
      gposLength: gposLength,
    );
    return _layoutEngine;
  }

  int mapCodePoint(int codePoint) {
    int gid = _cmapMapper.map(codePoint);
    if (gid != 0) return gid;

    // Fonts with Windows Symbol cmap often store glyphs in U+F000..U+F0FF.
    if (isSymbolFont && codePoint >= 0 && codePoint <= 0xFF) {
      gid = _cmapMapper.map(codePoint + 0xF000);
    }
    return gid;
  }

  int glyphAdvanceUnits(int glyphId) {
    if (hmtxOffset <= 0 || hmtxLength < 4 || numHMetrics <= 0) {
      return unitsPerEm > 0 ? unitsPerEm : 1000;
    }
    int gid = glyphId;
    if (gid < 0) gid = 0;
    if (glyphCount > 0 && gid >= glyphCount) gid = glyphCount - 1;

    final metricIndex = gid < numHMetrics ? gid : (numHMetrics - 1);
    final off = hmtxOffset + metricIndex * 4;
    if (off < 0 || off + 2 > data.lengthInBytes) {
      return unitsPerEm > 0 ? unitsPerEm : 1000;
    }
    return _view.getUint16(off, Endian.big);
  }

  double glyphAdvance(double fontSize, int glyphId) {
    final upm = unitsPerEm > 0 ? unitsPerEm : 1000;
    return glyphAdvanceUnits(glyphId) * (fontSize / upm);
  }

  int kerningUnits(int leftGlyphId, int rightGlyphId) {
    final key = ((leftGlyphId & 0xFFFF) << 16) | (rightGlyphId & 0xFFFF);
    return _kernPairUnits[key] ?? 0;
  }

  double kerning(double fontSize, int leftGlyphId, int rightGlyphId) {
    if (_kernPairUnits.isEmpty) return 0.0;
    final upm = unitsPerEm > 0 ? unitsPerEm : 1000;
    return kerningUnits(leftGlyphId, rightGlyphId) * (fontSize / upm);
  }

  BLGlyphBounds? glyphBoundsUnits(int glyphId) {
    final range = _glyphDataRange(glyphId);
    if (range == null) return null;
    final start = range.$1;
    final end = range.$2;

    if (start == end) {
      return const BLGlyphBounds.empty();
    }
    final dataSize = end - start;
    if (dataSize < 10 || start < 0 || end > data.lengthInBytes) {
      return null;
    }

    final contourCount = _i16(_view, start + 0);
    final xMin = _i16(_view, start + 2);
    final yMin = _i16(_view, start + 4);
    final xMax = _i16(_view, start + 6);
    final yMax = _i16(_view, start + 8);

    // Blend2D/FreeType convention in pipeline: Y up in font -> Y down in raster.
    final top = -yMax;
    final bottom = -yMin;
    return BLGlyphBounds(
      left: xMin,
      top: top,
      right: xMax,
      bottom: bottom,
      contourCount: contourCount,
      isComposite: contourCount < 0,
    );
  }

  BLPathData? glyphOutlineUnits(
    int glyphId, {
    int maxCompoundDepth = 16,
  }) {
    if (glyphCount <= 0) return null;

    int gid = glyphId;
    if (gid < 0) gid = 0;
    if (gid >= glyphCount) gid = glyphCount - 1;

    final cached = _glyphOutlineUnitsCache[gid];
    if (cached != null) return cached;

    BLPathData? out;

    if (hasTrueTypeOutlines) {
      final path = BLPath();
      final decodingStack = <int>{};
      final ok = _appendGlyphOutlineUnits(
        path,
        gid,
        _BLGlyphTransform.identity(),
        0,
        maxCompoundDepth < 1 ? 1 : maxCompoundDepth,
        decodingStack,
      );
      if (ok) out = path.toPathData();
    } else if (hasCFFOutlines) {
      out = BLCFFDecoder.decodeGlyph(
        _view,
        cffOffset,
        cffLength,
        gid,
      );
    }

    if (out == null) return null;

    if (_glyphOutlineUnitsCache.length >= 2048 &&
        !_glyphOutlineUnitsCache.containsKey(gid)) {
      _glyphOutlineUnitsCache.remove(_glyphOutlineUnitsCache.keys.first);
    }
    _glyphOutlineUnitsCache[gid] = out;
    return out;
  }

  void clearGlyphOutlineCache() {
    _glyphOutlineUnitsCache.clear();
  }

  (int, int)? _glyphDataRange(int glyphId) {
    if (!hasTrueTypeOutlines || glyphCount <= 0) return null;

    int gid = glyphId;
    if (gid < 0) gid = 0;
    if (gid >= glyphCount) gid = glyphCount - 1;

    if (indexToLocFormat == 0) {
      final idx = gid * 2;
      if (idx + 4 > locaLength) return null;
      final off0 = _u16(_view, locaOffset + idx) * 2;
      final off1 = _u16(_view, locaOffset + idx + 2) * 2;
      if (off0 > off1 || off1 > glyfLength) return null;
      return (glyfOffset + off0, glyfOffset + off1);
    }

    final idx = gid * 4;
    if (idx + 8 > locaLength) return null;
    final off0 = _u32(_view, locaOffset + idx);
    final off1 = _u32(_view, locaOffset + idx + 4);
    if (off0 > off1 || off1 > glyfLength) return null;
    return (glyfOffset + off0, glyfOffset + off1);
  }

  bool _appendGlyphOutlineUnits(
    BLPath path,
    int glyphId,
    _BLGlyphTransform transform,
    int depth,
    int maxCompoundDepth,
    Set<int> decodingStack,
  ) {
    if (depth > maxCompoundDepth) return false;
    if (!decodingStack.add(glyphId)) return false;

    bool ok = false;
    try {
      final range = _glyphDataRange(glyphId);
      if (range == null) {
        ok = false;
      } else {
        final start = range.$1;
        final end = range.$2;
        if (start == end) {
          ok = true;
        } else {
          if (start < 0 || end > data.lengthInBytes || end - start < 10) {
            ok = false;
          } else {
            final contourCount = _i16(_view, start);
            if (contourCount > 0) {
              ok = _decodeSimpleGlyphToPath(
                path,
                start,
                end,
                contourCount,
                transform,
              );
            } else if (contourCount == -1) {
              ok = _decodeCompoundGlyphToPath(
                path,
                start,
                end,
                transform,
                depth,
                maxCompoundDepth,
                decodingStack,
              );
            } else if (contourCount == 0) {
              ok = true;
            } else {
              ok = false;
            }
          }
        }
      }
    } finally {
      decodingStack.remove(glyphId);
    }

    return ok;
  }

  bool _decodeSimpleGlyphToPath(
    BLPath path,
    int start,
    int end,
    int contourCount,
    _BLGlyphTransform transform,
  ) {
    int p = start + 10;

    final endPts = Int32List(contourCount);
    for (int i = 0; i < contourCount; i++) {
      if (p + 2 > end) return false;
      endPts[i] = _u16(_view, p);
      p += 2;
    }
    if (contourCount <= 0) return true;

    final pointCount = endPts[contourCount - 1] + 1;
    if (pointCount <= 0) return true;

    if (p + 2 > end) return false;
    final instructionLength = _u16(_view, p);
    p += 2;
    if (instructionLength < 0 || p + instructionLength > end) return false;
    p += instructionLength;

    final flags = Uint8List(pointCount);
    int fi = 0;
    while (fi < pointCount) {
      if (p >= end) return false;
      final f = _view.getUint8(p++);
      flags[fi++] = f;
      if ((f & _ttRepeatFlag) == 0) continue;

      if (p >= end) return false;
      final repeat = _view.getUint8(p++);
      if (fi + repeat > pointCount) return false;
      for (int r = 0; r < repeat; r++) {
        flags[fi++] = f;
      }
    }

    final xs = Int32List(pointCount);
    final ys = Int32List(pointCount);

    int x = 0;
    for (int i = 0; i < pointCount; i++) {
      final f = flags[i];
      int dx;
      if ((f & _ttXIsByte) != 0) {
        if (p >= end) return false;
        dx = _view.getUint8(p++);
        if ((f & _ttXIsSameOrPositive) == 0) dx = -dx;
      } else if ((f & _ttXIsSameOrPositive) != 0) {
        dx = 0;
      } else {
        if (p + 2 > end) return false;
        dx = _i16(_view, p);
        p += 2;
      }
      x += dx;
      xs[i] = x;
    }

    int y = 0;
    for (int i = 0; i < pointCount; i++) {
      final f = flags[i];
      int dy;
      if ((f & _ttYIsByte) != 0) {
        if (p >= end) return false;
        dy = _view.getUint8(p++);
        if ((f & _ttYIsSameOrPositive) == 0) dy = -dy;
      } else if ((f & _ttYIsSameOrPositive) != 0) {
        dy = 0;
      } else {
        if (p + 2 > end) return false;
        dy = _i16(_view, p);
        p += 2;
      }
      y += dy;
      ys[i] = y;
    }

    int contourStart = 0;
    for (int c = 0; c < contourCount; c++) {
      final contourEnd = endPts[c];
      if (contourEnd < contourStart || contourEnd >= pointCount) return false;
      _appendSimpleContour(
        path,
        xs,
        ys,
        flags,
        contourStart,
        contourEnd,
        transform,
      );
      contourStart = contourEnd + 1;
    }

    return true;
  }

  bool _decodeCompoundGlyphToPath(
    BLPath path,
    int start,
    int end,
    _BLGlyphTransform parentTransform,
    int depth,
    int maxCompoundDepth,
    Set<int> decodingStack,
  ) {
    int p = start + 10;
    bool hasMore = true;

    while (hasMore) {
      if (p + 4 > end) return false;

      final flags = _u16(_view, p);
      int componentGlyphId = _u16(_view, p + 2);
      p += 4;

      int arg1;
      int arg2;
      if ((flags & _ttCompoundArgsAreWords) != 0) {
        if (p + 4 > end) return false;
        arg1 = _i16(_view, p);
        arg2 = _i16(_view, p + 2);
        p += 4;
      } else {
        if (p + 2 > end) return false;
        arg1 = _view.getInt8(p);
        arg2 = _view.getInt8(p + 1);
        p += 2;
      }

      final local = _BLGlyphTransform.identity();
      if ((flags & _ttCompoundArgsAreXYValues) != 0) {
        local.m20 = arg1.toDouble();
        local.m21 = arg2.toDouble();
      }

      if ((flags & _ttCompoundWeHaveScale) != 0) {
        if (p + 2 > end) return false;
        final s = _i16(_view, p) / 16384.0;
        local.m00 = s;
        local.m11 = s;
        p += 2;
      } else if ((flags & _ttCompoundWeHaveScaleXY) != 0) {
        if (p + 4 > end) return false;
        local.m00 = _i16(_view, p) / 16384.0;
        local.m11 = _i16(_view, p + 2) / 16384.0;
        p += 4;
      } else if ((flags & _ttCompoundWeHave2x2) != 0) {
        if (p + 8 > end) return false;
        local.m00 = _i16(_view, p) / 16384.0;
        local.m01 = _i16(_view, p + 2) / 16384.0;
        local.m10 = _i16(_view, p + 4) / 16384.0;
        local.m11 = _i16(_view, p + 6) / 16384.0;
        p += 8;
      }

      // Compatibilidade com comportamento de rasterizadores de referência:
      // quando deslocamento escalado é explicitamente solicitado, escala a
      // tradução pelo módulo dos vetores-base.
      if ((flags & (_ttCompoundArgsAreXYValues | _ttCompoundAnyOffset)) ==
          (_ttCompoundArgsAreXYValues | _ttCompoundScaledComponentOffset)) {
        local.m20 *= math.sqrt(local.m00 * local.m00 + local.m01 * local.m01);
        local.m21 *= math.sqrt(local.m10 * local.m10 + local.m11 * local.m11);
      }

      if (componentGlyphId < 0 || componentGlyphId >= glyphCount) return false;
      final combined = _BLGlyphTransform.multiply(local, parentTransform);
      final ok = _appendGlyphOutlineUnits(
        path,
        componentGlyphId,
        combined,
        depth + 1,
        maxCompoundDepth,
        decodingStack,
      );
      if (!ok) return false;

      hasMore = (flags & _ttCompoundMoreComponents) != 0;
      if (!hasMore && (flags & _ttCompoundWeHaveInstructions) != 0) {
        if (p + 2 > end) return false;
        final instructionsLength = _u16(_view, p);
        p += 2;
        if (p + instructionsLength > end) return false;
        p += instructionsLength;
      }
    }

    return true;
  }

  void _appendSimpleContour(
    BLPath path,
    Int32List xs,
    Int32List ys,
    Uint8List flags,
    int start,
    int end,
    _BLGlyphTransform transform,
  ) {
    final n = end - start + 1;
    if (n <= 0) return;

    final points = List<_BLGlyphPoint>.filled(
      n,
      const _BLGlyphPoint(0.0, 0.0, false),
      growable: false,
    );
    for (int i = 0; i < n; i++) {
      final idx = start + i;
      final p = transform.apply(xs[idx].toDouble(), ys[idx].toDouble());
      points[i] = _BLGlyphPoint(
        p.$1,
        -p.$2,
        (flags[idx] & _ttOnCurvePoint) != 0,
      );
    }

    final first = points[0];
    final last = points[n - 1];
    double startX;
    double startY;
    int startIndex;

    if (first.onCurve) {
      startX = first.x;
      startY = first.y;
      startIndex = 1 % n;
    } else if (last.onCurve) {
      startX = last.x;
      startY = last.y;
      startIndex = 0;
    } else {
      startX = (first.x + last.x) * 0.5;
      startY = (first.y + last.y) * 0.5;
      startIndex = 0;
    }

    path.moveTo(startX, startY);

    int processed = 0;
    int idx = startIndex;
    while (processed < n) {
      final curr = points[idx];
      final next = points[(idx + 1) % n];

      if (curr.onCurve) {
        final isRedundantClose =
            processed == n - 1 && curr.x == startX && curr.y == startY;
        if (!isRedundantClose) {
          path.lineTo(curr.x, curr.y);
        }
        idx = (idx + 1) % n;
        processed += 1;
        continue;
      }

      if (next.onCurve) {
        path.quadTo(curr.x, curr.y, next.x, next.y);
        idx = (idx + 2) % n;
        processed += 2;
      } else {
        final mx = (curr.x + next.x) * 0.5;
        final my = (curr.y + next.y) * 0.5;
        path.quadTo(curr.x, curr.y, mx, my);
        idx = (idx + 1) % n;
        processed += 1;
      }
    }

    path.close();
  }

  static BLFontFace parse(
    Uint8List data, {
    String? familyName,
  }) {
    final view = ByteData.sublistView(data);
    final tableMap = _readSfntTableDirectory(view);

    final head = tableMap[_tag('head')];
    final maxp = tableMap[_tag('maxp')];
    final hhea = tableMap[_tag('hhea')];
    final hmtx = tableMap[_tag('hmtx')];
    final cmap = tableMap[_tag('cmap')];
    final kern = tableMap[_tag('kern')];
    final name = tableMap[_tag('name')];
    final os2 = tableMap[_tag('OS/2')];
    final loca = tableMap[_tag('loca')];
    final glyf = tableMap[_tag('glyf')];
    final cffTable = tableMap[_tag('CFF ')];
    final gsubTable = tableMap[_tag('GSUB')];
    final gposTable = tableMap[_tag('GPOS')];

    int unitsPerEm = 1000;
    int indexToLocFormat = 0;
    if (head != null && head.length >= 54) {
      unitsPerEm = _u16(view, head.offset + 18);
      if (unitsPerEm <= 0) unitsPerEm = 1000;
      indexToLocFormat = _i16(view, head.offset + 50);
      if (indexToLocFormat != 0 && indexToLocFormat != 1) {
        indexToLocFormat = 0;
      }
    }

    int glyphCount = 0;
    if (maxp != null && maxp.length >= 6) {
      glyphCount = _u16(view, maxp.offset + 4);
    }

    int ascender = 0;
    int descender = 0;
    int lineGap = 0;
    int xHeight = 0;
    int capHeight = 0;
    int weightClass = 400;
    int widthClass = 5;
    bool useTypographicMetrics = false;
    int numHMetrics = 0;
    if (hhea != null && hhea.length >= 36) {
      ascender = _i16(view, hhea.offset + 4);
      descender = _i16(view, hhea.offset + 6);
      lineGap = _i16(view, hhea.offset + 8);
      numHMetrics = _u16(view, hhea.offset + 34);
    }

    if (os2 != null && os2.length >= 8) {
      final os2Version = _u16(view, os2.offset);

      final parsedWeight = _u16(view, os2.offset + 4);
      if (parsedWeight >= 1 && parsedWeight <= 9) {
        weightClass = parsedWeight * 100;
      } else if (parsedWeight > 0) {
        weightClass = parsedWeight;
      }
      if (weightClass < 1) weightClass = 1;
      if (weightClass > 999) weightClass = 999;

      final parsedWidth = _u16(view, os2.offset + 6);
      if (parsedWidth > 0) widthClass = parsedWidth;
      if (widthClass < 1) widthClass = 1;
      if (widthClass > 9) widthClass = 9;

      if (os2.length >= 74) {
        final fsSelection = _u16(view, os2.offset + 62);
        useTypographicMetrics = (fsSelection & 0x0080) != 0;

        final typoAsc = _i16(view, os2.offset + 68);
        final typoDesc = _i16(view, os2.offset + 70);
        final typoLineGap = _i16(view, os2.offset + 72);

        final missingHhea = hhea == null || hhea.length < 36;
        if (useTypographicMetrics || missingHhea) {
          ascender = typoAsc;
          descender = typoDesc;
          lineGap = typoLineGap;
        }

        if (os2Version >= 2 && os2.length >= 90) {
          xHeight = _i16(view, os2.offset + 86);
          capHeight = _i16(view, os2.offset + 88);
        }
      }
    }

    int hmtxOffset = 0;
    int hmtxLength = 0;
    int locaOffset = 0;
    int locaLength = 0;
    int glyfOffset = 0;
    int glyfLength = 0;
    bool hasTrueTypeOutlines = false;
    if (hmtx != null && hmtx.length > 0) {
      hmtxOffset = hmtx.offset;
      hmtxLength = hmtx.length;
    }
    if (loca != null && loca.length > 0 && glyf != null && glyf.length > 0) {
      locaOffset = loca.offset;
      locaLength = loca.length;
      glyfOffset = glyf.offset;
      glyfLength = glyf.length;
      hasTrueTypeOutlines = true;
    }

    bool hasCFFOutlines = false;
    int cffOffsetVal = 0;
    int cffLengthVal = 0;
    if (!hasTrueTypeOutlines && cffTable != null && cffTable.length > 4) {
      hasCFFOutlines = true;
      cffOffsetVal = cffTable.offset;
      cffLengthVal = cffTable.length;
    }

    bool isSymbolFont = false;
    _BLCmapMapper cmapMapper = _BLCmapNone.instance;
    if (cmap != null && cmap.length >= 4) {
      final selected = _selectCmapEncoding(view, cmap.offset, cmap.length);
      if (selected != null) {
        isSymbolFont = selected.$3;
        cmapMapper = _buildCmapMapper(
          view,
          cmap.offset,
          cmap.length,
          selected.$1,
          selected.$2,
        );
      }
    }

    final kernPairUnits = <int, int>{};
    if (kern != null && kern.length >= 4) {
      _parseLegacyKern(view, kern.offset, kern.length, kernPairUnits);
    }

    final names =
        name != null ? _parseNameTable(view, name.offset, name.length) : null;
    final resolvedFamily = (familyName != null && familyName.trim().isNotEmpty)
        ? familyName
        : ((names?.family.isNotEmpty ?? false) ? names!.family : 'Unknown');
    final resolvedSubfamily = names?.subfamily ?? '';
    final resolvedFull = names?.full ?? '';
    final resolvedPs = names?.postScript ?? '';

    return BLFontFace(
      familyName: resolvedFamily,
      subfamilyName: resolvedSubfamily,
      fullName: resolvedFull,
      postScriptName: resolvedPs,
      data: Uint8List.fromList(data),
      unitsPerEm: unitsPerEm,
      glyphCount: glyphCount,
      ascender: ascender,
      descender: descender,
      lineGap: lineGap,
      xHeight: xHeight,
      capHeight: capHeight,
      weightClass: weightClass,
      widthClass: widthClass,
      useTypographicMetrics: useTypographicMetrics,
      indexToLocFormat: indexToLocFormat,
      locaOffset: locaOffset,
      locaLength: locaLength,
      glyfOffset: glyfOffset,
      glyfLength: glyfLength,
      hasTrueTypeOutlines: hasTrueTypeOutlines,
      hasCFFOutlines: hasCFFOutlines,
      cffOffset: cffOffsetVal,
      cffLength: cffLengthVal,
      numHMetrics: numHMetrics,
      hmtxOffset: hmtxOffset,
      hmtxLength: hmtxLength,
      isSymbolFont: isSymbolFont,
      gsubOffset: gsubTable?.offset ?? 0,
      gsubLength: gsubTable?.length ?? 0,
      gposOffset: gposTable?.offset ?? 0,
      gposLength: gposTable?.length ?? 0,
      kernPairUnits: kernPairUnits,
      cmapMapper: cmapMapper,
    );
  }

  static Map<int, _BLTableRecord> _readSfntTableDirectory(ByteData view) {
    final out = <int, _BLTableRecord>{};
    if (view.lengthInBytes < 12) return out;

    final numTables = _u16(view, 4);
    final recordsOffset = 12;
    final recordsEnd = recordsOffset + numTables * 16;
    if (numTables == 0 || recordsEnd > view.lengthInBytes) return out;

    for (int i = 0; i < numTables; i++) {
      final recOff = recordsOffset + i * 16;
      final tag = _u32(view, recOff);
      final offset = _u32(view, recOff + 8);
      final length = _u32(view, recOff + 12);
      if (length <= 0) continue;
      if (offset < 0 || offset + length > view.lengthInBytes) continue;
      out[tag] = _BLTableRecord(offset, length);
    }
    return out;
  }

  static (int, int, bool)? _selectCmapEncoding(
    ByteData view,
    int cmapOffset,
    int cmapLength,
  ) {
    if (cmapLength < 4) return null;

    final encodingCount = _u16(view, cmapOffset + 2);
    final encRecOffset = cmapOffset + 4;
    final encRecEnd = encRecOffset + encodingCount * 8;
    if (encodingCount <= 0 || encRecEnd > cmapOffset + cmapLength) return null;

    const int kScoreNothing = 0x00000;
    const int kScoreMacRoman = 0x00001;
    const int kScoreSymbolFont = 0x00002;
    const int kScoreAnyUnicode = 0x10000;
    const int kScoreWinUnicode = 0x20000;

    int matchedScore = kScoreNothing;
    int matchedSubOffset = -1;
    int matchedFormat = -1;
    bool matchedSymbol = false;

    for (int i = 0; i < encodingCount; i++) {
      final recOff = encRecOffset + i * 8;
      final platformId = _u16(view, recOff);
      final encodingId = _u16(view, recOff + 2);
      final subOffset = _u32(view, recOff + 4);

      if (subOffset < 0 || subOffset + 4 > cmapLength) continue;
      final absSubOff = cmapOffset + subOffset;
      final format = _u16(view, absSubOff);
      if (!_isSupportedCmapFormat(format)) continue;

      int score = kScoreNothing;
      bool symbol = false;
      if (platformId == 0) {
        score = kScoreAnyUnicode + encodingId;
      } else if (platformId == 3) {
        if (encodingId == 0) {
          score = kScoreSymbolFont;
          symbol = true;
        } else if (encodingId == 1 || encodingId == 10) {
          score = kScoreWinUnicode + encodingId;
        }
      } else if (platformId == 1) {
        if (encodingId == 0 && format == 0) {
          score = kScoreMacRoman;
        }
      }

      if (score > matchedScore) {
        matchedScore = score;
        matchedSubOffset = subOffset;
        matchedFormat = format;
        matchedSymbol = symbol;
      }
    }

    if (matchedScore == kScoreNothing || matchedSubOffset < 0) return null;
    return (matchedSubOffset, matchedFormat, matchedSymbol);
  }

  static _BLCmapMapper _buildCmapMapper(
    ByteData view,
    int cmapOffset,
    int cmapLength,
    int subOffset,
    int format,
  ) {
    final base = cmapOffset + subOffset;
    final available = cmapLength - subOffset;
    if (available < 4) return _BLCmapNone.instance;

    switch (format) {
      case 0:
        if (available < 262) return _BLCmapNone.instance;
        final length = _u16(view, base + 2);
        if (length < 262 || length > available) return _BLCmapNone.instance;
        return _BLCmapFormat0(view, base + 6);

      case 4:
        if (available < 24) return _BLCmapNone.instance;
        final length = _u16(view, base + 2);
        if (length < 24 || length > available) return _BLCmapNone.instance;
        final numSegX2 = _u16(view, base + 6);
        if (numSegX2 <= 0 || (numSegX2 & 1) != 0) return _BLCmapNone.instance;
        final numSeg = numSegX2 >> 1;

        final endCodesOff = base + 14;
        final startCodesOff = endCodesOff + numSeg * 2 + 2;
        final idDeltaOff = startCodesOff + numSeg * 2;
        final idRangeOff = idDeltaOff + numSeg * 2;
        final endOff = idRangeOff + numSeg * 2;
        if (endOff > base + length) return _BLCmapNone.instance;

        final startCodes = Int32List(numSeg);
        final endCodes = Int32List(numSeg);
        final idDeltas = Int32List(numSeg);
        final idRangeOffsets = Int32List(numSeg);

        for (int i = 0; i < numSeg; i++) {
          endCodes[i] = _u16(view, endCodesOff + i * 2);
          startCodes[i] = _u16(view, startCodesOff + i * 2);
          idDeltas[i] = _i16(view, idDeltaOff + i * 2);
          idRangeOffsets[i] = _u16(view, idRangeOff + i * 2);
        }

        return _BLCmapFormat4(
          view,
          startCodes,
          endCodes,
          idDeltas,
          idRangeOffsets,
          idRangeOff,
        );

      case 6:
        if (available < 10) return _BLCmapNone.instance;
        final length = _u16(view, base + 2);
        if (length < 10 || length > available) return _BLCmapNone.instance;
        final firstCode = _u16(view, base + 6);
        final entryCount = _u16(view, base + 8);
        if (entryCount <= 0) return _BLCmapNone.instance;
        if (10 + entryCount * 2 > length) return _BLCmapNone.instance;
        return _BLCmapFormat6(view, firstCode, entryCount, base + 10);

      case 10:
        if (available < 20) return _BLCmapNone.instance;
        final length = _u32(view, base + 4);
        if (length < 20 || length > available) return _BLCmapNone.instance;
        final firstCode = _u32(view, base + 12);
        final entryCount = _u32(view, base + 16);
        if (entryCount <= 0) return _BLCmapNone.instance;
        if (firstCode > 0x10FFFF || entryCount > 0x10FFFF)
          return _BLCmapNone.instance;
        if (firstCode + entryCount > 0x110000) return _BLCmapNone.instance;
        if (20 + entryCount * 2 > length) return _BLCmapNone.instance;
        return _BLCmapFormat10(view, firstCode, entryCount, base + 20);

      case 12:
      case 13:
        if (available < 16) return _BLCmapNone.instance;
        final length = _u32(view, base + 4);
        if (length < 16 || length > available) return _BLCmapNone.instance;
        final groupCount = _u32(view, base + 12);
        if (groupCount <= 0) return _BLCmapNone.instance;
        if (16 + groupCount * 12 > length) return _BLCmapNone.instance;

        final starts = Int32List(groupCount);
        final ends = Int32List(groupCount);
        final glyphs = Int32List(groupCount);
        int prevEnd = -1;

        for (int i = 0; i < groupCount; i++) {
          final goff = base + 16 + i * 12;
          final first = _u32(view, goff);
          final last = _u32(view, goff + 4);
          final glyph = _u32(view, goff + 8);
          if (first > last) return _BLCmapNone.instance;
          if (prevEnd >= 0 && first <= prevEnd) return _BLCmapNone.instance;
          starts[i] = first;
          ends[i] = last;
          glyphs[i] = glyph;
          prevEnd = last;
        }

        return _BLCmapFormat12Or13(starts, ends, glyphs, format == 13);

      default:
        return _BLCmapNone.instance;
    }
  }

  static void _parseLegacyKern(
    ByteData view,
    int kernOffset,
    int kernLength,
    Map<int, int> outPairs,
  ) {
    if (kernLength < 4) return;
    final tableEnd = kernOffset + kernLength;
    if (tableEnd > view.lengthInBytes) return;

    int headerSize;
    int groupCount;

    final version16 = _u16(view, kernOffset);
    if (version16 == 0) {
      headerSize = 4;
      groupCount = _u16(view, kernOffset + 2);
    } else {
      final version32 = _u32(view, kernOffset);
      // Apple old header 1.0 fixed (0x00010000).
      if (version32 != 0x00010000 || kernLength < 8) return;
      headerSize = 8;
      groupCount = _u32(view, kernOffset + 4);
    }

    int p = kernOffset + headerSize;
    for (int gi = 0; gi < groupCount; gi++) {
      if (p + 6 > tableEnd) break;

      int subLength;
      int format;
      int coverage;
      int dataStart;

      if (headerSize == 4) {
        // Windows style group header.
        subLength = _u16(view, p + 2);
        format = view.getUint8(p + 4);
        coverage = view.getUint8(p + 5);
        dataStart = p + 6;
      } else {
        // Mac style group header.
        subLength = _u32(view, p);
        coverage = view.getUint8(p + 4);
        format = view.getUint8(p + 5);
        dataStart = p + 8;
      }

      if (subLength <= 0 || p + subLength > tableEnd) break;

      final isHorizontal =
          headerSize == 4 ? ((coverage & 0x01) != 0) : ((coverage & 0x80) == 0);
      final isCrossStream =
          headerSize == 4 ? ((coverage & 0x04) != 0) : ((coverage & 0x40) != 0);

      if (isHorizontal && !isCrossStream && format == 0) {
        _parseKernFormat0(view, dataStart, p + subLength, outPairs);
      }

      p += subLength;
    }
  }

  static void _parseKernFormat0(
    ByteData view,
    int dataStart,
    int dataEnd,
    Map<int, int> outPairs,
  ) {
    if (dataStart + 8 > dataEnd) return;
    final pairCount = _u16(view, dataStart);
    final pairDataStart = dataStart + 8;
    final required = pairDataStart + pairCount * 6;
    if (required > dataEnd) return;

    int off = pairDataStart;
    for (int i = 0; i < pairCount; i++, off += 6) {
      final left = _u16(view, off);
      final right = _u16(view, off + 2);
      final value = _i16(view, off + 4);
      if (value == 0) continue;
      final key = (left << 16) | right;
      outPairs[key] = (outPairs[key] ?? 0) + value;
    }
  }

  static _BLParsedNameTable? _parseNameTable(
    ByteData view,
    int nameOffset,
    int nameLength,
  ) {
    if (nameLength < 6) return null;
    final tableEnd = nameOffset + nameLength;
    if (nameOffset < 0 || tableEnd > view.lengthInBytes) return null;

    final format = _u16(view, nameOffset);
    if (format > 1) return null;

    final recordCount = _u16(view, nameOffset + 2);
    final stringOffset = _u16(view, nameOffset + 4);
    if (recordCount <= 0) return null;

    final recordsStart = nameOffset + 6;
    final recordsEnd = recordsStart + recordCount * 12;
    if (recordsEnd > tableEnd) return null;

    if (stringOffset >= nameLength) return null;
    final stringRegionStart = nameOffset + stringOffset;
    final stringRegionSize = nameLength - stringOffset;
    if (stringRegionStart < nameOffset || stringRegionStart > tableEnd)
      return null;

    final selected = <int, _BLNameCandidate>{};

    for (int i = 0; i < recordCount; i++) {
      final recOff = recordsStart + i * 12;
      final platformId = _u16(view, recOff);
      final specificId = _u16(view, recOff + 2);
      final languageId = _u16(view, recOff + 4);
      final nameId = _u16(view, recOff + 6);
      final stringLength = _u16(view, recOff + 8);
      int stringOff = _u16(view, recOff + 10);

      if (!_isInterestingNameId(nameId)) continue;
      if (stringLength == 0) {
        stringOff = 0;
      } else if (stringOff >= stringRegionSize ||
          (stringRegionSize - stringOff) < stringLength) {
        continue;
      }

      final score = _scoreNameRecord(platformId, specificId, languageId);
      if (score <= 0) continue;

      final text = _decodeNameString(
        view,
        stringRegionStart + stringOff,
        stringLength,
        platformId,
      );
      if (text == null) continue;

      int finalScore = score;
      // Blend2D: prioriza subfamily vazia de Mac quando existir.
      if (platformId == 1 && nameId == 2 && text.isEmpty) {
        finalScore = 0xFFFF;
      }

      final prev = selected[nameId];
      if (prev == null || finalScore > prev.score) {
        selected[nameId] = _BLNameCandidate(text, finalScore);
      }
    }

    if (selected.isEmpty) return null;

    // Preferencia tipografica: usa name IDs 16/17 quando presentes.
    if (selected.containsKey(16)) {
      selected.remove(1);
      selected.remove(21);
    }
    if (selected.containsKey(17)) {
      selected.remove(2);
      selected.remove(22);
    }

    String family = _pickBestName(selected, const [16, 1, 21]);
    String subfamily = _pickBestName(selected, const [17, 2, 22]);
    final full = _pickBestName(selected, const [4]);
    final postScript = _pickBestName(selected, const [6]);

    if (family.isNotEmpty &&
        subfamily.isNotEmpty &&
        family.endsWith(subfamily)) {
      subfamily = '';
    }

    return _BLParsedNameTable(
      family: family,
      subfamily: subfamily,
      full: full,
      postScript: postScript,
    );
  }

  static bool _isInterestingNameId(int nameId) {
    switch (nameId) {
      case 1: // Family
      case 2: // Subfamily
      case 4: // Full
      case 6: // PostScript
      case 16: // Typographic Family
      case 17: // Typographic Subfamily
      case 21: // WWS Family
      case 22: // WWS Subfamily
        return true;
      default:
        return false;
    }
  }

  static int _scoreNameRecord(
    int platformId,
    int specificId,
    int languageId,
  ) {
    switch (platformId) {
      case 0: // Unicode
        return 3;

      case 1: // Mac
        if (specificId != 0) return 0; // Roman only
        int score = 2;
        if (languageId == 0) {
          score |= (0x01 << 8);
        }
        return score;

      case 3: // Windows
        int score;
        if (specificId == 0) {
          score = 1; // Symbol
        } else if (specificId == 1 || specificId == 10) {
          score = 4; // Unicode UCS2/UCS4
        } else {
          return 0;
        }

        final primaryLanguageId = languageId & 0xFF;
        if (primaryLanguageId == 0x09) {
          // English variants.
          if (languageId == 0x0409) {
            score |= (0x04 << 8); // en-US
          } else if (languageId == 0x0809) {
            score |= (0x03 << 8); // en-UK
          } else {
            score |= (0x02 << 8); // any English
          }
        }
        return score;

      default:
        return 0;
    }
  }

  static String _pickBestName(
    Map<int, _BLNameCandidate> selected,
    List<int> ids,
  ) {
    for (final id in ids) {
      final entry = selected[id];
      if (entry != null) return entry.value;
    }
    return '';
  }

  static String? _decodeNameString(
    ByteData view,
    int offset,
    int length,
    int platformId,
  ) {
    if (length < 0 || offset < 0 || offset + length > view.lengthInBytes)
      return null;

    final isUtf16Be = platformId == 0 || platformId == 3;
    if (isUtf16Be) {
      return _decodeUtf16BeString(view, offset, length);
    }
    return _decodeLatin1String(view, offset, length);
  }

  static String? _decodeLatin1String(ByteData view, int offset, int length) {
    if (length == 0) return '';

    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = view.getUint8(offset + i);
    }

    int end = bytes.length;
    while (end > 0 && bytes[end - 1] == 0) {
      end--;
    }
    for (int i = 0; i < end; i++) {
      if (bytes[i] == 0) return null;
    }
    if (end == 0) return '';
    return String.fromCharCodes(bytes.sublist(0, end));
  }

  static String? _decodeUtf16BeString(ByteData view, int offset, int length) {
    if (length < 2) return '';
    final unitCount = length >> 1;
    if (unitCount == 0) return '';

    final units = Uint16List(unitCount);
    for (int i = 0; i < unitCount; i++) {
      units[i] = view.getUint16(offset + i * 2, Endian.big);
    }

    int end = unitCount;
    while (end > 0 && units[end - 1] == 0) {
      end--;
    }
    for (int i = 0; i < end; i++) {
      if (units[i] == 0) return null;
    }
    if (end == 0) return '';
    return String.fromCharCodes(units.sublist(0, end));
  }

  static bool _isSupportedCmapFormat(int format) {
    switch (format) {
      case 0:
      case 4:
      case 6:
      case 10:
      case 12:
      case 13:
        return true;
      default:
        return false;
    }
  }

  static int _tag(String s) {
    return (s.codeUnitAt(0) << 24) |
        (s.codeUnitAt(1) << 16) |
        (s.codeUnitAt(2) << 8) |
        s.codeUnitAt(3);
  }

  @pragma('vm:prefer-inline')
  static int _u16(ByteData d, int o) => d.getUint16(o, Endian.big);

  @pragma('vm:prefer-inline')
  static int _i16(ByteData d, int o) => d.getInt16(o, Endian.big);

  @pragma('vm:prefer-inline')
  static int _u32(ByteData d, int o) => d.getUint32(o, Endian.big);
}

/// Instancia de fonte com tamanho configurado.
class BLFont {
  final BLFontFace face;
  final double size;
  final Map<int, BLPathData> _glyphOutlineCache = <int, BLPathData>{};

  BLFont(this.face, this.size);

  BLFont withSize(double newSize) => BLFont(face, newSize);

  double glyphAdvance(int glyphId) => face.glyphAdvance(size, glyphId);

  double kerning(int leftGlyphId, int rightGlyphId) {
    return face.kerning(size, leftGlyphId, rightGlyphId);
  }

  /// Converts a value in font units to the current font size.
  double scaleValue(int fontUnits) {
    final upm = face.unitsPerEm > 0 ? face.unitsPerEm : 1000;
    return fontUnits * size / upm;
  }

  BLPathData? glyphOutline(int glyphId) {
    int gid = glyphId;
    if (gid < 0) gid = 0;
    if (face.glyphCount > 0 && gid >= face.glyphCount)
      gid = face.glyphCount - 1;

    final cached = _glyphOutlineCache[gid];
    if (cached != null) return cached;

    final unitsPath = face.glyphOutlineUnits(gid);
    if (unitsPath == null) return null;

    final upm = face.unitsPerEm > 0 ? face.unitsPerEm : 1000;
    final scale = size / upm;

    final src = unitsPath.vertices;
    final dst = List<double>.filled(src.length, 0.0, growable: false);
    for (int i = 0; i < src.length; i++) {
      dst[i] = src[i] * scale;
    }

    final contourCounts = unitsPath.contourVertexCounts;
    final out = BLPathData(
      vertices: dst,
      contourVertexCounts:
          contourCounts == null ? null : List<int>.from(contourCounts),
    );

    if (_glyphOutlineCache.length >= 4096 &&
        !_glyphOutlineCache.containsKey(gid)) {
      _glyphOutlineCache.remove(_glyphOutlineCache.keys.first);
    }
    _glyphOutlineCache[gid] = out;
    return out;
  }

  void clearGlyphOutlineCache() {
    _glyphOutlineCache.clear();
  }
}

class _BLGlyphPoint {
  final double x;
  final double y;
  final bool onCurve;

  const _BLGlyphPoint(this.x, this.y, this.onCurve);
}

class _BLGlyphTransform {
  double m00;
  double m01;
  double m10;
  double m11;
  double m20;
  double m21;

  _BLGlyphTransform(
    this.m00,
    this.m01,
    this.m10,
    this.m11,
    this.m20,
    this.m21,
  );

  factory _BLGlyphTransform.identity() {
    return _BLGlyphTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0);
  }

  (double, double) apply(double x, double y) {
    final ox = x * m00 + y * m10 + m20;
    final oy = x * m01 + y * m11 + m21;
    return (ox, oy);
  }

  static _BLGlyphTransform multiply(
    _BLGlyphTransform a,
    _BLGlyphTransform b,
  ) {
    return _BLGlyphTransform(
      a.m00 * b.m00 + a.m01 * b.m10,
      a.m00 * b.m01 + a.m01 * b.m11,
      a.m10 * b.m00 + a.m11 * b.m10,
      a.m10 * b.m01 + a.m11 * b.m11,
      a.m20 * b.m00 + a.m21 * b.m10 + b.m20,
      a.m20 * b.m01 + a.m21 * b.m11 + b.m21,
    );
  }
}

class BLGlyphBounds {
  final int left;
  final int top;
  final int right;
  final int bottom;
  final int contourCount;
  final bool isComposite;

  const BLGlyphBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.contourCount,
    required this.isComposite,
  });

  const BLGlyphBounds.empty()
      : left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        contourCount = 0,
        isComposite = false;

  bool get isEmpty => left == 0 && top == 0 && right == 0 && bottom == 0;

  int get width => right - left;
  int get height => bottom - top;
}

class _BLParsedNameTable {
  final String family;
  final String subfamily;
  final String full;
  final String postScript;

  const _BLParsedNameTable({
    required this.family,
    required this.subfamily,
    required this.full,
    required this.postScript,
  });
}

class _BLNameCandidate {
  final String value;
  final int score;

  const _BLNameCandidate(this.value, this.score);
}

class _BLTableRecord {
  final int offset;
  final int length;
  const _BLTableRecord(this.offset, this.length);
}

abstract class _BLCmapMapper {
  int map(int codePoint);
}

class _BLCmapNone implements _BLCmapMapper {
  static const _BLCmapNone instance = _BLCmapNone();
  const _BLCmapNone();

  @override
  int map(int codePoint) {
    if (codePoint == 0) return 0;
    return 0;
  }
}

class _BLCmapFormat0 implements _BLCmapMapper {
  final ByteData _view;
  final int _glyphArrayOffset;

  const _BLCmapFormat0(this._view, this._glyphArrayOffset);

  @override
  int map(int codePoint) {
    if (codePoint < 0 || codePoint > 255) return 0;
    final off = _glyphArrayOffset + codePoint;
    if (off < 0 || off >= _view.lengthInBytes) return 0;
    return _view.getUint8(off);
  }
}

class _BLCmapFormat6 implements _BLCmapMapper {
  final ByteData _view;
  final int _firstCode;
  final int _entryCount;
  final int _glyphArrayOffset;

  const _BLCmapFormat6(
    this._view,
    this._firstCode,
    this._entryCount,
    this._glyphArrayOffset,
  );

  @override
  int map(int codePoint) {
    final idx = codePoint - _firstCode;
    if (idx < 0 || idx >= _entryCount) return 0;
    final off = _glyphArrayOffset + idx * 2;
    if (off < 0 || off + 2 > _view.lengthInBytes) return 0;
    return _view.getUint16(off, Endian.big);
  }
}

class _BLCmapFormat10 implements _BLCmapMapper {
  final ByteData _view;
  final int _firstCode;
  final int _entryCount;
  final int _glyphArrayOffset;

  const _BLCmapFormat10(
    this._view,
    this._firstCode,
    this._entryCount,
    this._glyphArrayOffset,
  );

  @override
  int map(int codePoint) {
    final idx = codePoint - _firstCode;
    if (idx < 0 || idx >= _entryCount) return 0;
    final off = _glyphArrayOffset + idx * 2;
    if (off < 0 || off + 2 > _view.lengthInBytes) return 0;
    return _view.getUint16(off, Endian.big);
  }
}

class _BLCmapFormat4 implements _BLCmapMapper {
  final ByteData _view;
  final Int32List _startCodes;
  final Int32List _endCodes;
  final Int32List _idDeltas;
  final Int32List _idRangeOffsets;
  final int _idRangeArrayOffset;

  const _BLCmapFormat4(
    this._view,
    this._startCodes,
    this._endCodes,
    this._idDeltas,
    this._idRangeOffsets,
    this._idRangeArrayOffset,
  );

  @override
  int map(int codePoint) {
    if (codePoint < 0 || codePoint > 0xFFFF) return 0;

    int lo = 0;
    int hi = _endCodes.length - 1;
    int seg = -1;

    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final end = _endCodes[mid];
      if (codePoint > end) {
        lo = mid + 1;
      } else {
        if (codePoint < _startCodes[mid]) {
          hi = mid - 1;
        } else {
          seg = mid;
          break;
        }
      }
    }

    if (seg < 0) return 0;
    final idRangeOffset = _idRangeOffsets[seg];
    if (idRangeOffset == 0) {
      return (codePoint + _idDeltas[seg]) & 0xFFFF;
    }

    final glyphWordOff = _idRangeArrayOffset +
        seg * 2 +
        idRangeOffset +
        (codePoint - _startCodes[seg]) * 2;
    if (glyphWordOff < 0 || glyphWordOff + 2 > _view.lengthInBytes) return 0;

    int glyphId = _view.getUint16(glyphWordOff, Endian.big);
    if (glyphId == 0) return 0;
    glyphId = (glyphId + _idDeltas[seg]) & 0xFFFF;
    return glyphId;
  }
}

class _BLCmapFormat12Or13 implements _BLCmapMapper {
  final Int32List _startChars;
  final Int32List _endChars;
  final Int32List _startGlyphIds;
  final bool _isFormat13;

  const _BLCmapFormat12Or13(
    this._startChars,
    this._endChars,
    this._startGlyphIds,
    this._isFormat13,
  );

  @override
  int map(int codePoint) {
    if (codePoint < 0) return 0;

    int lo = 0;
    int hi = _startChars.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final end = _endChars[mid];
      if (codePoint > end) {
        lo = mid + 1;
      } else {
        final start = _startChars[mid];
        if (codePoint < start) {
          hi = mid - 1;
        } else {
          if (_isFormat13) return _startGlyphIds[mid] & 0xFFFF;
          return (_startGlyphIds[mid] + (codePoint - start)) & 0xFFFF;
        }
      }
    }
    return 0;
  }
}
