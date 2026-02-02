Como o Blend2D consegue ser tão rápido no CPU

(um “raio-X” técnico da arquitetura: JIT de pipelines + rasterização analítica otimizada + paralelismo por bandas)

Este artigo descreve as técnicas centrais que explicam a performance do Blend2D em renderização 2D vetorial no CPU: geração JIT de “pipelines” de pixel, rasterização analítica com estruturas densas, e multi-thread assíncrono distribuído por bands (conjuntos de scanlines). A base principal aqui é a documentação oficial e a apresentação de Petr Kobalíček.

1) A intuição certa: “2D vetorial rápido” = otimizar o miolo de pixels

Em praticamente todo renderer 2D no CPU, o custo dominante costuma cair em:

cobertura/AA (quanto cada pixel deve ser afetado),

busca de estilo (cor sólida / gradiente / padrão),

composição (misturar src no dst com o operador atual, premultiplicação, etc.).

O Blend2D trata isso como o núcleo: em vez de um pipeline “genérico” cheio de branches, ele tenta executar um kernel altamente especializado para aquele caso (formato do pixel, operador, estilo, máscara/cobertura…), usando JIT e estruturas de dados desenhadas para cache.

2) Técnica #1 (principal): geração JIT de pipelines de pixel
2.1 O que é “pipeline” no Blend2D

Um “pipeline” aqui é essencialmente um loop que pega cobertura + estilo + destino e grava o resultado. A apresentação descreve explicitamente que o pipeline JIT faz inline de 3 estágios:

Coverage stage

Style Fetch stage

Composition stage

…e destaca que os dados fluem entre estágios via registradores da CPU (evitando intermediários em memória).

2.2 Por que isso ganha tanto

Em pipelines tradicionais (estáticos), é comum ter estruturas intermediárias (listas de spans, buffers de spans, etc.). O material contrasta o caminho “estático” com o “JIT” e sugere que o JIT reduz/evita parte dessa colagem, mantendo mais coisa em registradores.

Na prática, isso costuma reduzir:

branches por pixel,

chamadas indiretas/virtual,

loads/stores intermediários,

custo de “colar” etapas.

2.3 JIT com custo baixo (e cache forte)

O Blend2D usa AsmJit para gerar código e afirma números bem agressivos de throughput de geração (ordem de 100+ MB/s e até 200+ MB/s em hardware recente), com pipelines tipicamente pequenos (centenas de bytes a poucos KB) e cacheados para nunca serem gerados duas vezes. O texto também diz que o tempo de criação de pipeline tende a ser fração de milissegundo.

No README do projeto no GitHub, também fica claro que a dependência externa relevante é justamente o AsmJit (quando JIT está habilitado).

2.4 Especialização por CPU (SSE2/AVX2/AVX-512, BMI…)

A apresentação menciona explicitamente que o pipeline pode escolher extensões (ex.: BMI/BMI2) e níveis SIMD (SSE2+, AVX2+FMA, AVX-512+). Isso é um dos motivos do Blend2D “envelhecer bem”: o mesmo desenho escala conforme o host tem mais ISA disponível.

2.5 “Bands”: várias scanlines por chamada

O material aponta que o processamento por bands permite “múltiplas scanlines por chamada” no pipeline JIT. Isso tende a melhorar:

amortização de overhead,

localidade de cache,

layout de trabalho para multi-thread (ver seção 4).

3) Técnica #2: rasterização analítica com estruturas densas (cache-friendly)
3.1 O “modelo” analítico (area/cover)

A apresentação descreve o básico da rasterização analítica: iterar arestas, acumular area e cover por pixel (células), e calcular a cobertura final a partir desses acumulados.

O site oficial também afirma que o Blend2D usa AA de 8 bits (256 níveis) por padrão e que o algoritmo é da mesma família do usado por FreeType e AGG, mas otimizado para performance.

3.2 Onde entra a otimização: “dense cell-buffer”

A parte interessante é quando o Blend2D foge do padrão “lista encadeada/vetor esparso de células” e usa:

buffer denso de células: “cada pixel tem uma célula pré-alocada”; células consecutivas; e a apresentação afirma redução de armazenamento ao usar “um único valor por célula”, reduzindo em ~50% (no contexto descrito).

shadow bit-buffer: uma máscara para marcar quais células realmente foram tocadas; cada bit cobrindo um grupo de células, permitindo pular rápido os “zeros”. A apresentação cita o uso de contagem de bits (trailing/leading bit count) para achar coordenadas de células não-zero.

Por que isso é grande?
Porque rasterização analítica pode gastar muito tempo “administrando” células (alocação, encadeamento, ordenação, merges…). Um buffer denso + bitset transforma várias operações em indexação trivial + varredura rápida só do que mudou.

3.3 Pseudocódigo (ideia)
para cada band:
  zerar cellBuffer[bandWidth * bandHeight]
  zerar bitsetTouched


  para cada edge que cruza a band:
    para cada interseção com scanline:
      atualizar area/cover na célula (x,y)
      marcar bitsetTouched[x,y] = 1


  para cada bloco de bits marcado no bitsetTouched:
    para cada célula não-zero do bloco:
      acumular cover/area e produzir cobertura final
      alimentar o pipeline (style fetch + composition)

A graça é que o “para cada célula” vira “para cada célula marcada”.

4) Técnica #3: multi-thread assíncrono por bandas + filas de comando/job
4.1 Assíncrono de verdade: comandos são enfileirados

A doc oficial de multi-thread enfatiza que, no modo multi-thread, o contexto não muda o destino imediatamente: ele serializa operações em batches e workers executam depois. Isso muda expectativas (ex.: fill_rect() não “aparece” até sincronizar).

O próprio “About” descreve o mesmo conceito: render calls vão para uma fila e os workers executam, pegando uma band por vez.

4.2 Cada worker “possui” uma band (zero sincronização de pixels)

O “About” também explica o benefício: quando um worker adquire uma band, ele processa comandos dentro dela e nenhum outro thread mexe naqueles pixels, reduzindo necessidade de sincronização e aproveitando cache (band fica “quente” enquanto executa vários comandos que a intersectam).

4.3 Separação “render command” vs “compute job”

A apresentação detalha o modelo: existem dois tipos de trabalho por thread:

render command (mexe em pixels e invoca pipelines)

compute job (trabalho prévio: construir edges, stroking, extração de contorno de fonte etc.)
E também descreve a serialização: o frontend precisa “capturar estado”, enfileirar jobs e depois enfileirar comandos.

Uma tese acadêmica recente também comenta que há paralelismo em etapas como stroking/flattening antes do raster.

4.4 Como configurar e sincronizar (pontos práticos)

thread_count = 0 → síncrono (efeito imediato)

thread_count = 1 → assíncrono, mas usando o próprio thread do usuário como worker

thread_count > 1 → assíncrono com pool (adiciona workers)

E a doc reforça que flush(sync) / end() fazem a sincronização (no modo assíncrono eles bloqueiam até concluir).

5) Técnica #4: “performance de engenharia” (API, dependências, foco em integração)

Na apresentação, o Blend2D é descrito como:

escrito em C++, mas exportando C API (bom para bindings),

sem exceções e sem depender da STL (no núcleo),

com dependência opcional do AsmJit.

Isso importa para performance porque facilita:

controle fino de alocação,

pools/memórias “zeroed” e reuso,

previsibilidade de layout,

e integração em ambientes com regras duras de build.

6) Um detalhe que parece pequeno, mas é vital: cache global de pipelines

A doc do contexto alerta que um modo “isolated JIT runtime” não usa o cache global de pipelines e é recomendado apenas para teste/benchmark isolado (porque as pipelines morrem com o runtime). Isso deixa claro o quanto o reuso/caching de pipeline é parte do desenho.

7) O que copiar dessa arquitetura em outro projeto (ex.: Dart puro, sem JIT nativo)

Mesmo sem gerar assembly em runtime, dá para herdar o “espírito”:

Especialização por caso quente

Em vez de 1 compositor genérico, tenha N kernels (ex.: prgb32 + srcOver + solid, prgb32 + srcOver + linearGradient, etc.).

Cacheie o “dispatch” para não decidir isso por pixel.

Pipeline “fundido”

Tente fazer coverage→style→compose no mesmo loop, com variáveis locais (simulando “registradores”).

Processamento em bands/tiles

Trabalhe em blocos (ex.: 16–32 scanlines por vez), para o destino caber melhor em cache e para paralelismo ficar simples (cada worker pega uma band).

Raster denso + bitset de touched cells

Mesmo em linguagem gerenciada, um Uint32List/Int32List + bitset pode ser muito mais rápido do que mapas/estruturas esparsas.

Fila de “compute jobs”

Flattening, stroking, decomposição de curvas → separar e paralelizar antes do blend final.

8) Como o Blend2D mede performance (e como você pode imitar)

A página de performance descreve que os gráficos vêm do bl_bench, repetindo chamadas de render com tamanhos variados e operadores/estilos diferentes. É um bom modelo de benchmark porque força o pipeline a mostrar custo por pixel vs overhead por chamada.

Referências principais (para você checar e citar no seu próprio texto)

Site oficial (visão geral, AA 8-bit, portabilidade, JIT, multi-thread).

“About” (custo do JIT, cache de pipelines, bands e cache no multi-thread).

Documentação de multi-thread (assíncrono, flush/end, lifetime).

Apresentação Helsinki 2023 (3 estágios do pipeline, registradores, bands, dense cell-buffer, shadow bit-buffer, filas).

README no GitHub (dependência do AsmJit quando JIT está habilitado).

Tese (análise/descrição acadêmica de paralelismo e organização do trabalho).

SIMD no Dart (Float32x4/Int32x4) – como a VM realmente ganha performance
O que é “SIMD no Dart” na prática

O suporte de SIMD exposto pelo Dart acontece principalmente via os tipos de dart:typed_data Float32x4, Int32x4 (e listas “packed” como Float32x4List/Int32x4List). O modelo é de valores 128-bit em lanes (x, y, z, w) e as instâncias são imutáveis; cada operação produz uma nova instância. 

2568058.2568066

O “pulo do gato” é que, embora o modelo de alto nível pareça custoso (métodos, objetos, novas instâncias), a VM (JIT/AOT) pode compilar isso para instruções SIMD reais (SSE/NEON) e, em código otimizado, eliminar a sobrecarga: temporários ficam em registradores, chamadas viram instruções únicas e o custo de alocação pode desaparecer. 

2568058.2568066

Por que Float32x4List é importante (cache + layout)

Para throughput, a recomendação “de verdade” é estruturar seus dados como arrays contíguos de payload 128-bit (ex.: Float32x4List) em vez de List<Float32x4>. Essas listas armazenam o payload 128-bit contiguamente, o que melhora cache e reduz indireções; o acesso “carrega”/“armazena” vetores 128-bit por índice. 

2568058.2568066

Operações: máscaras e seleção sem branch

Comparações em SIMD não geram um boolean único: geram uma máscara por lane (0xFFFFFFFF/0x0), usada para seleção “branchless” (ex.: mask.select(a,b)). 

2568058.2568066

Ganhos reais: quando esperar speedup

Benchmarks clássicos mostram que, dependendo do algoritmo, o speedup pode ser bem significativo (com casos acima de 4× em cenários específicos). 

2568058.2568066


Um detalhe crucial: em alguns testes os ganhos passam de 4× porque o scalar pode acabar promovendo para double, enquanto o SIMD opera em float32 e evita conversões. 

2568058.2568066

“Pegadinhas” de performance: JIT vs AOT e custo de acessar lanes
Acessar .x/.y/.z/.w é caro

Um dos pontos mais importantes (e mais ignorados): operações “horizontais”/acesso individual a lanes tendem a ser lentas — e a orientação é evitar ao máximo e “pagar” esse custo só uma vez no final (ex.: reduzir 4 lanes para 1 escalar fora do loop).

Dados “uniformes” funcionam melhor

SIMD funciona melhor quando cada vetor guarda dados “uniformes” por operação (ex.: alpha de 4 pixels, ou um mesmo canal em 4 pixels), porque uma instrução altera todas as lanes de forma útil.

Diferenças grandes entre JIT e AOT podem aparecer

Na prática, há casos em que o JIT consegue otimizar muito melhor que o AOT (e vice-versa), especialmente quando o padrão de acesso vira “acesso de lane” + criação de temporários em hot loop. Um relato recente (Issue #61087 no repositório do SDK) mostra exatamente esse tipo de discrepância: certos microbenchmarks ficam muito mais lentos em AOT ou têm resultados “estranhos” dependendo da forma de ler lanes/estruturar o loop.

Implicação para código de renderização/PNG/PDF (seu caso):

foque em loops longos com Float32x4List/Int32x4List;

evite ler .x/.y/.z/.w dentro do loop;

prefira padrões “vertical SIMD” (operação lane-a-lane) e só “reduza” para escalar no fim.

Isolates: “compartilhamento” eficiente de memória (sem cópia)
O que mudou/ficou mais importante nas docs recentes

O Dart continua com a regra: isolates não compartilham heap; a comunicação é por mensagens. Só que, para performance, a documentação destaca um ponto vital: em Isolate.run(), ao retornar resultados, o isolate worker pode transferir a memória do resultado para o isolate principal sem copiar, desde que o objeto seja transferível (há uma checagem para garantir isso).

Isso é o que, na prática, vira “compartilhamento eficiente”: não é memória compartilhada simultaneamente, mas transferência de ownership (zero-copy / no-copy) quando possível, reduzindo custo de serialização/cópia em pipelines de dados grandes (ex.: buffers de imagem).

O “canivete suíço” para buffers grandes: TransferableTypedData

Para blobs grandes (PNG scanlines, tiles, buffers RGBA, máscaras etc.), use TransferableTypedData: ele permite transferir Uint8List/buffers entre isolates com custo muito menor do que mandar listas comuns (que podem ser copiadas).

Exemplo (padrão recomendado para renderização/encoder em isolate)
import 'dart:isolate';
import 'dart:typed_data';


Future<TransferableTypedData> renderInWorker(int w, int h) async {
  return Isolate.run(() {
    final bytes = Uint8List(w * h * 4); // RGBA
    // ...renderiza preenchendo bytes...
    return TransferableTypedData.fromList([bytes]);
  });
}


Future<Uint8List> mainUse() async {
  final t = await renderInWorker(1920, 1080);
  return t.materialize().asUint8List(); // materializa no isolate principal
}

Por que isso importa no seu artigo: para workloads “server/desktop Dart puro” (sem Flutter), o melhor desenho costuma ser:

isolate principal: coordena I/O, filas, chunking, escrita em disco;

isolate(s) worker: rasterização/filtragem/compactação;

dados grandes: TransferableTypedData (evitar cópia).

Checklist prático para o artigo (resumo executivo)

SIMD: use Float32x4List/Int32x4List e loops longos; a VM pode eliminar abstrações e mapear para instruções reais. 

2568058.2568066

Evite .x/.y/.z/.w em hot loop; reduza para escalar só no final.

JIT vs AOT: valide em AOT (se você distribui binário) porque micro-padrões podem inverter o resultado; há relatos recentes com discrepâncias fortes.

Isolates: pre

2568058.2568066

 worker for “curto”, e explore o fato de que o resultado pode ser transferido sem cópia.

Buffers grandes: passe dados como TransferableTypedData para reduzir overhead de cópia/serialização.