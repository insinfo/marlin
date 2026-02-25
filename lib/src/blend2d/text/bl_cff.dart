/// CFF/CFF2 outline decoder (port of Blend2D's `otcff.cpp` charstring interpreter).
///
/// Parses CFF/CFF2 charstring programs and converts them to BLPath outlines.
/// Supports Type 2 charstring operators: move, line, curve, vstem, hstem,
/// endchar, and most hinting operators (ignored for outline extraction).
///
/// Inspired by: `blend2d/opentype/otcff.cpp`, `otcff_p.h`

import 'dart:typed_data';

import '../geometry/bl_path.dart';

// ---------------------------------------------------------------------------
// CFF INDEX parser (v1)
// ---------------------------------------------------------------------------

/// A parsed CFF INDEX structure (v1).
class _CFFIndex {
  final int count;
  final int offsetSize;
  final int offsetsStart;
  final int dataStart;
  final ByteData view;

  const _CFFIndex(this.count, this.offsetSize, this.offsetsStart,
      this.dataStart, this.view);

  /// Total bytes consumed by this INDEX.
  int get totalSize {
    if (count == 0) return 2; // empty index = 2 bytes
    return dataStart + _readOffset(count) - 1;
  }

  int _readOffset(int index) {
    final off = offsetsStart + index * offsetSize;
    switch (offsetSize) {
      case 1:
        return view.getUint8(off);
      case 2:
        return view.getUint16(off, Endian.big);
      case 3:
        return (view.getUint8(off) << 16) |
            (view.getUint8(off + 1) << 8) |
            view.getUint8(off + 2);
      case 4:
        return view.getUint32(off, Endian.big);
      default:
        return 0;
    }
  }

  /// Returns (start, end) byte range for entry [index] relative to data start.
  (int, int)? entryRange(int index) {
    if (index < 0 || index >= count) return null;
    final off0 = _readOffset(index) - 1; // CFF offsets are 1-based
    final off1 = _readOffset(index + 1) - 1;
    if (off0 < 0 || off1 < off0) return null;
    return (dataStart + off0, dataStart + off1);
  }

  /// Parse a CFF v1 INDEX starting at [offset].
  static _CFFIndex? parse(ByteData view, int offset) {
    if (offset + 2 > view.lengthInBytes) return null;
    final count = view.getUint16(offset, Endian.big);
    if (count == 0) return _CFFIndex(0, 0, offset + 2, offset + 2, view);
    if (offset + 3 > view.lengthInBytes) return null;
    final offSize = view.getUint8(offset + 2);
    if (offSize < 1 || offSize > 4) return null;
    final offsetsStart = offset + 3;
    final dataStart = offsetsStart + (count + 1) * offSize;
    if (dataStart > view.lengthInBytes) return null;
    return _CFFIndex(count, offSize, offsetsStart, dataStart, view);
  }
}

// ---------------------------------------------------------------------------
// Type 2 Charstring interpreter (subset for outline extraction)
// ---------------------------------------------------------------------------

/// Type 2 charstring operators.
class _T2Op {
  static const int hstem = 1;
  static const int vstem = 3;
  static const int vmoveto = 4;
  static const int rlineto = 5;
  static const int hlineto = 6;
  static const int vlineto = 7;
  static const int rrcurveto = 8;
  static const int callsubr = 10;
  static const int returnOp = 11;
  static const int endchar = 14;
  static const int hstemhm = 18;
  static const int hintmask = 19;
  static const int cntrmask = 20;
  static const int rmoveto = 21;
  static const int hmoveto = 22;
  static const int vstemhm = 23;
  static const int rcurveline = 24;
  static const int rlinecurve = 25;
  static const int vvcurveto = 26;
  static const int hhcurveto = 27;
  static const int callgsubr = 29;
  static const int vhcurveto = 30;
  static const int hvcurveto = 31;
}

/// Interprets a Type 2 charstring and appends the outline to [path].
///
/// Returns true on success.
bool _interpretCharstring(
  BLPath path,
  ByteData view,
  int start,
  int end,
  double scaleX,
  double scaleY,
  double offsetX,
  double offsetY, {
  _CFFIndex? localSubrs,
  _CFFIndex? globalSubrs,
}) {
  final stack = Float64List(48); // CFF operand stack (max 48 per spec)
  int sp = 0; // stack pointer
  double x = offsetX, y = offsetY;
  bool hasWidth = false;
  bool hasMoveTo = false;
  int stemCount = 0;

  void _moveTo(double dx, double dy) {
    x += dx;
    y += dy;
    path.moveTo(x * scaleX, -y * scaleY);
    hasMoveTo = true;
  }

  void _lineTo(double dx, double dy) {
    x += dx;
    y += dy;
    if (!hasMoveTo) {
      path.moveTo(x * scaleX, -y * scaleY);
      hasMoveTo = true;
    } else {
      path.lineTo(x * scaleX, -y * scaleY);
    }
  }

  void _curveTo(
    double dx1,
    double dy1,
    double dx2,
    double dy2,
    double dx3,
    double dy3,
  ) {
    final x1 = x + dx1, y1 = y + dy1;
    final x2 = x1 + dx2, y2 = y1 + dy2;
    final x3 = x2 + dx3, y3 = y2 + dy3;
    x = x3;
    y = y3;
    if (!hasMoveTo) {
      path.moveTo(x * scaleX, -y * scaleY);
      hasMoveTo = true;
    } else {
      path.cubicTo(
        x1 * scaleX,
        -y1 * scaleY,
        x2 * scaleX,
        -y2 * scaleY,
        x3 * scaleX,
        -y3 * scaleY,
      );
    }
  }

  void _handleStems() {
    // Consume pairs from the stack as stems; ignore for outline.
    if (!hasWidth && (sp & 1) != 0) {
      hasWidth = true;
      // First number is width hint — skip
      stemCount += (sp - 1) >> 1;
    } else {
      stemCount += sp >> 1;
    }
    sp = 0;
  }

  int _hintBytes() => (stemCount + 7) >> 3;

  // Subroutine bias (CFF spec)
  int _subrBias(int count) {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
  }

  // Call stack for subroutine calls
  final callStack = <(int, int)>[]; // (savedP, savedEnd)
  int maxCallDepth = 10;

  int p = start;
  while (p < end) {
    final b0 = view.getUint8(p++);

    // Operand encoding
    if (b0 >= 32) {
      // Number
      if (b0 <= 246) {
        if (sp < 48) stack[sp++] = (b0 - 139).toDouble();
      } else if (b0 <= 250) {
        if (p >= end) return false;
        final b1 = view.getUint8(p++);
        if (sp < 48) stack[sp++] = ((b0 - 247) * 256 + b1 + 108).toDouble();
      } else if (b0 <= 254) {
        if (p >= end) return false;
        final b1 = view.getUint8(p++);
        if (sp < 48) stack[sp++] = (-(b0 - 251) * 256 - b1 - 108).toDouble();
      } else {
        // b0 == 255: 32-bit fixed-point (16.16)
        if (p + 4 > end) return false;
        final val = view.getInt32(p, Endian.big);
        p += 4;
        if (sp < 48) stack[sp++] = val / 65536.0;
      }
      continue;
    }

    // Operator
    switch (b0) {
      case _T2Op.rmoveto:
        if (!hasWidth && sp > 2) hasWidth = true;
        if (hasMoveTo) path.close();
        if (sp >= 2) {
          _moveTo(stack[sp - 2], stack[sp - 1]);
        }
        sp = 0;
        break;

      case _T2Op.hmoveto:
        if (!hasWidth && sp > 1) hasWidth = true;
        if (hasMoveTo) path.close();
        if (sp >= 1) {
          _moveTo(stack[sp - 1], 0);
        }
        sp = 0;
        break;

      case _T2Op.vmoveto:
        if (!hasWidth && sp > 1) hasWidth = true;
        if (hasMoveTo) path.close();
        if (sp >= 1) {
          _moveTo(0, stack[sp - 1]);
        }
        sp = 0;
        break;

      case _T2Op.rlineto:
        for (int i = 0; i < sp - 1; i += 2) {
          _lineTo(stack[i], stack[i + 1]);
        }
        sp = 0;
        break;

      case _T2Op.hlineto:
        for (int i = 0; i < sp; i++) {
          if ((i & 1) == 0) {
            _lineTo(stack[i], 0);
          } else {
            _lineTo(0, stack[i]);
          }
        }
        sp = 0;
        break;

      case _T2Op.vlineto:
        for (int i = 0; i < sp; i++) {
          if ((i & 1) == 0) {
            _lineTo(0, stack[i]);
          } else {
            _lineTo(stack[i], 0);
          }
        }
        sp = 0;
        break;

      case _T2Op.rrcurveto:
        for (int i = 0; i + 5 < sp; i += 6) {
          _curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3],
              stack[i + 4], stack[i + 5]);
        }
        sp = 0;
        break;

      case _T2Op.hhcurveto:
        {
          int i = 0;
          double dy1 = 0;
          if ((sp & 1) != 0) {
            dy1 = stack[i++];
          }
          while (i + 3 < sp) {
            _curveTo(
                stack[i], dy1, stack[i + 1], stack[i + 2], stack[i + 3], 0);
            i += 4;
            dy1 = 0;
          }
        }
        sp = 0;
        break;

      case _T2Op.vvcurveto:
        {
          int i = 0;
          double dx1 = 0;
          if ((sp & 1) != 0) {
            dx1 = stack[i++];
          }
          while (i + 3 < sp) {
            _curveTo(
                dx1, stack[i], stack[i + 1], stack[i + 2], 0, stack[i + 3]);
            i += 4;
            dx1 = 0;
          }
        }
        sp = 0;
        break;

      case _T2Op.hvcurveto:
        {
          int i = 0;
          bool startH = true;
          while (i + 3 < sp) {
            if (startH) {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              _curveTo(
                  stack[i], 0, stack[i + 1], stack[i + 2], extra, stack[i + 3]);
              i += (extra != 0 ? 5 : 4);
            } else {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              _curveTo(
                  0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], extra);
              i += (extra != 0 ? 5 : 4);
            }
            startH = !startH;
          }
        }
        sp = 0;
        break;

      case _T2Op.vhcurveto:
        {
          int i = 0;
          bool startV = true;
          while (i + 3 < sp) {
            if (startV) {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              _curveTo(
                  0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], extra);
              i += (extra != 0 ? 5 : 4);
            } else {
              final extra = (i + 4 < sp && i + 5 >= sp) ? stack[i + 4] : 0.0;
              _curveTo(
                  stack[i], 0, stack[i + 1], stack[i + 2], extra, stack[i + 3]);
              i += (extra != 0 ? 5 : 4);
            }
            startV = !startV;
          }
        }
        sp = 0;
        break;

      case _T2Op.rcurveline:
        {
          int i = 0;
          while (i + 7 < sp) {
            _curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3],
                stack[i + 4], stack[i + 5]);
            i += 6;
          }
          if (i + 1 < sp) {
            _lineTo(stack[i], stack[i + 1]);
          }
        }
        sp = 0;
        break;

      case _T2Op.rlinecurve:
        {
          int i = 0;
          final lineEnd = sp - 6;
          while (i + 1 < lineEnd) {
            _lineTo(stack[i], stack[i + 1]);
            i += 2;
          }
          if (i + 5 < sp) {
            _curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3],
                stack[i + 4], stack[i + 5]);
          }
        }
        sp = 0;
        break;

      case _T2Op.endchar:
        if (hasMoveTo) path.close();
        sp = 0;
        return true;

      case _T2Op.callsubr:
        if (localSubrs != null && sp >= 1) {
          final idx = stack[--sp].toInt() + _subrBias(localSubrs.count);
          final range = localSubrs.entryRange(idx);
          if (range != null && callStack.length < maxCallDepth) {
            callStack.add((p, end));
            p = range.$1;
            end = range.$2;
          }
        }
        break;

      case _T2Op.callgsubr:
        if (globalSubrs != null && sp >= 1) {
          final idx = stack[--sp].toInt() + _subrBias(globalSubrs.count);
          final range = globalSubrs.entryRange(idx);
          if (range != null && callStack.length < maxCallDepth) {
            callStack.add((p, end));
            p = range.$1;
            end = range.$2;
          }
        }
        break;

      case _T2Op.returnOp:
        if (callStack.isNotEmpty) {
          final saved = callStack.removeLast();
          p = saved.$1;
          end = saved.$2;
        }
        break;

      case _T2Op.hstem:
      case _T2Op.vstem:
      case _T2Op.hstemhm:
      case _T2Op.vstemhm:
        _handleStems();
        break;

      case _T2Op.hintmask:
      case _T2Op.cntrmask:
        // If any stems remain on the stack, consume them first
        if (sp > 0) _handleStems();
        // Skip hint mask bytes
        p += _hintBytes();
        break;

      case 12: // escape — two-byte operators
        if (p >= end) return false;
        final b1 = view.getUint8(p++);
        // Most escape operators are hints/math that don't affect outlines.
        // We skip them but pop the stack appropriately.
        switch (b1) {
          case 34: // hflex
            if (sp >= 7) {
              _curveTo(stack[0], 0, stack[1], stack[2], stack[3], 0);
              _curveTo(stack[4], 0, stack[5], -stack[2], stack[6], 0);
            }
            sp = 0;
            break;
          case 35: // flex
            if (sp >= 12) {
              _curveTo(
                  stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]);
              _curveTo(
                  stack[6], stack[7], stack[8], stack[9], stack[10], stack[11]);
            }
            sp = 0;
            break;
          case 36: // hflex1
            if (sp >= 9) {
              _curveTo(stack[0], stack[1], stack[2], stack[3], stack[4], 0);
              _curveTo(stack[5], 0, stack[6], stack[7], stack[8],
                  -(stack[1] + stack[3] + stack[7]));
            }
            sp = 0;
            break;
          case 37: // flex1
            if (sp >= 11) {
              final dx = stack[0] + stack[2] + stack[4] + stack[6] + stack[8];
              final dy = stack[1] + stack[3] + stack[5] + stack[7] + stack[9];
              if (dx.abs() > dy.abs()) {
                _curveTo(
                    stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]);
                _curveTo(
                    stack[6], stack[7], stack[8], stack[9], stack[10], -dy);
              } else {
                _curveTo(
                    stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]);
                _curveTo(
                    stack[6], stack[7], stack[8], stack[9], -dx, stack[10]);
              }
            }
            sp = 0;
            break;
          default:
            // Unknown escape operator — clear stack
            sp = 0;
            break;
        }
        break;

      default:
        // Unknown operator — ignore
        sp = 0;
        break;
    }
  }

  if (hasMoveTo) path.close();
  return true;
}

// ---------------------------------------------------------------------------
// CFF font outline decoder (public API)
// ---------------------------------------------------------------------------

/// Decodes a CFF glyph outline from font data.
///
/// [cffOffset] and [cffLength] point to the 'CFF ' table in the font.
/// [glyphId] is the glyph to decode.
/// [unitsPerEm] is used for scaling if [fontSize] is provided.
///
/// Returns a [BLPathData] or null if decoding fails.
class BLCFFDecoder {
  const BLCFFDecoder._();

  /// Decodes glyph outline from a CFF table.
  ///
  /// Parses the CFF header, Name INDEX, TopDict INDEX, String INDEX, GSubR INDEX,
  /// and the CharStrings INDEX to locate and interpret the charstring for [glyphId].
  static BLPathData? decodeGlyph(
    ByteData view,
    int cffOffset,
    int cffLength,
    int glyphId, {
    double scaleX = 1.0,
    double scaleY = 1.0,
  }) {
    if (cffLength < 4) return null;

    // Header
    final major = view.getUint8(cffOffset);
    if (major != 1) return null; // Only CFF v1 supported in this bootstrap
    final headerSize = view.getUint8(cffOffset + 2);

    // Name INDEX (skip)
    final nameIdx = _CFFIndex.parse(view, cffOffset + headerSize);
    if (nameIdx == null) return null;

    // TopDict INDEX
    int nextOff =
        cffOffset + headerSize + (nameIdx.count == 0 ? 2 : nameIdx.totalSize);
    final topDictIdx = _CFFIndex.parse(view, nextOff);
    if (topDictIdx == null || topDictIdx.count == 0) return null;

    // String INDEX (skip)
    nextOff += (topDictIdx.count == 0 ? 2 : topDictIdx.totalSize);
    final stringIdx = _CFFIndex.parse(view, nextOff);

    // GSubR INDEX
    _CFFIndex? gsubrIdx;
    if (stringIdx != null) {
      final gsubrOff =
          nextOff + (stringIdx.count == 0 ? 2 : stringIdx.totalSize);
      gsubrIdx = _CFFIndex.parse(view, gsubrOff);
    }

    // Parse TopDict to find CharStrings offset and Private DICT
    final topDictRange = topDictIdx.entryRange(0);
    if (topDictRange == null) return null;
    final charStringsOffset =
        _findCharStringsOffset(view, topDictRange.$1, topDictRange.$2);
    if (charStringsOffset < 0) return null;

    // Parse Private DICT to find local subrs
    final privInfo = _findPrivateDict(view, topDictRange.$1, topDictRange.$2);
    _CFFIndex? localSubrs;
    if (privInfo != null) {
      final privOffset = cffOffset + privInfo.$1;
      final privLength = privInfo.$2;
      final localSubrOffset =
          _findLocalSubrOffset(view, privOffset, privOffset + privLength);
      if (localSubrOffset >= 0) {
        localSubrs = _CFFIndex.parse(view, privOffset + localSubrOffset);
      }
    }

    // CharStrings INDEX
    final csIdx = _CFFIndex.parse(view, cffOffset + charStringsOffset);
    if (csIdx == null || glyphId >= csIdx.count) return null;

    final csRange = csIdx.entryRange(glyphId);
    if (csRange == null) return null;

    final path = BLPath();
    final ok = _interpretCharstring(
      path,
      view,
      csRange.$1,
      csRange.$2,
      scaleX,
      scaleY,
      0,
      0,
      localSubrs: localSubrs,
      globalSubrs: gsubrIdx,
    );
    if (!ok) return null;

    return path.toPathData();
  }

  /// Finds the Private DICT offset and size from the TopDict (operator 18).
  static (int, int)? _findPrivateDict(ByteData view, int start, int end) {
    int p = start;
    final operands = <int>[];

    while (p < end) {
      final b0 = view.getUint8(p++);
      if (b0 >= 32 && b0 <= 246) {
        operands.add(b0 - 139);
      } else if (b0 >= 247 && b0 <= 250) {
        if (p >= end) return null;
        final b1 = view.getUint8(p++);
        operands.add((b0 - 247) * 256 + b1 + 108);
      } else if (b0 >= 251 && b0 <= 254) {
        if (p >= end) return null;
        final b1 = view.getUint8(p++);
        operands.add(-(b0 - 251) * 256 - b1 - 108);
      } else if (b0 == 28) {
        if (p + 2 > end) return null;
        operands.add(view.getInt16(p, Endian.big));
        p += 2;
      } else if (b0 == 29) {
        if (p + 4 > end) return null;
        operands.add(view.getInt32(p, Endian.big));
        p += 4;
      } else if (b0 == 30) {
        while (p < end) {
          final nibByte = view.getUint8(p++);
          if ((nibByte & 0xF) == 0xF || (nibByte >> 4) == 0xF) break;
        }
        operands.add(0);
      } else if (b0 == 12) {
        if (p >= end) return null;
        p++;
        operands.clear();
      } else {
        // operator 18 = Private
        if (b0 == 18 && operands.length >= 2) {
          return (operands[operands.length - 1], operands[operands.length - 2]);
        }
        operands.clear();
      }
    }
    return null;
  }

  /// Finds the local Subrs offset from a Private DICT (operator 19).
  static int _findLocalSubrOffset(ByteData view, int start, int end) {
    int p = start;
    final operands = <int>[];

    while (p < end) {
      final b0 = view.getUint8(p++);
      if (b0 >= 32 && b0 <= 246) {
        operands.add(b0 - 139);
      } else if (b0 >= 247 && b0 <= 250) {
        if (p >= end) return -1;
        final b1 = view.getUint8(p++);
        operands.add((b0 - 247) * 256 + b1 + 108);
      } else if (b0 >= 251 && b0 <= 254) {
        if (p >= end) return -1;
        final b1 = view.getUint8(p++);
        operands.add(-(b0 - 251) * 256 - b1 - 108);
      } else if (b0 == 28) {
        if (p + 2 > end) return -1;
        operands.add(view.getInt16(p, Endian.big));
        p += 2;
      } else if (b0 == 29) {
        if (p + 4 > end) return -1;
        operands.add(view.getInt32(p, Endian.big));
        p += 4;
      } else if (b0 == 30) {
        while (p < end) {
          final nibByte = view.getUint8(p++);
          if ((nibByte & 0xF) == 0xF || (nibByte >> 4) == 0xF) break;
        }
        operands.add(0);
      } else if (b0 == 12) {
        if (p >= end) return -1;
        p++;
        operands.clear();
      } else {
        // operator 19 = Subrs
        if (b0 == 19 && operands.isNotEmpty) {
          return operands.last;
        }
        operands.clear();
      }
    }
    return -1;
  }

  /// Scans a TopDict for the CharStrings offset (operator 17).
  static int _findCharStringsOffset(ByteData view, int start, int end) {
    int p = start;
    final operands = <int>[];

    while (p < end) {
      final b0 = view.getUint8(p++);
      if (b0 >= 32 && b0 <= 246) {
        operands.add(b0 - 139);
      } else if (b0 >= 247 && b0 <= 250) {
        if (p >= end) return -1;
        final b1 = view.getUint8(p++);
        operands.add((b0 - 247) * 256 + b1 + 108);
      } else if (b0 >= 251 && b0 <= 254) {
        if (p >= end) return -1;
        final b1 = view.getUint8(p++);
        operands.add(-(b0 - 251) * 256 - b1 - 108);
      } else if (b0 == 28) {
        if (p + 2 > end) return -1;
        operands.add(view.getInt16(p, Endian.big));
        p += 2;
      } else if (b0 == 29) {
        if (p + 4 > end) return -1;
        operands.add(view.getInt32(p, Endian.big));
        p += 4;
      } else if (b0 == 30) {
        // Skip CFF float (nibble-encoded)
        while (p < end) {
          final nibByte = view.getUint8(p++);
          if ((nibByte & 0xF) == 0xF || (nibByte >> 4) == 0xF) break;
        }
        operands.add(0); // placeholder
      } else if (b0 == 12) {
        // Two-byte operator — we just skip
        if (p >= end) return -1;
        p++;
        operands.clear();
      } else {
        // Single-byte operator
        if (b0 == 17 && operands.isNotEmpty) {
          return operands.last; // CharStrings offset
        }
        operands.clear();
      }
    }
    return -1;
  }
}
