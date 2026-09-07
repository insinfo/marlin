/// Barrel dos rasterizadores experimentais de pesquisa.
///
/// NÃO faz parte do pacote publicado (veja `.pubignore`) e não é alcançável a
/// partir de `package:dgfx/dgfx.dart`. Existe para que o harness de benchmark
/// em `benchmark/` possa comparar as implementações lado a lado.
///
/// O motor de produção é o port do Blend2D em `lib/src/blend2d/`; o que está
/// aqui são estudos de algoritmos de rasterização, cada um documentado em
/// `pesquisa/`.
library;

export 'acdr/acdr_rasterizer.dart';
export 'amcad/amcad_rasterizer.dart' hide kFixedBits, kFixedOne;
export 'blaze_fast/blaze_fast_rasterizer.dart';
export 'blend2d/blend2d_rasterizer.dart';
export 'common/polygon_contract.dart';
export 'daa/daa_rasterizer.dart';
export 'dbsr/dbsr_rasterizer.dart' hide Edge;
export 'ddfi/ddfi_rasterizer.dart';
export 'edge_flag_aa/edge_flag_aa_rasterizer.dart' hide ScanEdge;
export 'epl_aa/epl_aa_rasterizer.dart';
export 'hsgr/hsgr_rasterizer.dart';
export 'lnaf_se/lnaf_se_rasterizer.dart';
export 'msaa_2d/msaa_rasterizer.dart';
export 'qcs/qcs_rasterizer.dart';
export 'rhbd/rhbd_rasterizer.dart';
export 'scdt/scdt_rasterizer.dart';
export 'scp_aed/scp_aed_rasterizer.dart';
export 'skia_scanline/skia_scanline_rasterizer.dart'
    hide
        kFixedBits,
        kFixedOne,
        kFixedHalf,
        kFixedMask,
        kSubpixelBits,
        kSubpixelCount,
        kSubpixelMask;
export 'ssaa/ssaa_rasterizer.dart';
export 'sweep_sdf/sweep_sdf_rasterizer.dart';
export 'tessellation/tessellation_rasterizer.dart';
export 'wavelet_haar/wavelet_haar_rasterizer.dart';
