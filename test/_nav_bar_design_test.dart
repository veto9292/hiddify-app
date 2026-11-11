// TEMP design test: round 3 of the floating bottom navigation bar. Not part of the app.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

final _tab = ValueNotifier(0);
final _scroll = ValueNotifier(0.0);

/// Selected tab over time, in seconds.
int _at(double t) => switch (t) {
  < 0.5 => 1,
  < 2.0 => 0,
  < 2.8 => 1,
  < 4.4 => 0,
  _ => 1,
};

const _tabs = [(Icons.power_settings_new_rounded, 'Home'), (Icons.settings_rounded, 'Settings')];
const _dur = Duration(milliseconds: 420);

/// Fake page content that scrolls under the bar, with colors so the blur shows.
class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final colors = [Colors.orange, Colors.teal, Colors.pink, Colors.indigo, Colors.green, Colors.amber];
    return ValueListenableBuilder(
      valueListenable: _tab,
      builder: (context, tab, _) => ValueListenableBuilder(
        valueListenable: _scroll,
        builder: (context, s, _) => ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: double.infinity,
            child: Transform.translate(
              offset: Offset(0, -s),
              child: Column(
                children: [
                  const SizedBox(height: 48),
                  Text(_tabs[tab].$2, style: tt.headlineSmall),
                  const SizedBox(height: 16),
                  for (var i = 0; i < 18; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Container(
                        height: 64,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(backgroundColor: colors[(i + tab * 2) % colors.length], radius: 18),
                            const SizedBox(width: 12),
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tab == 0 ? 'Proxy ${i + 1}' : 'Option ${i + 1}', style: tt.titleSmall),
                                Text('Description line', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Saturation boost, the "glass makes colors pop" part of the effect.
ColorFilter _saturate(double s) {
  const r = .2126, g = .7152, b = .0722;
  final i = 1 - s;
  return ColorFilter.matrix([
    r * i + s, g * i, b * i, 0, 0, //
    r * i, g * i + s, b * i, 0, 0, //
    r * i, g * i, b * i + s, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
}

/// Stronger glass: more blur, less paint, boosted colors, light top edge, soft shadow.
/// Real liquid glass from liquid_glass_renderer, iOS 27 regular material.
Widget _glass(BuildContext context, BorderRadius r, Widget child) => LiquidGlass.withOwnLayer(
  shape: LiquidRoundedSuperellipse(borderRadius: r.topLeft.x),
  settings: LiquidGlassSettings.ios27RegularDark(),
  appearance: LiquidGlassAppearance.ios27Regular(brightness: Brightness.dark),
  shadows: const [BoxShadow(color: Color(0x59000000), offset: Offset(0, 6), blurRadius: 24)],
  child: child,
);

/// Bottom-to-top fade behind the bar.
class _Fade extends StatelessWidget {
  const _Fade();

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      child: Container(
        height: 130,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [bg.withValues(alpha: .8), bg.withValues(alpha: .45), bg.withValues(alpha: 0)],
            stops: const [0, .4, 1],
          ),
        ),
      ),
    );
  }
}

/// How the power icon reacts when Home gets selected. The gear always turns.
enum Anim {
  /// the symbol draws itself: the line drops in, the ring closes around it
  draw,

  /// a button press: pushed down, springs back with a soft glow
  press,

  /// the ring spins one turn and lands with its gap on the line
  spin,

  /// a switch: the line drops into a closed ring and pushes its gap open
  flip,
}

/// The power symbol, drawn so its parts can move apart.
class _PowerPainter extends CustomPainter {
  _PowerPainter({
    required this.color,
    this.line = 1,
    this.lineDy = 0,
    this.ring = 1,
    this.gap = 1,
    this.turn = 0,
  });
  final Color color;

  /// share of the line drawn, from the top
  final double line;

  /// line offset, in px
  final double lineDy;

  /// share of the ring drawn, growing from the bottom up both sides
  final double ring;

  /// how open the top gap is, 0 = closed circle
  final double gap;

  /// ring rotation, in turns
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final c = size.center(Offset.zero);
    const r = 7.6;
    final gapAngle = 0.62 * gap; // half gap, radians
    final half = (math.pi - gapAngle) * ring; // each side, from the bottom
    if (half > 0) {
      final start = math.pi / 2 + turn * 2 * math.pi;
      final rect = Rect.fromCircle(center: c, radius: r);
      canvas.drawArc(rect, start, half, false, p);
      canvas.drawArc(rect, start, -half, false, p);
    }
    if (line > 0) {
      final top = c + Offset(0, -10 + lineDy);
      canvas.drawLine(top, top + Offset(0, 9 * line), p);
    }
  }

  @override
  bool shouldRepaint(_PowerPainter o) => true;
}

class _Icon extends StatefulWidget {
  const _Icon(this.i, this.selected, this.anim);
  final int i;
  final bool selected;
  final Anim anim;

  @override
  State<_Icon> createState() => _IconState();
}

class _IconState extends State<_Icon> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 750), value: 1);

  @override
  void didUpdateWidget(_Icon old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static double _seg(double t, double a, double b, [Curve c = Curves.easeOutCubic]) =>
      c.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  static final _pop = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: .7).chain(CurveTween(curve: Curves.easeOut)), weight: 25),
    TweenSequenceItem(tween: Tween(begin: .7, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)), weight: 75),
  ]);

  Widget _power(Color color, double t) {
    Widget paint(_PowerPainter p) => CustomPaint(size: const Size(24, 24), painter: p);
    switch (widget.anim) {
      case Anim.draw:
        return paint(
          _PowerPainter(
            color: color,
            line: _seg(t, 0, .35),
            ring: _seg(t, .2, .9),
          ),
        );
      case Anim.press:
        final down = _seg(t, 0, .18, Curves.easeOut);
        final up = _seg(t, .18, 1, Curves.elasticOut);
        final scale = 1 - .22 * down + .22 * up;
        final glow = math.sin(_seg(t, .15, 1, Curves.linear) * math.pi);
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: color.withValues(alpha: .55 * glow), blurRadius: 16, spreadRadius: 2)],
              ),
            ),
            Transform.translate(
              offset: Offset(0, 2 * down * (1 - up)),
              child: Transform.scale(scale: scale, child: paint(_PowerPainter(color: color))),
            ),
          ],
        );
      case Anim.spin:
        return paint(
          _PowerPainter(
            color: color,
            turn: _seg(t, 0, .85, Curves.easeOutBack) - 1,
            line: _seg(t, .45, .8),
          ),
        );
      case Anim.flip:
        final drop = _seg(t, 0, .4, Curves.easeIn);
        return Transform.scale(
          scale: 1 + .12 * math.sin(_seg(t, .35, .8, Curves.linear) * math.pi),
          child: paint(
            _PowerPainter(
              color: color,
              lineDy: -9 * (1 - drop),
              line: drop > 0 ? 1 : 0,
              gap: _seg(t, .35, 1, Curves.elasticOut),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = widget.selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: _dur,
      builder: (context, c, _) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          if (widget.i == 0) return SizedBox.square(dimension: 24, child: _power(c!, t));
          final turn = Curves.easeOutBack.transform(t) * .5;
          return Transform.rotate(angle: turn * 2 * math.pi, child: Icon(_tabs[1].$1, color: c, size: 24));
        },
      ),
    );
  }
}

/// B: compact centered pill; the selected tab grows to show its label.
class _B extends StatelessWidget {
  const _B(this.anim);
  final Anim anim;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Center(
        heightFactor: 1,
        child: _glass(
          context,
          BorderRadius.circular(30),
          ValueListenableBuilder(
            valueListenable: _tab,
            builder: (context, sel, _) => Padding(
              padding: const EdgeInsets.all(5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 2; i++)
                    AnimatedContainer(
                      duration: _dur,
                      curve: Curves.easeOutCubic,
                      height: 50,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        color: i == sel ? cs.secondaryContainer.withValues(alpha: .9) : Colors.transparent,
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: AnimatedSize(
                        duration: _dur,
                        curve: Curves.easeOutCubic,
                        child: Row(
                          children: [
                            _Icon(i, i == sel, anim),
                            if (i == sel) ...[
                              const SizedBox(width: 8),
                              Text(
                                _tabs[i].$2,
                                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                  color: cs.onSecondaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<ByteData> _file(String path) => File(path).readAsBytes().then((b) => ByteData.sublistView(b));

Future<void> _load() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(a['asset'] as String));
    }
    await loader.load();
  }
  await (FontLoader('Segoe UI')
        ..addFont(_file('C:/Windows/Fonts/segoeui.ttf'))
        ..addFont(_file('C:/Windows/Fonts/seguisb.ttf')))
      .load();
}

ThemeData _theme(Brightness b) {
  final app = AppTheme(AppThemeMode.system, FontFamily.emoji);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0078D4), brightness: b);
  final t = b == Brightness.dark ? app.darkTheme(scheme) : app.lightTheme(scheme);
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: ['Segoe UI']));
}

void main() {
  final out = Platform.environment['OUT']!;

  testWidgets('nav bar round 3', (tester) async {
    await tester.runAsync(_load);
    await tester.runAsync(LiquidGlass.precache);
    final t = _theme(Brightness.dark);
    const phone = Size(360, 720);
    await tester.binding.setSurfaceSize(Size(phone.width + 20, phone.height + 90));
    final key = GlobalKey();
    Widget screen(String name, Widget bar) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(name, style: t.textTheme.titleMedium?.copyWith(color: Colors.white, height: 1.2)),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox.fromSize(
            size: phone,
            child: ColoredBox(
              color: t.scaffoldBackgroundColor,
              child: Stack(
                children: [
                  const Positioned.fill(child: _Page()),
                  const Positioned(left: 0, right: 0, bottom: 0, child: _Fade()),
                  Positioned(left: 0, right: 0, bottom: 0, child: bar),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: t,
        home: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: Colors.black,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  screen('P1  draw', const _B(Anim.draw)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() => Directory('$out/frames').create(recursive: true));
    var n = 0;
    for (var ms = 0; ms < 6000; ms += 40) {
      final s = ms / 1000;
      _tab.value = _at(s);
      _scroll.value = 260 + 220 * math.sin(s / 6 * 2 * math.pi);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(() async {
        final frame = await boundary.toImage(pixelRatio: 1.25);
        final png = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/frames/f_${(n++).toString().padLeft(3, '0')}.png').writeAsBytes(png!.buffer.asUint8List());
      });
    }
  });
}
