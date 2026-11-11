// TEMP design test: the proxy card's flag with each of its badges (state, host logo, hop logo), large,
// in light and dark, on the main row's flag and the hop's. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_flag_badges_test.dart
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
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final _badges = <(String, Widget)>[
  ('Waiting', const StepStateBadge(StepStatus.waiting)),
  ('Connecting', const StepStateBadge(StepStatus.connecting)),
  ('Connected', const StepStateBadge(StepStatus.connected)),
  ('Failed', const StepStateBadge(StepStatus.failed)),
  ('Host: Hetzner', LogoBadge.host('Hetzner Online GmbH')!),
  ('Host: Cloudflare', LogoBadge.host('Cloudflare, Inc.')!),
  ('Hop: WARP', LogoBadge.hop(ChainMode.warp)),
  ('Hop: Psiphon', LogoBadge.hop(ChainMode.psiphon)),
  ('Hop: profile', LogoBadge.hop(ChainMode.profile)),
];

/// (dark, the hop's smaller flag).
const _columns = [(false, false), (false, true), (true, false), (true, true)];

const _cell = Size(110, 80);

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
  return dark ? app.darkTheme(scheme) : app.lightTheme(scheme);
}

class _Cell extends StatelessWidget {
  const _Cell(this.badge, this.column);

  final Widget badge;
  final (bool, bool) column;

  @override
  Widget build(BuildContext context) {
    final (dark, hop) = column;
    final t = _theme(dark);
    // the flag and badge sit as in the card's rows
    final (size, radius, inset) = hop ? (30.0, 4.0, -4.0) : (36.0, 8.0, -3.0);
    return Theme(
      data: t,
      child: Container(
        width: _cell.width,
        height: _cell.height,
        color: t.colorScheme.surfaceContainerLow,
        alignment: Alignment.center,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            IPCountryFlag(countryCode: 'de', size: size, radius: radius),
            PositionedDirectional(end: inset, top: inset, child: badge),
          ],
        ),
      ),
    );
  }
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('flag badges', (tester) async {
    await tester.runAsync(_load);
    const labelWidth = 130.0;
    const headerHeight = 30.0;
    await tester.binding.setSurfaceSize(
      Size(labelWidth + _cell.width * _columns.length, headerHeight + _cell.height * _badges.length),
    );
    final container = ProviderContainer(
      overrides: [translationsProvider.overrideWith((ref) => AppLocale.en.build())],
    );
    addTearDown(container.dispose);
    container.listen(translationsProvider, (_, _) {});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final key = GlobalKey();
    const label = TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
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
                        for (final (dark, hop) in _columns)
                          SizedBox(
                            width: _cell.width,
                            height: headerHeight,
                            child: Center(
                              child: Text('${dark ? 'Dark' : 'Light'} · ${hop ? 'hop' : 'proxy'}', style: label),
                            ),
                          ),
                      ],
                    ),
                    for (final (name, badge) in _badges)
                      Row(
                        children: [
                          SizedBox(
                            width: labelWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Text(name, style: label),
                            ),
                          ),
                          for (final c in _columns) _Cell(badge, c),
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
    // the flags and logos decode; the check has popped in but not yet faded (1.5 s)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/flag_badges2.png').writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
