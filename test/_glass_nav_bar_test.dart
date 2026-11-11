// TEMP design test: the bottom navigation bar as GlassSurface glass, over light, dark,
// plain and busy backgrounds. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_glass_nav_bar_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/widget/glass_surface.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _Bg { lightPlain, lightMap, colorful, darkPlain, darkColorful }

const _bgNames = {
  _Bg.lightPlain: 'Light, plain',
  _Bg.lightMap: 'Light, map',
  _Bg.colorful: 'Light, colorful',
  _Bg.darkPlain: 'Dark, plain',
  _Bg.darkColorful: 'Dark, colorful',
};

const _cell = Size(380, 280);
const _barHeight = 64.0;

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

/// Colored blobs and lines, so blur, tint and edges show the way they would over a photo.
class _Blobs extends StatelessWidget {
  const _Blobs({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final line = dark ? Colors.white70 : Colors.black87;
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
        blob(-20, 30, 110, Colors.orange),
        blob(110, 50, 100, Colors.pink),
        blob(200, 20, 90, Colors.yellow),
        blob(270, 60, 120, Colors.purple),
        blob(60, 90, 70, Colors.teal),
        Positioned(left: 0, right: 0, top: 58, height: 3, child: ColoredBox(color: line)),
      ],
    );
  }
}

class _Tab {
  const _Tab(this.icon, this.label);

  final IconData icon;
  final String label;
}

const _tabs = [_Tab(Icons.power_settings_new_rounded, 'Home'), _Tab(Icons.settings_rounded, 'Settings')];

/// The tabs in one glass capsule; the selected tab sits in a soft inner pill.
class _Bar extends StatelessWidget {
  const _Bar({required this.selected});

  final int selected;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return GlassSurface(
      height: _barHeight,
      borderRadius: _barHeight / 2,
      padding: const EdgeInsets.all(5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, tab) in _tabs.indexed)
            Container(
              width: 86,
              decoration: i == selected
                  ? BoxDecoration(
                      color: dark ? Colors.white.withValues(alpha: .10) : Colors.black.withValues(alpha: .06),
                      borderRadius: BorderRadius.circular(_barHeight),
                    )
                  : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(tab.icon, size: 24, color: i == selected ? t.colorScheme.primary : t.colorScheme.onSurface),
                  Text(
                    tab.label,
                    style: t.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: i == selected ? t.colorScheme.primary : t.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A round glass button beside the bar, as the reference's search button.
class _RoundButton extends StatelessWidget {
  const _RoundButton(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => GlassSurface(
    width: _barHeight,
    height: _barHeight,
    borderRadius: _barHeight / 2,
    child: Icon(icon, size: 28, color: Theme.of(context).colorScheme.onSurface),
  );
}

enum _Option { pillAbove, roundRight, bothSides }

/// Picked: C.
const _shown = [_Option.bothSides];

const _optionNames = {
  _Option.pillAbove: 'A  pill above, add right',
  _Option.roundRight: 'B  both on the right',
  _Option.bothSides: 'C  add left, settings right',
};

/// One selected config, connected, with no chain: the plainest real card.
OutboundGroupList _outbounds() => OutboundGroupList(
  items: [
    OutboundGroup(
      tag: 'select',
      selectable: true,
      items: [
        OutboundInfo(
          tag: 'Germany · Frankfurt',
          type: 'VLESS',
          urlTestDelay: 118,
          isSelected: true,
          status: Status.READY,
          ipinfo: IpInfo(ip: '45.12.3.9', countryCode: 'de'),
        ),
      ],
    ),
  ],
);

class _Prefs implements SharedPreferences {
  @override
  Object? get(String key) => null;
  @override
  String? getString(String key) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Main extends MainOutboundsNotifier {
  @override
  Stream<OutboundGroupList> build() => Stream.value(_outbounds());
}

class _Conn extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() => Stream.value(const Connected());
}

/// The app's real proxy card (ActiveProxyFooter) with glass behind it: its own
/// Card is made transparent, and a GlassSurface fills the space inside the card's
/// 16 px margin.
class _ProxyCard extends StatelessWidget {
  const _ProxyCard();

  static const _radius = 20.0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Theme(
      data: t.copyWith(
        cardTheme: t.cardTheme.copyWith(
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(_radius)),
        ),
      ),
      child: const Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: GlassSurface(borderRadius: _radius, child: SizedBox.expand()),
            ),
          ),
          ActiveProxyFooter(),
        ],
      ),
    );
  }
}

/// A glass pill that opens quick settings.
class _QuickPill extends StatelessWidget {
  const _QuickPill();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return GlassSurface(
      height: 40,
      borderRadius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tune_rounded, size: 18, color: t.colorScheme.onSurface),
          const SizedBox(width: 8),
          Text('Quick settings', style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 2),
          Icon(Icons.keyboard_arrow_up_rounded, size: 20, color: t.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.bg, this.option);

  final _Bg bg;
  final _Option option;

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
              Positioned(
                left: 0,
                right: 0,
                bottom: 20,
                child: BackdropGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _ProxyCard(),
                      if (option == _Option.pillAbove) ...[const _QuickPill(), const SizedBox(height: 12)],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (option == _Option.bothSides) ...[
                            const _RoundButton(Icons.add_rounded),
                            const SizedBox(width: 10),
                          ],
                          const _Bar(selected: 0),
                          const SizedBox(width: 10),
                          if (option != _Option.bothSides) const _RoundButton(Icons.add_rounded),
                          if (option == _Option.roundRight) const SizedBox(width: 10),
                          if (option != _Option.pillAbove) const _RoundButton(Icons.tune_rounded),
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

  testWidgets('glass nav bar', (tester) async {
    await tester.runAsync(_load);
    const labelWidth = 120.0;
    const headerHeight = 30.0;
    await tester.binding.setSurfaceSize(
      Size(labelWidth + _cell.width * _shown.length, headerHeight + _cell.height * _Bg.values.length),
    );
    final key = GlobalKey();
    const label = TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
        connectionNotifierProvider.overrideWith(_Conn.new),
        mainOutboundsNotifierProvider.overrideWith(_Main.new),
      ],
    );
    addTearDown(container.dispose);
    container
      ..listen(translationsProvider, (_, _) {})
      ..listen(sharedPreferencesProvider, (_, _) {})
      ..listen(activeProxyCardProvider, (_, _) {});
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
                        for (final o in _shown)
                          SizedBox(
                            width: _cell.width,
                            height: headerHeight,
                            child: Center(child: Text(_optionNames[o]!, style: label)),
                          ),
                      ],
                    ),
                    for (final bg in _Bg.values)
                      Row(
                        children: [
                          SizedBox(
                            width: labelWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Text(_bgNames[bg]!, style: label),
                            ),
                          ),
                          for (final o in _shown) _Cell(bg, o),
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
    // let the map image decode and the glass shader load
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    // let the card's entry animations (flag, IP) finish
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 1.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/nav_bar5.png').writeAsBytes(png!.buffer.asUint8List());
    });
    // the card's animations leave timers; end them
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
