// Ported from liquid_glass_renderer 1.0.0-dev.2 (FakeGlass, its color matrices and
// roundedSuperellipseParameters), Copyright 2025 Tim Lehmann for whynotmake.it,
// licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
// Changed: only the standalone FakeGlass path with the iOS 27 regular preset, its
// resolved numbers written in as constants; no settings, color model or blend groups.
// The superellipse construction is adapted from Flutter's
// impeller/geometry/round_superellipse_param.cc, Copyright 2013 The Flutter Authors,
// BSD-style license.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A frosted glass panel, the look of iOS glass without refraction: blurs and
/// recolors what is behind it, draws a face with a thin dark border, a soft inner
/// shadow and a light glint along the edge, then [child] on top.
///
/// Speed:
/// - One backdrop pass (blur, then a color matrix) per panel. Panels under one
///   [BackdropGroup] share the background read, so wrap a screen or bar that holds
///   several panels in one.
/// - The face is one small shader, drawn twice (face, then the glint added as light)
///   plus once for the border ring outside the edge. Until the shader has loaded,
///   or where it can't load, the panel shows the blur alone.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child, this.borderRadius = 22, this.padding, this.width, this.height});

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  /// The face shader, null until loaded. Loading starts on first use.
  static final _program = ValueNotifier<ui.FragmentProgram?>(null);
  static Future<void>? _loading;

  static void _load() {
    _loading ??= ui.FragmentProgram.fromAsset('assets/shaders/glass_surface.frag').then(
      (program) => _program.value = program,
      onError: (Object e) => debugPrint('GlassSurface: shader failed to load, blur only: $e'),
    );
  }

  @override
  Widget build(BuildContext context) {
    _load();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final content = padding == null ? child : Padding(padding: padding!, child: child);
    return SizedBox(
      width: width,
      height: height,
      child: ValueListenableBuilder(
        valueListenable: _program,
        builder: (context, program, content) => _RawGlass(
          radius: borderRadius,
          preset: dark ? _Preset.dark : _Preset.light,
          program: program,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
          backdropKey: BackdropGroup.of(context)?.backdropKey,
          child: content,
        ),
        child: content,
      ),
    );
  }
}

/// The resolved iOS 27 regular preset of liquid_glass_renderer, per theme.
enum _Preset {
  light(
    faceMatrix: [
      1.04790304, -0.40737792, -0.04112512, 0, 107.16818625, //
      -0.12109696, 0.76162208, -0.04112512, 0, 106.76498625, //
      -0.12109696, -0.40737792, 1.12787488, 0, 107.16818625, //
      0, 0, 0, 1, 0,
    ],
    emission: (0.40003765, 0.39845647, 0.40003765),
    contourStrength: .43,
    contourDirectionality: .77,
  ),
  dark(
    faceMatrix: [
      0.90321775, -0.342402, -0.03456575, 0, 44.22421191, //
      -0.10178225, 0.662598, -0.03456575, 0, 44.22421191, //
      -0.10178225, -0.342402, 0.97043425, 0, 44.22421191, //
      0, 0, 0, 1, 0,
    ],
    emission: (0.12549020, 0.12549020, 0.12549020),
    contourStrength: .88,
    contourDirectionality: 1,
  );

  const _Preset({
    required this.faceMatrix,
    required this.emission,
    required this.contourStrength,
    required this.contourDirectionality,
  });

  /// The backdrop's color after the blur: emission + transmittance × lifted
  /// luminance + chroma gain × (color − luminance), as a 4×5 matrix.
  final List<double> faceMatrix;

  /// The face's own light (premultiplied RGB).
  final (double, double, double) emission;
  final double contourStrength;
  final double contourDirectionality;

  // Shared by both themes.
  static const highlight = .6;
  static const highlightWidth = 1.2;
  static const edgeDistanceRange = 20.0;
  static const highlightWrap = .5;
  static const highlightOpposite = 1.0;
  static const contourWidth = .75;
  static const bevelShadowStrength = .036;
  static const bevelShadowDepth = 16.0;
  static const bevelShadowOffset = 6.0;
  static const bevelShadowDirectionality = .5;
  static const glintLuminance = 1.6;
  static const glintFaceGain = 0.0;
  static const glintVibrancy = 2.85;

  /// Blur sigma in logical pixels: grows with the panel, as iOS diffuses large
  /// cards more than controls, and never drops below what the engine resolves.
  static double frostSigma(double devicePixelRatio, double shortSide) {
    const frost = 4.5;
    const minSigma = 2.1;
    const floorDevicePx = 5.8;
    double smooth(double t) {
      final c = t.clamp(0.0, 1.0);
      return c * c * (3 - 2 * c);
    }

    final sizeFrost =
        minSigma +
        2.4 * smooth((shortSide - 63) / 31) +
        1.1 * smooth((shortSide - 94) / 24) +
        2.4 * ((shortSide - 118) / 32).clamp(0.0, 1.0);
    final sized = math.max(minSigma, frost * (sizeFrost / frost).clamp(0.0, 1.78));
    return math.max(sized, floorDevicePx / math.max(devicePixelRatio, 2.0));
  }

  /// How far the border reaches outside the shape.
  static const surfaceOutset = contourWidth + 1;
}

class _RawGlass extends SingleChildRenderObjectWidget {
  const _RawGlass({
    required this.radius,
    required this.preset,
    required this.program,
    required this.devicePixelRatio,
    required this.backdropKey,
    super.child,
  });

  final double radius;
  final _Preset preset;
  final ui.FragmentProgram? program;
  final double devicePixelRatio;
  final BackdropKey? backdropKey;

  @override
  _RenderGlass createRenderObject(BuildContext context) => _RenderGlass()
    ..radius = radius
    ..preset = preset
    ..program = program
    ..devicePixelRatio = devicePixelRatio
    ..backdropKey = backdropKey;

  @override
  void updateRenderObject(BuildContext context, _RenderGlass renderObject) => renderObject
    ..radius = radius
    ..preset = preset
    ..program = program
    ..devicePixelRatio = devicePixelRatio
    ..backdropKey = backdropKey;
}

class _RenderGlass extends RenderProxyBox {
  double _radius = 0;
  double get radius => _radius;
  set radius(double v) => _set(_radius != v, () => _radius = v);

  _Preset _preset = _Preset.light;
  _Preset get preset => _preset;
  set preset(_Preset v) => _set(!identical(_preset, v), () => _preset = v);

  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;
  ui.FragmentProgram? get program => _program;
  set program(ui.FragmentProgram? v) => _set(!identical(_program, v), () {
    _program = v;
    _shader = v?.fragmentShader();
  });

  double _dpr = 1;
  double get devicePixelRatio => _dpr;
  set devicePixelRatio(double v) => _set(_dpr != v, () => _dpr = v);

  BackdropKey? _backdropKey;
  BackdropKey? get backdropKey => _backdropKey;
  set backdropKey(BackdropKey? v) => _set(_backdropKey != v, () => _backdropKey = v);

  void _set(bool changed, VoidCallback apply) {
    if (!changed) return;
    apply();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    final bounds = Offset.zero & size;
    final outline = Path()..addRSuperellipse(ui.RSuperellipse.fromRectAndRadius(bounds, Radius.circular(_radius)));
    final sigma = _Preset.frostSigma(_dpr, size.shortestSide);
    final layer = (this.layer ??= BackdropFilterLayer())
      ..filter = ui.ImageFilter.compose(
        outer: ColorFilter.matrix(_preset.faceMatrix),
        inner: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.mirror),
      )
      ..blendMode = BlendMode.srcATop
      ..backdropKey = _backdropKey;

    context.pushClipPath(true, offset, bounds, outline, (context, offset) {
      context.pushLayer(layer, (context, offset) {
        // Skia must not raster-cache a layer whose backdrop changes.
        if (!ui.ImageFilter.isShaderFilterSupported) context.setWillChangeHint();
        if (_shader case final shader?) {
          final canvas = context.canvas
            ..save()
            ..translate(offset.dx, offset.dy)
            ..clipPath(outline);
          _drawSurface(canvas, shader);
          _drawSurface(canvas, shader, highlightOnly: true);
          canvas.restore();
        }
        super.paint(context, offset);
      }, offset);
    });

    // The dark border lies just outside the silhouette, so it is drawn again
    // there, outside the clip that holds the blur.
    if (_shader case final shader?) {
      final ring = Path.from(outline)
        ..addRect(bounds.inflate(_Preset.surfaceOutset))
        ..fillType = PathFillType.evenOdd;
      final canvas = context.canvas
        ..save()
        ..translate(offset.dx, offset.dy)
        ..clipPath(ring);
      _drawSurface(canvas, shader, exteriorOnly: true);
      canvas.restore();
    }
  }

  void _drawSurface(Canvas canvas, ui.FragmentShader shader, {bool exteriorOnly = false, bool highlightOnly = false}) {
    final p = _preset;
    final floats = <double>[
      size.width, size.height, //
      2, _radius, // shape type: rounded superellipse
      0, 0, 0, 0, // tint: none in this preset
      _Preset.highlight,
      _Preset.highlightWidth,
      _Preset.edgeDistanceRange,
      _Preset.highlightWrap,
      _Preset.highlightOpposite,
      p.contourStrength,
      _Preset.contourWidth,
      0, // contour transmittance
      0, // contour offset
      p.contourDirectionality,
      _Preset.bevelShadowStrength,
      _Preset.bevelShadowDepth,
      _Preset.bevelShadowOffset,
      _Preset.bevelShadowDirectionality,
      0, // bevel shadow size response
      0, 1, // light direction
      1 / math.max(_dpr, .01),
      if (exteriorOnly) 1 else 0,
      _Preset.glintLuminance,
      p.emission.$1, p.emission.$2, p.emission.$3,
      ..._roundedSuperellipseParameters(size, _radius),
      _Preset.glintFaceGain,
      _Preset.glintVibrancy,
      if (highlightOnly) 1 else 0,
    ];
    for (var i = 0; i < floats.length; i++) {
      shader.setFloat(i, floats[i]);
    }
    final paint = Paint()..shader = shader;
    // The glint adds light on top of the face instead of replacing it.
    if (highlightOnly) paint.blendMode = BlendMode.plus;
    canvas.drawRect(
      _pixelAlignedQuad((Offset.zero & size).inflate(highlightOnly ? 0 : _Preset.surfaceOutset), canvas.getTransform()),
      paint,
    );
  }
}

/// Grows [localQuad] to whole device pixels. Impeller on Metal steps the shader's
/// smooth edge when a quad edge lands on a half pixel; the shape is placed by the
/// shader, so a bigger quad changes nothing else. Only axis-aligned transforms.
Rect _pixelAlignedQuad(Rect localQuad, Float64List s) {
  if (s[1] != 0 || s[2] != 0 || s[3] != 0 || s[4] != 0 || s[6] != 0 || s[7] != 0 || s[11] != 0 || s[14] != 0) {
    return localQuad;
  }
  if (s[0] == 0 || s[5] == 0) return localQuad;
  double lo(double a, double b, double scale, double shift) =>
      (math.min(scale * a + shift, scale * b + shift).floor() - shift) / scale;
  double hi(double a, double b, double scale, double shift) =>
      (math.max(scale * a + shift, scale * b + shift).ceil() - shift) / scale;
  return Rect.fromLTRB(
    lo(localQuad.left, localQuad.right, s[0], s[12]),
    lo(localQuad.top, localQuad.bottom, s[5], s[13]),
    hi(localQuad.left, localQuad.right, s[0], s[12]),
    hi(localQuad.top, localQuad.bottom, s[5], s[13]),
  );
}

(double, double) _rseNAndXj(double ratio) {
  const table = <(double, double)>[
    (2.00000000, 1.13276676),
    (2.18349805, 1.20311921),
    (2.33888662, 1.28698796),
    (2.48660575, 1.36351941),
    (2.62226596, 1.44717976),
    (2.75148990, 1.53385819),
    (3.36298265, 1.98288283),
    (4.08649929, 2.23811846),
    (4.85481134, 2.47563463),
    (5.62945551, 2.72948597),
    (6.43023796, 2.98020421),
  ];
  if (ratio > 5.0) {
    final n = 1.559599389 * (ratio - 5.0) + table.last.$1;
    final kXj = 0.522807185 * (ratio - 5.0) + table.last.$2;
    return (n, 1.0 - 1.0 / kXj);
  }
  final clampedRatio = ratio.clamp(2.0, 5.0);
  final steps = clampedRatio < 2.5 ? (clampedRatio - 2.0) * 10.0 : (clampedRatio - 2.5) * 2.0 + 5.0;
  final left = steps.floor().clamp(0, table.length - 2);
  final fraction = steps - left;
  final a = table[left];
  final b = table[left + 1];
  return (a.$1 + (b.$1 - a.$1) * fraction, 1.0 - 1.0 / (a.$2 + (b.$2 - a.$2) * fraction));
}

(double, double, Offset, double) _rseOctant(double axis, double radius) {
  if (radius <= 1e-3) return (0.0, 0.0, Offset.zero, 0.0);
  final (n, xJOverA) = _rseNAndXj(2.0 * axis / radius);
  final xJ = xJOverA * axis;
  final yJ = math.pow(math.max(1.0 - math.pow(xJOverA, n).toDouble(), 0.0), 1.0 / n).toDouble() * axis;
  final tanPhi = math.pow(xJ / math.max(yJ, 1e-6), n - 1.0).toDouble();
  final d = (xJ - tanPhi * yJ) / (1.0 - tanPhi);
  final gap = (1.0 - math.cos(math.pi / 4.0)) * radius;
  final circleRadius = (axis - d - gap) * math.sqrt2;
  final pointJ = Offset(xJ, yJ);
  final pointM = Offset(axis - gap, axis - gap);
  final chord = pointM - pointJ;
  final midpoint = (pointJ + pointM) / 2.0;
  final perpendicular = Offset(-chord.dy, chord.dx);
  final perpendicularLength = perpendicular.distance;
  final halfChord = chord.distance / 2.0;
  final centerDistance = math.sqrt(math.max(circleRadius * circleRadius - halfChord * halfChord, 0.0));
  final circleCenter = perpendicularLength <= 1e-6
      ? midpoint
      : midpoint - perpendicular * (centerDistance / perpendicularLength);
  final fromM = pointM - circleCenter;
  final fromJ = pointJ - circleCenter;
  final span = math.atan2(fromM.dx * fromJ.dy - fromM.dy * fromJ.dx, fromM.dx * fromJ.dx + fromM.dy * fromJ.dy).abs();
  return (n, span, circleCenter, circleRadius);
}

/// Flutter's rounded superellipse as the shader's three vec4s: octant degrees and
/// arc spans, circle centers, then semi-axes and circle radii.
List<double> _roundedSuperellipseParameters(Size size, double cornerRadius) {
  final halfWidth = size.width / 2.0;
  final halfHeight = size.height / 2.0;
  final radius = math.min(cornerRadius, math.min(halfWidth, halfHeight));
  final (topN, topSpan, topCenter, topRadius) = _rseOctant(halfWidth, radius);
  final (rightN, rightSpan, rightCenter, rightRadius) = _rseOctant(halfHeight, radius);
  return [
    topN, rightN, topSpan, rightSpan, //
    topCenter.dx, topCenter.dy, rightCenter.dx, rightCenter.dy, //
    halfWidth, halfHeight, topRadius, rightRadius,
  ];
}
