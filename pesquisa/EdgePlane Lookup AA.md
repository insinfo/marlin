Rasterização 2D com Antialiasing por Cobertura Analítica via Lookup de Semi-Plano Orientado

ma ideia bem diferente do “4×4 subpixel” e do “cell accumulation” estilo FreeType/Marlin/Blend2D: em vez de amostrar subpixels, você calcula (ou aproxima) diretamente a fração de área que um semi-plano (definido pela aresta mais relevante) ocupa dentro do quadrado do pixel — e faz isso com LUTs + aritmética incremental, quase sem divisões.

Não vou afirmar que “ninguém nunca pensou”, porque isso é impossível de garantir com honestidade. Mas a combinação específica (semi-plano orientado → cobertura exata do pixel via LUT 2D + seleção local de aresta + fallback só nos casos patológicos) é bem incomum em rasterizadores CPU “clássicos”, e fica muito compatível com Dart puro.

1) A mudança de paradigma: “cobertura por semi-plano orientado”

Para um pixel, a antialiasing “correta” (box filter) é:

𝛼
=
a
ˊ
rea
(
pixel
∩
forma
)
a
ˊ
rea
(
pixel
)
α=
a
ˊ
rea(pixel)
a
ˊ
rea(pixel∩forma)
	​


Na borda, localmente, a forma é (quase sempre) “um lado dentro, um lado fora” — ou seja, um semi-plano cortando o pixel. Então a gente aproxima:

forma dentro do pixel
≈
{
𝑝
:
  
𝑛
⋅
𝑝
+
𝑐
≤
0
}
forma dentro do pixel≈{p:n⋅p+c≤0}

O ponto chave: a cobertura do quadrado do pixel por um semi-plano depende só de:

orientação da reta (ângulo da normal/tangente), e

distância assinada da reta ao centro do pixel.

Ou seja:

𝛼
≈
𝐶
(
𝜃
,
𝑠
)
α≈C(θ,s)

onde s é a distância assinada em “unidades de pixel” (ex.: s=0 corta o centro; s=+0.5 encosta num lado), e θ é a orientação (pode ser reduzida por simetria para 0..π/2).

2) Por que isso pode ser MUITO rápido em CPU / Dart

Porque você transforma o “subpixel” em:

1 lookup numa tabela C(θ, s) (com interpolação opcional),

poucas contas para obter θ e s,

e o resto vira fill de spans (pixels 100% cheios) + AA só nos pixels de borda.

A sacada de performance (Dart-friendly)

Em vez de multiplicar para cada canto do pixel, você usa a forma linear:

Para uma aresta (segmento) P0(x0,y0) -> P1(x1,y1):

vetor v=(dx,dy)=(x1-x0, y1-y0)

normal (qualquer das duas, depende do winding) n=(dy, -dx)

equação: d(p)=n·p + c, com c = -(n·P0).

No tile/scanline, você calcula d num ponto e atualiza com incrementos:

ao andar 1 pixel em x: d += n.x

ao andar 1 pixel em y: d += n.y

Ou seja: quase tudo vira soma de inteiros.

A única “parte chata” é normalizar d para distância s:

𝑠
=
𝑑
∥
𝑛
∥
s=
∥n∥
d
	​


Mas você pode usar um invLen aproximado (LUT ou double rápido) porque isso só afeta os pixels de borda.

3) A LUT 2D que substitui o 4×4 subpixel
Pré-computação

Crie uma tabela:

thetaBins = 256 (0..π/2)

sBins = 1024 cobrindo s ∈ [-1.0, +1.0] (ou [-1.25,+1.25] pra folga)

valor: alpha 0..255

Cada entrada é a área exata do quadrado [-0.5,0.5]^2 que satisfaz n·p + s <= 0, com n unitário orientado por θ.

Você pode gerar isso offline (um script) e embutir como Uint8List no Dart.
Como gerar de forma simples e robusta:

para cada (θ,s), faça clipping do quadrado por semi-plano (Sutherland–Hodgman em 4 vértices, no máximo 6 vértices resultantes), calcule área do polígono.

isso dá “box AA” de verdade para a hipótese de semi-plano.

Em runtime (hot path)

Para um pixel de borda:

acha θbin da aresta “dominante”

calcula sbin (distância assinada ao centro)

alpha = LUT[θbin][sbin]

Opcional: bilinear entre bins pra suavizar ainda mais (normalmente nem precisa).

4) Como escolher a “aresta dominante” sem ficar caro

Esse é o ponto onde a aproximação pode falhar se você escolher errado.

Estratégia prática (rápida)

Processar em microtiles, ex. 16×16 ou 32×32 pixels:

Antes de rasterizar: faça binning das arestas por tile (bbox do segmento).

Para cada tile, você tem uma lista curta de arestas candidatas.

Na hora de AA do pixel de borda:

compute distância assinada |d| ao centro do pixel para cada aresta do tile,

pegue a menor |d| (com mais um critério: a aresta precisa “passar perto” do pixel; ex. bbox expandida por 1 pixel).

pronto: essa é a “dominante”.

Isso custa alguns dot-products só em pixels de borda, e tiles típicos têm poucas arestas.

Detecção de caso patológico + fallback

Quando dá ruim?

pixel perto de vértice (duas arestas competindo),

auto-interseção,

traços finos (duas bordas no mesmo pixel).

Então você faz um teste barato:

se a segunda menor distância |d2| também é pequena (ex. < 0.6 px), ou

se o pixel está a < 1 px de um endpoint do segmento,

→ fallback para um método mais “certo” só ali:

supersampling 2×2 ou 4×4 apenas nesses pixels (que são minoria),

ou clipping real do pixel contra os segmentos que cruzam (ainda constante, mas mais caro).

Isso mantém qualidade aceitável sem perder performance global.

5) Integração com fill rule (even-odd / non-zero) sem confusão

O método C(θ,s) te dá “quanto do pixel está do lado negativo da reta”.
Mas qual lado é “dentro” da forma?

Você resolve assim:

Primeiro, faça um fill “macro” para saber se o centro do pixel está dentro (via scanline AET / winding / even-odd).

Para AA, use a LUT da aresta dominante, mas alinhada ao inside/outside:

se o centro está dentro, você quer a área “inside”; se d(center) é positivo, você inverte s (ou usa 255-alpha).

Na prática:

calcule s com sinal coerente (normal apontando para fora, por exemplo).

se o centro do pixel está dentro mas s indica “mais fora”, usa alpha = 255 - alpha.

Isso evita artefato de “lado errado” quando a normal está invertida.

6) Por que isso é “subpixel” mesmo sem subpixels

Porque a LUT está modelando fração de área contínua do pixel, não uma contagem de amostras.
Você ganha “subpixel-like” por geometria, não por amostragem.

E como a borda real de paths é feita de segmentos, a hipótese de semi-plano é muito boa na maioria dos pixels.

7) O que eu implementaria em Dart puro (pipeline final)

Flatten de curvas → segmentos.

Binning de segmentos em tiles (32×32).

Rasterização por tile:

Determina spans cheios (scanline com AET, ou até um fill por interseções por linha).

Marca pixels 0/255 rapidamente.

Lista de pixels de borda (onde vizinho muda inside/outside).

Para cada pixel de borda:

seleciona aresta dominante (dentre arestas do tile),

calcula θbin (por LUT de razão |dy|/|dx|, sem atan),

calcula sbin (com invLen aproximado),

alpha = covLut[θbin][sbin] (com ajuste de lado),

se patológico → fallback 4×4 naquele pixel.

Blit final.

Esse desenho tende a ser muito rápido em Dart porque:

evita loops internos de 16 amostras,

reduz branch misprediction,

usa Uint8List/Int32List e soma incremental,

a parte “pesada” fica confinada a poucos pixels.