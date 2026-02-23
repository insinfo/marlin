import 'dart:math' as math;

import '../core/bl_types.dart';
import 'bl_path.dart';

/// Port do PathStroker do Blend2D para Dart (Fase 5).
///
/// Transforma um [BLPath] de entrada em um [BLPath] de saída representando
/// o outline do stroke. O resultado pode ser preenchido (`fillPath`) com
/// [BLFillRule.nonZero] para produzir o stroke visual.
///
/// Suporta:
///  - Caps: butt, square, round, roundRev, triangle, triangleRev
///  - Joins: bevel, miterBevel, miterRound, miterClip, round
///  - Contornos abertos e fechados
///
/// Inspirado em: `blend2d/core/pathstroke.cpp`
class BLStroker {
  static const double _kEps = 1e-10;
  static const double _kEpsSq = 1e-20;

  // ---------------------------------------------------------------------------
  // API pública
  // ---------------------------------------------------------------------------

  /// Transforma [input] em um outline de stroke de acordo com [options].
  ///
  /// O resultado é um [BLPath] que deve ser preenchido com fill rule
  /// [BLFillRule.nonZero] para produzir o stroke visual correto.
  static BLPath strokePath(BLPath input, BLStrokeOptions options) {
    final data = input.toPathData();
    final out = BLPath();
    final verts = data.vertices;
    if (verts.isEmpty) return out;

    final counts = data.contourVertexCounts ?? [verts.length ~/ 2];
    final closedFlags = data.contourClosed;
    final hw = options.width * 0.5;
    if (hw <= 0) return out;

    // Limite de miter ao quadrado relativo a hw:
    // |k|^2 <= (miterLimit * hw)^2
    final miterLimitSq = options.miterLimit * options.miterLimit * hw * hw;

    int offset = 0;
    for (int ci = 0; ci < counts.length; ci++) {
      final int n = counts[ci];
      final bool isClosed = (closedFlags != null && ci < closedFlags.length)
          ? closedFlags[ci]
          : false;
      if (n >= 2) {
        _strokeContour(
            verts, offset, n, isClosed, hw, miterLimitSq, options, out);
      }
      offset += n;
    }

    return out;
  }

  // ---------------------------------------------------------------------------
  // Processamento de um único contorno
  // ---------------------------------------------------------------------------

  static void _strokeContour(
    List<double> verts,
    int start,
    int n,
    bool isClosed,
    double hw,
    double miterLimitSq,
    BLStrokeOptions options,
    BLPath out,
  ) {
    // Extrair vértices do contorno em arrays locais
    final px = List<double>.filled(n, 0.0);
    final py = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      px[i] = verts[(start + i) * 2];
      py[i] = verts[(start + i) * 2 + 1];
    }

    // Computar normais por segmento.
    // nx[i], ny[i] = normal esquerda unitária do segmento de p[i] a p[(i+1)%n].
    final int segCount = isClosed ? n : n - 1;
    final nx = List<double>.filled(n, 0.0);
    final ny = List<double>.filled(n, 0.0);
    int lastValidSeg = -1;
    for (int i = 0; i < segCount; i++) {
      final j = (i + 1) % n;
      final dx = px[j] - px[i];
      final dy = py[j] - py[i];
      final lenSq = dx * dx + dy * dy;
      if (lenSq < _kEpsSq) {
        // Segmento degenerado: herdar normal anterior
        if (lastValidSeg >= 0) {
          nx[i] = nx[lastValidSeg];
          ny[i] = ny[lastValidSeg];
        }
        continue;
      }
      final len = math.sqrt(lenSq);
      nx[i] = -dy / len;
      ny[i] = dx / len;
      lastValidSeg = i;
    }
    // Para contornos abertos, estender a normal final para o ponto último
    if (!isClosed && n >= 2) {
      nx[n - 1] = nx[n - 2];
      ny[n - 1] = ny[n - 2];
    }

    // Lados A (esquerdo / +hw) e B (direito / -hw)
    final aVerts = <double>[];
    final bVerts = <double>[];

    for (int i = 0; i < n; i++) {
      final bool isFirst = !isClosed && i == 0;
      final bool isLast = !isClosed && i == n - 1;

      if (isFirst) {
        aVerts.add(px[0] + hw * nx[0]);
        aVerts.add(py[0] + hw * ny[0]);
        bVerts.add(px[0] - hw * nx[0]);
        bVerts.add(py[0] - hw * ny[0]);
        continue;
      }

      if (isLast) {
        final int lastSeg = n - 2;
        aVerts.add(px[n - 1] + hw * nx[lastSeg]);
        aVerts.add(py[n - 1] + hw * ny[lastSeg]);
        bVerts.add(px[n - 1] - hw * nx[lastSeg]);
        bVerts.add(py[n - 1] - hw * ny[lastSeg]);
        continue;
      }

      // Vértice com join
      final int prevSeg = isClosed ? (i - 1 + n) % n : i - 1;
      final int currSeg = i; // segmento de saída a partir de p[i]

      final double npx = nx[prevSeg], npy = ny[prevSeg];
      final double nnx = nx[currSeg], nny = ny[currSeg];

      // Cross: > 0 → vira esquerda (A é externo); < 0 → vira direita (B é externo)
      final double cross = npx * nny - npy * nnx;

      // Vetor bissetriz: m = np + nn
      final double mx = npx + nnx, my = npy + nny;
      final double mLenSq = mx * mx + my * my;

      if (mLenSq < _kEps) {
        // Normais anti-paralelas: U-turn de 180°
        // Adicionar ponto intermediário por segmento
        aVerts.add(px[i] + hw * npx);
        aVerts.add(py[i] + hw * npy);
        aVerts.add(px[i] + hw * nnx);
        aVerts.add(py[i] + hw * nny);
        bVerts.add(px[i] - hw * npx);
        bVerts.add(py[i] - hw * npy);
        bVerts.add(px[i] - hw * nnx);
        bVerts.add(py[i] - hw * nny);
        continue;
      }

      // Ponto de miter (offset do vértice central): k = m * hw / |m|^2
      final double kx = mx * hw / mLenSq;
      final double ky = my * hw / mLenSq;
      final double kLenSq = kx * kx + ky * ky;

      if (cross >= 0.0) {
        // Vira esquerda: A externo → join; B interno
        _addOuterJoin(aVerts, px[i], py[i], hw, npx, npy, nnx, nny,
            kx, ky, kLenSq, miterLimitSq, options.join);
        _addInnerJoin(bVerts, px[i], py[i], -kx, -ky);
      } else {
        // Vira direita: B externo → join; A interno
        _addOuterJoin(bVerts, px[i], py[i], -hw, -npx, -npy, -nnx, -nny,
            -kx, -ky, kLenSq, miterLimitSq, options.join);
        _addInnerJoin(aVerts, px[i], py[i], kx, ky);
      }
    }

    if (isClosed) {
      // Dois polígonos fechados: A (winding +1) e B invertido (winding -1).
      // Preenchimento nonZero produz o stroke anelar.
      _emitClosedPolygon(aVerts, out);
      _emitClosedPolygonReversed(bVerts, out);
    } else {
      // Um polígono fechado: A → end_cap → B_reversed → start_cap
      final int na = aVerts.length ~/ 2;
      final int nb = bVerts.length ~/ 2;
      if (na < 1 || nb < 1) return;

      out.moveTo(aVerts[0], aVerts[1]);
      for (int i = 1; i < na; i++) {
        out.lineTo(aVerts[i * 2], aVerts[i * 2 + 1]);
      }

      // End cap: do último A ao último B
      _addCapToPath(
        out,
        aVerts[(na - 1) * 2],
        aVerts[(na - 1) * 2 + 1],
        px[n - 1],
        py[n - 1],
        bVerts[(nb - 1) * 2],
        bVerts[(nb - 1) * 2 + 1],
        options.endCap,
        hw,
        nx[n - 2],
        ny[n - 2],
      );

      // B invertido
      for (int i = nb - 2; i >= 0; i--) {
        out.lineTo(bVerts[i * 2], bVerts[i * 2 + 1]);
      }

      // Start cap: do primeiro B ao primeiro A
      // A direção de entrada do cap é o oposto do segmento inicial
      _addCapToPath(
        out,
        bVerts[0],
        bVerts[1],
        px[0],
        py[0],
        aVerts[0],
        aVerts[1],
        options.startCap,
        hw,
        -nx[0],
        -ny[0],
      );

      out.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Join externo (lado convexo)
  // Inspirado em outer_join() de pathstroke.cpp
  // ---------------------------------------------------------------------------

  static void _addOuterJoin(
    List<double> verts,
    double cx,
    double cy,
    double hw, // halfWidth com sinal (+hw = A, -hw = B)
    double npx,
    double npy, // normal inbound
    double nnx,
    double nny, // normal outbound
    double kx,
    double ky, // offset do miter para este lado
    double kLenSq,
    double miterLimitSq,
    BLStrokeJoin joinType,
  ) {
    // Ponto final do segmento anterior offset e ponto inicial do próximo
    final double peX = cx + hw * npx;
    final double peY = cy + hw * npy;
    final double nsX = cx + hw * nnx;
    final double nsY = cy + hw * nny;

    // Collinear: não precisa de join
    final double ddx = nsX - peX, ddy = nsY - peY;
    if (ddx * ddx + ddy * ddy < _kEpsSq) {
      verts.add(peX);
      verts.add(peY);
      return;
    }

    switch (joinType) {
      case BLStrokeJoin.miterBevel:
      case BLStrokeJoin.miterRound:
      case BLStrokeJoin.miterClip:
        if (kLenSq <= miterLimitSq) {
          // Miter dentro do limite
          verts.add(cx + kx);
          verts.add(cy + ky);
          return;
        }
        // Fallback por tipo
        if (joinType == BLStrokeJoin.miterRound) {
          _addArcPoints(verts, cx, cy, peX, peY, nsX, nsY);
          return;
        }
        if (joinType == BLStrokeJoin.miterClip) {
          // Clipar o miter ao limite
          final double miterLen = math.sqrt(miterLimitSq);
          final double kLen = math.sqrt(kLenSq);
          if (kLen > _kEps) {
            final double clip = miterLen / kLen;
            verts.add(cx + kx * clip);
            verts.add(cy + ky * clip);
          }
          verts.add(nsX);
          verts.add(nsY);
          return;
        }
        // miterBevel → bevel
        verts.add(peX);
        verts.add(peY);
        verts.add(nsX);
        verts.add(nsY);
        return;

      case BLStrokeJoin.round:
        _addArcPoints(verts, cx, cy, peX, peY, nsX, nsY);
        return;

      case BLStrokeJoin.bevel:
        verts.add(peX);
        verts.add(peY);
        verts.add(nsX);
        verts.add(nsY);
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // Join interno (lado côncavo) — simplesmente usa a intersecção do miter
  // ---------------------------------------------------------------------------

  static void _addInnerJoin(
    List<double> verts,
    double cx,
    double cy,
    double ikx,
    double iky,
  ) {
    verts.add(cx + ikx);
    verts.add(cy + iky);
  }

  // ---------------------------------------------------------------------------
  // Arco genérico (round join / round cap)
  // Calcula pontos sobre o arco de a até b ao redor de c (short arc).
  // ---------------------------------------------------------------------------

  static void _addArcPoints(
    List<double> verts,
    double cx,
    double cy,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final double ux = ax - cx, uy = ay - cy;
    final double vx = bx - cx, vy = by - cy;
    final double r = math.sqrt(ux * ux + uy * uy);
    if (r < _kEps) {
      verts.add(bx);
      verts.add(by);
      return;
    }

    final double startAngle = math.atan2(uy, ux);
    final double endAngle = math.atan2(vy, vx);

    // Cruzamento determina a direção do arco (short arc, convex side)
    final double crossUV = ux * vy - uy * vx;
    double deltaAngle;
    if (crossUV >= 0.0) {
      // CCW
      deltaAngle = endAngle - startAngle;
      if (deltaAngle < 0) deltaAngle += 2 * math.pi;
    } else {
      // CW
      deltaAngle = endAngle - startAngle;
      if (deltaAngle > 0) deltaAngle -= 2 * math.pi;
    }

    if (deltaAngle.abs() < _kEps) {
      verts.add(bx);
      verts.add(by);
      return;
    }

    // Subdividir a ~45° por passo para qualidade suficiente
    final int steps =
        math.max(1, (deltaAngle.abs() / (math.pi / 4)).ceil());
    final double step = deltaAngle / steps;

    for (int i = 1; i <= steps; i++) {
      final double angle = startAngle + i * step;
      verts.add(cx + r * math.cos(angle));
      verts.add(cy + r * math.sin(angle));
    }
  }

  // ---------------------------------------------------------------------------
  // Cap de extremidade → emite direto no BLPath de saída
  // Inspirado em add_cap() de pathstroke.cpp
  // Parâmetros:
  //   p0x/p0y   = último ponto do lado A (ou primeiro do B)  
  //   pivX/pivY = ponto final do contorno original
  //   p1x/p1y   = primeiro ponto do lado B (ou último do A)
  //   segNx/Ny  = normal do segmento adjacente ao pivot (direção de saída)
  // ---------------------------------------------------------------------------

  static void _addCapToPath(
    BLPath out,
    double p0x,
    double p0y,
    double pivX,
    double pivY,
    double p1x,
    double p1y,
    BLStrokeCap cap,
    double hw,
    double segNx,   // normal do segmento (nx[último ou primeiro])
    double segNy,
  ) {
    // Vetor de avanço do cap na tangente do segmento.
    // A tangente é perpendicular à normal do segmento: (tx, ty)=(-ny, nx).
    // O sinal já vem correto via segNx/segNy no chamador (end/start cap).
    final double qx = -segNy * hw;
    final double qy = segNx * hw;

    switch (cap) {
      case BLStrokeCap.butt:
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.square:
        // Estender por hw além do pivot
        out.lineTo(p0x + qx, p0y + qy);
        out.lineTo(p1x + qx, p1y + qy);
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.round:
        // Arco semicircular de 180° ao redor do pivot
        _addRoundCapToPath(out, p0x, p0y, pivX, pivY, p1x, p1y, segNx, segNy, hw);
        return;

      case BLStrokeCap.roundRev:
        // Arco reverso: recua para dentro
        final double cx2 = (p0x + p1x) * 0.5;
        final double cy2 = (p0y + p1y) * 0.5;
        out.lineTo(cx2 + qx, cy2 + qy); // extender
        out.lineTo(pivX, pivY);          // recuar ao centro
        out.lineTo(cx2 + qx, cy2 + qy); // re-extender (outro lado)
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.triangle:
        out.lineTo(pivX, pivY);
        out.lineTo(p1x, p1y);
        return;

      case BLStrokeCap.triangleRev:
        out.lineTo(p0x + qx, p0y + qy);
        out.lineTo(pivX, pivY);
        out.lineTo(p1x + qx, p1y + qy);
        out.lineTo(p1x, p1y);
        return;
    }
  }

  /// Arco de cap semicircular: de p0 ao redor de piv até p1 (180°).
  static void _addRoundCapToPath(
    BLPath out,
    double p0x,
    double p0y,
    double pivX,
    double pivY,
    double p1x,
    double p1y,
    double segNx,
    double segNy,
    double hw,
  ) {
    // O ponto de meia-lua do cap: pivot + hw * tangente_forward.
    // Tangente forward = (segNy, -segNx) onde segN é a normal esquerda do segmento.
    // Para o end cap: tangente = (ny_last, -nx_last)
    // Para o start cap: a direção é invertida.
    final double tx = segNy, ty = -segNx;
    final double midX = pivX + hw * tx;
    final double midY = pivY + hw * ty;

    // Cross de (p0 - piv) com (mid - piv): determina sentido do arco
    final double ax = p0x - pivX, ay = p0y - pivY;
    final double mx = midX - pivX, my = midY - pivY;
    final double cross0 = ax * my - ay * mx;

    // Arco de p0 passando por mid até p1
    // Subdividir em 2 passos via mid como waypoint
    final tmpVerts = <double>[];
    if (cross0 >= 0.0) {
      _addArcPoints(tmpVerts, pivX, pivY, p0x, p0y, midX, midY);
      _addArcPoints(tmpVerts, pivX, pivY, midX, midY, p1x, p1y);
    } else {
      // Sentido inverso: p0 → mid do outro lado
      _addArcPoints(tmpVerts, pivX, pivY, p0x, p0y, midX, midY);
      _addArcPoints(tmpVerts, pivX, pivY, midX, midY, p1x, p1y);
    }

    final int nPts = tmpVerts.length ~/ 2;
    for (int i = 0; i < nPts; i++) {
      out.lineTo(tmpVerts[i * 2], tmpVerts[i * 2 + 1]);
    }
    // Garantir que chegamos exatamente em p1
    out.lineTo(p1x, p1y);
  }

  // ---------------------------------------------------------------------------
  // Utilitários de emissão de polígono no BLPath de saída
  // ---------------------------------------------------------------------------

  static void _emitClosedPolygon(List<double> verts, BLPath out) {
    final int n = verts.length ~/ 2;
    if (n < 2) return;
    out.moveTo(verts[0], verts[1]);
    for (int i = 1; i < n; i++) {
      out.lineTo(verts[i * 2], verts[i * 2 + 1]);
    }
    out.close();
  }

  static void _emitClosedPolygonReversed(List<double> verts, BLPath out) {
    final int n = verts.length ~/ 2;
    if (n < 2) return;
    out.moveTo(verts[(n - 1) * 2], verts[(n - 1) * 2 + 1]);
    for (int i = n - 2; i >= 0; i--) {
      out.lineTo(verts[i * 2], verts[i * 2 + 1]);
    }
    out.close();
  }
}
