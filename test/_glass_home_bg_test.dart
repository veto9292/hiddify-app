// TEMP design test: home (the parts designed so far: the real proxy card on glass with extra security,
// the layout C glass bar) on three backgrounds, light and dark: A the map now, B soft colored glows
// under the map, C the same glows turning green once connected. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_glass_home_bg_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fixnum/fixnum.dart';
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

enum _Step { starting, firstStep, connected, testing, tested }

var _now = _Step.tested;

const _phone = Size(400, 520);
const _barHeight = 64.0;

OutboundInfo _server(_Step step) {
  final up = step.index >= _Step.firstStep.index;
  final info = OutboundInfo(
    tag: 'Germany · Frankfurt',
    type: 'VLESS',
    urlTestDelay: up ? 118 : 0,
    isSelected: true,
    status: Status.READY,
    ipinfo: up ? IpInfo(ip: '45.12.3.9', countryCode: 'de', org: 'Hetzner Online GmbH') : IpInfo(),
  );
  if (step == _Step.testing) {
    info
      ..uploadTesting = true
      ..downloadTesting = true;
  }
  if (step == _Step.tested) {
    info
      ..uploadSpeed = Int64(3400000)
      ..downloadSpeed = Int64(12800000);
  }
  return info;
}

OutboundInfo _hop(_Step step) => step.index < _Step.connected.index
    ? OutboundInfo(tag: 'hop §hide§', type: 'Psiphon Connecting...', status: Status.CONNECTING, isSelected: true)
    : OutboundInfo(
        tag: 'hop §hide§',
        type: 'Psiphon',
        urlTestDelay: 230,
        isSelected: true,
        status: Status.READY,
        ipinfo: IpInfo(ip: '104.28.9.2', countryCode: 'us', org: 'Cloudflare, Inc.'),
      );

class _Prefs implements SharedPreferences {
  @override
  Object? get(String key) => _values[key];
  @override
  String? getString(String key) => _values[key];
  static const _values = {'chain-status': 'extraSecurity', 'extra-security-mode': 'psiphon'};
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Main extends MainOutboundsNotifier {
  @override
  Stream<OutboundGroupList> build() => Stream.value(
    OutboundGroupList(
      items: [
        OutboundGroup(tag: 'select', selectable: true, items: [_server(_now)]),
      ],
      chainHop: _hop(_now),
    ),
  );
}

class _Conn extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() => Stream.value(const Connected());
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

ThemeData _theme(bool dark) {
  final app = AppTheme(AppThemeMode.system, FontFamily.emoji);
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0078D4),
    brightness: dark ? Brightness.dark : Brightness.light,
  );
  final t = dark ? app.darkTheme(scheme) : app.lightTheme(scheme);
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: ['Segoe UI']));
}

enum _Bg { darker, gradient, shade }

const _bgNames = {
  _Bg.darker: 'A1  darker map',
  _Bg.gradient: 'A2  + light gradient',
  _Bg.shade: 'A3  + gradient and shade',
};

/// Home's background: the theme's color with the world map as the feature, neutral. A1 the map a
/// little darker in light; A2 the land shades softly from top-left to bottom-right; A3 also lifts
/// off the page with a faint shadow.
class _HomeBackground extends StatelessWidget {
  const _HomeBackground(this.bg);

  final _Bg bg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final land = dark ? Colors.white.withValues(alpha: .075) : Colors.black.withValues(alpha: .12);
    Widget map(Color color) =>
        Image.asset('assets/images/world_map.png', fit: BoxFit.cover, color: color, colorBlendMode: BlendMode.srcIn);
    Widget lit = map(land);
    if (bg != _Bg.darker) {
      // the land itself carries a soft gradient: a touch deeper at the top left, lighter at the
      // bottom right, as if lit from the bottom
      lit = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0x8CFFFFFF)],
        ).createShader(rect),
        child: map(dark ? Colors.white.withValues(alpha: .10) : Colors.black.withValues(alpha: .15)),
      );
    }
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bg == _Bg.shade)
            // a faint shadow just under the land
            Transform.translate(
              offset: const Offset(0, 2),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
                child: map(Colors.black.withValues(alpha: dark ? .35 : .08)),
              ),
            ),
          lit,
        ],
      ),
    );
  }
}

/// The real card with glass behind it: its own Card made transparent, a GlassSurface inside the
/// card's 16 px margin.
class _GlassCard extends StatelessWidget {
  const _GlassCard();

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
        clipBehavior: Clip.none,
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

const _tabs = [(Icons.power_settings_new_rounded, 'Home'), (Icons.settings_rounded, 'Settings')];

/// The tabs in one glass capsule; the selected tab sits in a soft inner pill.
class _Bar extends StatelessWidget {
  const _Bar();

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
          for (final (i, (icon, label)) in _tabs.indexed)
            Container(
              width: 86,
              decoration: i == 0
                  ? BoxDecoration(
                      color: dark ? Colors.white.withValues(alpha: .10) : Colors.black.withValues(alpha: .06),
                      borderRadius: BorderRadius.circular(_barHeight),
                    )
                  : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 24, color: i == 0 ? t.colorScheme.primary : t.colorScheme.onSurface),
                  Text(
                    label,
                    style: t.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: i == 0 ? t.colorScheme.primary : t.colorScheme.onSurface,
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

class _Phone extends StatelessWidget {
  const _Phone({required this.dark, required this.bg});

  final bool dark;
  final _Bg bg;

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme(dark),
    child: Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: SizedBox.fromSize(
          size: _phone,
          child: Stack(
            children: [
              Positioned.fill(child: _HomeBackground(bg)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 20,
                child: BackdropGroup(
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _GlassCard(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _RoundButton(Icons.add_rounded),
                          SizedBox(width: 10),
                          _Bar(),
                          SizedBox(width: 10),
                          _RoundButton(Icons.tune_rounded),
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
  );
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('glass home backgrounds', (tester) async {
    await tester.runAsync(_load);
    const bandHeight = 34.0;
    await tester.binding.setSurfaceSize(
      Size((_phone.width + 16) * _Bg.values.length + 16, (bandHeight + _phone.height + 16) * 2),
    );
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
    final key = GlobalKey();
    const label = TextStyle(color: Colors.white, fontSize: 15, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
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
                  children: [
                    for (final dark in [false, true])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (final bg in _Bg.values)
                              Column(
                                children: [
                                  SizedBox(
                                    height: bandHeight,
                                    child: Center(
                                      child: Text('${_bgNames[bg]} · ${dark ? 'dark' : 'light'}', style: label),
                                    ),
                                  ),
                                  _Phone(dark: dark, bg: bg),
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
      ),
    );
    // the glass shader loads and the map decodes; the card settles (checks gone, logos in)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // the logos (images) decode off the test clock
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 1.25);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/home_bg3.png').writeAsBytes(png!.buffer.asUint8List());
    });
    // the card's animations leave timers; end them
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
