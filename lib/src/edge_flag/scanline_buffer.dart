import 'dart:typed_data';

abstract class ScanlineBuffer {
  int get width;
  void clear();
  void toggle(int x, int sampleIndex); // For Even-Odd
  void add(int x, int sampleIndex, int delta); // For Non-Zero
  
  // Converts the buffer content to alpha values (0-255) into the target buffer.
  // target should be Uint8List of size width.
  void resolveToAlpha(Uint8List target);
}

// Optimized for 8 samples Even-Odd
class ScanlineBufferEvenOdd8 implements ScanlineBuffer {
  final int _width;
  final Uint8List _buffer;
  
  ScanlineBufferEvenOdd8(this._width) : _buffer = Uint8List(_width);

  @override
  int get width => _width;

  @override
  @pragma('vm:prefer-inline')
  void clear() {
    // Fast clear
     // On VM, creating a new list might be faster than fillRange for large buffers, 
     // but reusing and clearing is better for GC.
     // fillRange is usually optimized.
    _buffer.fillRange(0, _width, 0);
  }

  @override
  @pragma('vm:prefer-inline')
  void toggle(int x, int sampleIndex) {
    if (x >= 0 && x < _width) {
      _buffer[x] ^= (1 << sampleIndex);
    }
  }

  @override
  void add(int x, int sampleIndex, int delta) {
    throw UnsupportedError("Use ScanlineBufferNonZero for winding rules");
  }

  static const List<int> _popcount8 = [
    0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    4, 5, 5, 6, 5, 6, 6, 7, 5, 6, 6, 7, 6, 7, 7, 8
  ];

  @override
  @pragma('vm:prefer-inline')
  void resolveToAlpha(Uint8List target) {
    // Scanline fill (XOR accumulation)
    int mask = 0;
    for (int i = 0; i < _width; i++) {
        mask ^= _buffer[i];
        
        // Debug
        // if (mask != 0 && (i == 30)) print('Resolve x=$i mask=$mask count=${_popcount8[mask]}');
        
        // Popcount to get alpha (0-8 mapped to 0-255)
        // 255 / 8 = 31.875 -> ~32
        int count = _popcount8[mask];
        // target[i] = (count * 32); 
        target[i] = (count * 255) >> 3;
    }
  }
}

// Optimized for 8 samples Non-Zero Winding
class ScanlineBufferNonZero8 implements ScanlineBuffer {
  final int _width;
  final Uint64List _buffer;
  
  ScanlineBufferNonZero8(this._width) : _buffer = Uint64List(_width);

  @override
  int get width => _width;

  @override
  @pragma('vm:prefer-inline')
  void clear() {
    _buffer.fillRange(0, _width, 0);
  }

  @override
  void toggle(int x, int sampleIndex) {
     throw UnsupportedError("Use ScanlineBufferEvenOdd for toggle/xor");
  }

  @override
  @pragma('vm:prefer-inline')
  void add(int x, int sampleIndex, int delta) {
    if (x >= 0 && x < _width) {
      int shift = sampleIndex << 3; // * 8
      if (delta > 0) {
        _buffer[x] += (1 << shift);
      } else {
        _buffer[x] -= (1 << shift);
      }
    }
  }

  @override
  @pragma('vm:prefer-inline')
  void resolveToAlpha(Uint8List target) {
    int accum = 0;
    
    for (int i = 0; i < _width; i++) {
        accum += _buffer[i];
        
        if (accum == 0) {
            target[i] = 0;
        } else {
            int count = 0;
            if ((accum & 0xFF) != 0) count++;
            if ((accum & 0xFF00) != 0) count++;
            if ((accum & 0xFF0000) != 0) count++;
            if ((accum & 0xFF000000) != 0) count++;
            if ((accum & 0xFF00000000) != 0) count++;
            if ((accum & 0xFF0000000000) != 0) count++;
            if ((accum & 0xFF000000000000) != 0) count++;
            if ((accum & 0xFF00000000000000) != 0) count++;
            
            target[i] = (count * 255) >> 3;
        }
    }
  }
}
