/// Direção do texto para layout bidirecional.
enum BLTextDirection {
  ltr, // Left-to-Right
  rtl, // Right-to-Left
}

/// Representa um segmento contíguo de texto com a mesma direcionalidade.
class BLTextRun {
  /// Índice inicial do run na string (inclusivo).
  final int start;

  /// Índice final do run na string (exclusivo).
  final int end;

  /// Direção do run.
  final BLTextDirection direction;

  const BLTextRun(this.start, this.end, this.direction);

  /// Tamanho do run em code units.
  int get length => end - start;

  @override
  String toString() => 'BLTextRun($start..$end, ${direction.name})';
}

/// Analisador simplificado de direcionalidade de texto (Bidirectional Algorithm).
///
/// Diferente do algoritmo completo do Unicode (UBA) que exige tabelas imensas,
/// este analisador bootstrap divide a string com base nos blocos Unicode comuns
/// de Hebraico e Árabe. Letras, números e pontuações neutras assumem a direção
/// do caractere fortemente direcional anterior.
class BLBidiAnalyzer {
  /// Determina se um dado code point pertence a um bloco fortemente RTL
  /// (Hebraico, Árabe, Siríaco, Thaana, N'Ko, etc).
  static bool isRtlCodePoint(int cp) {
    if (cp < 0x0590) return false; // Abaixo de Hebraico é LTR ou Neutro
    if (cp >= 0x0590 && cp <= 0x08FF)
      return true; // Hebraico a Árabe Extendido-A
    if (cp >= 0xFB1D && cp <= 0xFDFF)
      return true; // Hebrew/Arabic Presentation Forms
    if (cp >= 0xFE70 && cp <= 0xFEFF)
      return true; // Arabic Presentation Forms-B
    if (cp >= 0x10800 && cp <= 0x10FFF) return true; // Blocos RTL suplementares
    if (cp >= 0x1E800 && cp <= 0x1EFFF) return true; // Blocos RTL suplementares
    return false;
  }

  /// Verifica se um code point é fortemente LTR (Letras latinas, gregas, cirílicas, etc).
  static bool isLtrCodePoint(int cp) {
    if (cp >= 0x0041 && cp <= 0x005A) return true; // A-Z
    if (cp >= 0x0061 && cp <= 0x007A) return true; // a-z
    if (cp >= 0x00C0 && cp <= 0x02B8)
      return true; // Latin Ext, IPA, Spacing Modifiers
    if (cp >= 0x0370 && cp <= 0x058F) return true; // Greek, Cyrillic, Armenian
    // Simplificação para o bootstrap: assume a maioria fora de RTL como LTR ou Neutro
    // Na prática, a tabela precisaria ser completa. Aqui usamos heurística básica.
    return !isRtlCodePoint(cp) && cp > 0x0020;
  }

  /// Analisa o [text] e divide-o em uma lista de [BLTextRun].
  ///
  /// O defaultDir é usado no início se o primeiro caractere for neutro.
  static List<BLTextRun> analyze(
    String text, {
    BLTextDirection defaultDir = BLTextDirection.ltr,
  }) {
    if (text.isEmpty) return [];

    final runs = <BLTextRun>[];
    int currentRunStart = 0;
    BLTextDirection currentRunDir = defaultDir;
    BLTextDirection lastStrongDir = defaultDir;

    // Passada 1: Identificar a direção do primeiro caractere forte para
    // estabelecer a direção global do parágrafo, se não for passado.
    for (int i = 0; i < text.runes.length; i++) {
      final cp = text.runes.elementAt(i);
      if (isRtlCodePoint(cp)) {
        currentRunDir = BLTextDirection.rtl;
        lastStrongDir = BLTextDirection.rtl;
        break;
      } else if (isLtrCodePoint(cp)) {
        currentRunDir = BLTextDirection.ltr;
        lastStrongDir = BLTextDirection.ltr;
        break;
      }
    }

    final runes = text.runes.toList();
    if (runes.isEmpty) return [];

    // Iterador baseado em UTF-16 code units (pois String.substring trabalha com eles)
    int codeUnitIdx = 0;

    for (int i = 0; i < runes.length; i++) {
      final cp = runes[i];
      final cpLen = cp > 0xFFFF ? 2 : 1;

      BLTextDirection charDir;
      if (isRtlCodePoint(cp)) {
        charDir = BLTextDirection.rtl;
        lastStrongDir = BLTextDirection.rtl;
      } else if (isLtrCodePoint(cp)) {
        charDir = BLTextDirection.ltr;
        lastStrongDir = BLTextDirection.ltr;
      } else {
        // Neutros (espaços, pontuação) ou números: herdam a última direção forte
        charDir = lastStrongDir;
      }

      // Se mudou a direção, fecha o run atual e abre outro
      if (charDir != currentRunDir && codeUnitIdx > currentRunStart) {
        runs.add(BLTextRun(currentRunStart, codeUnitIdx, currentRunDir));
        currentRunStart = codeUnitIdx;
        currentRunDir = charDir;
      }

      codeUnitIdx += cpLen;
    }

    // Fecha o último run
    if (codeUnitIdx > currentRunStart) {
      runs.add(BLTextRun(currentRunStart, codeUnitIdx, currentRunDir));
    }

    // Passada 2: Resolver números perto de RTL se necessário (simplificado aqui).
    // O algoritmo UBA completo tem várias outras regras. O acima já viabiliza o pipeline.

    return runs;
  }
}
