// TEMP design test: the real proxy card (ActiveProxyFooter) on glass, in its states, with the speed
// test in the row or as a corner badge. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_glass_proxy_card_test.dart
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

enum _State { connecting, justConnected, untested, testing, tested, earlierRun, failed }

/// The states shown.
const _shown = [_State.untested, _State.testing, _State.tested];

const _stateNames = {
  _State.connecting: 'Connecting',
  _State.justConnected: 'Just connected',
  _State.untested: 'Check gone,\nnot tested',
  _State.testing: 'Testing',
  _State.tested: 'Tested',
  _State.earlierRun: 'Earlier run',
  _State.failed: 'Test failed',
};

/// (theme, speed test in the corner).
const _columns = [(false, false), (true, false), (false, true), (true, true)];

String _columnName((bool, bool) c) => '${c.$2 ? 'B  corner badge' : 'A  in the row'} · ${c.$1 ? 'dark' : 'light'}';

const _cell = Size(420, 200);

/// The just-connected row mounts late, so its check is caught before it fades.
final _late = ValueNotifier(false);

OutboundInfo _server(_State s) {
  final connecting = s == _State.connecting;
  final info = OutboundInfo(
    tag: 'Germany · Frankfurt',
    type: 'VLESS',
    urlTestDelay: connecting ? 0 : 118,
    isSelected: true,
    status: Status.READY,
    ipinfo: connecting ? IpInfo() : IpInfo(ip: '45.12.3.9', countryCode: 'de', org: 'Hetzner Online GmbH'),
  );
  switch (s) {
    case _State.testing:
      info
        ..uploadTesting = true
        ..downloadTesting = true;
    case _State.tested || _State.earlierRun:
      info
        ..uploadSpeed = Int64(3400000)
        ..downloadSpeed = Int64(12800000)
        ..uploadSpeedCached = s == _State.earlierRun
        ..downloadSpeedCached = s == _State.earlierRun;
    case _State.failed:
      info
        ..uploadSpeed = Int64(-1)
        ..downloadSpeed = Int64(-1);
    default:
  }
  return info;
}

/// Extra security on, through Psiphon.
class _Prefs implements SharedPreferences {
  static const _values = {'chain-status': 'extraSecurity', 'extra-security-mode': 'psiphon'};
  @override
  Object? get(String key) => _values[key];
  @override
  String? getString(String key) => _values[key];
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Main extends MainOutboundsNotifier {
  _Main(this._state);
  final _State _state;
  @override
  Stream<OutboundGroupList> build() => Stream.value(
    OutboundGroupList(
      items: [
        OutboundGroup(tag: 'select', selectable: true, items: [_server(_state)]),
      ],
      // the hop, already connected
      chainHop: OutboundInfo(
        tag: 'hop §hide§',
        type: 'Psiphon',
        urlTestDelay: 230,
        isSelected: true,
        status: Status.READY,
        ipinfo: IpInfo(ip: '104.28.9.2', countryCode: 'us', org: 'Cloudflare, Inc.'),
      ),
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

ThemeData _theme(Brightness b) {
  final app = AppTheme(AppThemeMode.system, FontFamily.emoji);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0078D4), brightness: b);
  final t = b == Brightness.dark ? app.darkTheme(scheme) : app.lightTheme(scheme);
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: ['Segoe UI']));
}

/// Home's background: the theme's color with the world map, as on home.
class _Blobs extends StatelessWidget {
  const _Blobs({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: Image.asset(
      'assets/images/world_map.png',
      fit: BoxFit.cover,
      color: dark ? Colors.white.withValues(alpha: .10) : Colors.black.withValues(alpha: .20),
      colorBlendMode: BlendMode.srcIn,
    ),
  );
}

/// The real card with glass behind it: its own Card made transparent, a GlassSurface inside the
/// card's 16 px margin.
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.speedInCorner});

  final bool speedInCorner;

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
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: GlassSurface(borderRadius: _radius, child: SizedBox.expand()),
            ),
          ),
          ActiveProxyFooter(speedInCorner: speedInCorner),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.state, this.column);

  final _State state;
  final (bool, bool) column;

  @override
  Widget build(BuildContext context) {
    final (dark, corner) = column;
    final t = _theme(dark ? Brightness.dark : Brightness.light);
    final card = Center(
      child: BackdropGroup(child: _GlassCard(speedInCorner: corner)),
    );
    return Theme(
      data: t,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox.fromSize(
          size: _cell,
          child: Stack(
            children: [
              Positioned.fill(child: _Blobs(dark: dark)),
              if (state == _State.justConnected)
                ValueListenableBuilder(
                  valueListenable: _late,
                  builder: (context, mounted, _) => mounted ? card : const SizedBox.shrink(),
                )
              else
                card,
            ],
          ),
        ),
      ),
    );
  }
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('glass proxy card', (tester) async {
    await tester.runAsync(_load);
    const labelWidth = 130.0;
    const headerHeight = 30.0;
    await tester.binding.setSurfaceSize(
      Size(labelWidth + _cell.width * _columns.length, headerHeight + _cell.height * _shown.length),
    );
    final containers = {
      for (final s in _shown)
        s: ProviderContainer(
          overrides: [
            translationsProvider.overrideWith((ref) => AppLocale.en.build()),
            sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
            connectionNotifierProvider.overrideWith(_Conn.new),
            mainOutboundsNotifierProvider.overrideWith(() => _Main(s)),
          ],
        ),
    };
    for (final c in containers.values) {
      addTearDown(c.dispose);
      c
        ..listen(translationsProvider, (_, _) {})
        ..listen(sharedPreferencesProvider, (_, _) {})
        ..listen(activeProxyCardProvider, (_, _) {});
    }
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
                      for (final c in _columns)
                        SizedBox(
                          width: _cell.width,
                          height: headerHeight,
                          child: Center(child: Text(_columnName(c), style: label)),
                        ),
                    ],
                  ),
                  for (final s in _shown)
                    UncontrolledProviderScope(
                      container: containers[s]!,
                      child: Row(
                        children: [
                          SizedBox(
                            width: labelWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Text(_stateNames[s]!, style: label),
                            ),
                          ),
                          for (final c in _columns) _Cell(s, c),
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
    // the glass shader loads
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    // 3 s on the test clock: entry animations finish and the checks fade; the late row mounts
    // 0.7 s before the picture, so its check still shows
    for (var i = 0; i < 30; i++) {
      if (i == 23) _late.value = true;
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 1.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/speed_corner.png').writeAsBytes(png!.buffer.asUint8List());
    });
    // the card's animations leave timers; end them
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
