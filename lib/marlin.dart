/// Marlin Rasterization Library
///
/// A comprehensive collection of rasterization algorithms for Dart,
/// implementing various techniques from research papers.
///
/// ## Methods Included:
///
/// - **ACDR** - Accumulated Coverage Derivative Rasterization
/// - **DAA** - Delta-Analytic Approximation
/// - **DDFI** - Discrete Differential Flux Integration
/// - **DBSR** - Distance-Based Subpixel Rasterization
/// - **EPL_AA** - EdgePlane Lookup Anti-Aliasing
/// - **QCS** - Quantized Coverage Signature
/// - **RHBD** - Rasterização Híbrida em Blocos para Dart
/// - **AMCAD** - Analytic Micro-Cell Adaptive Distance-field
/// - **HSGR** - Hilbert-Space Guided Rasterization
/// - **SWEEP_SDF** - Scanline with Analytical SDF for Subpixel
/// - **SCDT** - Spectral Coverage Decomposition with Ternary Encoding
/// - **SCP_AED** - Stochastic Coverage Propagation with Adaptive Error Diffusion
/// - **BLEND2D** - Blend2D-like rasterizer
/// - **SKIA_SCANLINE** - Skia-like scanline rasterizer
/// - **EDGE_FLAG_AA** - Edge Flag Anti-Aliasing
///
library marlin;

// Core algorithms
export 'src/rasterization_algorithms/acdr/acdr_rasterizer.dart';
export 'src/rasterization_algorithms/daa/daa_rasterizer.dart';
export 'src/rasterization_algorithms/ddfi/ddfi_rasterizer.dart';
export 'src/rasterization_algorithms/dbsr/dbsr_rasterizer.dart' hide Edge;
export 'src/rasterization_algorithms/epl_aa/epl_aa_rasterizer.dart';
export 'src/rasterization_algorithms/qcs/qcs_rasterizer.dart';
export 'src/rasterization_algorithms/rhbd/rhbd_rasterizer.dart';
export 'src/rasterization_algorithms/amcad/amcad_rasterizer.dart' hide kFixedBits, kFixedOne;
export 'src/rasterization_algorithms/hsgr/hsgr_rasterizer.dart';
export 'src/rasterization_algorithms/sweep_sdf/sweep_sdf_rasterizer.dart';
export 'src/rasterization_algorithms/scdt/scdt_rasterizer.dart';
export 'src/rasterization_algorithms/scp_aed/scp_aed_rasterizer.dart';
export 'src/rasterization_algorithms/blend2d/blend2d_rasterizer.dart';
export 'src/rasterization_algorithms/skia_scanline/skia_scanline_rasterizer.dart' hide kFixedBits, kFixedOne, kFixedHalf, kFixedMask, kSubpixelBits, kSubpixelCount, kSubpixelMask;
export 'src/rasterization_algorithms/edge_flag_aa/edge_flag_aa_rasterizer.dart' hide ScanEdge;

// SVG Support
export 'src/svg/svg_parser.dart';

// PNG Output
export 'src/png/png_writer.dart';

// Marlin Renderer (reference implementation)
export 'src/marlin/marlin.dart';
