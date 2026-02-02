

/// Marlin constant holder
abstract class MarlinConst {
  // Subpixels expressed as log2
  static const int subpixelLgPositionsX = 3; // 8 subpixels
  static const int subpixelLgPositionsY = 3; // 8 subpixels

  // Number of subpixels
  static const int subpixelPositionsX = 1 << subpixelLgPositionsX;  // 8
  static const int subpixelPositionsY = 1 << subpixelLgPositionsY;  // 8

  // Subpixel masks
  static const int subpixelMaskX = subpixelPositionsX - 1; // 7
  static const int subpixelMaskY = subpixelPositionsY - 1; // 7

  // Max anti-aliasing alpha
  static const int maxAAAlpha = subpixelPositionsX * subpixelPositionsY; // 64

  // Tile size
  static const int tileSizeLg = 5; // 32 pixels
  static const int tileSize = 1 << tileSizeLg;

  // Initial array sizes
  static const int initialPixelDim = 2048;
  static const int initialArray = 256;
  static const int initialSmallArray = 1024;
  static const int initialMediumArray = 4096;
  static const int initialLargeArray = 8192;
  static const int initialArray16K = 16384;
  static const int initialArray32K = 32768;
  static const int initialAAArray = initialPixelDim;

  // Initial edges capacity (6 ints per edge)
  static const int initialEdgesCapacity = 4096 * 6;

  // Initial bucket array size
  static const int initialBucketArray = initialPixelDim * subpixelPositionsY;

  // Winding rules
  static const int windEvenOdd = 0;
  static const int windNonZero = 1;

  // Edge structure offsets
  static const int offCurX = 0;
  static const int offError = 1;
  static const int offBumpX = 2;
  static const int offBumpErr = 3;
  static const int offNext = 4;
  static const int offYmaxOr = 5;
  static const int sizeofEdge = 6;

  // Subpixel conversion constants
  static const double fSubpixelPositionsX = 8.0; // subpixelPositionsX as double
  static const double fSubpixelPositionsY = 8.0; // subpixelPositionsY as double

  // Power of 2^32 for fixed-point arithmetic
  static const double power2To32 = 4294967296.0; // 2^32

  // Cubic curve flattening constants
  static const int cubCountLg = 2;
  static const int cubCount = 1 << cubCountLg;  // 4
  static const int cubCount2 = 1 << (2 * cubCountLg); // 16
  static const int cubCount3 = 1 << (3 * cubCountLg); // 64
  static const double cubInvCount = 1.0 / cubCount;
  static const double cubInvCount2 = 1.0 / cubCount2;
  static const double cubInvCount3 = 1.0 / cubCount3;
}
