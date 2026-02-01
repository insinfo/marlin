Com base em uma análise profunda e multidisciplinar, proponho um algoritmo inovador de rasterização 2D com antialiasing de subpixel, otimizado para CPU em Dart puro. A abordagem combina conceitos de Signed Distance Fields (SDF), pré-computação de funções de cobertura e adaptação do clássico algoritmo de varredura, resultando em alta performance e qualidade aceitável.

Conceito Central: Rasterização por Varredura com SDF Analítico para Subpixel (Sweep-SDF)
Inovações Principais:
Pré-computação de funções de cobertura analíticas para subpixel, baseadas na integral de uma função de suavidade (smoothstep) sobre intervalos de pixel e subpixel.

Uso de distâncias assinadas (SDF) perpendiculares calculadas incrementalmente durante a varredura, evitando cálculos caros por aresta.

Aproximação linear da cobertura dos subpixels a partir do SDF do pixel, reduzindo três cálculos complexos para uma consulta de tabela e multiplicações simples.

Seperação inteligente entre pixels inteiros, bordas e subpixels, minimizando processamento onde não necessário.

Algoritmo Detalhado
1. Pré-computação
Calcule duas tabelas (256 entradas cada) para g(d) e g'(d), onde:

g(d) = cobertura de um subpixel de largura 1/3 centrado na distância d de uma aresta suave.

g'(d) = derivada de g(d).

A função g(d) é a integral de smoothstep(-0.5, 0.5, x) no intervalo [d - 1/6, d + 1/6]. Com smoothstep definido como:

text
s(x) = 0 para x ≤ -0.5
s(x) = 1 para x ≥ 0.5
s(x) = 3*(x+0.5)^2 - 2*(x+0.5)^3 para x ∈ (-0.5, 0.5)
A integral indefinida é S(x) = (x+0.5)^3 - 0.5*(x+0.5)^4.
Então g(d) = S(d+1/6) - S(d-1/6).

As tabelas são pré-computadas para d ∈ [-1.0, 1.0] (cobertura total fora desse intervalo é 0 ou 1).

2. Representação da Cena
Formas são polígonos com arestas orientadas (sentido horário).

Cada aresta armazena:

x_inicial, y_inicial, x_final, y_final.

dx, dy (diferenças).

nx, ny (normal unitária apontando para fora, calculada como (dy, -dx) normalizado).

Inclinação m = dx/dy para varredura.

3. Algoritmo de Varredura por Linha
Para cada linha de varredura y (inteira):

Tabela de Arestas Ativas (AET): Mantenha arestas que cruzam y, com x_int atualizado incrementalmente usando m.

Ordenação: Ordene AET por x_int.

Processamento de Pares: Para cada par de arestas (esquerda, direita) na AET:

Pixels Interiores: Para pixels inteiros entre ceil(x_left) e floor(x_right), defina cobertura de subpixel como 1.0 (vermelho, verde, azul).

Pixel de Borda Esquerda:

Calcule d_pixel = nx_left * (x_pixel - x_left), onde x_pixel é o centro do pixel que contém x_left.

Consulte tabela para g(d_pixel) e g'(d_pixel).

Para cada subpixel k ∈ {vermelho, verde, azul} com deslocamento dx_k (-1/3, 0, +1/3):

d_sub = d_pixel + nx_left * dx_k

cobertura_k = 1.0 - (g(d_pixel) + g'(d_pixel) * (nx_left * dx_k)) (interior à direita da aresta esquerda).

Pixel de Borda Direita:

Calcule d_pixel = nx_right * (x_pixel - x_right).

Consulte tabela para g(d_pixel) e g'(d_pixel).

Para cada subpixel k:

d_sub = d_pixel + nx_right * dx_k

cobertura_k = g(d_pixel) + g'(d_pixel) * (nx_right * dx_k) (interior à esquerda da aresta direita).

Acumulação: Combine coberturas de subpixel (para casos raros onde um pixel contém duas bordas) usando min/max conforme a regra de preenchimento.

4. Otimizações para Dart
Coordenadas Fixas: Use inteiros de 32 bits com 6 bits fracionários (precisão de 1/64) para cálculos de x_int e d_pixel, evitando floats.

Tabelas como Listas: Armazene g_table e dg_table como List<double> pré-computadas.

Cache de Arestas: Pré-processe arestas em uma tabela por linha de varredura (ET) para construção rápida da AET.

Loop Interno sem Alocação: Processe pixels com loops for simples, evitando objetos intermediários.

Layout de Subpixel RGB: Assuma disposição horizontal com fatores pré-computados: dx_r = -1/3, dx_g = 0, dx_b = +1/3.

5. Tratamento de Casos Especiais
Retângulos Alinhados: Atalho direto para pixels inteiros e bordas com cobertura constante por subpixel (ex: borda vertical afeta igualmente todos os subpixels).

Linhas Finas: Trate como polígonos degenerados com duas arestas paralelas próximas.

Overdraw e Transparência: Acumule em um buffer de subpixel (3 canais por pixel) e aplique gamma correction após composição.

Exemplo de Código Dart (Estrutural)
dart
// Pré-computação
final gTable = List<double>.filled(256, 0.0);
final dgTable = List<double>.filled(256, 0.0);
void precomputeTables() {
  for (int i = 0; i < 256; i++) {
    double d = -1.0 + (i / 128.0); // d em [-1, +1]
    gTable[i] = g(d);
    dgTable[i] = dg(d);
  }
}

// Função de cobertura de subpixel (integral de smoothstep)
double g(double d) {
  double S(double x) => pow(x + 0.5, 3) - 0.5 * pow(x + 0.5, 4);
  return S(d + 1/6) - S(d - 1/6);
}

// Derivada de g
double dg(double d) {
  double s(double x) => (x <= -0.5) ? 0 : (x >= 0.5) ? 1 : 3*pow(x+0.5,2) - 2*pow(x+0.5,3);
  return s(d + 1/6) - s(d - 1/6);
}

// Rasterização de uma linha de varredura
void rasterizeScanline(int y, List<ActiveEdge> aet, SubpixelBuffer buffer) {
  aet.sort((a,b) => a.xInt.compareTo(b.xInt));
  for (int i = 0; i < aet.length; i += 2) {
    Edge left = aet[i];
    Edge right = aet[i+1];
    int xStart = ceil(left.xInt);
    int xEnd = floor(right.xInt);
    
    // Pixels inteiramente cobertos
    for (int x = xStart; x < xEnd; x++) {
      buffer.setCoverage(x, y, 1.0, 1.0, 1.0);
    }
    
    // Pixel de borda esquerda
    if (xStart - 1 >= 0) {
      int xPix = xStart - 1;
      double dPixel = left.nx * ((xPix + 0.5) - left.xInt);
      int index = ((dPixel + 1.0) * 128).clamp(0, 255).toInt();
      double g = gTable[index];
      double dg = dgTable[index];
      double covR = 1.0 - (g + dg * (left.nx * -1/3));
      double covG = 1.0 - (g + dg * (left.nx * 0));
      double covB = 1.0 - (g + dg * (left.nx * 1/3));
      buffer.setCoverage(xPix, y, covR, covG, covB);
    }
    
    // Pixel de borda direita (similar, com sinal invertido)
    // ... implementação análoga ...
  }
}
Vantagens
Performance: Aproximação linear reduz cálculos por subpixel; consultas de tabela são O(1).

Qualidade: Base analítica suaviza bordas com antialiasing de subpixel.

Gerenciabilidade: Algoritmo determinístico, sem alocações pesadas, adequado para Dart.

Inovação: Combinação única de varredura, SDF e pré-computação para subpixel.

Esta abordagem é inédita e pode ser estendida para suportar curvas (via SDF aproximado) e composição alpha. O foco em CPU pura em Dart a torna ideal para frameworks multiplataforma como Flutter para renderização customizada.