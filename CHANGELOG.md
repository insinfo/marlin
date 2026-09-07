# Changelog

## 1.0.0

Primeira versão publicada, sob o nome `dgfx`. O pacote foi reorganizado a
partir do repositório de pesquisa `marlin`, que era um workspace de
experimentos e não um pacote distribuível.

### Adicionado

- `package:dgfx/dgfx.dart` como ponto de entrada único e compatível com web e
  wasm. Um teste de arquitetura percorre o grafo de imports real a cada build
  para garantir que nada ali alcance `dart:io`, `dart:isolate`, `dart:ffi` ou
  `dart:html` — e um caso-guarda verifica que o próprio detector ainda funciona.
- `package:dgfx/dgfx_io.dart` para os recursos que exigem plataforma nativa
  (`BLFontLoader`, `BLIsolatePool`), separado justamente para que importá-los
  seja uma decisão explícita.
- `BLMatrix2D` com `multiply`, `invert`, `mapPoint`, determinante e os
  construtores `translation`, `scaling` e `rotation`.
- Clipping por caminho arbitrário (`clipToPath`, `clipToRectPath`,
  `resetClip`), recortando por máscara de cobertura em vez de rejeitar por
  bounding box.
- `BLStrokeOptions.minimumWidth`, para o caso em que a largura pedida é zero e
  ainda assim se espera a linha mais fina que o dispositivo desenha.
- Exemplo executável e documentação de API.

### Alterado

- **Licença agora é MIT**, com a atribuição ao Blend2D (zlib) registrada em
  `NOTICE`, incluindo a marcação de versão alterada que a cláusula 2 da zlib
  exige.
- O construtor `BLFontFace` passou a ser privado. Ele recebia trinta campos de
  estado interno já decodificado e nunca foi utilizável de fora;
  `BLFontFace.parse(bytes)` é a única porta de entrada.
- Os rasterizadores experimentais de pesquisa, o parser SVG e o escritor PNG
  continuam no repositório mas ficam fora do pacote publicado. Com isso o
  pacote passou a ter **zero dependências de runtime**.

### Movido

- O port em Dart do Marlin renderer do OpenJDK saiu de `lib/src/marlin/` para
  `third_party/marlin_openjdk/`, com licença própria (GPL versão 2 com
  Classpath Exception), os cabeçalhos de copyright da Oracle restaurados em
  cada arquivo e o aviso de modificação que a GPL exige. Ele não entra no
  pacote publicado e nenhuma linha dele é alcançável a partir de
  `package:dgfx/dgfx.dart` — há um teste de arquitetura que verifica isso.
  Continua servindo como oráculo independente nos testes de conformidade.

### Removido

- As dependências `unicode` e `logging`, que não eram usadas por nenhum
  arquivo. `archive` passou a ser dependência apenas de desenvolvimento.
