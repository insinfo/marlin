import '../core/bl_types.dart';

/// Fetcher basico de cor solida.
class BLSolidFetcher {
  BLColor color;

  BLSolidFetcher(this.color);

  @pragma('vm:prefer-inline')
  BLColor fetch() => color;
}

