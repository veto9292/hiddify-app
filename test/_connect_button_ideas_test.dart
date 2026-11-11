// TEMP design test: 10 glass looks for the connect button alone (no badge, label or ping), each
// off and on, on home's background in dark. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_connect_button_ideas_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/widget/glass_surface.dart';
import 'package:hiddify/gen/fonts.gen.dart';

const _size = 148.0;
const _tile = Size(300, 300);

/// The button's colors today (ConnectionButtonTheme): connected green, idle indigo. The logo is
/// drawn in them, as the button draws it now.
const _on = Color(0xFF44A334);
const _idle = Color(0xFF4A4D8B);

Color _state(bool on) => on ? _on : _idle;

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
  await (FontLoader('Segoe UI')..addFont(_file('C:/Windows/Fonts/seguisb.ttf'))).load();
}

ThemeData _theme() {
  final app = AppTheme(AppThemeMode.system, FontFamily.emoji);
  return app.darkTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF0078D4), brightness: Brightness.dark));
}

/// The app's logo, in one color.
Widget _logo(Color color, {double size = 64}) => SvgPicture.asset(
  'assets/images/logo.svg',
  width: size,
  height: size,
  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
);

Widget _disc({required Widget child, double size = _size}) =>
    GlassSurface(width: size, height: size, borderRadius: size / 2, child: Center(child: child));

/// A soft colored light behind the glass, which the glass bends and blurs.
Widget _lightBehind(Color color, {double size = _size, double alpha = .55}) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    shape: BoxShape.circle,
    boxShadow: [BoxShadow(color: color.withValues(alpha: alpha), blurRadius: 60, spreadRadius: 6)],
  ),
);

class _RingPainter extends CustomPainter {
  _RingPainter(this.color, {this.width = 3, this.inset = 10, this.glow = true});
  final Color color;
  final double width;
  final double inset;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - inset;
    final c = size.center(Offset.zero);
    if (glow) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width + 6
          ..color = color.withValues(alpha: .35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => false;
}

typedef _Look = Widget Function(BuildContext c, bool on);

/// A white face with the logo in the state's color: the logo as the button shows it today.
Widget _face(bool on, {double size = 112, double logo = 60, BorderRadius? radius}) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: Colors.white,
    shape: radius == null ? BoxShape.circle : BoxShape.rectangle,
    borderRadius: radius,
    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .25), blurRadius: 12, offset: const Offset(0, 4))],
  ),
  child: Center(child: _logo(_state(on), size: logo)),
);

final _designs = <(String, _Look)>[
  ('B1  Glass rim, white face', (c, on) => _disc(child: _face(on))),
  (
    'B2  Frosted white glass',
    (c, on) => _disc(
      child: Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .82)),
        child: Center(child: _logo(_state(on))),
      ),
    ),
  ),
  (
    'B3  Ring between rim and face',
    (c, on) => _disc(
      child: CustomPaint(
        size: const Size.square(_size),
        painter: _RingPainter(on ? _on : Colors.white.withValues(alpha: .25), inset: 13, glow: on),
        child: Center(child: _face(on, size: 100, logo: 54)),
      ),
    ),
  ),
  (
    'B4  Light behind the glass',
    (c, on) => Stack(
      alignment: Alignment.center,
      children: [
        _lightBehind(_state(on), alpha: on ? .8 : .7),
        _disc(child: _face(on)),
      ],
    ),
  ),
  (
    'B5  Glass squircle',
    (c, on) => GlassSurface(
      width: 148,
      height: 148,
      borderRadius: 46,
      child: Center(child: _face(on, radius: BorderRadius.circular(34))),
    ),
  ),
  (
    'B6  Logo on clear glass',
    (c, on) => _disc(
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [Colors.white.withValues(alpha: .9), Colors.white.withValues(alpha: 0)]),
        ),
        child: Center(child: _logo(_state(on))),
      ),
    ),
  ),
  (
    'B7  Halo rings',
    (c, on) => Stack(
      alignment: Alignment.center,
      children: [
        for (final (grow, alpha) in [(56.0, .12), (28.0, .26)])
          CustomPaint(
            size: Size.square(_size + grow),
            painter: _RingPainter(
              (on ? _on : Colors.white).withValues(alpha: on ? alpha * 2.2 : alpha * .6),
              width: 1.5,
              inset: 0,
              glow: false,
            ),
          ),
        _disc(child: _face(on)),
      ],
    ),
  ),
  ('B8  Wide glass plate', (c, on) => _disc(size: 184, child: _face(on, size: 116))),
  (
    'B9  Tinted rim',
    (c, on) => _disc(
      child: Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: _state(on).withValues(alpha: on ? .55 : .45)),
        child: Center(child: _face(on)),
      ),
    ),
  ),
  (
    'B10  Glass switch',
    (c, on) => GlassSurface(
      width: 210,
      height: 100,
      borderRadius: 50,
      padding: const EdgeInsets.all(9),
      child: Align(
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: _face(on, size: 82, logo: 44),
      ),
    ),
  ),
];

class _Tile extends StatelessWidget {
  const _Tile(this.look, {required this.on});
  final _Look look;
  final bool on;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: SizedBox.fromSize(
      size: _tile,
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Image.asset(
                'assets/images/world_map.png',
                fit: BoxFit.cover,
                alignment: const Alignment(.1, -.3),
                color: Colors.white.withValues(alpha: .10),
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
          ),
          Center(child: BackdropGroup(child: Builder(builder: (c) => look(c, on)))),
        ],
      ),
    ),
  );
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('connect button ideas', (tester) async {
    await tester.runAsync(_load);
    const perRow = 5;
    const labelHeight = 30.0;
    final rows = (_designs.length / perRow).ceil();
    await tester.binding.setSurfaceSize(
      Size((_tile.width + 14) * perRow + 14, (labelHeight + (_tile.height + 10) * 2 + 14) * rows),
    );
    const label = TextStyle(color: Colors.white, fontSize: 15, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: Material(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black,
              child: Column(
                children: [
                  for (var row = 0; row < rows; row++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (final (name, look) in _designs.skip(row * perRow).take(perRow))
                            Column(
                              children: [
                                SizedBox(height: labelHeight, child: Center(child: Text(name, style: label))),
                                _Tile(look, on: false),
                                const SizedBox(height: 10),
                                _Tile(look, on: true),
                              ],
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 1.25);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/connect_button_ideas.png').writeAsBytes(png!.buffer.asUint8List());
    });
  });
}
