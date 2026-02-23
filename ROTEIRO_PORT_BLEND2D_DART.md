# Roteiro Detalhado: Port do Blend2D para Dart (extremamente otimizado)

Projeto alvo:
- Referência C++: `referencias/blend2d-master/blend2d`
- Port Dart: `lib/src/blend2d`

Objetivo:
- Portar a arquitetura do Blend2D de forma incremental, com foco em:
  - Qualidade visual correta (AA, furos, composições)
  - Throughput alto em CPU
  - Renderização de texto em puro Dart (OpenType + shaping + glyph raster + cache)
  - Design estável para evoluir depois para FFI/shared memory, sem retrabalho estrutural
  - API gráfica completa para futuro renderizador PDF otimizado em puro Dart

## Status de Execução (atualizado)

Concluído agora:
- Bootstrap inicial criado em `lib/src/blend2d/`:
  - `core/`: `bl_types.dart`, `bl_image.dart`
  - `geometry/`: `bl_path.dart`
  - `raster/`: `bl_edge_builder.dart`, `bl_edge_storage.dart`, `bl_analytic_rasterizer.dart` (scanline nativo inicial)
  - `pipeline/`: `bl_compop_kernel.dart`, `bl_fetch_solid.dart`
  - `context/`: `bl_context.dart`
  - `threading/`: `bl_isolate_pool.dart` (API estável, execução local por enquanto)
  - `text/`: `bl_font.dart`, `bl_font_loader.dart`, `bl_glyph_run.dart`, `bl_text_layout.dart`
  - barrel export: `lib/src/blend2d/blend2d.dart`
- Harness de benchmark inicial:
  - `benchmark/blend2d_port_benchmark.dart`
  - cena sintética com furos, linha fina, arco e sobreposição.

Estado por fase:
- Fase 0: parcialmente concluída (harness dedicado já existe, falta diff automatizado/heatmap).
- Fase 1: parcialmente concluída (API mínima funcional para fill de polígonos/paths).
- Fase 2: iniciada (scanline nativo com AET, suporte a `evenOdd/nonZero` e contornos múltiplos).
- Fase 3: iniciada (composição `srcCopy/srcOver` no raster nativo).
- Fase 4-7: não iniciadas no port nativo avançado (gradientes/pattern, stroker robusto, paralelismo real e otimizações agressivas ainda pendentes).
- Fase 8-11 (texto): bootstrap avançando (loader + parser OpenType base de `head/maxp/hhea/hmtx/cmap/name/OS/2/kern` + layout simples + decoder inicial de outlines `glyf` simples/compostos + cache de outline por tamanho). Shaping avançado (GSUB/GPOS), `cff/cff2` e raster dedicado de glifos ainda pendentes.

Atualização incremental (port C++ -> Dart):
- `raster/bl_analytic_rasterizer.dart` não depende mais do backend legado.
- Regras de varredura estabilizadas com:
  - intervalo ativo em `y + 0.5` (semântica top/bottom mais robusta),
  - agrupamento por `x` coincidente para aplicar winding/toggle sem artefatos de vértice.
- Estrutura `raster/bl_edge_storage.dart` adicionada (SoA + buckets por scanline), inspirada em `edgestorage_p.h`, reduzindo alocações por draw-call.
- Raster migrado para base `A8` fixed-point (inspirado em `Pipeline::A8Info`):
  - constantes/ops em `raster/bl_raster_defs.dart`,
  - interseções e spans calculados em inteiro subpixel (8 bits),
  - avanço incremental por `xLift/xRem/xErr` (estilo `analyticrasterizer_p.h`).
- AA incremental adicionado no raster nativo:
  - subamostragem vertical por scanline (`aaSubsampleY`, default 2),
  - composição por cobertura acumulada da linha,
  - fast-path para runs com cobertura total e `src` opaco.
- Otimização do estágio AA:
  - acumulação de cobertura por `difference buffer + prefix sum` por scanline,
  - remoção do incremento pixel-a-pixel por span em cada subamostra,
  - redução de custo no hot-loop mantendo a mesma saída visual do AA incremental atual.
- Otimizações adicionais de hot-loop (inspiradas em `analyticrasterizer_p.h`):
  - lista de AET migrada para `Int32List + activeCount` (sem `List<int>.add/clear/length` no loop por scanline),
  - ordenação da AET trocada de `List.sort(comparator)` para insertion sort in-place incremental (menor overhead em listas quase ordenadas),
  - passo de erro do edge (`xErr/xRem/dy`) reescrito em forma branch-minimized (mesma matemática, menos jitter de branch).
- Geometria de path evoluída:
  - `BLPath` agora suporta `quadTo()` e `cubicTo()` com flatten adaptativo (De Casteljau),
  - base pronta para aproximação de curvas do pipeline `EdgeSourcePath` do Blend2D.
- OpenType/texto (bootstrap avançado, inspirado em `otcore/otcmap/otmetrics`):
  - parser SFNT de diretório de tabelas (`head`, `maxp`, `hhea`, `hmtx`, `cmap`) em `text/bl_font.dart`,
  - seleção de melhor sub-tabela `cmap` por score de plataforma/encoding (priorizando Windows Unicode, como no Blend2D),
  - mapeamento de caracteres para glifos suportando formatos `0`, `4`, `6`, `10`, `12` e `13`,
  - leitura de métricas horizontais (`numHMetrics`/`hmtx`) e cálculo de advance por glifo,
  - `BLTextLayout.shapeSimple()` passou a usar `glyphId` real (`cmap`) + `advance` real da fonte,
  - fallback para fontes símbolo (`codepoint + 0xF000`) quando o mapeamento direto retorna glifo indefinido.
- OpenType `name` (inspirado em `otname.cpp`):
  - parser da tabela `name` com escolha por score de plataforma/encoding/idioma (Unicode, Windows, Mac Roman),
  - suporte a `nameId` essenciais (`1/2/4/6/16/17/21/22`) com preferência tipográfica (`16/17` sobre `1/2/21/22`),
  - decodificação `UTF16-BE` e `Latin1` com saneamento de terminadores nulos,
  - normalização de `family/subfamily` para evitar subfamily redundante no fim do family.
- OpenType `kern` legacy (inspirado em `otkern`):
  - parser do `kern` (headers Windows/Mac) com seleção de sub-tabelas horizontais `format 0`,
  - extração e composição de pares `(left,right)->value` em unidades da fonte,
  - aplicação de kerning em `BLTextLayout.shapeSimple()` antes do avanço do glifo atual.
- OpenType `OS/2` (inspirado em `otcore.cpp`):
  - leitura de `weightClass`/`widthClass` com clamp e correção do intervalo `1..9 -> 100..900`,
  - suporte ao bit `USE_TYPO_METRICS` (`fsSelection`) para priorizar `sTypoAscender/Descender/LineGap`,
  - leitura de `xHeight/capHeight` quando `version >= 2`.
- TrueType `loca/glyf` (inspirado em `otglyf.cpp`):
  - leitura de `indexToLocFormat` do `head` e mapeamento de ranges de glifos via `loca` 16/32-bit,
  - extração de `glyph bounds` em unidades da fonte (bbox) com conversão de eixo Y para convenção raster top-down,
  - identificação estrutural de glifos compostos (`contourCount < 0`) para próxima etapa de outline decoder.
- TrueType `glyf` outlines (inspirado em `otglyf.cpp`):
  - decoder de glifo simples implementado (`flags`, expansão de `repeat`, deltas X/Y compactados e reconstrução de contornos),
  - conversão de pontos on/off-curve para `BLPath` com emissão de quadráticas implícitas em sequências off-curve,
  - suporte inicial a glifo composto (`compound`) com transformação afim (`scale`, `xy-scale`, `2x2`) e composição hierárquica com limite de profundidade,
  - suporte de tradução por componente para `ARGS_ARE_XY_VALUES` e proteção contra ciclos/recursão inválida em compostos.
- Cache de outlines:
  - cache por glifo em unidades da fonte dentro de `BLFontFace`,
  - cache de outline escalado por tamanho dentro de `BLFont` (reduz custo em texto repetido no mesmo size),
  - APIs adicionadas: `glyphOutlineUnits()`, `glyphOutline()`, `clearGlyphOutlineCache()`.
- Loader de fonte:
  - removido override indevido de `familyName` por nome de arquivo em `BLFontLoader`,
  - parser `name` passa a ser usado como fonte primária de nomenclatura quando `familyName` não é informado explicitamente.
- Raster AA:
  - corrigida a acumulação de cobertura para usar contribuição fracionária horizontal por pixel (A8),
  - ajuste de quantização para spans parciais com contribuição mínima de subpixel (reduzindo “gaps” em linha fina),
  - removido erro de análise em `bl_analytic_rasterizer.dart` (`return_without_value`) no caminho de AA.
- Composição (`pipeline/bl_compop_kernel.dart`):
  - `srcOver` ajustado para considerar corretamente alpha de destino (`dstA`) no caminho geral,
  - fast-path preservado para destino opaco (`dstA=255`) para manter custo baixo no bootstrap atual,
  - resultado final passa a preservar alpha de saída (em vez de fixar `0xFF` incondicionalmente) quando renderizando sobre destinos translúcidos.
- Fetchers/estilos (avanço de Fase 4 no port):
  - adicionada fundação de gradiente linear com tipos `BLGradientStop`/`BLLinearGradient` em `core/bl_types.dart`,
  - novo fetcher `pipeline/bl_fetch_linear_gradient.dart` com LUT de 256 amostras e interpolação de stops,
  - `BLContext` recebeu API `setLinearGradient(...)` e estado de estilo preparado para integração completa no resolve,
  - integração direta do gradiente no hot-path do raster foi testada nesta etapa, porém recuada no bootstrap por regressão de throughput,
  - caminho separado de resolve para fonte por pixel foi implementado em `bl_analytic_rasterizer.dart` (`drawPolygonFetched` + resolve fetched `nonZero/evenOdd`),
  - `BLContext.fillPolygon()` agora despacha gradiente linear para esse caminho separado, preservando o hot-path sólido principal sem branch extra no loop crítico.
- Raster analítico (upgrade de qualidade/robustez no bootstrap):
  - `bl_analytic_rasterizer.dart` migrou de AA simplificado por subamostragem vertical para acumulação analítica `cover/area` por célula com máscara ativa por scanline,
  - resolução de cobertura agora segue o modelo de prefix-sum de células (mesma família de abordagem do pipeline Batch Scalar), incluindo suporte correto a `evenOdd/nonZero`,
  - limpeza de buffers (`covers/areas/activeMask`) acoplada ao resolve para reduzir lixo residual entre draw-calls e eliminar artefatos visuais recorrentes em linhas finas/diagonais,
  - resolve otimizado por spans constantes entre eventos da `activeMask` (prefix-sum preservado), reduzindo trabalho em regiões sem células ativas,
  - fast-path opaco por run no resolve (`srcOver/srcCopy` com `srcA=255`) para escrita direta em spans de cobertura total,
  - rastreamento de min/max X por linha (`rowMinX/rowMaxX`), inspirado no uso de limites em `analyticrasterizer_p.h` (`kOptionRecordMinXMaxX`) para limitar a janela de resolve,
  - separação do resolve em dois hot-paths dedicados (`nonZero` e `evenOdd`) para remover branch de `fillRule` no loop interno, alinhado à estratégia de especialização do pipeline C++ (`fill_analytic` com `fillRule` definido por comando),
  - tentativa de especialização adicional por `compOp` (`srcOver/srcCopy`) foi avaliada e revertida no bootstrap atual por regressão de throughput; caminho estável mantido com branch local de comp-op,
  - tentativa de restringir limpeza da `activeMask` por faixa de words ativas (`minWord/maxWord` por linha), inspirada no padrão de limites do raster C++, foi avaliada e revertida no bootstrap atual por não mostrar ganho consistente no benchmark local.
- Harness do port (`blend2d_port_benchmark.dart`) alinhado ao benchmark principal:
  - cena sintética atualizada para 20 polígonos (paridade com benchmark principal),
  - inclusão da letra `A` (path fiel ao `assets/svg/a.svg`) para detectar regressões de winding/furos/contornos em cenários de texto vetorial,
  - benchmark dedicado de gradiente linear adicionado em `benchmark/blend2d_linear_gradient_benchmark.dart` (8 polígonos com gradientes lineares), com saída isolada em `output/rasterization_benchmark/BLEND2D_PORT_LINEAR_GRADIENT.png`.

Medição recente do benchmark do port (`benchmark/blend2d_port_benchmark.dart`, 512x512, 30 iterações):
- faixa observada no ambiente atual: ~`1.50ms` a `1.77ms` por frame (`~10k` a `12k poly/s`), com variação de execução a execução.
- última execução desta etapa: `1.665ms/frame` (`10809 poly/s`).
- após cobertura fracionária + kern: ~`1.823ms/frame` (`9875 poly/s`) no cenário sintético atual.
- após `name + OS/2` parser + ajuste de quantização AA em linha fina: faixa recente `2.05ms` a `2.14ms/frame` (`~8.4k` a `8.8k poly/s`) no cenário sintético atual.
- após base `loca/glyf` + limpeza do loader: execução recente na faixa `1.97ms` a `2.88ms/frame` (`~6.2k` a `9.1k poly/s`) com variabilidade de ambiente observada.
- após suporte `cmap` format 10 + fallback de símbolo: execução recente em `1.985ms/frame` (`9070 poly/s`).
- após migração do bootstrap para raster analítico `cover/area` com máscara ativa + cena sintética de 20 polígonos: `3.260ms/frame` (`6135 poly/s`) na execução local mais recente.
- após port do resolve por spans + fast-path opaco (inspirado no fluxo de limites/bit-scan do C++): execução recente em `1.938ms/frame` (`10321 poly/s`) e revalidação em `1.944ms/frame` (`10287 poly/s`).
- após separar o resolve por `fillRule` (`nonZero/evenOdd`) no hot-path: execução recente em `1.892ms/frame` (`10573 poly/s`).
- após tentativa de especialização por `compOp` e rollback para caminho estável: medições recentes em `2.021ms/frame` (`9897 poly/s`) e `1.929ms/frame` (`10370 poly/s`) no mesmo cenário sintético.
- após tentativa de limpeza parcial da `activeMask` por words ativas e rollback: medições recentes em `2.009ms/frame` (`9955 poly/s`), `2.015ms/frame` (`9927 poly/s`), `2.014ms/frame` (`9930 poly/s`) e `2.259ms/frame` (`8852 poly/s`), com variabilidade de ambiente elevada.
- após correção de `srcOver` (alpha de destino no caminho geral): medições recentes em `2.051ms/frame` (`9750 poly/s`) e `1.951ms/frame` (`10253 poly/s`) no cenário sintético atual.
- após fatia grande de fundação para gradiente linear + estabilização do hot-path sólido: medições recentes em `1.950ms/frame` (`10257 poly/s`) e `2.203ms/frame` (`9077 poly/s`), mantendo variabilidade de ambiente observada.
- após integração do gradiente linear via caminho separado de resolve (sem tocar o loop sólido principal): medições recentes em `2.314ms/frame` (`8644 poly/s`) e `2.140ms/frame` (`9348 poly/s`) no benchmark sintético atual.
- benchmark dedicado de gradiente linear (`blend2d_linear_gradient_benchmark.dart`, 512x512, 30 iterações, 8 polígonos): `2.473ms/frame` (`3235 poly/s`) na execução local recente.
- revalidação do baseline sólido após criação do benchmark dedicado: `1.976ms/frame` (`10119 poly/s`) em `blend2d_port_benchmark.dart`.

## 1) Princípios de engenharia (não negociáveis)

1. Correção antes de micro-otimização.
2. No hot-path: zero alocação por frame.
3. Dados em SoA (`Int32List`, `Uint32List`, `Float64List`) e loops planos.
4. Pipeline previsível: `build edges -> raster cells -> resolve coverage -> comp op`.
5. Sempre benchmarkar contra baseline interno (Marlin + Blend2D_v2 atual).
6. Toda feature nova entra com teste visual + teste numérico.

## 2) Escopo do “port completo”

Blend2D completo é grande. Para viabilizar em Dart com performance:

Escopo faseado:
1. Núcleo Raster + Composição (equivalente ao coração do Blend2D para shapes 2D).
2. Fetchers essenciais: cor sólida, gradiente linear/radial, pattern simples.
3. Context API equivalente (subset amplo e estável).
4. Stroke/path robustos.
5. Texto completo em puro Dart (fontes, shaping, glyph cache, render).
6. Paralelismo e batch avançado.
7. Recursos secundários (codecs/imagens avançadas) em trilha separada.

## 3) Mapeamento de módulos (C++ -> Dart)

Referência C++:
- `blend2d/core/*`
- `blend2d/geometry/*`
- `blend2d/raster/*`
- `blend2d/pipeline/*`
- `blend2d/opentype/*`
- `blend2d/unicode/*`
- `blend2d/tables/*`
- `blend2d/threading/*`
- `blend2d/pixelops/*`

Estrutura recomendada em Dart:
- `lib/src/blend2d/core/`
  - tipos base (`B2DColor`, `B2DRect`, `B2DMatrix`, enums)
  - runtime/config/capabilities
- `lib/src/blend2d/geometry/`
  - path, flatten, bbox, stroker
- `lib/src/blend2d/raster/`
  - edge builder, cell accumulation, analytic rasterizer, tile scheduler
- `lib/src/blend2d/pipeline/`
  - comp-op kernels, fetchers, span runners
- `lib/src/blend2d/text/`
  - parsing OpenType/TrueType, cmap, glyf/cff (escopo incremental)
  - shaping (GSUB/GPOS subset prioritário), bidi e segmentação
  - glyph cache, atlas/tiles, raster de glyph (gray/lcd opcional)
- `lib/src/blend2d/unicode/`
  - normalização mínima, bidi runs, quebra de linha e script runs
- `lib/src/blend2d/tables/`
  - tabelas compactas para classificar scripts, bidi e lookup rápido
- `lib/src/blend2d/threading/`
  - isolate pool persistente, filas de job, sync
- `lib/src/blend2d/pixelops/`
  - convert, premultiply, swizzle
- `lib/src/blend2d/context/`
  - API de alto nível (`fillPath`, `strokePath`, `setCompOp`, etc.)

## 4) Ordem de implementação (fases executáveis)

## Fase 0 - Baseline e harness (1-2 dias)

Entregáveis:
- Benchmark dedicado: `benchmark/blend2d_port_benchmark.dart`
- Corpus visual fixo:
  - `assets/svg/froggy-simple.svg`
  - `assets/svg/Ghostscript_Tiger.svg`
  - cena sintética com:
    - furos (anel/retângulo vazado/A com buraco)
    - linha fina
    - arcos
    - sobreposição com mesma cor (detectar cancelamentos indevidos)
- Métricas:
  - `ms/frame`
  - `polygons/s`
  - diferença de imagem (pixel mismatch + heatmap)

Critério de saída:
- baseline reproduzível e automatizado.

## Fase 1 - Núcleo de dados e API mínima (3-5 dias)

Entregáveis:
- `B2DImage` (ARGB32), `B2DContext` mínimo
- `drawPolygon(vertices, color, windingRule, contourVertexCounts)`
- fill rules corretas (`EvenOdd`, `NonZero`)
- compatibilidade com `PolygonContract` existente

Critério de saída:
- Sem regressão nos testes de furos/contornos.

## Fase 2 - Raster analítico de células (1-2 semanas)

Entregáveis:
- `EdgeBuilder` com clipping robusto
- buffers `covers` e `areas` por tile
- resolve escalar determinístico (sem branch excessivo)
- correção de casos degenerados:
  - horizontal/vertical extrema
  - micro-segmentos
  - self-overlap simples

Critério de saída:
- Qualidade equivalente ao pipeline Blend2D atual do projeto, sem artefatos de “linha fantasma”.

## Fase 3 - Pipeline de composição (1 semana)

Entregáveis:
- kernels de comp-op em Dart:
  - `SrcCopy`, `SrcOver` (prioridade)
  - preparar infraestrutura para `Multiply`, `Screen`, etc.
- caminho premultiplied consistente
- clamp/saturate sem custo desnecessário

Critério de saída:
- Render final idêntico (ou erro mínimo) nos casos sólidos e alpha.

## Fase 4 - Fetchers e estilos (1-2 semanas)

Entregáveis:
- fetcher sólido (já no caminho principal)
- gradiente linear + radial
- pattern básico (nearest/bilinear inicial)
- cache de estado por draw-call (evitar recomputo)

Critério de saída:
- SVGs com gradientes principais renderizando sem fallback para outros rasterizadores.

## Fase 5 - Stroke/path robusto (1-2 semanas)

Entregáveis:
- stroker (miter/round/bevel, cap butt/round/square)
- flatten adaptativo de curvas
- tratamento robusto de joins e caps em subpixel

Critério de saída:
- linhas finas e contornos equivalentes ao Marlin/AMCAD visualmente.

## Fase 6 - Paralelismo real (1 semana)

Entregáveis:
- isolate pool persistente por tiles sujos
- scheduler por custo estimado de tile (não só altura fixa)
- merge/composite final sem cópias extras

Critério de saída:
- ganho consistente em cenas grandes (`Tiger`) sem degradar cenas pequenas (`Froggy`).

## Fase 7 - Otimização agressiva (contínua)

Checklist:
- remover bounds checks redundantes via organização de loop
- reduzir branches no resolve
- compactar estado quente em arrays contíguos
- pré-cálculo de spans e run-length de cobertura
- “dirty rectangles” por comando
- fast-path opaco para `SrcCopy/SrcOver`

Critério de saída:
- alvo inicial: superar `Marlin` em throughput no benchmark sintético sem perder qualidade visual.

## Fase 8 - Fontes e OpenType em puro Dart (1-2 semanas)

Entregáveis:
- Loader de fonte (`.ttf`, `.otf`, `.ttc`) em memória.
- Parser de tabelas essenciais:
  - `head`, `hhea`, `maxp`, `hmtx`, `cmap`, `name`, `OS/2`
- Parser de outlines:
  - prioridade `glyf` (TrueType)
  - `cff/cff2` em trilha subsequente
- Métricas tipográficas: ascent/descent/lineGap/xHeight/capHeight quando disponível.

Critério de saída:
- carregar fontes reais e mapear código Unicode -> glyph ID corretamente.

## Fase 9 - Shaping e layout de texto (1-2 semanas)

Entregáveis:
- Pipeline de shaping em Dart:
  - segmentação por script/língua
  - bidi por runs
  - aplicação incremental de `GSUB/GPOS` (subset inicial)
- Kerning e advance positioning corretos.
- API mínima:
  - `shapeText(String text, TextStyle style) -> GlyphRun`
  - `measureText(...)`

Critério de saída:
- palavras latinas e casos com ligaduras/kerning renderizando com posicionamento estável.

## Fase 10 - Rasterização de glyphs e cache (1-2 semanas)

Entregáveis:
- Raster de glyph por cobertura (grayscale AA) em puro Dart.
- Cache de glyph por chave:
  - `(fontId, glyphId, size, transformHint, renderMode)`
- Atlas de glyphs (ou cache por tiles) com política de eviction.
- Composição de glyph no mesmo pipeline de spans/composition.

Critério de saída:
- texto com AA consistente sem custo explosivo por frame.

## Fase 11 - API gráfica de texto + ponte para PDF (1 semana)

Entregáveis:
- API de contexto:
  - `setFont(...)`, `fillText(...)`, `strokeText(...)`, `drawGlyphRun(...)`
- Estruturas para PDF futuro:
  - `GlyphRun` serializável
  - mapeamento de fonte/subset ID
  - coleta de glyphs usados por página
- Modo dual:
  - render direto em bitmap
  - exportar comandos de texto para backend PDF futuro

Critério de saída:
- mesma cena pode ser renderizada em bitmap e também gerar dados prontos para writer PDF.

## 5) Estratégia de performance para Dart (específica)

1. Tipos:
- usar `int` em ponto fixo no raster/resolve.
- evitar `double` no hot loop (permitido só em pré-processamento).

2. Memória:
- buffers fixos reciclados.
- nada de `List<dynamic>` no núcleo.
- evitar `sublist` que aloca; usar views ou índices.

3. Branching:
- separar loops por `fillRule` (dois caminhos específicos).
- separar comp-op opaco vs alpha.

4. SIMD:
- tratar SIMD em Dart como opcional e medido, nunca presumido.
- manter fallback escalar como caminho canônico.

5. Isolates:
- pool persistente.
- chunking por tile sujo e custo real.
- minimizar serialização (mensagens pequenas + dados já particionados).

6. Texto:
- cache agressivo de glyph + métricas.
- evitar re-shaping quando texto/style/font não mudam.
- separar pipeline `shape` (CPU pesado, reusável) de `paint` (hot-path por frame).

## 6) Qualidade e validação

Testes obrigatórios por fase:
1. Furos:
- anel, retângulo vazado, letra A com buraco.
2. Sobreposição:
- triângulo sobre quadrado de mesma cor (não pode “abrir furo”).
3. Linha fina:
- diagonal subpixel longa.
4. Curvas:
- arco fino e bezier.
5. SVG real:
- `froggy-simple.svg`
- `Ghostscript_Tiger.svg`
6. Texto:
- Latin básico, acentos, kerning, ligaduras.
- bidi básico (LTR/RTL em mesma linha).
- tamanhos pequenos (8-12px) para detectar perda de hint/legibilidade.

Métrica visual:
- diff vs referência (Marlin/AMCAD) com tolerância definida por caso.

## 7) Roadmap de entregas (marcos)

Marco M1:
- Fase 0 + Fase 1 concluídas.
- API mínima funcional em `lib/src/blend2d`.

Marco M2:
- Fase 2 + Fase 3 concluídas.
- Raster sólido com composições básicas e sem artefatos graves.

Marco M3:
- Fase 4 + Fase 5 concluídas.
- estilos (gradiente/pattern) + stroke robusto.

Marco M4:
- Fase 6 + Fase 8 concluídas.
- paralelismo + fundação OpenType em puro Dart.

Marco M5:
- Fase 9 + Fase 10 concluídas.
- shaping + raster/cache de texto prontos para produção.

Marco M6:
- Fase 11 + otimizações finais.
- ganho real de throughput em cenas grandes.
- API gráfica completa (shape + text) e base pronta para backend PDF.

## 8) Plano de arquivos (bootstrap imediato)

Criar (ou preencher) em `lib/src/blend2d`:
- `context/bl_context.dart`
- `core/bl_types.dart`
- `core/bl_compop.dart`
- `geometry/bl_path.dart`
- `raster/bl_edge_builder.dart`
- `raster/bl_analytic_rasterizer.dart`
- `pipeline/bl_compop_kernel.dart`
- `pipeline/bl_fetch_solid.dart`
- `text/bl_font.dart`
- `text/bl_font_loader.dart`
- `text/bl_opentype_parser.dart`
- `text/bl_shaper.dart`
- `text/bl_glyph_run.dart`
- `text/bl_glyph_cache.dart`
- `text/bl_text_layout.dart`
- `unicode/bl_bidi.dart`
- `unicode/bl_script_runs.dart`
- `tables/bl_unicode_tables.dart`
- `threading/bl_isolate_pool.dart`
- `blend2d.dart` (barrel export interno)

## 9) Riscos e mitigação

Risco: regressão de qualidade em casos degenerados.
- Mitigação: suíte visual focada em degenerados + asserts em debug.

Risco: SIMD em Dart piorar performance.
- Mitigação: feature flag + benchmark A/B obrigatório.

Risco: overhead de isolates anular ganho.
- Mitigação: paralelismo só acima de limiar de custo de tile.

Risco: shaping OpenType incompleto degradar tipografia.
- Mitigação: priorizar subset de features críticas e corpus de regressão tipográfica.

Risco: cache de glyph crescer demais.
- Mitigação: LRU por memória alvo + métricas de hit-rate no benchmark.

Risco: escopo “completo” explodir prazo.
- Mitigação: congelar “core port” primeiro (raster/pipeline/context) e executar texto em fases curtas com metas objetivas.

## 10) Definição de pronto (DoD) por etapa

Uma fase só fecha quando:
1. `dart analyze` sem issues novos.
2. benchmark roda estável (mínimo 3 execuções consistentes).
3. testes visuais sem regressões críticas.
4. documentação de decisões e trade-offs atualizada.

---

Resumo objetivo:
- Primeiro portamos o coração do Blend2D (raster + pipeline + contexto) com qualidade correta.
- Em paralelo, fechamos a trilha de texto em puro Dart (fontes, shaping, raster e cache).
- Depois expandimos recursos avançados e integração com backend PDF.
- Tudo guiado por benchmark e validação visual contínua.
