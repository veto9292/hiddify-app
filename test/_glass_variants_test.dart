// TEMP design test: GlassSurface variants over light, dark, plain and busy backgrounds. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_glass_variants_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/widget/glass_surface.dart';
import 'package:hiddify/gen/fonts.gen.dart';

/// Draws one glass panel: (width, height, corner radius, padding, child).
typedef _Glass = Widget Function(bool dark, double? w, double? h, double r, EdgeInsets? padding, Widget child);

Widget _ours(bool dark, double? w, double? h, double r, EdgeInsets? padding, Widget child) =>
    GlassSurface(width: w, height: h, borderRadius: r, padding: padding, child: child);

final _variants = <(String, _Glass)>[('GlassSurface', _ours)];

enum _Bg { lightPlain, lightMap, colorful, darkPlain, darkColorful }

const _bgNames = {
  _Bg.lightPlain: 'Light, plain',
  _Bg.lightMap: 'Light, map',
  _Bg.colorful: 'Light, colorful',
  _Bg.darkPlain: 'Dark, plain',
  _Bg.darkColorful: 'Dark, colorful',
};

const _cell = Size(230, 150);

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

/// Colored blobs, so blur, tint and edges show the way they would over a photo.
class _Blobs extends StatelessWidget {
  const _Blobs({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final a = dark ? .9 : 1.0;
    final line = dark ? Colors.white70 : Colors.black87;
    Widget blob(double l, double t, double s, Color c) => Positioned(
      left: l,
      top: t,
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.withValues(alpha: a),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: dark
                    ? const [Color(0xFF101828), Color(0xFF1E1B4B)]
                    : const [Color(0xFFFFF1E6), Color(0xFFE0F2FE)],
              ),
            ),
          ),
        ),
        blob(-20, -10, 90, Colors.orange),
        blob(120, 60, 110, Colors.purple),
        blob(40, 90, 70, Colors.teal),
        blob(170, -30, 80, Colors.pink),
        for (final y in [42.0, 66.0, 112.0])
          Positioned(
            left: 0,
            right: 0,
            top: y,
            height: 3,
            child: ColoredBox(color: line),
          ),
        for (final x in [70.0, 160.0])
          Positioned(
            top: 0,
            bottom: 0,
            left: x,
            width: 3,
            child: ColoredBox(color: line),
          ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.bg, this.glass);

  final _Bg bg;
  final _Glass glass;

  @override
  Widget build(BuildContext context) {
    final dark = bg == _Bg.darkPlain || bg == _Bg.darkColorful;
    final t = _theme(dark ? Brightness.dark : Brightness.light);
    final background = switch (bg) {
      _Bg.lightPlain || _Bg.darkPlain => ColoredBox(color: t.scaffoldBackgroundColor),
      _Bg.lightMap => ColoredBox(
        color: t.scaffoldBackgroundColor,
        child: Image.asset(
          'assets/images/world_map.png',
          fit: BoxFit.cover,
          opacity: const AlwaysStoppedAnimation(.09),
          color: Colors.grey,
          colorBlendMode: BlendMode.srcATop,
        ),
      ),
      _Bg.colorful || _Bg.darkColorful => _Blobs(dark: dark),
    };
    return Theme(
      data: t,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox.fromSize(
          size: _cell,
          child: Stack(
            children: [
              Positioned.fill(child: background),
              Center(
                child: BackdropGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      glass(dark, 150, 48, 24, null, Center(child: Text('Connect', style: t.textTheme.titleSmall))),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          glass(
                            dark,
                            null,
                            null,
                            16,
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.arrow_downward_rounded, size: 16),
                                const SizedBox(width: 4),
                                Text('12.4 MB/s', style: t.textTheme.labelLarge),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          glass(dark, 40, 40, 20, null, const Icon(Icons.bolt_rounded, size: 20)),
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
    );
  }
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('glass variants', (tester) async {
    await tester.runAsync(_load);
    const labelWidth = 110.0;
    const headerHeight = 30.0;
    await tester.binding.setSurfaceSize(
      Size(labelWidth + _cell.width * _Bg.values.length, headerHeight + _cell.height * _variants.length),
    );
    final key = GlobalKey();
    const label = TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: labelWidth),
                      for (final bg in _Bg.values)
                        SizedBox(
                          width: _cell.width,
                          height: headerHeight,
                          child: Center(child: Text(_bgNames[bg]!, style: label)),
                        ),
                    ],
                  ),
                  for (final (name, glass) in _variants)
                    Row(
                      children: [
                        SizedBox(
                          width: labelWidth,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(name, style: label),
                          ),
                        ),
                        for (final bg in _Bg.values) _Cell(bg, glass),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // let the map image decode and both shaders load
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 1.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/glass.png').writeAsBytes(png!.buffer.asUint8List());
    });
  });
}
