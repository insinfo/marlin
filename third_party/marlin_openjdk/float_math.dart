/*
 * Copyright (c) 2007, 2015, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

/*
 * MODIFICADO: este arquivo e uma traducao para Dart do Marlin renderer do
 * OpenJDK (org.marlin.pisces / sun.java2d.marlin), feita por Isaque Neves em
 * 2026. A traducao e uma obra derivada e permanece sob a GNU General Public
 * License versao 2 com a Classpath Exception, exatamente como o original.
 *
 * Este diretorio NAO faz parte do pacote `dgfx` publicado no pub.dev, que e
 * licenciado sob MIT. Veja `third_party/marlin_openjdk/README.md`.
 */

import 'dart:math' as math;

/// Fast math operations for renderer
class FloatMath {
  FloatMath._();

  /// Fast ceiling as int
  static int ceilInt(double a) {
    final int intpart = a.toInt();
    if (a <= intpart || a.isNaN || a.isInfinite) {
      return intpart;
    }
    return intpart + 1;
  }

  /// Fast floor as int
  static int floorInt(double a) {
    final int intpart = a.toInt();
    if (a >= intpart || a.isNaN || a.isInfinite) {
      return intpart;
    }
    return intpart - 1;
  }

  /// Fast ceiling as double
  static double ceilF(double a) {
    final double result = a.ceilToDouble();
    return result;
  }

  /// Fast floor as double
  static double floorF(double a) {
    return a.floorToDouble();
  }

  /// Power of two
  static double powerOfTwoD(int n) {
    return math.pow(2, n).toDouble();
  }

  /// Absolute value
  static double abs(double a) => a.abs();

  /// Maximum of two values
  static double max(double a, double b) => a > b ? a : b;

  /// Minimum of two values
  static double min(double a, double b) => a < b ? a : b;

  /// Maximum of two ints
  static int maxInt(int a, int b) => a > b ? a : b;

  /// Minimum of two ints
  static int minInt(int a, int b) => a < b ? a : b;

  /// Square root
  static double sqrt(double a) => math.sqrt(a);
}
