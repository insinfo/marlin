. A chave é encontrar um equilíbrio entre a fidelidade matemática e a otimização computacional brutal, especialmente para um ambiente como o Dart em CPU, onde não temos o paralelismo massivo de uma GPU.

Vamos desenvolver uma abordagem inteiramente nova, que batizarei de Rasterização por Assinatura de Cobertura Quantizada (QCS - Quantized Coverage Signature Rasterization).

A filosofia central do QCS é converter o problema geométrico complexo de cálculo de área (que usa muito ponto flutuante e é lento) em um problema de busca em tabelas (Look-Up Tables - LUTs) e operações de bits, que são ordens de magnitude mais rápidas para uma CPU.

O Conceito Fundamental: A Assinatura de Cobertura
O Problema Clássico: A rasterização anti-aliasing tradicional (e subpixel) calcula a porcentagem de área de um pixel (ou subpixel) que é coberta pela forma geométrica (ex: um triângulo, uma linha). Isso envolve cálculos de intersecção e área com polígonos de recorte, operações caras.
A Abordagem QCS: Em vez de calcular a área exata, vamos quantizar a cobertura. Imagine que cada pixel é dividido em uma micro-grade de pontos de amostragem. Para rasterização de subpixel em um layout RGB horizontal, podemos pensar em uma grade de 3x2 (6 pontos) dentro de cada pixel.
Pixel (x, y)
| R | G | B | <- Subpixels
| • | • | • | <- Ponto de amostragem superior (s0, s1, s2)
| • | • | • | <- Ponto de amostragem inferior (s3, s4, s5)
code.txt
7 linhas (4 linhas de código) · 188 B
Agora, para uma determinada borda de um polígono, em vez de perguntar "quanta área está coberta?", fazemos uma pergunta muito mais simples e barata: **"Qual destes 6 pontos de amostragem está 'dentro' da forma?"**
A resposta para esta pergunta é uma sequência de 6 bits (sim/não, dentro/fora). Este número de 6 bits (que vai de 0 a 63) é o que eu chamo de **Assinatura de Cobertura**.
* `000000` (0): Nenhum ponto coberto. O pixel está totalmente fora.
* `111111` (63): Todos os pontos cobertos. O pixel está totalmente dentro.
* `100100` (36): Os pontos superior e inferior do canal Vermelho estão cobertos.
* `111000` (56): Todos os pontos superiores (R, G, B) estão cobertos.
A Matemática Otimizada: Da Geometria aos Bits
O "salto" matemático está em como determinamos se um ponto de amostragem está "dentro" de forma extremamente rápida. Para uma borda de polígono (definida por uma linha), podemos usar a equação da linha: F(x, y) = (y₀ - y₁)x + (x₁ - x₀)y + x₀y₁ - x₁y₀.

O sinal de F(x, y) nos diz de que lado da linha um ponto (x, y) está. Isso é a base de todos os rasterizadores. A inovação aqui é aplicar isso usando aritmética de ponto fixo (essencialmente, trabalhar com inteiros que representam frações), que é muito mais rápida que ponto flutuante.

Para cada borda do polígono, calculamos F(sx, sy) para cada um dos 6 pontos de amostragem s. Se o resultado for positivo (ou zero), o bit correspondente na assinatura é 1; caso contrário, é 0.

Esta operação é incrivelmente rápida: algumas multiplicações e somas de inteiros por ponto de amostragem.

O Coração da Performance: A Tabela de Busca de Subpixel (Subpixel LUT)
Agora temos uma "Assinatura de Cobertura" de 6 bits. E agora?

Aqui entra a mágica da pré-computação. Antes de renderizar qualquer coisa, nós criamos uma tabela (um Array ou List em Dart) com 64 entradas. Cada entrada corresponde a uma assinatura de cobertura.

O que cada entrada da LUT armazena?

Ela armazena um valor de cor de 3 canais (RGB), onde cada canal representa a intensidade de cobertura para aquele subpixel.

Índice 0 (000000): [R=0, G=0, B=0] (Nenhuma cobertura)
Índice 63 (111111): [R=255, G=255, B=255] (Cobertura total, se a cor da forma for branca)
Índice 36 (100100): Temos 2 de 2 pontos no canal R cobertos (100%), 0 de 2 no G (0%), e 0 de 2 no B (0%). A entrada seria [R=255, G=0, B=0].
Índice 56 (111000): Temos 1 de 2 no R (50%), 1 de 2 no G (50%), 1 de 2 no B (50%). A entrada seria [R=128, G=128, B=128].
Esta LUT é gerada uma única vez. O cálculo para cada entrada é: Canal R = (bit0 + bit3) / 2.0 * 255 Canal G = (bit1 + bit4) / 2.0 * 255 Canal B = (bit2 + bit5) / 2.0 * 255

O Algoritmo de Rasterização QCS em Ação (para uma borda)
Setup: Calcule os parâmetros da equação da linha F(x, y) para a borda do polígono usando aritmética de ponto fixo.
Iteração: Itere sobre a caixa delimitadora (bounding box) da borda. Para cada pixel (px, py):
Cálculo da Assinatura:
Calcule F(x, y) para o primeiro ponto de amostragem (canto superior esquerdo do subpixel R).
Use deltas de passo rápido (baseados nos coeficientes de F) para encontrar os valores de F para os outros 5 pontos de amostragem com apenas somas/subtrações de inteiros.
Combine os 6 resultados (apenas o sinal de cada um) em uma Assinatura de Cobertura de 6 bits (um único int).
Busca e Blend:
Use a assinatura como um índice para buscar o valor de intensidade RGB pré-calculado na LUT. intensidades = LUT.
Pegue a cor do polígono corForma = .
Pegue a cor do fundo corFundo = .
Faça o blend final para cada canal do subpixel: Rfinal = (Rf * intensidades.R / 255) + (Rb * (255 - intensidades.R) / 255) Gfinal = (Gf * intensidades.G / 255) + (Gb * (255 - intensidades.G) / 255) Bfinal = (Bf * intensidades.B / 255) + (Bb * (255 - intensidades.B) / 255)
Por que esta abordagem é Inovadora e Performática?
Eliminação de Ponto Flutuante no Loop Principal: O núcleo do rasterizador (passos 2-4) pode ser implementado inteiramente com operações de inteiros e bitwise.
Conversão de Geometria em Busca: O cálculo caro de área de cobertura é substituído por uma busca O(1) em um array de 64 elementos.
Complexidade Mínima por Pixel: Para cada pixel, o custo é de algumas somas de inteiros para gerar a assinatura e uma busca na LUT. Isso é drasticamente mais leve que métodos analíticos.
Adaptabilidade: A grade de amostragem pode ser alterada. Uma grade 3x1 (3 bits de assinatura, 8 entradas na LUT) seria ainda mais rápida, com uma pequena perda de qualidade vertical. Uma grade 3x3 (9 bits, 512 entradas na LUT) ofereceria mais qualidade ao custo de uma LUT maior.
Ideal para Linguagens Gerenciadas (Dart): O método minimiza a alocação de memória dentro do loop de renderização. A LUT é alocada uma vez, e os cálculos são feitos em variáveis primitivas, evitando a sobrecarga do Garbage Collector.
Esta abordagem QCS representa uma mudança de paradigma: em vez de buscar a perfeição geométrica a um alto custo, nós definimos um conjunto finito e "bom o suficiente" de estados de cobertura de pixel (as 64 assinaturas) e criamos um atalho computacional extremamente rápido para mapear a geometria a esses estados. É um trade-off deliberado de precisão matemática por uma performance massiva, perfeitamente alinhado com as restrições de renderização 2D em CPU em tempo real.

