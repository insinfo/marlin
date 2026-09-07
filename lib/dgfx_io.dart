/// Extensões do motor gráfico que dependem da plataforma nativa.
///
/// Este ponto de entrada é separado de `package:dgfx/dgfx.dart` de propósito:
/// tudo aqui usa `dart:io` ou `dart:isolate`, então importá-lo tira o seu
/// programa da compatibilidade com web e wasm. Se você compila para o
/// navegador, importe apenas `dgfx.dart` e carregue fontes com
/// `BLFontFace.parse(bytes)`, obtendo os bytes por conta própria.
///
/// - [BLFontLoader] lê arquivos de fonte do disco (`dart:io`).
/// - [BLIsolatePool] distribui trabalho de rasterização entre isolates
///   (`dart:isolate`), sem sentido num runtime single-threaded.
library;

export 'dgfx.dart';

export 'src/blend2d/text/bl_font_loader.dart';
export 'src/blend2d/threading/bl_isolate_pool.dart';
