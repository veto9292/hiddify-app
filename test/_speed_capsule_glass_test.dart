// TEMP design test: the speed test capsule (SpeedCapsule) alone, on a glass card, in every state
// and on light, dark, plain and colorful backgrounds. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_speed_capsule_glass_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/widget/glass_surface.dart';
import 'package:hiddify/features/proxy/widget/upload_speed.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// (name, upload, uploadTesting, uploadCached, download, downloadTesting, downloadCached).
const _states = <(String, int, bool, bool, int, bool, bool)>[
  ('Testing', 0, true, false, 0, true, false),
  ('Upload done', 3400000, false, false, 0, true, false),
  ('Tested', 3400000, false, false, 12800000, false, false),
  ('Slow', 120000, false, false, 600000, false, false),
  ('Upload failed', -1, false, false, 12800000, false, false),
  ('Both failed', -1, false, false, -1, false, false),
];

/// (dark, colorful background).
const _looks = [(false, false), (false, true), (true, false), (true, true)];

const _cell = Size(210, 96);

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

ThemeData _theme(bool dark) {
  final app = AppTheme(AppThemeMode.system, FontFamily.emoji);
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0078D4),
    brightness: dark ? Brightness.dark : Brightness.light,
  );
  final t = dark ? app.darkTheme(scheme) : app.lightTheme(scheme);
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamilyFallback: ['Segoe UI']),
    // the card is glass: its own color is transparent, as on home
    cardTheme: t.cardTheme.copyWith(color: Colors.transparent),
  );
}

class _Blobs extends StatelessWidget {
  const _Blobs({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    Widget blob(double l, double t, double s, Color c) => Positioned(
      left: l,
      top: t,
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.withValues(alpha: dark ? .9 : 1),
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
        blob(-10, -20, 80, Colors.orange),
        blob(80, 30, 70, Colors.pink),
        blob(150, -10, 70, Colors.yellow),
        blob(170, 50, 80, Colors.purple),
        Positioned(
          left: 0,
          right: 0,
          top: 46,
          height: 3,
          child: ColoredBox(color: dark ? Colors.white70 : Colors.black87),
        ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.state, this.look);

  final (String, int, bool, bool, int, bool, bool) state;
  final (bool, bool) look;

  @override
  Widget build(BuildContext context) {
    final (dark, colorful) = look;
    final t = _theme(dark);
    final (_, up, upT, upC, down, downT, downC) = state;
    return Theme(
      data: t,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox.fromSize(
          size: _cell,
          child: Stack(
            children: [
              Positioned.fill(
                child: colorful ? _Blobs(dark: dark) : ColoredBox(color: t.scaffoldBackgroundColor),
              ),
              // a slice of the glass card, as behind the capsule on home
              Center(
                child: BackdropGroup(
                  child: GlassSurface(
                    width: 200,
                    height: 64,
                    borderRadius: 20,
                    child: Center(
                      child: SpeedCapsule(
                        upload: up,
                        uploadTesting: upT,
                        uploadCached: upC,
                        download: down,
                        downloadTesting: downT,
                        downloadCached: downC,
                        onTest: () {},
                      ),
                    ),
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

  testWidgets('speed capsule on glass', (tester) async {
    await tester.runAsync(_load);
    const labelWidth = 120.0;
    const headerHeight = 30.0;
    await tester.binding.setSurfaceSize(
      Size(labelWidth + _cell.width * _looks.length, headerHeight + _cell.height * _states.length),
    );
    final key = GlobalKey();
    const label = TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    final container = ProviderContainer(overrides: [translationsProvider.overrideWith((ref) => AppLocale.en.build())]);
    addTearDown(container.dispose);
    container.listen(translationsProvider, (_, _) {});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
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
                        for (final (dark, colorful) in _looks)
                          SizedBox(
                            width: _cell.width,
                            height: headerHeight,
                            child: Center(
                              child: Text(
                                '${dark ? 'Dark' : 'Light'}, ${colorful ? 'colorful' : 'plain'}',
                                style: label,
                              ),
                            ),
                          ),
                      ],
                    ),
                    for (final state in _states)
                      Row(
                        children: [
                          SizedBox(
                            width: labelWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Text(state.$1, style: label),
                            ),
                          ),
                          for (final look in _looks) _Cell(state, look),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // the glass shader loads; translations resolve
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 1.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/speed_capsule3.png').writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
