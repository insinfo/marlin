class BLContourSpan {
  final int start;
  final int count;

  const BLContourSpan(this.start, this.count);
}

class BLEdgeBuilder {
  const BLEdgeBuilder._();

  static List<BLContourSpan> resolveContours(
    int totalPoints,
    List<int>? contourVertexCounts,
  ) {
    if (contourVertexCounts == null || contourVertexCounts.isEmpty) {
      return <BLContourSpan>[BLContourSpan(0, totalPoints)];
    }

    int consumed = 0;
    final out = <BLContourSpan>[];
    for (final raw in contourVertexCounts) {
      if (raw <= 0) continue;
      if (consumed + raw > totalPoints) {
        return <BLContourSpan>[BLContourSpan(0, totalPoints)];
      }
      out.add(BLContourSpan(consumed, raw));
      consumed += raw;
    }

    if (out.isEmpty || consumed != totalPoints) {
      return <BLContourSpan>[BLContourSpan(0, totalPoints)];
    }
    return out;
  }
}

