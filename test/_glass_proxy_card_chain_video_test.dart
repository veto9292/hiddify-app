// TEMP design video: the real proxy card (ActiveProxyFooter) on glass with no chain, extra security
// (Psiphon) and unblocker (WARP), going through the same steps together. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_glass_proxy_card_chain_video_test.dart
// Frames land in OUT/chain_frames; ffmpeg turns them into a video.
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

enum _Chain { off, extraSecurity, unblocker }

const _chainNames = {
  _Chain.off: 'No chain',
  _Chain.extraSecurity: 'Extra security · Psiphon',
  _Chain.unblocker: 'Unblocker · WARP',
};

/// The steps every card goes through, in order.
enum _Step { starting, firstStep, connected, testing, tested }

const _stepNames = {
  _Step.starting: 'Starting',
  _Step.firstStep: 'First step connected',
  _Step.connected: 'Connected',
  _Step.testing: 'Testing speed',
  _Step.tested: 'Tested',
};

const _timeline = [
  (_Step.starting, 2.0),
  (_Step.firstStep, 2.5),
  (_Step.connected, 3.5),
  (_Step.testing, 2.0),
  (_Step.tested, 2.5),
];

var _now = _Step.starting;

const _cell = Size(440, 200);
const _fps = 20;

/// The config in use, as the core reports it at [step] on [chain].
OutboundInfo _server(_Chain chain, _Step step) {
  // extra security connects the config first; unblocker connects it last
  final up = switch (chain) {
    _Chain.unblocker => step.index >= _Step.connected.index,
    _ => step.index >= _Step.firstStep.index,
  };
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

/// The chain's hop at [step]: connecting until its turn, then connected with its own IP.
OutboundInfo? _hop(_Chain chain, _Step step) {
  if (chain == _Chain.off) return null;
  final psiphon = chain == _Chain.extraSecurity;
  final up = switch (chain) {
    _Chain.unblocker => step.index >= _Step.firstStep.index,
    _ => step.index >= _Step.connected.index,
  };
  if (!up) {
    return OutboundInfo(
      tag: 'hop §hide§',
      type: psiphon ? 'Psiphon ⏳ Connecting...' : 'WARP · Auto 🔑 Registering...',
      status: psiphon ? Status.CONNECTING : Status.REGISTERING,
      isSelected: true,
    );
  }
  return OutboundInfo(
    tag: 'hop §hide§',
    type: psiphon ? 'Psiphon' : 'WARP',
    urlTestDelay: 230,
    isSelected: true,
    status: Status.READY,
    ipinfo: IpInfo(ip: '104.28.9.2', countryCode: psiphon ? 'us' : 'nl', org: 'Cloudflare, Inc.'),
  );
}

class _Prefs implements SharedPreferences {
  _Prefs(this._values);
  final Map<String, Object> _values;
  @override
  Object? get(String key) => _values[key];
  @override
  String? getString(String key) => _values[key] as String?;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Main extends MainOutboundsNotifier {
  _Main(this._chain);
  final _Chain _chain;
  @override
  Stream<OutboundGroupList> build() => Stream.value(
    OutboundGroupList(
      items: [
        OutboundGroup(tag: 'select', selectable: true, items: [_server(_chain, _now)]),
      ],
      chainHop: _hop(_chain, _now),
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

/// (dark, colorful background).
const _looks = [(false, false), (false, true), (true, false), (true, true)];

ThemeData _theme(bool dark) {
  final app = AppTheme(AppThemeMode.system, FontFamily.emoji);
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0078D4),
    brightness: dark ? Brightness.dark : Brightness.light,
  );
  final t = dark ? app.darkTheme(scheme) : app.lightTheme(scheme);
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: ['Segoe UI']));
}

/// Colored blobs and a line, so blur, tint and edges show the way they would over a photo.
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
        decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: .9)),
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
        blob(-20, 20, 120, Colors.orange),
        blob(150, 70, 110, Colors.pink),
        blob(290, 0, 100, Colors.yellow),
        blob(330, 110, 130, Colors.purple),
        Positioned(
          left: 0,
          right: 0,
          top: 90,
          height: 3,
          child: ColoredBox(color: dark ? Colors.white70 : Colors.black87),
        ),
      ],
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

class _Cell extends StatelessWidget {
  const _Cell(this.chain, this.look);

  final _Chain chain;
  final (bool, bool) look;

  @override
  Widget build(BuildContext context) {
    final (dark, colorful) = look;
    final t = _theme(dark);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 26,
          child: Center(
            child: Text(
              '${_chainNames[chain]}  ·  ${dark ? 'dark' : 'light'}, ${colorful ? 'colorful' : 'plain'}',
              style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'Segoe UI'),
            ),
          ),
        ),
        Theme(
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
                  Center(child: BackdropGroup(child: const _GlassCard())),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('glass proxy card chain video', (tester) async {
    await tester.runAsync(_load);
    const bandHeight = 34.0;
    await tester.binding.setSurfaceSize(Size(_cell.width * 3 + 20, bandHeight + (26 + _cell.height) * _looks.length));
    final containers = {
      for (final chain in _Chain.values)
        chain: ProviderContainer(
          overrides: [
            translationsProvider.overrideWith((ref) => AppLocale.en.build()),
            sharedPreferencesProvider.overrideWith(
              (ref) => _Prefs(switch (chain) {
                _Chain.off => {},
                _Chain.extraSecurity => {'chain-status': 'extraSecurity', 'extra-security-mode': 'psiphon'},
                _Chain.unblocker => {'chain-status': 'unblocker', 'unblocker-mode': 'warp'},
              }),
            ),
            connectionNotifierProvider.overrideWith(_Conn.new),
            mainOutboundsNotifierProvider.overrideWith(() => _Main(chain)),
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
    final stepName = ValueNotifier(_stepNames[_now]!);
    final key = GlobalKey();
    const label = TextStyle(color: Colors.white, fontSize: 15, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    await tester.pumpWidget(
      MaterialApp(
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
                        valueListenable: stepName,
                        builder: (context, name, _) => Text(name, style: label),
                      ),
                    ),
                  ),
                  for (final look in _looks)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final chain in _Chain.values)
                          UncontrolledProviderScope(container: containers[chain]!, child: _Cell(chain, look)),
                      ],
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
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final frames = Directory('$out/chain_frames');
    await tester.runAsync(() async {
      if (frames.existsSync()) await frames.delete(recursive: true);
      await frames.create(recursive: true);
    });
    var n = 0;
    for (final (step, seconds) in _timeline) {
      _now = step;
      stepName.value = _stepNames[step]!;
      for (final c in containers.values) {
        c.invalidate(mainOutboundsNotifierProvider);
      }
      for (var i = 0; i < seconds * _fps; i++) {
        await tester.pump(const Duration(milliseconds: 1000 ~/ _fps));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.1);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${frames.path}/f_${(n++).toString().padLeft(4, '0')}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
    }
    // the card's animations leave timers; end them
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
