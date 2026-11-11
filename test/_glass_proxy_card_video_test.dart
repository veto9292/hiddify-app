// TEMP design video: the real proxy card (ActiveProxyFooter) on glass going through its states, speed
// test in the row (A) beside the speed test as a corner badge (B). Not part of the app.
// Run: OUT=build/glass_design flutter test test/_glass_proxy_card_video_test.dart
// Frames land in OUT/card_frames; ffmpeg turns them into a video.
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

enum _State { connecting, connected, testing, tested, earlierRun, failed }

const _stateNames = {
  _State.connecting: 'Connecting',
  _State.connected: 'Connected, not tested',
  _State.testing: 'Testing',
  _State.tested: 'Tested',
  _State.earlierRun: 'From an earlier run',
  _State.failed: 'Test failed',
};

/// What the card shows over time: (state, seconds).
const _timeline = [
  (_State.connected, 2.0),
  (_State.testing, 2.5),
  (_State.tested, 2.5),
];

/// The state the fake core reports now.
var _now = _State.connecting;

const _cell = Size(420, 190);
const _fps = 30;

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
  @override
  Stream<OutboundGroupList> build() => Stream.value(
    OutboundGroupList(
      items: [
        OutboundGroup(tag: 'select', selectable: true, items: [_server(_now)]),
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

/// Colored blobs and a line, so blur, tint and edges show the way they would over a photo.
class _Blobs extends StatelessWidget {
  const _Blobs();

  @override
  Widget build(BuildContext context) {
    Widget blob(double l, double t, double s, Color c) => Positioned(
      left: l,
      top: t,
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: .9)),
      ),
    );
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF101828), Color(0xFF1E1B4B)])),
          ),
        ),
        blob(-20, 10, 110, Colors.orange),
        blob(140, 40, 100, Colors.pink),
        blob(270, -10, 90, Colors.yellow),
        blob(320, 70, 120, Colors.purple),
        const Positioned(left: 0, right: 0, top: 60, height: 3, child: ColoredBox(color: Colors.white70)),
      ],
    );
  }
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
  const _Cell({required this.corner});

  final bool corner;

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme(Brightness.dark),
    child: Material(
      type: MaterialType.transparency,
      child: SizedBox.fromSize(
        size: _cell,
        child: Stack(
          children: [
            const Positioned.fill(child: _Blobs()),
            Center(child: BackdropGroup(child: _GlassCard(speedInCorner: corner))),
          ],
        ),
      ),
    ),
  );
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('glass proxy card video', (tester) async {
    await tester.runAsync(_load);
    const bandHeight = 34.0;
    await tester.binding.setSurfaceSize(Size(_cell.width, bandHeight + _cell.height));
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
    final stateName = ValueNotifier(_stateNames[_now]!);
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
                    SizedBox(
                      height: bandHeight,
                      child: Center(
                        child: ValueListenableBuilder(
                          valueListenable: stateName,
                          builder: (context, name, _) => Text(name, style: label),
                        ),
                      ),
                    ),
                    const _Cell(corner: false),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // the glass shader loads
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final frames = Directory('$out/card_frames');
    await tester.runAsync(() async {
      if (frames.existsSync()) await frames.delete(recursive: true);
      await frames.create(recursive: true);
    });
    var n = 0;
    for (final (state, seconds) in _timeline) {
      _now = state;
      stateName.value = _stateNames[state]!;
      container.invalidate(mainOutboundsNotifierProvider);
      for (var i = 0; i < seconds * _fps; i++) {
        await tester.pump(const Duration(milliseconds: 1000 ~/ _fps));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${frames.path}/f_${(n++).toString().padLeft(4, '0')}.png').writeAsBytes(png!.buffer.asUint8List());
        });
      }
    }
    // the card's animations leave timers; end them
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
