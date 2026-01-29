// Offset n-rooks para 8, 16, 32 amostras
// Convertido de PolygonFiller.h

class SamplingPatterns {
  static const int shift8 = 3;
  static const int count8 = 8;
  static const List<double> offsets8 = [
    5.0/8.0, 0.0/8.0, 3.0/8.0, 6.0/8.0, 
    1.0/8.0, 4.0/8.0, 7.0/8.0, 2.0/8.0
  ];

  static const int shift16 = 4;
  static const int count16 = 16;
  static const List<double> offsets16 = [
    1.0/16.0, 8.0/16.0, 4.0/16.0, 15.0/16.0,
    11.0/16.0, 2.0/16.0, 6.0/16.0, 14.0/16.0,
    10.0/16.0, 3.0/16.0, 7.0/16.0, 12.0/16.0,
    0.0/16.0, 9.0/16.0, 5.0/16.0, 13.0/16.0,
  ];

  static const int shift32 = 5;
  static const int count32 = 32;
  // TODO: Add 32 offsets if needed, for now focusing on 8/16
}
