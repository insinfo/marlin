import 'dart:typed_data';

import 'bl_font.dart';

/// Inclinação solicitada ao resolver uma face.
enum BLFontSlant { normal, italic, oblique }

/// Pedido independente de plataforma para localizar uma fonte.
class BLFontQuery {
  final List<String> families;
  final int weight;
  final BLFontSlant slant;

  const BLFontQuery(
    this.families, {
    this.weight = 400,
    this.slant = BLFontSlant.normal,
  });
}

/// Origem assíncrona de fontes, utilizável também no navegador.
///
/// Uma aplicação web pode implementar esta interface com `fetch`, URLs,
/// Google Fonts ou `FontFace`. O núcleo recebe bytes para não depender de
/// `dart:html`, cuja API não existe em wasm e já foi descontinuada em favor de
/// `package:web`.
abstract interface class BLFontProvider {
  Future<BLFontFace?> resolve(BLFontQuery query);
}

/// Callback conveniente para provedores que baixam ou recuperam bytes.
typedef BLFontBytesProvider = Future<Uint8List?> Function(BLFontQuery query);

/// Adapta qualquer fonte de bytes para [BLFontProvider].
class BLCallbackFontProvider implements BLFontProvider {
  final BLFontBytesProvider loadBytes;

  const BLCallbackFontProvider(this.loadBytes);

  @override
  Future<BLFontFace?> resolve(BLFontQuery query) async {
    final bytes = await loadBytes(query);
    return bytes == null ? null : BLFontFace.parse(bytes);
  }
}

/// Catálogo em memória com seleção determinística de face.
class BLFontCollection implements BLFontProvider {
  final List<BLFontFace> _faces = <BLFontFace>[];
  final List<BLFontProvider> _providers = <BLFontProvider>[];
  final Map<String, List<BLFontFace>> _aliases = <String, List<BLFontFace>>{};

  List<BLFontFace> get faces => List<BLFontFace>.unmodifiable(_faces);

  void addFace(BLFontFace face) => _faces.add(face);

  /// Makes [face] selectable through an additional CSS or application family.
  ///
  /// This is useful for `@font-face { font-family: Alias; src: local(...) }`,
  /// where the face keeps its intrinsic family name but must also answer to the
  /// author-defined one. Several weights/styles may share the same alias.
  void addAlias(String family, BLFontFace face) {
    final normalized = _normalize(family);
    if (normalized.isEmpty) return;
    final faces = _aliases.putIfAbsent(normalized, () => <BLFontFace>[]);
    if (!faces.contains(face)) faces.add(face);
  }

  BLFontFace addBytes(Uint8List bytes, {String? familyName}) {
    final face = BLFontFace.parse(bytes, familyName: familyName);
    addFace(face);
    return face;
  }

  void addProvider(BLFontProvider provider) => _providers.add(provider);

  /// Resolve primeiro pelo catálogo e consulta provedores na ordem registrada.
  /// Uma face obtida externamente fica em cache para os próximos pedidos.
  @override
  Future<BLFontFace?> resolve(BLFontQuery query) async {
    final local = resolveLocal(query);
    if (local != null) return local;
    for (final provider in _providers) {
      final face = await provider.resolve(query);
      if (face != null) {
        addFace(face);
        // A remote source may serve a face whose internal OpenType family is
        // different from the CSS/application family used to locate it. Keep
        // the query names as aliases so the successful lookup is genuinely
        // cached and subsequent resolutions do not fetch the same bytes.
        for (final family in query.families) {
          addAlias(family, face);
        }
        return face;
      }
    }
    return null;
  }

  BLFontFace? resolveLocal(BLFontQuery query) {
    BLFontFace? best;
    var bestScore = 1 << 30;
    for (final face in _faces) {
      var familyRank = _familyRank(face.familyName, query.families);
      for (var i = 0; i < query.families.length; i++) {
        if (_aliases[_normalize(query.families[i])]?.contains(face) ?? false) {
          if (familyRank < 0 || i < familyRank) familyRank = i;
        }
      }
      if (familyRank < 0) continue;
      final faceSlant = _slantOf(face);
      final slantPenalty = faceSlant == query.slant
          ? 0
          : (query.slant == BLFontSlant.normal ||
                  faceSlant == BLFontSlant.normal)
              ? 2000
              : 500;
      final score = familyRank * 10000 +
          slantPenalty +
          (face.weightClass - query.weight).abs();
      if (score < bestScore) {
        best = face;
        bestScore = score;
      }
    }
    return best;
  }

  static int _familyRank(String family, List<String> requested) {
    final normalized = _normalize(family);
    for (var i = 0; i < requested.length; i++) {
      if (_normalize(requested[i]) == normalized) return i;
    }
    return -1;
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), ' ').trim();

  static BLFontSlant _slantOf(BLFontFace face) {
    final name = '${face.subfamilyName} ${face.fullName}'.toLowerCase();
    if (name.contains('oblique')) return BLFontSlant.oblique;
    if (name.contains('italic')) return BLFontSlant.italic;
    return BLFontSlant.normal;
  }
}
