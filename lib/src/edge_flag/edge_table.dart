import 'edge.dart';

 class EdgeTable {
   // Bucket sort by yStart
   final List<Edge?> buckets;
   final int minY;
   final int maxY;
   
   EdgeTable(this.minY, this.maxY) : buckets = List.filled(maxY - minY + 1, null);
   
   void addEdge(Edge edge) {
     if (edge.yStart < minY || edge.yStart >= maxY) return; // Clip should handle this but safety check
     int index = edge.yStart - minY;
     edge.next = buckets[index];
     buckets[index] = edge;
   }
   
   Edge? getEdgesForScanline(int y) {
     int index = y - minY;
     if (index < 0 || index >= buckets.length) return null;
     return buckets[index];
   }
 }
