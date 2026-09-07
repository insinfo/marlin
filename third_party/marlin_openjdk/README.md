# Marlin renderer (OpenJDK) — port em Dart

**Este diretório NÃO é MIT e NÃO faz parte do pacote `dgfx` publicado.**

    Licença:   GNU General Public License, versão 2, com Classpath Exception
    Copyright: Oracle and/or its affiliates
    Original:  sun.java2d.marlin / org.marlin.pisces (OpenJDK)
    Tradução:  Isaque Neves, 2026

## O que é

Uma tradução para Dart do Marlin renderer, o rasterizador de vetores do
OpenJDK. Traduzir código é criar obra derivada, então este port continua sob a
mesma licença do original — a GPL versão 2 com a Classpath Exception — e não
pode ser redistribuído sob MIT.

## Por que está aqui

O restante do repositório é o pacote [`dgfx`](../../README.md), licenciado sob
MIT. Manter este port em um diretório separado, com sua própria licença e com
os cabeçalhos de copyright originais intactos, é a forma correta de preservar o
trabalho sem contaminar nem deturpar a licença do pacote. É a mesma convenção
que o Chromium e o Android usam em `third_party/`.

Ele serve como **oráculo independente** nos testes: um rasterizador escrito por
outras pessoas, a partir de outra base de código, contra o qual a saída do
`dgfx` pode ser conferida. Um bug que existisse nos dois é muito menos provável
do que um bug em apenas um.

## Regras

1. Nada em `lib/` importa deste diretório. O pacote publicado não contém e não
   alcança nenhuma linha daqui — há um teste de arquitetura que verifica isso.
2. `.pubignore` exclui `third_party/` do arquivo enviado ao pub.dev.
3. Os cabeçalhos de copyright em cada arquivo não devem ser removidos. O
   próprio cabeçalho diz isso, e a GPL exige que arquivos modificados tragam
   aviso da modificação — que está registrado logo abaixo do cabeçalho.
4. Se algum dia este código for usado além de testes, a implicação de licença
   precisa ser reavaliada. A Classpath Exception permite que um módulo
   independente *linke* com este código sem se tornar GPL, que é exatamente o
   caso de um teste; ela não permite relicenciar o código em si.

## Arquivos de licença

- [`LICENSE`](LICENSE) — texto integral da GPL versão 2.
- [`ASSEMBLY_EXCEPTION`](ASSEMBLY_EXCEPTION) — a Classpath Exception.
