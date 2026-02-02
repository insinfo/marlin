/// ============================================================================
/// SCP_AED — Stochastic Coverage Propagation with Adaptive Error Diffusion
/// ============================================================================
///
/// Redesenhado para alinhar com o artigo de pesquisa:
///   1. Rasterização por Varredura para preenchimento (Interior/Exterior)
///   2. Difusão Estocástica para Anti-Aliasing Suave
///   3. Difusão de Erro Adaptativa para Quantização
///
library scp_aed;

import 'dart:typed_data';
import 'dart:math' as math;

class SCPAEDRasterizer {
  final int width;
  final int height;

  /// Buffer de pixels (ARGB)
  late final Uint32List _framebuffer;

  /// Campo de potencial φ (onde σ(φ) é a cobertura)
  late final Float64List _phi;
  late final Float64List _phiPrev;
  
  /// Buffer de curvatura (κ)
  late final Float64List _curvature;

  /// Parâmetros do artigo
  static const double alpha = 0.25; // Taxa de difusão
  static const double beta = 0.15;  // Intensidade do ruído estocástico

  SCPAEDRasterizer({required this.width, required this.height}) {
    _framebuffer = Uint32List(width * height);
    _phi = Float64List(width * height);
    _phiPrev = Float64List(width * height);
    _curvature = Float64List(width * height);
  }

  void clear([int backgroundColor = 0xFF000000]) {
    _framebuffer.fillRange(0, _framebuffer.length, backgroundColor);
    _phi.fillRange(0, _phi.length, -10.0); // Inicializa como "fora" (phi negativo)
    _curvature.fillRange(0, _curvature.length, 0.0);
  }

  /// Desenha um polígono seguindo a lógica de propagação estocástica
  void drawPolygon(List<double> vertices, int color) {
    if (vertices.length < 6) return;

    // 1. Fase de Varredura (Scanline) para identificar Interior/Exterior
    _fillInteriorScanline(vertices);

    // 2. Cálculo de Curvatura nas bordas
    _computeCurvature(vertices);

    // 3. Difusão Estocástica Controlada (2 iterações como sugerido)
    for (int iter = 0; iter < 2; iter++) {
      _diffuse();
    }

    // 4. Renderização com Sigmóide e Difusão de Erro
    _render(color);
  }

  /// Preenchimento básico por scanline para inicializar φ
  void _fillInteriorScanline(List<double> vertices) {
    final n = vertices.length ~/ 2;
    final edges = <_Edge>[];
    
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      double x0 = vertices[i * 2];
      double y0 = vertices[i * 2 + 1];
      double x1 = vertices[j * 2];
      double y1 = vertices[j * 2 + 1];
      
      if (y0 == y1) continue;
      if (y0 > y1) {
        final tx = x0; x0 = x1; x1 = tx;
        final ty = y0; y0 = y1; y1 = ty;
      }
      edges.add(_Edge(x0, y0, x1, y1));
    }

    // Para cada scanline
    for (int y = 0; y < height; y++) {
      final scanY = y + 0.5;
      final intersections = <double>[];
      
      for (final edge in edges) {
        if (scanY >= edge.y0 && scanY < edge.y1) {
          final t = (scanY - edge.y0) / (edge.y1 - edge.y0);
          intersections.add(edge.x0 + t * (edge.x1 - edge.x0));
        }
      }
      
      intersections.sort();
      
      for (int i = 0; i + 1 < intersections.length; i += 2) {
        int startX = intersections[i].ceil().clamp(0, width);
        int endX = intersections[i + 1].floor().clamp(0, width);
        
        for (int x = startX; x < endX; x++) {
          _phi[y * width + x] = 10.0; // Interior => phi positivo
        }
        
        // Bordas (zona de transição)
        if (startX > 0) _phi[y * width + startX - 1] = 0.0;
        if (endX < width) _phi[y * width + endX] = 0.0;
      }
    }
  }

  void _computeCurvature(List<double> vertices) {
    // Estimativa simples de curvatura baseada na mudança de ângulo entre arestas
    final n = vertices.length ~/ 2;
    for (int i = 0; i < n; i++) {
        final p0 = i;
        final p1 = (i + 1) % n;
        final p2 = (i + 2) % n;
        
        final dx1 = vertices[p1*2] - vertices[p0*2];
        final dy1 = vertices[p1*2+1] - vertices[p0*2+1];
        final dx2 = vertices[p2*2] - vertices[p1*2];
        final dy2 = vertices[p2*2+1] - vertices[p1*2+1];
        
        final ang1 = math.atan2(dy1, dx1);
        final ang2 = math.atan2(dy2, dx2);
        double diff = (ang2 - ang1).abs();
        if (diff > math.pi) diff = 2 * math.pi - diff;
        
        // Marcar curvatura no pixel do vértice
        final vx = vertices[p1*2].round().clamp(0, width - 1);
        final vy = vertices[p1*2+1].round().clamp(0, height - 1);
        _curvature[vy * width + vx] = diff;
    }
  }

  void _diffuse() {
    _phiPrev.setRange(0, _phi.length, _phi);
    
    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        final idx = y * width + x;
        
        // Laplaciano 3x3
        final lap = _phiPrev[idx - width] + _phiPrev[idx + width] + 
                    _phiPrev[idx - 1] + _phiPrev[idx + 1] - 4.0 * _phiPrev[idx];
        
        // Kappa (curvatura) suavizada
        final kappa = _curvature[idx] + 0.1;
        
        // Ruído estocástico estruturado
        final noise = (_pseudoRandom(x, y) - 0.5) * 2.0;
        
        // Equação de difusão do artigo
        _phi[idx] = _phiPrev[idx] + alpha * lap + beta * (1.0 / kappa) * noise;
      }
    }
  }

  void _render(int color) {
    final r = (color >> 16) & 0xFF;
    final g = (color >> 8) & 0xFF;
    final b = color & 0xFF;

    final errorBuffer = Float64List(width * height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final idx = y * width + x;
        
        // Sigmóide idealizado para cobertura: σ(φ) = 1 / (1 + e^-φ)
        // Adicionamos o erro propagado (Dithering)
        double p = _phi[idx] + errorBuffer[idx];
        double coverage = 1.0 / (1.0 + math.exp(-p));
        
        // Clamp
        if (coverage < 0.05) coverage = 0.0;
        if (coverage > 0.95) coverage = 1.0;
        
        final alpha = (coverage * 255).round().clamp(0, 255);
        
        if (alpha > 0) {
          _blendPixel(idx, r, g, b, alpha);
        }
        
        // Difusão de erro (Adaptive Error Diffusion)
        final error = coverage - (alpha / 255.0);
        final kappa = _curvature[idx] + 0.1;
        _propagateError(x, y, error, kappa, errorBuffer);
      }
    }
  }

  void _propagateError(int x, int y, double err, double kappa, Float64List buffer) {
    if (err.abs() < 0.001) return;
    
    // Pesos adaptativos: concentrar em direções de baixa curvatura
    // Floyd-Steinberg modificado
    final wRight = 7/16;
    final wDownLeft = 3/16;
    final wDown = 5/16;
    final wDownRight = 1/16;
    
    // Se kappa for alto (canto), reduzir difusão para preservar detalhe
    final scale = math.exp(-2.0 * kappa);
    
    if (x + 1 < width) buffer[y * width + x + 1] += err * wRight * scale;
    if (y + 1 < height) {
      if (x > 0) buffer[(y + 1) * width + x - 1] += err * wDownLeft * scale;
      buffer[(y + 1) * width + x] += err * wDown * scale;
      if (x + 1 < width) buffer[(y + 1) * width + x + 1] += err * wDownRight * scale;
    }
  }

  double _pseudoRandom(int x, int y) {
    int n = x * 374761393 + y * 668265263;
    n = (n ^ (n >> 13)) * 1274126177;
    return (n & 0x7FFFFFFF) / 0x7FFFFFFF;
  }

  void _blendPixel(int idx, int r, int g, int b, int a) {
    if (a >= 255) {
      _framebuffer[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
      return;
    }
    final bg = _framebuffer[idx];
    final bgR = (bg >> 16) & 0xFF;
    final bgG = (bg >> 8) & 0xFF;
    final bgB = bg & 0xFF;
    final invA = 255 - a;
    final outR = (r * a + bgR * invA) ~/ 255;
    final outG = (g * a + bgG * invA) ~/ 255;
    final outB = (b * a + bgB * invA) ~/ 255;
    _framebuffer[idx] = 0xFF000000 | (outR << 16) | (outG << 8) | outB;
  }

  Uint32List get buffer => _framebuffer;
}

class _Edge {
  final double x0, y0, x1, y1;
  _Edge(this.x0, this.y0, this.x1, this.y1);
}
