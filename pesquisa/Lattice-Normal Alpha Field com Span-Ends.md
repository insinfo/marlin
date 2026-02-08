A tua saída de benchmark já está te contando uma verdade bem “CPU-real”: o gargalo não é “matemática exata” — é largura de banda de memória + branches + overdraw. Por isso o teu SCANLINE_EO (sem AA) voa, e quase todo o resto perde feio quando passa a tocar muitos pixels, ou faz muita conta por pixel.

Então, se a meta é AA (ou subpixel) com custo quase de “scanline sem AA”, o caminho “de fronteira” é:

continuar preenchendo o interior como spans sólidos (memset/memcpy/blit super barato), e

pagar AA só nos pixels de borda (quase sempre 2 pixels por span), e

fazer esse AA de borda com zero sqrt, zero trig, zero float, zero clipping por pixel, só inteiros + LUT.

A seguir vai um algoritmo novo (no sentido de “pipeline e matemática” pensados especificamente pra linguagem gerenciada), que encaixa perfeito no teu ecossistema (scanline/AET) e mira exatamente o ponto fraco do AA tradicional.

LNAF-SE: Lattice-Normal Alpha Field com Span-Ends

(“Campo de Alfa por Normal Lattice” + “AA só nas pontas de spans”)

Ideia central

Para um scanline renderer, em cada linha y você produz spans [xL, xR) “dentro”. Em cenas reais, a maioria esmagadora dos pixels está 100% dentro ou 100% fora — o que precisa suavizar é só a fronteira.

Então o LNAF-SE faz:

Interior do span: escreve cobertura 255 direto (ou aplica fill opaco direto).

Somente nos pixels de borda (xL-1/xL e xR-1/xR): calcula α parcial via uma LUT baseada em:

normal inteira da aresta (reduzida/quantizada),

offset assinado (também quantizado) do centro do pixel até a aresta.

É o mesmo “espírito” de converter geometria em lookup (como teu QCS e EdgePlane), mas aqui com uma matemática que elimina a parte cara: normalização por comprimento (sqrt(A²+B²)). 

Quantized Coverage Signature Ra…

A matemática nova: “Normal lattice” que dispensa sqrt

Uma aresta (segmento) define um half-plane pelo edge function:

𝐹
(
𝑥
,
𝑦
)
=
𝐴
𝑥
+
𝐵
𝑦
+
𝐶
F(x,y)=Ax+By+C

com 
𝐴
=
Δ
𝑦
A=Δy e 
𝐵
=
−
Δ
𝑥
B=−Δx (ou equivalente). Em AA “analítico”, você quer o signed distance:

𝑑
=
𝐹
(
𝑥
𝑐
,
𝑦
𝑐
)
𝐴
2
+
𝐵
2
d=
A
2
+B
2
	​

F(x
c
	​

,y
c
	​

)
	​


e então transformar isso em cobertura da célula do pixel.

O pulo do LNAF-SE: em vez de dividir por 
𝐴
2
+
𝐵
2
A
2
+B
2
	​

, você projeta a aresta para um espaço de normais inteiras pequenas:

pega a normal 
(
𝐴
,
𝐵
)
(A,B) em ponto fixo,

reduz/quantiza para um par pequeno 
(
𝑝
,
𝑞
)
(p,q) que representa só a direção (ex.: gcd + clamp/shift),

mede o offset 
𝑡
=
𝐹
(
𝑥
𝑐
,
𝑦
𝑐
)
t=F(x
c
	​

,y
c
	​

) no mesmo sistema quantizado.

Assim, a cobertura do pixel vira uma função:

𝛼
=
LUT
[
 
sig
(
𝑝
,
𝑞
)
 
]
[
 
𝑡
𝑞
 
]
α=LUT[sig(p,q)][t
q
	​

]

Onde sig(p,q) é um ID da normal quantizada, e t_q é o offset quantizado (por exemplo, em passos de 1/16 px).
Toda a “normalização” fica embutida na LUT.

Isso é viável porque, quando 
(
𝑝
,
𝑞
)
(p,q) é pequeno e discreto, o recorte do quadrado do pixel por um half-plane só produz um conjunto finito de áreas possíveis. Ou seja: dá pra pré-computar exatamente (via clipping de polígono off-line) e armazenar em tabela compacta.

Por que isso tende a ser absurdamente rápido em Dart

Porque o hot loop vira:

AET/interseções (você já tem isso super otimizado e o benchmark prova),

fill do miolo = escrita contígua (cache-friendly),

AA = 2 LUT fetch + 2 blends por span.

Sem double, sem objetos temporários, sem sort caro (já já falo disso), e sem tocar pixel fora de spans.

Esse tipo de desenho (scan converter → coverage mask) é literalmente como arquiteturas clássicas de raster em CPU são descritas (Skia: SkScan gera máscara de cobertura por scanline e um “blitter” aplica cor).
E o Blend2D também discute o núcleo “area/cover” e como chegar em coverage final via acumulação.

A diferença é: você não está gerando uma máscara inteira, só corrigindo a fronteira dos spans.

Pipeline completo (pronto pra encaixar no teu SCANLINE_EO)
1) Pré-processo (uma vez por path)

Flatten das curvas (você já faz no parser SVG).

Para cada aresta:

yMin..yMax, xAtYMin (fixed-point), dx/dy (fixed-point)

normal signature: quantiza 
(
𝐴
,
𝐵
)
→
(
𝑝
,
𝑞
)
→
𝑖
𝑑
(A,B)→(p,q)→id

C do edge function (ou forma incremental).

2) Scanline (por y)

Atualiza AET e gera interseções x[i].

Evite sort de comparação: faça bucket sort por subpixel dentro do tile/linha quando possível
(em tile 32px com 8 subpixels = 256 buckets; isso é ouro em linguagem gerenciada).

Aplica regra (even-odd ou non-zero) e gera spans.

3) Escreve spans

Miolo: fillSolid(xL+1 .. xR-1) direto.

Bordas:

pixel à esquerda e à direita: calcula t_q (offset quantizado) via edge function incremental

alpha = LUT[id][t_q]

blend só nesses pixels.

Corner cases (vértice agudo / duas arestas no mesmo pixel):
detecta quando xR-xL é muito pequeno ou quando duas interseções caem no mesmo pixel; aí faz fallback baratíssimo (ex.: 2×2 ou 4 amostras) só nesses poucos pixels.
Isso mantém qualidade sem “explodir custo”.

LUT: tamanho realista

Você não precisa de “ângulo 0..360”. Usa simetrias:

só 1º quadrante (p≥0,q≥0) e aplica sinais por espelhamento,

troca (p,q) por (q,p) com transposição.

Exemplo prático:

p,q em 0..31 com redução por gcd → dá poucas centenas de assinaturas úteis

t_q em [-32..+32] (em 1/16 px) → 65 entradas

total: ~300 * 65 = 19.500 bytes (se α em uint8) — ridiculamente pequeno, cabe em cache L1.

Isso conversa diretamente com a tua linha de pesquisa de LUTs (QCS / EdgePlane Lookup AA). 

Quantized Coverage Signature Ra…

Onde isso pode “ganhar de C/C++” na prática

Ser honesto: em micro-benchmark puro, C++ bem escrito ainda costuma ganhar.
Mas você pode vencer bibliotecas C++ “

Quantized Coverage Signature Ra…

eais quando:

há muito overdraw (ex.: SVGs em camadas tipo Ghostscript Tiger), e você implementa oclusão por tiles para fills opacos:

se um tile ficou 100% coberto por shapes opacos no topo, você pula o resto (hierarchical coverage).

o pipeline C++ está fazendo máscara completa (coverage buffer) e você está fazendo span-ends (custo proporcional a perímetro e spans, não à área).

sua versão Dart é “no-allocation + typed arrays + loops planos”, e o C++ concorrente tem mais overhead estrutural (virtual calls, pipeline muito geral).

Ou seja: o “truque” não é “Dart mais rápido que C++”, é menos trabalho total.

Relação com o estado da arte (pra você se ancorar)

Edge-flag AA (Kallio) mostra como ganhar performance forte com amostragem e operações baratas em scanlines.

stb_truetype v2 populariza o raciocínio de computar cobertura sem clipping explícito caro e com lógica de AET bem parecida.

Skia CPU descreve o modelo “scan converter → coverage mask → blitter”.

Blend2D discute o núcleo analítico de “area/cover”.

O LNAF-SE pega essa tradição e faz o corte “de linguagem gerenciada”: AA só onde importa + LUT que remove as operações caras de distância.

Nome da técnica (se você quiser “branding”)

LNAF-SE — Lattice-Normal Alpha Field, Span-Ends
apelido: “AA por Assinatura de Normal”
 
## exemplo de implementação:

// lnaf_se_rasterizer.dart
//
// LNAF-SE — Lattice-Normal Alpha Field, Span-Ends
// Rasterizador 2D CPU (scanline) com AA focado nas pontas dos spans.
// - Interior: fill sólido (muito rápido / cache-friendly)
// - Bordas: 1 lookup (LUT) + 1 blend por pixel de borda
// - Opcional: preenchimento SIMD (Int32x4List) APENAS para spans sólidos.
//
// Observação importante sobre SIMD no Dart:
// Há relatos/benchmarks onde Int32x4/Float32x4 podem ficar mais lentos em AOT,
// dependendo do padrão de acesso e extração de lanes. Por isso o SIMD aqui é
// opcional e restrito ao caso mais “seguro” (store vetorial de cor constante).
//
// Uso rápido (exemplo no main):
//   dart run lnaf_se_rasterizer.dart
//
// Integração:
// - Use LnafSeRasterizer(width,height, useSimdFill: true/false)
// - Chame fillPath(...) com contornos (listas de pontos).
// - Leia pixels32 (Uint32List ARGB).
//
// Sem dependências externas.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io';

/// Ponto 2D simples (double).
class Pt {
  final double x;
  final double y;
  const Pt(this.x, this.y);
}

/// Regras de preenchimento.
enum FillRule { evenOdd, nonZero }

/// Tabela de cobertura AA: [dirId][dist16] -> alpha (0..255).
///
/// dist16 é a distância assinada (em pixels * 16) do centro do pixel até a linha,
/// positiva para o lado "dentro" do half-plane.
///
/// Implementação:
/// - Quantiza direção em 8 octantes * binsPerOctant.
/// - Para cada direção, pré-computa a área exata do recorte do quadrado do pixel
///   [-0.5,0.5]^2 pelo half-plane n·x >= d.
class LnafSeLut {
  final int dirCount;
  final int binsPerOctant;
  final int maxDist16; // Ex: 32 -> +-2px em passos de 1/16.
  final Uint8List table; // tamanho = dirCount*(2*maxDist16+1)

  // Normais unitárias para geração/debug (double).
  final Float32List nx;
  final Float32List ny;

  static const int _distStrideMax = 1024; // limite de segurança

  LnafSeLut._(
    this.dirCount,
    this.binsPerOctant,
    this.maxDist16,
    this.table,
    this.nx,
    this.ny,
  );

  int get distStride => 2 * maxDist16 + 1;

  @pragma('vm:prefer-inline')
  int alpha(int dirId, int dist16) {
    if (dist16 <= -maxDist16) return 0;
    if (dist16 >= maxDist16) return 255;
    return table[dirId * distStride + (dist16 + maxDist16)];
  }

  /// Cria LUT em runtime (uma vez). Reuso recomendado.
  static LnafSeLut build({
    int binsPerOctant = 16, // 8*16 = 128 direções
    int maxDist16 = 32,
  }) {
    if (binsPerOctant <= 0) {
      throw ArgumentError('binsPerOctant must be > 0');
    }
    if (maxDist16 <= 0 || (2 * maxDist16 + 1) > _distStrideMax) {
      throw ArgumentError('maxDist16 inválido');
    }

    final dirCount = 8 * binsPerOctant;
    final stride = 2 * maxDist16 + 1;
    final table = Uint8List(dirCount * stride);
    final nx = Float32List(dirCount);
    final ny = Float32List(dirCount);

    // Define direção central de cada bin dentro de cada octante.
    // Octantes em torno do círculo, cada octante cobre 45° (pi/4).
    for (int oct = 0; oct < 8; oct++) {
      final base = oct * (math.pi / 4.0);
      for (int b = 0; b < binsPerOctant; b++) {
        final t = (b + 0.5) / binsPerOctant; // centro do bin
        final ang = base + t * (math.pi / 4.0);
        final id = oct * binsPerOctant + b;
        nx[id] = math.cos(ang).toDouble();
        ny[id] = math.sin(ang).toDouble();
      }
    }

    // Geração: clipping do quadrado unitário pelo half-plane.
    for (int id = 0; id < dirCount; id++) {
      final nxx = nx[id];
      final nyy = ny[id];

      for (int di = -maxDist16; di <= maxDist16; di++) {
        final d = di / 16.0; // distância em pixels
        final cov = _coverageHalfPlane(nxx, nyy, d);
        final a = (cov * 255.0 + 0.5).floor();
        table[id * stride + (di + maxDist16)] = a.clamp(0, 255);
      }
    }

    // Pequeno pós-processo para garantir monotonicidade (evita serrilhado por
    // erros numéricos microscópicos do double).
    for (int id = 0; id < dirCount; id++) {
      final base = id * stride;
      for (int i = 1; i < stride; i++) {
        final prev = table[base + i - 1];
        final cur = table[base + i];
        if (cur < prev) table[base + i] = prev;
      }
    }

    return LnafSeLut._(dirCount, binsPerOctant, maxDist16, table, nx, ny);
  }

  // --- Geometria de cobertura: recorte de polígono convexo (Sutherland–Hodgman).

  static double _coverageHalfPlane(double nx, double ny, double d) {
    // Quadrado do pixel no espaço local (centro em 0): área = 1.
    // Vértices CCW.
    const x0 = -0.5, x1 = 0.5;
    const y0 = -0.5, y1 = 0.5;

    // Polígono inicial (4 pontos).
    final px = Float64List(8);
    final py = Float64List(8);
    int n = 4;
    px[0] = x0; py[0] = y0;
    px[1] = x1; py[1] = y0;
    px[2] = x1; py[2] = y1;
    px[3] = x0; py[3] = y1;

    // Clipa contra a borda única: nx*x + ny*y - d >= 0.
    final outx = Float64List(8);
    final outy = Float64List(8);
    int outN = 0;

    double sx = px[n - 1];
    double sy = py[n - 1];
    double sVal = nx * sx + ny * sy - d;
    bool sIn = sVal >= 0.0;

    for (int i = 0; i < n; i++) {
      final ex = px[i];
      final ey = py[i];
      final eVal = nx * ex + ny * ey - d;
      final eIn = eVal >= 0.0;

      if (sIn && eIn) {
        // Dentro -> mantém E
        outx[outN] = ex;
        outy[outN] = ey;
        outN++;
      } else if (sIn && !eIn) {
        // Sai -> adiciona interseção
        final t = sVal / (sVal - eVal);
        outx[outN] = sx + (ex - sx) * t;
        outy[outN] = sy + (ey - sy) * t;
        outN++;
      } else if (!sIn && eIn) {
        // Entra -> interseção + E
        final t = sVal / (sVal - eVal);
        outx[outN] = sx + (ex - sx) * t;
        outy[outN] = sy + (ey - sy) * t;
        outN++;
        outx[outN] = ex;
        outy[outN] = ey;
        outN++;
      }

      sx = ex;
      sy = ey;
      sVal = eVal;
      sIn = eIn;
    }

    if (outN < 3) return 0.0;
    // Área do polígono recortado (shoelace).
    double area2 = 0.0;
    double ax = outx[outN - 1];
    double ay = outy[outN - 1];
    for (int i = 0; i < outN; i++) {
      final bx = outx[i];
      final by = outy[i];
      area2 += ax * by - bx * ay;
      ax = bx;
      ay = by;
    }
    final area = (area2.abs()) * 0.5;
    // Área do quadrado é 1.0
    if (area <= 0.0) return 0.0;
    if (area >= 1.0) return 1.0;
    return area;
  }
}

/// Rasterizador LNAF-SE (scanline) com span-ends AA.
class LnafSeRasterizer {
  // Coordenadas em fixo 24.8 (scale=256).
  static const int kScale = 256;
  static const int kHalf = 128;
  static const int kInvQ = 20; // precisão do invDen (shift)
  static const int kClampDist16 = 32; // precisa bater com LUT.maxDist16 (default)

  final int width;
  final int height;
  final bool useSimdFill;
  final LnafSeLut lut;

  final Uint32List pixels32;
  Int32x4List? _pixelsV; // view SIMD (opcional)

  // Edge storage (SoA) - tamanhos definidos em buildEdges.
  late Int32List _eYStart;
  late Int32List _eYEnd;
  late Int32List _eX;      // x intersection atual (24.8)
  late Int32List _eDx;     // delta x por scanline (24.8)
  late Int32List _eA;      // coef A da edge function
  late Int32List _eB;      // coef B
  late Int64List _eC;      // coef C (64)
  late Int32List _eInvDen; // invDen ~ 16/(scale*len) em Q=kInvQ
  late Int32List _eDir;    // dirId p/ LUT
  late Int32List _eWind;   // winding (+1/-1)
  late Int32List _eNext;   // próximo no bucket
  late Int32List _bucketHead; // por scanline

  // Reuso por scanline.
  late Int32List _active;  // edge indices
  int _activeCount = 0;

  late Int32List _ix;      // intersections X
  late Int32List _ie;      // intersections edgeId

  // Quicksort stack
  late Int32List _qsL;
  late Int32List _qsR;

  LnafSeRasterizer(
    this.width,
    this.height, {
    required this.lut,
    this.useSimdFill = false,
  }) : pixels32 = Uint32List(width * height) {
    if (useSimdFill) {
      // View de 16 bytes (4 pixels) - útil apenas p/ store vetorial de cor constante.
      _pixelsV = pixels32.buffer.asInt32x4List();
    }
  }

  void clear(int argb) {
    final c = argb & 0xFFFFFFFF;
    if (!useSimdFill) {
      for (int i = 0; i < pixels32.length; i++) {
        pixels32[i] = c;
      }
      return;
    }
    final v = _pixelsV!;
    final vv = Int32x4(c, c, c, c);
    final n4 = v.length;
    for (int i = 0; i < n4; i++) {
      v[i] = vv;
    }
    // Tail (se len não múltiplo de 4)
    final start = n4 << 2;
    for (int i = start; i < pixels32.length; i++) {
      pixels32[i] = c;
    }
  }

  /// Preenche um "path" com múltiplos contornos.
  /// - Para buracos em SVG/PDF: passe todos os contornos e escolha FillRule.
  void fillPath(
    List<List<Pt>> contours,
    int argb, {
    FillRule rule = FillRule.nonZero,
  }) {
    _buildEdges(contours);
    _rasterize(argb, rule);
  }

  // --- Construção de edges + buckets

  @pragma('vm:prefer-inline')
  static int _ceilDiv(int a, int b) {
    // b > 0
    if (a >= 0) return (a + b - 1) ~/ b;
    return -((-a) ~/ b);
  }

  void _buildEdges(List<List<Pt>> contours) {
    // Conta edges (sem horizontais).
    int edgeCount = 0;
    for (final c in contours) {
      if (c.length < 2) continue;
      for (int i = 0; i < c.length; i++) {
        final p0 = c[i];
        final p1 = c[(i + 1) % c.length];
        if (p0.y == p1.y) continue;
        edgeCount++;
      }
    }

    // Aloca SoA.
    _eYStart = Int32List(edgeCount);
    _eYEnd = Int32List(edgeCount);
    _eX = Int32List(edgeCount);
    _eDx = Int32List(edgeCount);
    _eA = Int32List(edgeCount);
    _eB = Int32List(edgeCount);
    _eC = Int64List(edgeCount);
    _eInvDen = Int32List(edgeCount);
    _eDir = Int32List(edgeCount);
    _eWind = Int32List(edgeCount);
    _eNext = Int32List(edgeCount);

    _bucketHead = Int32List(height);
    for (int i = 0; i < height; i++) _bucketHead[i] = -1;

    // Reuso para raster.
    _active = Int32List(edgeCount);
    _ix = Int32List(edgeCount);
    _ie = Int32List(edgeCount);
    _qsL = Int32List(64);
    _qsR = Int32List(64);

    int e = 0;
    final binsPerOct = lut.binsPerOctant;

    for (final c in contours) {
      if (c.length < 2) continue;
      for (int i = 0; i < c.length; i++) {
        final p0 = c[i];
        final p1 = c[(i + 1) % c.length];
        if (p0.y == p1.y) continue;

        // Converte para fixo 24.8
        int x0 = (p0.x * kScale).round();
        int y0 = (p0.y * kScale).round();
        int x1 = (p1.x * kScale).round();
        int y1 = (p1.y * kScale).round();

        // winding é baseado no sentido original (antes de possivelmente trocar)
        final winding = (y1 > y0) ? 1 : -1;

        // Normaliza para y0 < y1 para scanline.
        if (y0 > y1) {
          final tx = x0; x0 = x1; x1 = tx;
          final ty = y0; y0 = y1; y1 = ty;
        }

        // Define faixa de scanlines baseada em centros yCenter = y*256 + 128
        // ativo quando yCenter >= y0 && yCenter < y1.
        final yStart = _ceilDiv(y0 - kHalf, kScale);
        final yEndEx = _ceilDiv(y1 - kHalf, kScale);

        if (yEndEx <= 0 || yStart >= height) {
          // totalmente fora
          continue;
        }

        final yS = yStart.clamp(0, height);
        final yE = yEndEx.clamp(0, height);

        if (yS >= yE) continue;

        // x no primeiro scanline (yS)
        final yCenter = yS * kScale + kHalf;
        final dy = (y1 - y0);
        final dx = (x1 - x0);
        // x = x0 + dx*(yCenter - y0)/dy
        final t = (yCenter - y0);
        final xAt = x0 + ((dx * t) ~/ dy);

        // step por scanline: dxPer = dx*scale/dy
        final xStep = (dx * kScale) ~/ dy;

        // Edge function F(x,y) = A*x + B*y + C
        // A = y0 - y1; B = x1 - x0; C = x0*y1 - x1*y0
        final A = (y0 - y1);
        final B = (x1 - x0);
        final C = (x0 * y1) - (x1 * y0);

        // invDen ~ 16/(scale*len) em Q=kInvQ
        final len = math.sqrt((A.toDouble() * A.toDouble()) + (B.toDouble() * B.toDouble()));
        final invDen = len <= 0.0
            ? 0
            : ((16.0 * (1 << kInvQ)) / (kScale * len)).round().clamp(0, 0x7FFFFFFF);

        // Direção quantizada p/ LUT (baseada em (A,B)).
        final dirId = _dirQuantize(A, B, binsPerOct);

        // Escreve edge.
        final idx = e++;
        _eYStart[idx] = yS;
        _eYEnd[idx] = yE;
        _eX[idx] = xAt;
        _eDx[idx] = xStep;
        _eA[idx] = A;
        _eB[idx] = B;
        _eC[idx] = C;
        _eInvDen[idx] = invDen;
        _eDir[idx] = dirId;
        _eWind[idx] = winding;

        // Bucket push.
        final head = _bucketHead[yS];
        _eNext[idx] = head;
        _bucketHead[yS] = idx;
      }
    }

    // Ajusta edgeCount real (caso tenha pulado edges fora).
    // Se e < edgeCount, truncar arrays seria ideal, mas isso aloca. Preferimos manter.
    // Vamos só memorizar _activeCount reset.
    _activeCount = 0;
  }

  /// Quantiza o vetor (A,B) em um dirId em [0, 8*binsPerOctant).
  @pragma('vm:prefer-inline')
  static int _dirQuantize(int A, int B, int binsPerOctant) {
    int a = A;
    int b = B;
    if (a == 0 && b == 0) return 0;

    final absA = a < 0 ? -a : a;
    final absB = b < 0 ? -b : b;

    // Decide octante
    int oct;
    final aGeB = absA >= absB;
    if (a >= 0) {
      if (b >= 0) {
        oct = aGeB ? 0 : 1;
      } else {
        oct = aGeB ? 7 : 6;
      }
    } else {
      if (b >= 0) {
        oct = aGeB ? 3 : 2;
      } else {
        oct = aGeB ? 4 : 5;
      }
    }

    final maxv = aGeB ? absA : absB;
    final minv = aGeB ? absB : absA;
    if (maxv == 0) return oct * binsPerOctant;

    // ratio em Q12
    final ratioQ12 = (minv << 12) ~/ maxv; // 0..4096
    int bin = (ratioQ12 * binsPerOctant) >> 12;
    if (bin >= binsPerOctant) bin = binsPerOctant - 1;
    return oct * binsPerOctant + bin;
  }

  // --- Rasterização

  void _rasterize(int argb, FillRule rule) {
    // Componentes da cor (pré-extraídos).
    final srcA0 = (argb >>> 24) & 255;
    final srcR = (argb >>> 16) & 255;
    final srcG = (argb >>> 8) & 255;
    final srcB = (argb) & 255;

    for (int y = 0; y < height; y++) {
      // Adiciona edges que começam aqui.
      for (int e = _bucketHead[y]; e != -1; e = _eNext[e]) {
        _active[_activeCount++] = e;
      }

      if (_activeCount == 0) continue;

      // Remove edges expiradas e coleta interseções.
      int n = 0;
      final yCenter = y * kScale + kHalf;

      for (int i = 0; i < _activeCount; i++) {
        final e = _active[i];
        if (y >= _eYEnd[e]) {
          continue; // remove (não copia)
        }
        // intersection x atual
        _ix[n] = _eX[e];
        _ie[n] = e;
        n++;

        // avança x para próximo scanline
        _eX[e] = _eX[e] + _eDx[e];

        // mantém na lista ativa
        _active[i] = e;
      }

      _activeCount = n;
      if (n < 2) continue;

      _sortPairsByX(_ix, _ie, n);

      // Gera spans conforme regra.
      if (rule == FillRule.evenOdd) {
        for (int i = 0; i + 1 < n; i += 2) {
          final x0 = _ix[i];
          final e0 = _ie[i];
          final x1 = _ix[i + 1];
          final e1 = _ie[i + 1];
          if (x0 == x1) continue;
          _fillSpanAA(
            y,
            x0,
            x1,
            e0,
            e1,
            yCenter,
            srcA0,
            srcR,
            srcG,
            srcB,
          );
        }
      } else {
        int winding = 0;
        int xStart = 0;
        int eStart = -1;
        for (int i = 0; i < n; i++) {
          final x = _ix[i];
          final e = _ie[i];
          final w = _eWind[e];
          final newW = winding + w;
          if (winding == 0 && newW != 0) {
            xStart = x;
            eStart = e;
          } else if (winding != 0 && newW == 0) {
            final xEnd = x;
            final eEnd = e;
            if (xStart != xEnd) {
              _fillSpanAA(
                y,
                xStart,
                xEnd,
                eStart,
                eEnd,
                yCenter,
                srcA0,
                srcR,
                srcG,
                srcB,
              );
            }
            eStart = -1;
          }
          winding = newW;
        }
      }
    }
  }

  // Preenche um span entre x0 e x1 (24.8), com AA nas pontas.
  @pragma('vm:prefer-inline')
  void _fillSpanAA(
    int y,
    int x0,
    int x1,
    int leftEdge,
    int rightEdge,
    int yCenter,
    int srcA0,
    int srcR,
    int srcG,
    int srcB,
  ) {
    // Ordena.
    int xa = x0;
    int xb = x1;
    int eL = leftEdge;
    int eR = rightEdge;
    if (xa > xb) {
      final t = xa; xa = xb; xb = t;
      final te = eL; eL = eR; eR = te;
    }

    // Converte para pixels.
    final leftPix = xa >> 8;
    final rightPix = (xb - 1) >> 8;

    if (rightPix < 0 || leftPix >= width) return;

    final row = y * width;

    // Caso ultra-fino: tudo cai no mesmo pixel.
    if (leftPix == rightPix) {
      final pix = leftPix;
      if (pix < 0 || pix >= width) return;

      // cobertura aproximada 1D pela largura horizontal (boa para spans muito finos)
      int wFixed = xb - xa; // 0..256
      if (wFixed <= 0) return;
      if (wFixed > kScale) wFixed = kScale;
      final cover = (wFixed * 255 + 127) >> 8; // 0..255

      final effA = (cover * srcA0 + 127) ~/ 255;
      if (effA <= 0) return;

      final idx = row + pix;
      pixels32[idx] = _blendOver(
        pixels32[idx],
        srcR,
        srcG,
        srcB,
        effA,
      );
      return;
    }

    // Ponto de teste no interior do span, para orientar o half-plane (F >= 0).
    final midPix = ((leftPix + rightPix) >> 1).clamp(0, width - 1);
    final xMidC = midPix * kScale + kHalf;

    // Preenche interior sólido (exclui pixels de borda).
    final fillStart = math.max(leftPix + 1, 0);
    final fillEnd = math.min(rightPix, width); // exclusivo
    if (fillStart < fillEnd) {
      _fillSolidSpan(row, fillStart, fillEnd, (srcA0 << 24) | (srcR << 16) | (srcG << 8) | srcB);
    }

    // Pixel de borda esquerda
    if (leftPix >= 0 && leftPix < width) {
      final xLC = leftPix * kScale + kHalf;
      final insidePos = _evalF(eL, xMidC, yCenter) >= 0;
      final a = _alphaAt(eL, xLC, yCenter, insidePos);
      final effA = (a * srcA0 + 127) ~/ 255;
      if (effA > 0) {
        final idx = row + leftPix;
        pixels32[idx] = _blendOver(pixels32[idx], srcR, srcG, srcB, effA);
      }
    }

    // Pixel de borda direita
    if (rightPix >= 0 && rightPix < width) {
      final xRC = rightPix * kScale + kHalf;
      final insidePos = _evalF(eR, xMidC, yCenter) >= 0;
      final a = _alphaAt(eR, xRC, yCenter, insidePos);
      final effA = (a * srcA0 + 127) ~/ 255;
      if (effA > 0) {
        final idx = row + rightPix;
        pixels32[idx] = _blendOver(pixels32[idx], srcR, srcG, srcB, effA);
      }
    }
  }

  @pragma('vm:prefer-inline')
  int _evalF(int e, int x, int y) {
    // F = A*x + B*y + C
    return (_eA[e] * x) + (_eB[e] * y) + _eC[e].toInt();
  }

  @pragma('vm:prefer-inline')
  int _alphaAt(int e, int xC, int yC, bool insidePositive) {
    int f = _evalF(e, xC, yC);
    if (!insidePositive) f = -f;
    final invDen = _eInvDen[e];
    if (invDen == 0) return 255;

    // dist16 = round( f * invDen / 2^kInvQ )
    int dist16;
    if (f >= 0) {
      dist16 = (f * invDen + (1 << (kInvQ - 1))) >> kInvQ;
    } else {
      dist16 = -(((-f) * invDen + (1 << (kInvQ - 1))) >> kInvQ);
    }

    if (dist16 <= -kClampDist16) return 0;
    if (dist16 >= kClampDist16) return 255;

    final dir = _eDir[e];
    return lut.alpha(dir, dist16);
  }

  void _fillSolidSpan(int row, int x0, int x1, int argb) {
    int i = row + x0;
    final end = row + x1;
    final c = argb & 0xFFFFFFFF;

    if (!useSimdFill) {
      for (; i < end; i++) {
        pixels32[i] = c;
      }
      return;
    }

    // SIMD store em blocos de 4 pixels (Int32x4).
    final v = _pixelsV!;
    final vv = Int32x4(c, c, c, c);

    // Alinha em 4 pixels.
    int head = (i + 3) & ~3;
    for (; i < head && i < end; i++) {
      pixels32[i] = c;
    }
    int i4 = i >> 2;
    int end4 = end >> 2;
    for (; i4 < end4; i4++) {
      v[i4] = vv;
    }
    i = end4 << 2;
    for (; i < end; i++) {
      pixels32[i] = c;
    }
  }

  // --- Blend (SRC-over) sem premultiplicação (só 2 pixels por span, ok).

  @pragma('vm:prefer-inline')
  static int _blendOver(int dst, int sr, int sg, int sb, int sa) {
    // dst: ARGB
    final da = (dst >>> 24) & 255;
    final dr = (dst >>> 16) & 255;
    final dg = (dst >>> 8) & 255;
    final db = dst & 255;

    final invA = 255 - sa;

    final outA = sa + ((da * invA + 127) ~/ 255);
    final outR = ((sr * sa + dr * invA) + 127) ~/ 255;
    final outG = ((sg * sa + dg * invA) + 127) ~/ 255;
    final outB = ((sb * sa + db * invA) + 127) ~/ 255;

    return (outA << 24) | (outR << 16) | (outG << 8) | outB;
  }

  // --- Sort: quicksort iterativo (2 arrays paralelos) para evitar alocações.

  void _sortPairsByX(Int32List xs, Int32List es, int n) {
    // Pequenos n: insertion sort é melhor.
    if (n <= 16) {
      _insertionSort(xs, es, n);
      return;
    }

    int sp = 0;
    _qsL[sp] = 0;
    _qsR[sp] = n - 1;
    sp++;

    while (sp > 0) {
      sp--;
      int l = _qsL[sp];
      int r = _qsR[sp];

      while (l < r) {
        int i = l;
        int j = r;
        final pivot = xs[(l + r) >> 1];

        while (i <= j) {
          while (xs[i] < pivot) i++;
          while (xs[j] > pivot) j--;
          if (i <= j) {
            final tx = xs[i];
            xs[i] = xs[j];
            xs[j] = tx;
            final te = es[i];
            es[i] = es[j];
            es[j] = te;
            i++;
            j--;
          }
        }

        // Recurse no menor primeiro (stack pequena).
        if (j - l < r - i) {
          if (l < j) {
            if (sp >= _qsL.length) {
              _growStack();
            }
            _qsL[sp] = l;
            _qsR[sp] = j;
            sp++;
          }
          l = i;
        } else {
          if (i < r) {
            if (sp >= _qsL.length) {
              _growStack();
            }
            _qsL[sp] = i;
            _qsR[sp] = r;
            sp++;
          }
          r = j;
        }
      }
    }
  }

  void _growStack() {
    final nl = Int32List(_qsL.length * 2);
    final nr = Int32List(_qsR.length * 2);
    nl.setAll(0, _qsL);
    nr.setAll(0, _qsR);
    _qsL = nl;
    _qsR = nr;
  }

  @pragma('vm:prefer-inline')
  static void _insertionSort(Int32List xs, Int32List es, int n) {
    for (int i = 1; i < n; i++) {
      final keyX = xs[i];
      final keyE = es[i];
      int j = i - 1;
      while (j >= 0 && xs[j] > keyX) {
        xs[j + 1] = xs[j];
        es[j + 1] = es[j];
        j--;
      }
      xs[j + 1] = keyX;
      es[j + 1] = keyE;
    }
  }

  // --- Util: salvar como PPM (simples, sem libs)

  void savePpm(String path) {
    final f = File(path);
    final sink = f.openWrite();
    sink.write('P6\n$width $height\n255\n');
    final row = Uint8List(width * 3);
    for (int y = 0; y < height; y++) {
      int p = 0;
      final off = y * width;
      for (int x = 0; x < width; x++) {
        final c = pixels32[off + x];
        row[p++] = (c >>> 16) & 255;
        row[p++] = (c >>> 8) & 255;
        row[p++] = c & 255;
      }
      sink.add(row);
    }
    sink.close();
  }
}

void main() {
  // Demonstração mínima.
  // Gere LUT uma vez e reuse entre rasterizações (em produção, crie global/cache).
  final lut = LnafSeLut.build(binsPerOctant: 16, maxDist16: 32);

  final w = 512, h = 512;
  final r = LnafSeRasterizer(w, h, lut: lut, useSimdFill: false);

  r.clear(0xFFFFFFFF);

  // Estrela simples + buraco (contorno interno), FillRule.evenOdd.
  final outer = <Pt>[];
  final inner = <Pt>[];
  final cx = w / 2.0, cy = h / 2.0;
  const spikes = 5;
  final R = 200.0, r0 = 80.0;

  for (int i = 0; i < spikes * 2; i++) {
    final ang = -math.pi / 2 + i * (math.pi / spikes);
    final rr = (i.isEven) ? R : r0;
    outer.add(Pt(cx + math.cos(ang) * rr, cy + math.sin(ang) * rr));
  }
  // Buraco circular aproximado.
  const holeN = 32;
  final holeR = 50.0;
  for (int i = 0; i < holeN; i++) {
    final ang = 2 * math.pi * i / holeN;
    inner.add(Pt(cx + math.cos(ang) * holeR, cy + math.sin(ang) * holeR));
  }

  r.fillPath([outer, inner], 0xFF1E88E5, rule: FillRule.evenOdd);

  // Salva em PPM (abre em várias ferramentas, ou converte com ImageMagick).
  r.savePpm('lnaf_se_demo.ppm');
  stdout.writeln('Gerado: lnaf_se_demo.ppm');
}


