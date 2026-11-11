// TEMP design test: 10 ideas for showing the speed test on home, each on home's background with the
// real proxy card (extra security on, its own speed test hidden) and the glass bar, tested
// (↑ 27, ↓ 102 Mbps), in dark. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_speed_ideas_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/widget/glass_surface.dart';
import 'package:hiddify/features/chain/overview/chain_mode_icon.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/eclipse_button_painter.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/features/proxy/widget/upload_speed.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_parsing/path_parsing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bytes a second, as the core reports them: 27 and 102 Mbps.
const _up = 3400000;

/// How strong the world map is drawn.
var _mapAlpha = .02;

/// The ping with no glass behind it.
var _pingBare = true;

/// The speed test right of the button, level with its centre.
var _speedRight = true;
const _down = 12800000;

/// Whether the test has run: each idea draws its before-test look when false.
var _tested = true;

/// Whether the selected proxy is dead: its ping timed out.
var _dead = false;

/// Whether the test is running (our capsule only).
var _testing = false;

/// Whether the test failed (our capsule only).
var _failed = false;

/// The download needle's full scale, in Mbps.
const _scale = 200.0;

const _phone = Size(380, 600);
const _barHeight = 64.0;

/// Where the proxy row's end sits in the card: its vertical middle, and the room the chevron keeps.
const _rowMiddle = 16 + 38.0;
const _rowEnd = 16 + 16 + 24 + 8.0;

class _Prefs implements SharedPreferences {
  _Prefs([this.chain = 'extraSecurity']);

  /// extraSecurity, unblocker or off.
  final String chain;
  late final _values = {'chain-status': chain, 'extra-security-mode': 'psiphon', 'unblocker-mode': 'psiphon'};
  @override
  Object? get(String key) => _values[key];
  @override
  String? getString(String key) => _values[key];
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Main extends MainOutboundsNotifier {
  _Main([this.chain = 'extraSecurity']);
  final String chain;

  @override
  Stream<OutboundGroupList> build() => Stream.value(_outbounds(chain, dead: _dead, offer: _dead));
}

/// The core's list: the pick (dead: its ping timed out), the fastest server when [offer], the hop.
OutboundGroupList _outbounds(String chain, {required bool dead, required bool offer, bool hopPending = false}) =>
    OutboundGroupList(
      items: [
        OutboundGroup(
          tag: 'select',
          selectable: true,
          items: [
            OutboundInfo(
              tag: 'Germany · Frankfurt',
              type: 'VLESS',
              urlTestDelay: dead ? 65535 : 118,
              isSelected: true,
              status: Status.READY,
              ipinfo: IpInfo(ip: '45.12.3.9', countryCode: 'de', org: 'Hetzner Online GmbH'),
            ),
          ],
        ),
        // the fastest server the core found, which the dead pick offers to switch to
        if (offer)
          OutboundGroup(
            tag: lowestGroupTag,
            items: [
              OutboundInfo(tag: 'Netherlands · Amsterdam', type: 'VLESS', urlTestDelay: 95, status: Status.READY),
            ],
          ),
      ],
      chainHop: chain == 'off'
          ? null
          : OutboundInfo(
              tag: 'hop §hide§',
              type: 'Psiphon',
              urlTestDelay: hopPending ? 0 : 230,
              isSelected: true,
              status: hopPending ? Status.CONNECTING : Status.READY,
              ipinfo: IpInfo(ip: '104.28.9.2', countryCode: 'us', org: 'Cloudflare, Inc.'),
            ),
    );

/// A connection that stays in one state.
class _FixedConn extends ConnectionNotifier {
  _FixedConn(this.status);
  final ConnectionStatus status;

  @override
  Stream<ConnectionStatus> build() => Stream.value(status);
}

/// The core's list, the pick dead (with a faster one to offer) or working.
class _FixedMain extends MainOutboundsNotifier {
  _FixedMain(this.dead);
  final bool dead;

  @override
  Stream<OutboundGroupList> build() => Stream.value(_outbounds('extraSecurity', dead: dead, offer: dead));
}

/// What the pick does in the video: ok, dead (nothing faster answers) or offer (a faster one does).
final _pick = ValueNotifier('ok');

/// The core's list, sent again each time [_pick] changes.
class _LiveMain extends MainOutboundsNotifier {
  @override
  Stream<OutboundGroupList> build() {
    final out = StreamController<OutboundGroupList>();
    void send() => out.add(
      _outbounds(
        'extraSecurity',
        dead: _pick.value == 'dead' || _pick.value == 'offer',
        offer: _pick.value == 'offer',
        hopPending: _pick.value == 'hop',
      ),
    );
    send();
    _pick.addListener(send);
    ref.onDispose(() {
      _pick.removeListener(send);
      out.close();
    });
    return out.stream;
  }
}

/// Whether the core runs: false shows the button idle.
var _running = true;

class _Conn extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() => Stream.value(_running ? const Connected() : const Disconnected());
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

ThemeData _theme() {
  final app = AppTheme(AppThemeMode.system, FontFamily.emoji);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0078D4), brightness: Brightness.dark);
  final t = app.darkTheme(scheme);
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: ['Segoe UI']));
}

/// Home's background: the theme's color with the world map.
class _HomeBackground extends StatelessWidget {
  const _HomeBackground();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: Image.asset(
      'assets/images/world_map.png',
      fit: BoxFit.cover,
      color: Colors.white.withValues(alpha: _mapAlpha),
      colorBlendMode: BlendMode.srcIn,
    ),
  );
}

/// The real card, its speed test hidden, with glass behind it.
class _GlassCard extends StatelessWidget {
  const _GlassCard();

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
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      child: const Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: GlassSurface(borderRadius: 20, child: SizedBox.expand()),
            ),
          ),
          ActiveProxyFooter(hideSpeedTest: true),
        ],
      ),
    );
  }
}

const _tabs = [(Icons.power_settings_new_rounded, 'Home'), (Icons.settings_rounded, 'Settings')];

class _Bar extends StatelessWidget {
  const _Bar();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return GlassSurface(
      height: _barHeight,
      borderRadius: _barHeight / 2,
      padding: const EdgeInsets.all(5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, (icon, label)) in _tabs.indexed)
            Container(
              width: 80,
              decoration: i == 0
                  ? BoxDecoration(
                      color: Colors.white.withValues(alpha: _mapAlpha),
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

class _Round extends StatelessWidget {
  const _Round({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GlassSurface(
    width: _barHeight,
    height: _barHeight,
    borderRadius: _barHeight / 2,
    child: Center(child: child),
  );
}

// ---------- shared bits ----------

TextStyle? _num(BuildContext context, double size, {Color? color}) => Theme.of(context).textTheme.titleMedium?.copyWith(
  fontSize: size,
  fontWeight: FontWeight.w700,
  height: 1,
  color: color,
  fontFeatures: const [FontFeature.tabularFigures()],
);

TextStyle? _small(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

Color _green(BuildContext context) => uploadSpeedColor(context, _down);

/// One direction: its arrow, then its number.
Widget _dir(BuildContext context, {required bool up, double size = 15, double arrow = 12}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Icon(
      up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
      size: arrow,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    const SizedBox(width: 2),
    Text(formatMbps(up ? _up : _down), style: _num(context, size, color: _green(context))),
  ],
);

/// The gauge icon in the accent color, the before-test mark most ideas use.
Widget _gauge(BuildContext context, {double size = 18}) =>
    Icon(Icons.speed_rounded, size: size, color: Theme.of(context).colorScheme.primary);

/// A short call to test, in the accent color.
Widget _cta(BuildContext context, String text, {double icon = 16}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    _gauge(context, size: icon),
    const SizedBox(width: 5),
    Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
  ],
);

// ---------- the ten designs ----------

/// Where a design puts things: above the card, over the proxy row's end, below the card, or in
/// place of the bar's right button.
class _Design {
  const _Design(this.name, {this.above, this.inRow, this.below, this.barEnd});
  final String name;
  final WidgetBuilder? above;
  final WidgetBuilder? inRow;
  final WidgetBuilder? below;
  final WidgetBuilder? barEnd;
}

final _designs = <_Design>[
  _Design('1  Speedometer', above: (context) => const _Gauge()),
  _Design('2  Quiet numbers', inRow: (context) => const _QuietNumbers()),
  _Design('3  Speed strip under the card', below: (context) => const _Strip()),
  _Design('4  Two level bars', inRow: (context) => const _LevelBars()),
  _Design('5  Tab on the card\'s edge', below: (context) => const _HangingTab()),
  _Design('6  Ring', inRow: (context) => const _Ring()),
  _Design('7  Speed in the bar', barEnd: (context) => const _BarSpeed()),
  _Design('8  Sparkline', inRow: (context) => const _Sparkline()),
  _Design('9  Big number', above: (context) => const _Hero()),
  _Design('10  Two chips', above: (context) => const _Chips()),
  _Design('Our capsule in spot 10', above: (context) => const _OurCapsule()),
];

/// 1: a glass speedometer above the card: the download's needle on an arc, the upload under it.
class _Gauge extends StatelessWidget {
  const _Gauge();

  @override
  Widget build(BuildContext context) => GlassSurface(
    width: 150,
    height: 104,
    borderRadius: 28,
    child: !_tested
        ? Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                top: 10,
                child: CustomPaint(
                  size: const Size(120, 64),
                  painter: _ArcPainter(0, Theme.of(context).colorScheme.onSurface, _green(context)),
                ),
              ),
              Positioned(top: 44, child: _gauge(context, size: 26)),
              Positioned(bottom: 12, child: Text('Test speed', style: Theme.of(context).textTheme.labelLarge)),
            ],
          )
        : Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                top: 10,
                child: CustomPaint(
                  size: const Size(120, 64),
                  painter: _ArcPainter(
                    _down * 8 / 1e6 / _scale,
                    Theme.of(context).colorScheme.onSurface,
                    _green(context),
                  ),
                ),
              ),
              Positioned(
                top: 38,
                child: Column(
                  children: [
                    Text(formatMbps(_down), style: _num(context, 24, color: _green(context))),
                    Text('Mbps', style: _small(context)),
                  ],
                ),
              ),
              Positioned(bottom: 8, child: _dir(context, up: true, size: 12, arrow: 10)),
            ],
          ),
  );
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.share, this.track, this.color);
  final double share;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(center: Offset(size.width / 2, size.height), radius: size.height - 4);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawArc(rect, math.pi, math.pi, false, pen..color = track.withValues(alpha: .12))
      ..drawArc(rect, math.pi, math.pi * share.clamp(0, 1), false, pen..color = color);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.share != share;
}

/// 2: no box at all: the download large, the upload small under it, at the row's end.
class _QuietNumbers extends StatelessWidget {
  const _QuietNumbers();

  @override
  Widget build(BuildContext context) => !_tested
      ? _cta(context, 'Speed')
      : Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _dir(context, up: false, size: 17),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dir(context, up: true, size: 11, arrow: 9),
                const SizedBox(width: 4),
                Text('Mbps', style: _small(context)),
              ],
            ),
          ],
        );
}

/// 3: a slim glass strip joined under the card: label, both speeds, and a retest button.
class _Strip extends StatelessWidget {
  const _Strip();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: GlassSurface(
      height: 40,
      borderRadius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(Icons.speed_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text('Speed', style: Theme.of(context).textTheme.labelLarge),
          const Spacer(),
          if (!_tested) ...[
            Text('Tap to test', style: _small(context)),
            const SizedBox(width: 8),
            Icon(Icons.play_arrow_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
          ] else ...[
            _dir(context, up: false),
            const SizedBox(width: 14),
            _dir(context, up: true),
            const SizedBox(width: 6),
            Text('Mbps', style: _small(context)),
            const SizedBox(width: 10),
            Icon(Icons.refresh_rounded, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ],
      ),
    ),
  );
}

/// 4: two thin level bars, filled to each speed, with the numbers beside them.
class _LevelBars extends StatelessWidget {
  const _LevelBars();

  @override
  Widget build(BuildContext context) {
    Widget bar(bool up) {
      final share = _tested ? ((up ? _up : _down) * 8 / 1e6 / _scale).clamp(.06, 1.0) : 0.0;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: share,
              child: Container(
                decoration: BoxDecoration(color: _green(context), borderRadius: BorderRadius.circular(3)),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 28,
            child: _tested
                ? Text(formatMbps(up ? _up : _down), style: _num(context, 12, color: _green(context)))
                : Text('–', style: _num(context, 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ],
      );
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [bar(false), const SizedBox(height: 7), bar(true)]);
  }
}

/// 5: a small glass tab hanging from the card's bottom edge.
class _HangingTab extends StatelessWidget {
  const _HangingTab();

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: const Offset(0, -16),
    child: GlassSurface(
      height: 30,
      borderRadius: 15,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: !_tested
          ? Center(widthFactor: 1, child: _cta(context, 'Test speed', icon: 15))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                _dir(context, up: false, size: 13, arrow: 10),
                const SizedBox(width: 10),
                _dir(context, up: true, size: 13, arrow: 10),
                const SizedBox(width: 5),
                Text('Mbps', style: _small(context)),
              ],
            ),
    ),
  );
}

/// 6: a ring filled to the download speed, its number inside, the upload under it.
class _Ring extends StatelessWidget {
  const _Ring();

  @override
  Widget build(BuildContext context) => !_tested
      ? SizedBox.square(
          dimension: 44,
          child: CustomPaint(
            painter: _RingPainter(0, _green(context)),
            child: Center(child: _gauge(context)),
          ),
        )
      : Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _dir(context, up: true, size: 11, arrow: 9),
                Text('Mbps', style: _small(context)),
              ],
            ),
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: 44,
              child: CustomPaint(
                painter: _RingPainter(_down * 8 / 1e6 / _scale, _green(context)),
                child: Center(
                  child: Text(formatMbps(_down), style: _num(context, 13, color: _green(context))),
                ),
              ),
            ),
          ],
        );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.share, this.color);
  final double share;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawArc(rect, 0, 2 * math.pi, false, pen..color = Colors.white.withValues(alpha: .1))
      ..drawArc(rect, -math.pi / 2, 2 * math.pi * share.clamp(0, 1), false, pen..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.share != share;
}

/// 7: the bar's right button shows the speed, and a tap tests it.
class _BarSpeed extends StatelessWidget {
  const _BarSpeed();

  @override
  Widget build(BuildContext context) => _Round(
    child: !_tested
        ? _gauge(context, size: 28)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(formatMbps(_down), style: _num(context, 18, color: _green(context))),
              const SizedBox(height: 2),
              Text('Mbps', style: _small(context)?.copyWith(fontSize: 9)),
            ],
          ),
  );
}

/// 8: a sparkline of the last tests, with the latest download above it.
class _Sparkline extends StatelessWidget {
  const _Sparkline();

  @override
  Widget build(BuildContext context) => !_tested
      ? Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _cta(context, 'Speed', icon: 14),
            const SizedBox(height: 6),
            Container(width: 64, height: 1.5, color: Colors.white.withValues(alpha: .15)),
          ],
        )
      : Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dir(context, up: false, size: 14, arrow: 10),
                const SizedBox(width: 3),
                Text('Mbps', style: _small(context)),
              ],
            ),
            const SizedBox(height: 4),
            CustomPaint(size: const Size(64, 18), painter: _SparkPainter(_green(context))),
          ],
        );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.color);
  final Color color;

  static const _runs = [62.0, 80, 71, 95, 88, 102];

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      for (final (i, v) in _runs.indexed)
        Offset(size.width * i / (_runs.length - 1), size.height * (1 - (v - 55) / 55)),
    ];
    final line = Path()..addPolygon(points, false);
    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas
      ..drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: .35), color.withValues(alpha: 0)],
          ).createShader(Offset.zero & size),
      )
      ..drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round,
      )
      ..drawCircle(points.last, 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.color != color;
}

/// 9: home's free space holds the result large, with a small "test again" pill.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!_tested)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('—', style: _num(context, 44, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Text('Speed not tested yet', style: _small(context)),
            ],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(formatMbps(_down), style: _num(context, 44, color: _green(context))),
                  const SizedBox(width: 6),
                  Text('Mbps ↓', style: Theme.of(context).textTheme.titleSmall),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _dir(context, up: true, size: 13, arrow: 11),
                  const SizedBox(width: 4),
                  Text('Mbps upload', style: _small(context)),
                ],
              ),
            ],
          ),
        const Spacer(),
        GlassSurface(
          height: 32,
          borderRadius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _tested ? Icons.refresh_rounded : Icons.speed_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Text(_tested ? 'Test again' : 'Test speed', style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 10: two glass chips above the card's end, one per direction, and a round retest button.
class _Chips extends StatelessWidget {
  const _Chips();

  @override
  Widget build(BuildContext context) {
    Widget chip(bool up) => GlassSurface(
      height: 34,
      borderRadius: 17,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dir(context, up: up, size: 14, arrow: 11),
          const SizedBox(width: 4),
          Text('Mbps', style: _small(context)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (!_tested)
            GlassSurface(
              height: 34,
              borderRadius: 17,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(widthFactor: 1, child: _cta(context, 'Test speed', icon: 15)),
            )
          else ...[
            chip(false),
            const SizedBox(width: 8),
            chip(true),
            const SizedBox(width: 8),
            GlassSurface(
              width: 34,
              height: 34,
              borderRadius: 17,
              child: Icon(Icons.refresh_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Our own speed capsule (the gauge icon, then ↑ | ↓ with Mbps below), where idea 10's chips sit:
/// above the card, its end on the card's end.
class _OurCapsule extends StatelessWidget {
  const _OurCapsule();

  @override
  // the card keeps a 16 px margin above its glass; the capsule reaches into it, 8 px from the glass
  // (Material's gap between related items)
  Widget build(BuildContext context) => Transform.translate(
    offset: const Offset(0, 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: SpeedCapsule(
          upload: _failed
              ? -1
              : _tested
              ? _up
              : 0,
          uploadTesting: _testing,
          uploadCached: false,
          download: _failed
              ? -1
              : _tested
              ? _down
              : 0,
          downloadTesting: _testing,
          downloadCached: false,
          onTest: () {},
          chevron: false,
        ),
      ),
    ),
  );
}

// ---------- ten looks for the speed test before its first run ----------

/// Puts a not-tested look where our numbers sit: 8 px above the card's glass, its end 14 px in from
/// the glass's end, like the tested numbers.
class _Spot extends StatelessWidget {
  const _Spot(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: const Offset(0, 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 40, 0),
      child: Align(alignment: AlignmentDirectional.centerEnd, child: child),
    ),
  );
}

Color _primary(BuildContext context) => Theme.of(context).colorScheme.primary;
Color _muted(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

/// U1: the tested layout with dashes in it, so nothing moves when the numbers arrive.
Widget _u1Ghost(BuildContext context) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.end,
  children: [
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.arrow_downward_rounded, size: 12, color: _muted(context)),
        const SizedBox(width: 2),
        Text('– –', style: _num(context, 17, color: _muted(context).withValues(alpha: .6))),
      ],
    ),
    const SizedBox(height: 3),
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.play_arrow_rounded, size: 12, color: _primary(context)),
        const SizedBox(width: 2),
        Text(
          'Test',
          style: _small(context)?.copyWith(color: _primary(context), fontWeight: FontWeight.w700),
        ),
      ],
    ),
  ],
);

/// U2: the gauge alone, no pill, with a soft ring around it as if it breathes.
Widget _u2Breath(BuildContext context) => Container(
  width: 34,
  height: 34,
  decoration: BoxDecoration(
    shape: BoxShape.circle,
    border: Border.all(color: _primary(context).withValues(alpha: .35), width: 1.5),
    boxShadow: [BoxShadow(color: _primary(context).withValues(alpha: .18), blurRadius: 12)],
  ),
  child: Icon(Icons.speed_rounded, size: 20, color: _primary(context)),
);

/// U3: plain text, a link: "Test speed ›".
Widget _u3Link(BuildContext context) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Text(
      'Test speed',
      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: _primary(context), fontWeight: FontWeight.w600),
    ),
    Icon(Icons.chevron_right_rounded, size: 18, color: _primary(context)),
  ],
);

/// U4: a small round glass button, like the bar's round buttons, the gauge in it.
Widget _u4Round(BuildContext context) => GlassSurface(
  width: 36,
  height: 36,
  borderRadius: 18,
  child: Icon(Icons.speed_rounded, size: 20, color: _primary(context)),
);

/// U5: a tiny empty speedometer, its needle resting at zero.
Widget _u5Dial(BuildContext context) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.end,
  children: [
    CustomPaint(size: const Size(40, 22), painter: _DialPainter(_muted(context), _primary(context))),
    const SizedBox(height: 3),
    Text('Mbps', style: _small(context)?.copyWith(fontSize: 10)),
  ],
);

class _DialPainter extends CustomPainter {
  _DialPainter(this.track, this.needle);
  final Color track;
  final Color needle;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height - 1);
    final r = size.width / 2 - 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
      rect,
      math.pi,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = track.withValues(alpha: .35),
    );
    // ticks
    for (var i = 0; i <= 4; i++) {
      final a = math.pi + math.pi * i / 4;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        c + d * (r - 6),
        c + d * (r - 4),
        Paint()
          ..strokeWidth = 1
          ..color = track.withValues(alpha: .5),
      );
    }
    // the needle at zero, slightly lifted
    const a = math.pi + .25;
    canvas
      ..drawLine(
        c,
        c + Offset(math.cos(a), math.sin(a)) * (r - 5),
        Paint()
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = needle,
      )
      ..drawCircle(c, 2.5, Paint()..color = needle);
  }

  @override
  bool shouldRepaint(_DialPainter old) => false;
}

/// U6: the gauge where the download number goes; the second line asks.
Widget _u6InPlace(BuildContext context) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.end,
  children: [
    Icon(Icons.speed_rounded, size: 20, color: _primary(context)),
    const SizedBox(height: 2),
    Text('Tap to test', style: _small(context)?.copyWith(fontSize: 10)),
  ],
);

/// U7: an outline pill drawn in dashes, a placeholder waiting to be filled.
Widget _u7Dashed(BuildContext context) => CustomPaint(
  painter: _DashedPillPainter(_primary(context).withValues(alpha: .6)),
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.speed_rounded, size: 16, color: _primary(context)),
        const SizedBox(width: 5),
        Text('Speed', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: _primary(context))),
      ],
    ),
  ),
);

class _DashedPillPainter extends CustomPainter {
  _DashedPillPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2)));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 3.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPillPainter old) => old.color != color;
}

/// U8: like a bar tab: the gauge in a tonal circle, its name under it.
Widget _u8Tab(BuildContext context) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _primary(context).withValues(alpha: .16)),
      child: Icon(Icons.speed_rounded, size: 18, color: _primary(context)),
    ),
    const SizedBox(height: 3),
    Text('Speed', style: _small(context)?.copyWith(fontSize: 10)),
  ],
);

/// U9: empty signal bars, rising, waiting to be filled by the test.
Widget _u9Bars(BuildContext context) => Row(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.end,
  children: [
    for (final h in [6.0, 10.0, 14.0, 18.0])
      Container(
        width: 4,
        height: h,
        margin: const EdgeInsets.only(left: 2.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          color: _primary(context).withValues(alpha: h == 6 ? .9 : .3),
        ),
      ),
    const SizedBox(width: 7),
    Text('Speed', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: _primary(context))),
  ],
);

/// U10: a glass tab grown from the card's top edge, the gauge in it, like a folder's tab.
Widget _u10Tab(BuildContext context) => _tab(Icon(Icons.speed_rounded, size: 18, color: _primary(context)));

/// The card-edge tab around any content.
Widget _tab(Widget child, {double width = 56}) => Transform.translate(
  offset: const Offset(0, 9),
  child: ClipRRect(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
    child: SizedBox(
      width: width,
      height: 30,
      child: Stack(
        children: [
          const Positioned.fill(bottom: -14, child: GlassSurface(borderRadius: 14, child: SizedBox.expand())),
          Center(child: child),
        ],
      ),
    ),
  ),
);

Widget _icon(BuildContext c, IconData i, {double size = 18}) => Icon(i, size: size, color: _primary(c));

Widget _iconText(BuildContext c, IconData? i, String text) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    if (i != null) ...[_icon(c, i, size: 16), const SizedBox(width: 4)],
    Text(
      text,
      style: Theme.of(c).textTheme.labelMedium?.copyWith(color: _primary(c), fontWeight: FontWeight.w600),
    ),
  ],
);

/// Two thin arrows, down and up, side by side: the two numbers to come.
Widget _arrows(BuildContext c) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    _icon(c, Icons.south_rounded, size: 15),
    Transform.translate(offset: const Offset(-3, 0), child: _icon(c, Icons.north_rounded, size: 15)),
  ],
);

/// A tab whose size follows its content.
Widget _tabFit(Widget child, {double height = 30}) => Transform.translate(
  offset: const Offset(0, 9),
  child: ClipRRect(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
    child: Stack(
      children: [
        const Positioned.fill(bottom: -14, child: GlassSurface(borderRadius: 14, child: SizedBox.expand())),
        SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Center(widthFactor: 1, child: child),
          ),
        ),
      ],
    ),
  ),
);

/// One half of the numbers: arrow, then the number, dots or failed dash, all sized by [size].
Widget _half(BuildContext c, {required bool up, required String state, required double size}) {
  final s = Theme.of(c).colorScheme;
  final Widget value = switch (state) {
    'testing' => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 2; i++)
          Container(
            width: size * .28,
            height: size * .28,
            margin: EdgeInsets.symmetric(horizontal: size * .1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.primary.withValues(alpha: i == 0 ? 1 : .35),
            ),
          ),
      ],
    ),
    'failed' => Container(
      width: size * .7,
      height: size * .13,
      decoration: BoxDecoration(color: s.error, borderRadius: BorderRadius.circular(2)),
    ),
    _ => Text(formatMbps(up ? _up : _down), style: _num(c, size, color: _green(c))),
  };
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: size * .7, color: s.onSurfaceVariant),
      const SizedBox(width: 2),
      value,
    ],
  );
}

Widget _unit(BuildContext c) => Text('Mbps', style: _small(c)?.copyWith(fontSize: 10, height: 1));

/// A: two lines, as now: download large, upload small with the unit.
Widget _twoLines(BuildContext c, String state) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.end,
  children: [
    _half(c, up: false, state: state, size: 17),
    const SizedBox(height: 3),
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _half(c, up: true, state: state, size: 11),
        const SizedBox(width: 4),
        _unit(c),
      ],
    ),
  ],
);

/// B: one line: download, upload, unit.
Widget _oneLine(BuildContext c, String state) => Row(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.center,
  children: [
    _half(c, up: false, state: state, size: 13),
    const SizedBox(width: 8),
    _half(c, up: true, state: state, size: 13),
    const SizedBox(width: 4),
    Text('Mbps', style: _small(c)?.copyWith(fontSize: 8.5, height: 1)),
  ],
);

Widget _dialTab(BuildContext c) =>
    _tab(CustomPaint(size: const Size(26, 15), painter: _DialPainter(_muted(c), _primary(c))));

final _tabStates = <_Design>[
  _Design('B  not tested', above: (c) => _Spot(_dialTab(c))),
  _Design('B  testing', above: (c) => _Spot(_tabFit(_oneLine(c, 'testing')))),
  _Design('B  tested', above: (c) => _Spot(_tabFit(_oneLine(c, 'tested')))),
  _Design('B  failed', above: (c) => _Spot(_tabFit(_oneLine(c, 'failed')))),
];

final _tabs10 = <_Design>[
  _Design('T1  Network check', above: (c) => _Spot(_tab(_icon(c, Icons.network_check_rounded)))),
  _Design('T2  Bolt', above: (c) => _Spot(_tab(_icon(c, Icons.bolt_rounded, size: 20)))),
  _Design('T3  Word only', above: (c) => _Spot(_tab(_iconText(c, null, 'Speed'), width: 66))),
  _Design('T4  Down + up arrows', above: (c) => _Spot(_tab(_arrows(c)))),
  _Design(
    'T5  Arrows + Speed',
    above: (c) => _Spot(
      _tab(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [_arrows(c), const SizedBox(width: 2), _iconText(c, null, 'Speed')],
        ),
        width: 84,
      ),
    ),
  ),
  _Design('T6  Play + Speed', above: (c) => _Spot(_tab(_iconText(c, Icons.play_arrow_rounded, 'Speed'), width: 80))),
  _Design(
    'T7  Mini dial',
    above: (c) => _Spot(_tab(CustomPaint(size: const Size(26, 15), painter: _DialPainter(_muted(c), _primary(c))))),
  ),
  _Design('T8  Signal bars', above: (c) => _Spot(_tab(_icon(c, Icons.signal_cellular_alt_rounded)))),
  _Design('T9  Swap arrows', above: (c) => _Spot(_tab(_icon(c, Icons.swap_vert_rounded, size: 20)))),
  _Design('T10  Rocket', above: (c) => _Spot(_tab(_icon(c, Icons.rocket_launch_rounded, size: 17)))),
];

final _untested = <_Design>[
  _Design('U1  Ghost numbers', above: (c) => _Spot(_u1Ghost(c))),
  _Design('U2  Breathing gauge', above: (c) => _Spot(_u2Breath(c))),
  _Design('U3  Text link', above: (c) => _Spot(_u3Link(c))),
  _Design('U4  Round glass button', above: (c) => _Spot(_u4Round(c))),
  _Design('U5  Empty dial', above: (c) => _Spot(_u5Dial(c))),
  _Design('U6  Gauge in the number\'s place', above: (c) => _Spot(_u6InPlace(c))),
  _Design('U7  Dashed placeholder', above: (c) => _Spot(_u7Dashed(c))),
  _Design('U8  Like a bar tab', above: (c) => _Spot(_u8Tab(c))),
  _Design('U9  Empty signal bars', above: (c) => _Spot(_u9Bars(c))),
  _Design('U10  Tab on the card\'s edge', above: (c) => _Spot(_u10Tab(c))),
];

// ---------- the card-edge speed tab, animated ----------

/// The tab's state in the video: untested, testing, tested or failed.
final _tabState = ValueNotifier('untested');

/// The speed tab on the card's edge: the dial before the first test, then one row with both
/// directions: arrows on top, numbers in the middle, the unit at the bottom.
class _TabSpeed extends StatefulWidget {
  const _TabSpeed({this.arrow, this.fixed, this.pill = false});

  /// Draws one direction's arrow; null = the plain arrow icons.
  final Widget Function(BuildContext context, bool up)? arrow;

  /// A state that stays, instead of following [_tabState].
  final String? fixed;

  /// A pill like the ping's, instead of the tab on the card's edge.
  final bool pill;

  @override
  State<_TabSpeed> createState() => _TabSpeedState();
}

class _TabSpeedState extends State<_TabSpeed> with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  Widget _value(BuildContext c, String state, bool up) {
    final s = Theme.of(c).colorScheme;
    const size = 13.0;
    return switch (state) {
      'testing' => AnimatedBuilder(
        animation: _clock,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 2; i++)
              Container(
                width: size * .28,
                height: size * .28,
                margin: const EdgeInsets.symmetric(horizontal: size * .1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: s.primary.withValues(
                    alpha: .3 + .7 * ((math.sin(_clock.value * 2 * math.pi - i * math.pi) + 1) / 2),
                  ),
                ),
              ),
          ],
        ),
      ),
      'failed' => Container(
        width: size * .7,
        height: size * .13,
        decoration: BoxDecoration(color: s.error, borderRadius: BorderRadius.circular(2)),
      ),
      _ => Text(formatMbps(up ? _up : _down), style: _num(c, size, color: _green(c))),
    };
  }

  Widget _row(BuildContext c, String state) {
    final muted = Theme.of(c).colorScheme.onSurfaceVariant;
    Widget arrow(bool up) => Align(
      alignment: Alignment.topCenter,
      widthFactor: 1,
      child:
          widget.arrow?.call(c, up) ??
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: CustomPaint(size: const Size(7, 5.5), painter: _TrianglePainter(up, muted)),
          ),
    );
    Widget value(bool up) => Align(widthFactor: 1, child: _value(c, state, up));
    return SizedBox(
      height: 15,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          arrow(false),
          const SizedBox(width: 2),
          value(false),
          const SizedBox(width: 8),
          arrow(true),
          const SizedBox(width: 2),
          value(true),
          const SizedBox(width: 4),
          Align(
            alignment: Alignment.bottomCenter,
            widthFactor: 1,
            child: Text('Mbps', style: _small(c)?.copyWith(fontSize: 7.5, height: 1)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _tabState,
    builder: (context, followed, _) {
      final state = widget.fixed ?? followed;
      final Widget content = state == 'untested'
          // the dial's drawing sits low in its box (the needle's hub is at the bottom); lift it so
          // its ink is centred
          ? Transform.translate(
              key: const ValueKey('dial'),
              offset: const Offset(0, -1.5),
              child: CustomPaint(size: const Size(26, 15), painter: _DialPainter(_muted(context), _primary(context))),
            )
          : KeyedSubtree(key: ValueKey(state), child: _row(context, state));
      if (widget.pill) {
        // the ping pill's look: 36 high, round ends, the same tonal fill
        return Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Center(widthFactor: 1, child: content),
        );
      }
      return Transform.translate(
        offset: const Offset(0, 9),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          child: Stack(
            children: [
              const Positioned.fill(bottom: -14, child: GlassSurface(borderRadius: 14, child: SizedBox.expand())),
              SizedBox(
                height: 30,
                // the tab's last pixel lies on the card's glass; centre in what shows above it
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 1),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.centerRight,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      reverseDuration: Duration.zero,
                      layoutBuilder: (current, previous) =>
                          Stack(alignment: Alignment.center, children: [...previous, ?current]),
                      child: Center(key: content.key, widthFactor: 1, child: content),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

const _tabTimeline = [('untested', 1.4), ('testing', 2.4), ('tested', 2.2), ('testing', 1.6), ('failed', 1.8)];

// ---------- ten looks for the up and down arrows ----------

/// Each direction's own color, as speed tests often do: download cyan, upload violet.
const _downColor = Color(0xFF4FC3F7);
const _upColor = Color(0xFFCE93D8);
Color _dirColor(bool up) => up ? _upColor : _downColor;

/// A filled triangle pointing the way the data goes.
class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.up, this.color);
  final bool up;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = up
        ? (Path()
            ..moveTo(w / 2, 0)
            ..lineTo(w, h)
            ..lineTo(0, h))
        : (Path()
            ..moveTo(0, 0)
            ..lineTo(w, 0)
            ..lineTo(w / 2, h));
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => false;
}

/// A chevron drawn in light, with a soft glow of its own color.
class _CaretPainter extends CustomPainter {
  _CaretPainter(this.up, this.color);
  final bool up;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = up
        ? (Path()
            ..moveTo(1, h - 2)
            ..lineTo(w / 2, 2)
            ..lineTo(w - 1, h - 2))
        : (Path()
            ..moveTo(1, 2)
            ..lineTo(w / 2, h - 2)
            ..lineTo(w - 1, 2));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..drawPath(
        path,
        stroke
          ..strokeWidth = 4
          ..color = color.withValues(alpha: .35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 1.8
          ..color = color,
      );
  }

  @override
  bool shouldRepaint(_CaretPainter old) => false;
}

IconData _arrowIcon(bool up) => up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded;

final _arrows10 = <(String, Widget Function(BuildContext, bool))>[
  (
    'A1  Small triangles',
    (c, up) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: CustomPaint(size: const Size(7, 5.5), painter: _TrianglePainter(up, _muted(c))),
    ),
  ),
  ('A2  Arrows in their own colors', (c, up) => Icon(_arrowIcon(up), size: 11, color: _dirColor(up))),
  (
    'A3  Arrow in a tonal circle',
    (c, up) => Container(
      width: 13,
      height: 13,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _dirColor(up).withValues(alpha: .2)),
      child: Icon(_arrowIcon(up), size: 9, color: _dirColor(up)),
    ),
  ),
  (
    'A4  Double chevrons',
    (c, up) => Icon(
      up ? Icons.keyboard_double_arrow_up_rounded : Icons.keyboard_double_arrow_down_rounded,
      size: 12,
      color: _dirColor(up),
    ),
  ),
  (
    'A5  Into and out of the tray',
    (c, up) => Icon(up ? Icons.upload_rounded : Icons.download_rounded, size: 12, color: _dirColor(up)),
  ),
  (
    'A6  To the line',
    (c, up) => Icon(
      up ? Icons.vertical_align_top_rounded : Icons.vertical_align_bottom_rounded,
      size: 12,
      color: _dirColor(up),
    ),
  ),
  (
    'A7  Slim north and south',
    (c, up) => Icon(up ? Icons.north_rounded : Icons.south_rounded, size: 11, color: _dirColor(up)),
  ),
  (
    'A8  Filled circles',
    (c, up) =>
        Icon(up ? Icons.arrow_circle_up_rounded : Icons.arrow_circle_down_rounded, size: 13, color: _dirColor(up)),
  ),
  (
    'A9  Glowing carets',
    (c, up) => Padding(
      padding: const EdgeInsets.only(top: 1),
      child: CustomPaint(size: const Size(9, 7), painter: _CaretPainter(up, _dirColor(up))),
    ),
  ),
  (
    'A10  Key caps',
    (c, up) => Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(3.5), color: _dirColor(up)),
      child: Icon(_arrowIcon(up), size: 9, color: Colors.black.withValues(alpha: .75)),
    ),
  ),
];

/// The card's top with the tab on it, on home's background: enough to judge the arrows up close.
class _CardTop extends StatelessWidget {
  const _CardTop(this.arrow);
  final Widget Function(BuildContext, bool) arrow;

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme(),
    child: Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: _phone.width,
          height: 120,
          child: Stack(
            children: [
              const Positioned.fill(child: _HomeBackground()),
              Positioned(
                left: 0,
                right: 0,
                top: 18,
                child: Column(
                  children: [
                    _Spot(_TabSpeed(arrow: arrow, fixed: 'tested')),
                    const _GlassCard(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---------- the speed beside the ping, under the connect button ----------

class _Stats extends StatsNotifier {
  // some traffic, so the connected button shows its light
  @override
  Stream<SystemInfo> build() => Stream.value(SystemInfo(downlink: Int64(260000), uplink: Int64(40000)));
}

/// Home in full: the connect button with its status and, under it, the ping pill with the speed
/// pill beside it; then the card (no tab) and the bar.
class _HomePhone extends StatelessWidget {
  const _HomePhone(this.state, [this.status, this.tab = false]);
  final String state;

  /// The speed as the tab on the card's edge, the real ping pill alone under the button.
  final bool tab;

  /// Draws the ping and the speed together under the button; null = the ping pill and a speed pill.
  final Widget Function(BuildContext, String state)? status;

  static const size = Size(380, 820);

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme(),
    child: Material(
      type: MaterialType.transparency,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: const Size(380, 900)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              children: [
                const Positioned.fill(child: _HomeBackground()),
                Positioned.fill(
                  bottom: 18,
                  child: BackdropGroup(
                    child: Column(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const ConnectionButton(),
                              if (tab)
                                const ActiveProxyDelayIndicator()
                              else if (status case final status?)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Builder(builder: (c) => status(c, state)),
                                )
                              else
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const ActiveProxyDelayIndicator(),
                                    const SizedBox(width: 8),
                                    _TabSpeed(fixed: state, pill: true),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        if (tab) _Spot(_TabSpeed(fixed: state)),
                        const _GlassCard(),
                        const SizedBox(height: 4),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _Round(child: Icon(Icons.add_rounded, size: 28)),
                            SizedBox(width: 10),
                            _Bar(),
                            SizedBox(width: 10),
                            _Round(child: Icon(Icons.tune_rounded, size: 28)),
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

// ---------- ten glass looks for the ping and the speed together ----------

const _pingMs = 230;

Widget _ms(BuildContext c, {double size = 15}) => Text.rich(
  TextSpan(
    children: [
      TextSpan(
        text: '$_pingMs',
        style: _num(c, size, color: Theme.of(c).colorScheme.onSurface),
      ),
      TextSpan(
        text: ' ms',
        style: _small(c)?.copyWith(fontSize: size * .72, height: 1),
      ),
    ],
  ),
);

Widget _wifi(BuildContext c, {double size = 18}) => Icon(Icons.wifi_rounded, size: size, color: _green(c));

/// Two dots, one lit, the other fading: a still of the testing animation, sized by the number.
Widget _stillDots(BuildContext c, double size) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    for (final a in [1.0, .35])
      Container(
        width: size * .28,
        height: size * .28,
        margin: EdgeInsets.symmetric(horizontal: size * .1),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _primary(c).withValues(alpha: a),
        ),
      ),
  ],
);

/// One direction's value in a state: the number, the dots, a red dash, or a gray dash before a test.
Widget _val(BuildContext c, String state, bool up, {double size = 15}) => switch (state) {
  'testing' => _stillDots(c, size),
  'failed' => Container(
    width: size * .7,
    height: size * .13,
    decoration: BoxDecoration(color: Theme.of(c).colorScheme.error, borderRadius: BorderRadius.circular(2)),
  ),
  'untested' => Text('–', style: _num(c, size, color: _muted(c).withValues(alpha: .6))),
  _ => Text(formatMbps(up ? _up : _down), style: _num(c, size, color: _green(c))),
};

/// A1: a small gray triangle, sized by [size] like an icon would be.
Widget _arr(BuildContext c, bool up, {double size = 12}) =>
    CustomPaint(size: Size(size * .62, size * .48), painter: _TrianglePainter(up, _muted(c)));

Widget _mbps(BuildContext c, {double size = 9}) => Text('Mbps', style: _small(c)?.copyWith(fontSize: size, height: 1));

Widget _dialMark(BuildContext c, {double width = 26}) =>
    CustomPaint(size: Size(width, width * 15 / 26), painter: _DialPainter(_muted(c), _primary(c)));

/// The dial and the word: the call to test before the first run.
Widget _testCall(BuildContext c, {double dial = 24}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Transform.translate(
      offset: const Offset(0, -1.5),
      child: _dialMark(c, width: dial),
    ),
    const SizedBox(width: 6),
    Text(
      'Speed',
      style: Theme.of(c).textTheme.labelLarge?.copyWith(color: _primary(c), fontWeight: FontWeight.w600),
    ),
  ],
);

/// Both directions in one line, or the call to test before the first run.
Widget _speedLine(BuildContext c, String state, {double size = 15}) => state == 'untested'
    ? _testCall(c)
    : Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _arr(c, false, size: size * .8),
          const SizedBox(width: 2),
          _val(c, state, false, size: size),
          SizedBox(width: size * .55),
          _arr(c, true, size: size * .8),
          const SizedBox(width: 2),
          _val(c, state, true, size: size),
          const SizedBox(width: 4),
          _mbps(c, size: size * .6),
        ],
      );

Widget _vDivider({double height = 18, double margin = 12}) => Container(
  width: 1,
  height: height,
  margin: EdgeInsets.symmetric(horizontal: margin),
  color: Colors.white.withValues(alpha: .14),
);

/// A tile: an icon or arrow on top, the value, its unit.
Widget _tile(BuildContext c, Widget top, Widget value, String unit) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    SizedBox(height: 16, child: Center(child: top)),
    const SizedBox(height: 4),
    SizedBox(height: 20, child: Center(child: value)),
    const SizedBox(height: 3),
    Text(unit, style: _small(c)?.copyWith(fontSize: 10, height: 1)),
  ],
);

class _SignalBarsPainter extends CustomPainter {
  _SignalBarsPainter(this.lit, this.on, this.off);
  final int lit;
  final Color on;
  final Color off;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 4;
    final w = (size.width - (n - 1) * 2) / n;
    for (var i = 0; i < n; i++) {
      final h = size.height * (i + 1) / n;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(i * (w + 2), size.height - h, w, h), const Radius.circular(1.5)),
        Paint()..color = i < lit ? on : off,
      );
    }
  }

  @override
  bool shouldRepaint(_SignalBarsPainter old) => false;
}

Color _err(BuildContext c) => Theme.of(c).colorScheme.error;

/// The dead pick's mark: a crossed-out wifi in a red circle.
Widget _deadMark(BuildContext c, {double size = 28}) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(color: _err(c).withValues(alpha: .18), shape: BoxShape.circle),
  child: Center(
    child: Icon(Icons.wifi_off_rounded, size: size * .57, color: _err(c)),
  ),
);

/// The offer: a bolt and "Switch to fastest", in green.
Widget _offer(BuildContext c, {double size = 14, bool twoLines = false}) {
  final style = Theme.of(
    c,
  ).textTheme.titleSmall?.copyWith(fontSize: size, fontWeight: FontWeight.w600, color: _green(c));
  final bolt = Icon(Icons.bolt_rounded, size: size + 4, color: _green(c));
  return twoLines
      ? Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            bolt,
            const SizedBox(height: 2),
            Text('Switch to fastest', style: style),
          ],
        )
      : Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            bolt,
            const SizedBox(width: 4),
            Text('Switch to fastest', style: style),
          ],
        );
}

/// The ping, or the dead pick with the offer to switch.
Widget _pingPart(BuildContext c, String s) => s == 'dead'
    ? Row(mainAxisSize: MainAxisSize.min, children: [_deadMark(c), const SizedBox(width: 8), _offer(c)])
    : Row(mainAxisSize: MainAxisSize.min, children: [_wifi(c), const SizedBox(width: 6), _ms(c)]);

/// The ping as a tile; a dead pick's tile says so in red.
Widget _pingTile(BuildContext c, String s) => s == 'dead'
    ? _tile(
        c,
        Icon(Icons.wifi_off_rounded, size: 16, color: _err(c)),
        Text('–', style: _num(c, 19, color: _err(c))),
        'Unavailable',
      )
    : _tile(c, _wifi(c, size: 16), Text('$_pingMs', style: _num(c, 19)), 'ms');

/// The speed, or with a dead pick the call to test, faded: nothing to test through.
Widget _speedPart(BuildContext c, String s, {double dial = 24}) =>
    s == 'dead' ? Opacity(opacity: .35, child: _testCall(c, dial: dial)) : _speedLine(c, s);

/// In the tile designs the offer takes the speed's place, in a green-tinted glass.
Widget _offerFill(BuildContext c, double radius) => DecoratedBox(
  decoration: BoxDecoration(color: _green(c).withValues(alpha: .14), borderRadius: BorderRadius.circular(radius)),
  child: Center(child: _offer(c, size: 14, twoLines: true)),
);

final _status10 = <(String, Widget Function(BuildContext, String))>[
  (
    'P2  Twin pills',
    (c, s) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassSurface(
          height: 42,
          borderRadius: 21,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Center(widthFactor: 1, child: _pingPart(c, s)),
        ),
        const SizedBox(width: 8),
        GlassSurface(
          height: 42,
          borderRadius: 21,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Center(widthFactor: 1, child: _speedPart(c, s)),
        ),
      ],
    ),
  ),
  (
    'P4  Three glass tiles',
    (c, s) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassSurface(width: 84, height: 72, borderRadius: 20, child: Center(child: _pingTile(c, s))),
        const SizedBox(width: 8),
        if (s == 'dead')
          GlassSurface(width: 176, height: 72, borderRadius: 20, child: _offerFill(c, 20))
        else if (s == 'untested')
          GlassSurface(width: 176, height: 72, borderRadius: 20, child: Center(child: _speedPart(c, s, dial: 30)))
        else
          for (final up in [false, true]) ...[
            GlassSurface(
              width: 84,
              height: 72,
              borderRadius: 20,
              child: Center(child: _tile(c, _arr(c, up, size: 15), _val(c, s, up, size: 19), 'Mbps')),
            ),
            if (!up) const SizedBox(width: 8),
          ],
      ],
    ),
  ),
  (
    'P7  Wide glass panel',
    (c, s) => GlassSurface(
      width: 300,
      height: 76,
      borderRadius: 24,
      child: Row(
        children: [
          Expanded(child: _pingTile(c, s)),
          _vDivider(height: 40, margin: 0),
          if (s == 'dead')
            Expanded(
              flex: 2,
              child: Padding(padding: const EdgeInsets.all(6), child: _offerFill(c, 18)),
            )
          else if (s == 'untested')
            Expanded(flex: 2, child: Center(child: _speedPart(c, s, dial: 30)))
          else
            for (final up in [false, true]) ...[
              Expanded(child: _tile(c, _arr(c, up, size: 15), _val(c, s, up, size: 19), 'Mbps')),
              if (!up) _vDivider(height: 40, margin: 0),
            ],
        ],
      ),
    ),
  ),
  (
    'P10  Quality glow',
    (c, s) {
      final glow = s == 'dead' ? Theme.of(c).colorScheme.error : _green(c);
      return GlassSurface(
        height: 42,
        borderRadius: 21,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(21),
                  gradient: LinearGradient(
                    colors: [glow.withValues(alpha: .28), glow.withValues(alpha: 0)],
                    stops: const [0, .45],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                widthFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s == 'dead')
                      _pingPart(c, s)
                    else ...[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: glow,
                          boxShadow: [BoxShadow(color: glow, blurRadius: 6)],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _ms(c),
                    ],
                    _vDivider(),
                    _speedPart(c, s),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  ),
];

// ---------- P2 and P10, animated between their states ----------

/// The state in the video: untested, testing, tested, failed (the pick works), dead (the pick does
/// not answer, nothing faster does) or offer (the pick does not answer, a faster one does).
final _video = ValueNotifier('untested');

/// How "Switch to fastest" is colored: 0 green text (now), 1 accent text, 2 mint text, 3 white on a
/// green piece, 4 accent on an accent-tinted piece.
var _offerLook = 16;

/// Fade and a slight grow, as the ping pill changes its content today.
Widget _fadeScale(Widget child, Animation<double> a) => FadeTransition(
  opacity: a,
  child: ScaleTransition(scale: Tween(begin: .94, end: 1.0).animate(a), child: child),
);

/// Fade while the width opens or closes from the start: for a part that comes and goes.
/// Only the width opens or closes, no fade: glass under a fade does not show until the fade ends.
Widget _openWidth(Widget child, Animation<double> a) => SizeTransition(
  sizeFactor: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
  axis: Axis.horizontal,
  axisAlignment: -1,
  fixedCrossAxisSizeFactor: 1,
  child: child,
);

Widget _fadeWidth(Widget child, Animation<double> a) => FadeTransition(
  opacity: a,
  // its own height, so the row centres it (otherwise it fills the pill and sits at the top)
  child: SizeTransition(
    sizeFactor: a,
    axis: Axis.horizontal,
    axisAlignment: -1,
    fixedCrossAxisSizeFactor: 1,
    child: child,
  ),
);

Widget _stacked(Widget? current, List<Widget> previous) =>
    Stack(alignment: Alignment.center, children: [...previous, ?current]);

class _LiveStatus extends StatefulWidget {
  const _LiveStatus(this.design, {this.fixed, super.key});

  /// P2, P10, P10s (a space instead of the divider) or P10g (two pills, a gap between).
  final String design;

  /// A state that stays, instead of following [_video].
  final String? fixed;

  @override
  State<_LiveStatus> createState() => _LiveStatusState();
}

class _LiveStatusState extends State<_LiveStatus> with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();

  static const _dur = Duration(milliseconds: 350);

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  Widget _dots(BuildContext c, double size) => AnimatedBuilder(
    animation: _clock,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 2; i++)
          Container(
            width: size * .28,
            height: size * .28,
            margin: EdgeInsets.symmetric(horizontal: size * .1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _primary(
                c,
              ).withValues(alpha: .3 + .7 * ((math.sin(_clock.value * 2 * math.pi - i * math.pi) + 1) / 2)),
            ),
          ),
      ],
    ),
  );

  /// The speed: the dial alone before a test, then both directions in one line.
  Widget _speed(BuildContext c, String s) {
    const size = 15.0;
    if (s == 'untested') {
      return Transform.translate(key: const ValueKey('dial'), offset: const Offset(0, -1.5), child: _dialMark(c));
    }
    Widget value(bool up) => s == 'testing' ? _dots(c, size) : _val(c, s, up, size: size);
    return Row(
      key: ValueKey(s),
      mainAxisSize: MainAxisSize.min,
      children: [
        _arr(c, false, size: size * .8),
        const SizedBox(width: 2),
        value(false),
        const SizedBox(width: size * .55),
        _arr(c, true, size: size * .8),
        const SizedBox(width: 2),
        value(true),
        const SizedBox(width: 4),
        _mbps(c, size: size * .6),
      ],
    );
  }

  /// The ping; or, with a dead pick, "Unavailable", or the offer to switch.
  Widget _ping(BuildContext c, String s, {bool dot = false}) => switch (s) {
    'dead' => Row(
      key: const ValueKey('dead'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.wifi_off_rounded, size: 18, color: _err(c)),
        const SizedBox(width: 6),
        Text(
          'Unavailable',
          style: Theme.of(c).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: _err(c)),
        ),
      ],
    ),
    'offer' => Row(
      key: const ValueKey('offer'),
      mainAxisSize: MainAxisSize.min,
      children: [_deadMark(c), const SizedBox(width: 8), _offer(c)],
    ),
    _ => Row(
      key: const ValueKey('ok'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // with dot (the P10 pills) the glass's own glow says the state: no mark beside the ping
        _wifi(c),
        const SizedBox(width: 6),
        _ms(c),
      ],
    ),
  };

  Widget _switch(Widget child, {Widget Function(Widget, Animation<double>) t = _fadeScale}) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 300),
    switchInCurve: Curves.easeOut,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: t,
    layoutBuilder: _stacked,
    child: child,
  );

  /// The pill's width follows its content.
  Widget _grow(Widget child) => AnimatedSize(duration: _dur, curve: Curves.easeOutCubic, child: child);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _video,
    builder: (c, followed, _) {
      final s = widget.fixed ?? followed;
      final pickDead = s == 'dead' || s == 'offer';
      final pingKey = pickDead ? s : 'ok';
      if (widget.design == 'P2') {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassSurface(
              height: 42,
              borderRadius: 21,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(widthFactor: 1, child: _grow(_switch(_ping(c, pingKey)))),
            ),
            // the speed pill leaves while the pick is dead: nothing to test through
            _grow(
              _switch(
                t: _fadeWidth,
                pickDead
                    ? const SizedBox(key: ValueKey('none'), height: 42)
                    : Padding(
                        key: const ValueKey('speed'),
                        padding: const EdgeInsets.only(left: 8),
                        child: GlassSurface(
                          height: 42,
                          borderRadius: 21,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Center(widthFactor: 1, child: _grow(_switch(_speed(c, s)))),
                        ),
                      ),
              ),
            ),
          ],
        );
      }
      final glow = pickDead ? _err(c) : _green(c);
      final glowFill = Positioned.fill(
        child: AnimatedContainer(
          duration: _dur,
          // the ping's glass stays clear
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(21), color: glow.withValues(alpha: 0)),
        ),
      );
      if (widget.design == 'P10c' || widget.design == 'P10p' || widget.design == 'P10q' || widget.design == 'P10r') {
        // the same pill, cut in two where the divider was: a hairline gap is the divider. Each
        // piece is a whole pill clipped flat on the cut side; with the speed gone the ping's piece
        // grows its round end back.
        // the cut corners round just a little
        const cutRadius = Radius.circular(4);
        Widget piece({
          required bool left,
          required bool cut,
          required Widget child,
          bool glowing = false,
          Color? tint,
          double tintAlpha = .32,
          Color? border,
          Gradient? gradient,
          bool clear = false,
        }) => ClipRRect(
          borderRadius: left
              ? BorderRadius.horizontal(
                  left: const Radius.circular(21),
                  right: cut ? cutRadius : const Radius.circular(21),
                )
              : BorderRadius.horizontal(
                  left: cut ? cutRadius : const Radius.circular(21),
                  right: const Radius.circular(21),
                ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: _dur,
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                left: left || !cut ? 0 : -24,
                right: left && cut ? -24 : 0,
                // clear: the content alone, no glass behind it
                child: clear
                    ? const SizedBox.shrink()
                    : GlassSurface(
                        borderRadius: 21,
                        child: glowing
                            ? Stack(children: [glowFill])
                            : AnimatedContainer(
                                duration: _dur,
                                decoration: BoxDecoration(
                                  // a transparent color would fade the gradient out with it
                                  color: gradient != null
                                      ? null
                                      : tint?.withValues(alpha: tintAlpha) ?? Colors.transparent,
                                  gradient: gradient,
                                  border: border == null ? null : Border.all(color: border, width: 1.2),
                                  borderRadius: BorderRadius.circular(21),
                                ),
                              ),
                      ),
              ),
              SizedBox(
                height: 42,
                child: Padding(
                  padding: EdgeInsets.only(left: left ? 16 : 12, right: left && cut ? 12 : 16),
                  child: Center(widthFactor: 1, child: child),
                ),
              ),
            ],
          ),
        );
        // the offer is cut the same way: the dead mark on the left, what to do on the right
        final offer = s == 'offer';
        // P10p: before a test the speed is the planet round the button, so the pill stays whole
        final unavailable =
            s == 'dead' ||
            (widget.design == 'P10p' && s == 'untested') ||
            ((widget.design == 'P10q' || widget.design == 'P10r') && !offer);
        final white = Theme.of(c).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: Colors.white);
        final greenText = white?.copyWith(color: _green(c));
        const solid = Color(0xFF2E9E5B);
        Widget words(TextStyle? style, {Color? chevron}) => Row(
          key: const ValueKey('offer'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Switch to fastest', style: style),
            if (chevron != null) ...[
              const SizedBox(width: 2),
              Icon(Icons.chevron_right_rounded, size: 20, color: chevron),
            ],
          ],
        );
        // O1 keeps one pill: no right piece
        final onePill = offer && _offerLook == 11;
        final left = !offer
            ? _ping(c, pingKey, dot: true)
            : switch (_offerLook) {
                11 => Row(
                  key: const ValueKey('o1'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _deadMark(c),
                    const SizedBox(width: 10),
                    words(white, chevron: Colors.white70),
                  ],
                ),
                16 => Icon(key: const ValueKey('o6'), Icons.wifi_off_rounded, size: 22, color: _degraded),
                _ => KeyedSubtree(key: const ValueKey('mark'), child: _deadMark(c)),
              };
        final right = !offer
            ? _speed(c, s)
            : switch (_offerLook) {
                12 => words(greenText, chevron: _green(c)),
                13 || 15 => words(white),
                14 => words(greenText),
                16 => Row(
                  key: const ValueKey('swap'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.swap_horiz_rounded, size: 20, color: Colors.white.withValues(alpha: .92)),
                    const SizedBox(width: 6),
                    Text('Switch to fastest', style: white),
                  ],
                ),
                _ => words(white),
              };
        final (Color? tint, double tintAlpha, Color? border, Gradient? gradient) = !offer
            ? (null, 0, null, null)
            : switch (_offerLook) {
                12 => (null, 0, null, null),
                13 => (solid, .92, null, null),
                14 => (null, 0, _green(c).withValues(alpha: .75), null),
                15 => (
                  null,
                  0,
                  null,
                  LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [_green(c).withValues(alpha: .6), _green(c).withValues(alpha: 0)],
                    stops: const [0, .85],
                  ),
                ),
                16 => (_green(c), .2, null, null),
                _ => (solid, .32, null, null),
              };
        // P10p: the result shows bare beside a whole ping pill, no glass of its own
        final bare = widget.design == 'P10p' && !offer;
        // P10p with the offer: the crossed-out wifi alone, then the whole offer pill
        final clearMark =
            (widget.design == 'P10p' || widget.design == 'P10q' || widget.design == 'P10r') &&
            offer &&
            _offerLook == 16;
        return _grow(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              piece(
                left: true,
                cut: !unavailable && !onePill && !bare && !clearMark,
                glowing: true,
                clear: clearMark || (widget.design == 'P10r' && !offer),
                child: _grow(_switch(left)),
              ),
              _switch(
                t: _openWidth,
                unavailable || onePill
                    ? const SizedBox(key: ValueKey('none'), height: 42)
                    : bare
                    ? Padding(
                        key: const ValueKey('bare'),
                        padding: const EdgeInsets.only(left: 12),
                        child: SizedBox(height: 42, child: Center(widthFactor: 1, child: _grow(_switch(right)))),
                      )
                    : Padding(
                        key: const ValueKey('right'),
                        padding: EdgeInsets.only(left: clearMark ? 0 : 3),
                        child: piece(
                          left: false,
                          cut: !clearMark,
                          tint: tint,
                          tintAlpha: tintAlpha,
                          border: border,
                          gradient: gradient,
                          child: _grow(_switch(right)),
                        ),
                      ),
              ),
            ],
          ),
        );
      }
      if (widget.design == 'P10g') {
        // two pills, a gap between: the ping's pill keeps the glow
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassSurface(
              height: 42,
              borderRadius: 21,
              child: Stack(
                children: [
                  glowFill,
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(widthFactor: 1, child: _grow(_switch(_ping(c, pingKey, dot: true)))),
                  ),
                ],
              ),
            ),
            _grow(
              _switch(
                t: _fadeWidth,
                pickDead
                    ? const SizedBox(key: ValueKey('none'), height: 42)
                    : Padding(
                        key: const ValueKey('speed'),
                        padding: const EdgeInsets.only(left: 8),
                        child: GlassSurface(
                          height: 42,
                          borderRadius: 21,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Center(widthFactor: 1, child: _grow(_switch(_speed(c, s)))),
                        ),
                      ),
              ),
            ),
          ],
        );
      }
      return GlassSurface(
        height: 42,
        borderRadius: 21,
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: _dur,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(21),
                  gradient: LinearGradient(
                    colors: [glow.withValues(alpha: .28), glow.withValues(alpha: 0)],
                    stops: const [0, .45],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                widthFactor: 1,
                child: _grow(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _switch(_ping(c, pingKey, dot: true)),
                      _switch(
                        t: _fadeWidth,
                        pickDead
                            ? const SizedBox(key: ValueKey('none'))
                            : Row(
                                key: const ValueKey('speed'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  widget.design == 'P10s' ? const SizedBox(width: 18) : _vDivider(),
                                  _grow(_switch(_speed(c, s))),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// [_LiveStatus] in one state of its own, for stills with several states side by side.
class _FixedStatus extends StatelessWidget {
  const _FixedStatus(this.design, this.state);
  final String design;
  final String state;

  @override
  Widget build(BuildContext context) => _LiveStatus(design, fixed: state);
}

/// Each step and how long it stays. A result goes back to the dial after 10 s.
const _statusTimeline = [
  ('untested', 1.5),
  ('testing', 2.5),
  ('tested', 10.0),
  ('untested', 1.5),
  ('testing', 2.0),
  ('failed', 10.0),
  ('untested', 1.5),
  ('dead', 2.5),
  ('offer', 3.0),
  ('untested', 2.0),
];

// ---------- the sun and its planet ----------

/// The connection in the video: disconnected, connecting, connected or disconnecting.
final _conn = ValueNotifier('disconnected');

/// The status line above the card: its words and color; null while disconnected.
final _line = ValueNotifier<(String, Color)?>(null);

/// The video's clock, in seconds: the button's own animations follow it.
var _fakeNow = 0.0;

class _LiveConn extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() {
    final out = StreamController<ConnectionStatus>();
    void send() => out.add(switch (_conn.value) {
      'connecting' => const Connecting(),
      'waiting' => const Waiting(),
      'connected' => const Connected(),
      'noProxies' => const NoAvailableProxies(),
      'hotReloading' => const HotReloading(),
      'disconnecting' => const Disconnecting(),
      'failed' => const Disconnected(ConnectionFailure.unexpected()),
      _ => const Disconnected(),
    });
    send();
    _conn.addListener(send);
    ref.onDispose(() {
      _conn.removeListener(send);
      out.close();
    });
    return out.stream;
  }
}

/// The speedometer drawn in frosted glass: a bright arc fading down, a needle, a soft shadow under.
class _GlassDialPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final c = Offset(w / 2, size.height * .6);
    final r = w * .36;
    final rect = Rect.fromCircle(center: c, radius: r);
    const start = math.pi * .8;
    const sweep = math.pi * 1.4;
    Paint stroke(double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    // shadow, then the glass, then a thin highlight along its top
    canvas
      ..drawArc(
        rect.shift(const Offset(0, 1.2)),
        start,
        sweep,
        false,
        stroke(w * .1)
          ..color = Colors.black.withValues(alpha: .28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
      )
      ..drawArc(
        rect,
        start,
        sweep,
        false,
        stroke(w * .1)
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white.withValues(alpha: .95), Colors.white.withValues(alpha: .4)],
          ).createShader(rect.inflate(w * .05)),
      )
      ..drawArc(
        rect.deflate(w * .02),
        math.pi * 1.15,
        math.pi * .5,
        false,
        stroke(w * .025)..color = Colors.white.withValues(alpha: .9),
      );
    // the needle, pointing up and right, as if reading a good speed
    const a = -math.pi * .28;
    final tip = c + Offset(math.cos(a), math.sin(a)) * r * .78;
    canvas
      ..drawLine(
        c + const Offset(0, 1.2),
        tip + const Offset(0, 1.2),
        stroke(w * .07)
          ..color = Colors.black.withValues(alpha: .25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2),
      )
      ..drawLine(c, tip, stroke(w * .07)..color = Colors.white.withValues(alpha: .95))
      ..drawCircle(c, w * .085, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_GlassDialPainter old) => false;
}

/// The planet: the glass speedometer alone, nothing behind it.
class _Planet extends StatelessWidget {
  const _Planet();

  @override
  Widget build(BuildContext context) => const _GlassShape(
    _materialSpeed,
    size: _SunState._icon,
    rim: .55,
    tint: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x26FFFFFF), Color(0x0AFFFFFF)],
    ),
  );
}

/// The speedometer's shape: a thick arc open at the bottom, a needle and its hub.
Path _dialShape(Size size) {
  final w = size.width;
  final c = Offset(w / 2, size.height * .6);
  final outer = w * .48;
  final thick = w * .19;
  const start = math.pi * .8;
  const sweep = math.pi * 1.4;
  final arc = Path()
    ..addArc(Rect.fromCircle(center: c, radius: outer), start, sweep)
    ..arcTo(Rect.fromCircle(center: c, radius: outer - thick), start + sweep, -sweep, false)
    ..close();
  // round ends
  Offset at(double a, double r) => c + Offset(math.cos(a), math.sin(a)) * r;
  final mid = outer - thick / 2;
  final ends = Path()
    ..addOval(Rect.fromCircle(center: at(start, mid), radius: thick / 2))
    ..addOval(Rect.fromCircle(center: at(start + sweep, mid), radius: thick / 2));
  // the needle, up and right, and its hub
  const a = -math.pi * .28;
  final tip = at(a, outer - thick - w * .04);
  final dir = (tip - c) / (tip - c).distance;
  final side = Offset(-dir.dy, dir.dx) * w * .07;
  final needle = Path()
    ..moveTo((c + side).dx, (c + side).dy)
    ..lineTo(tip.dx, tip.dy)
    ..lineTo((c - side).dx, (c - side).dy)
    ..close()
    ..addOval(Rect.fromCircle(center: c, radius: w * .13));
  return Path.combine(PathOperation.union, Path.combine(PathOperation.union, arc, ends), needle);
}

class _DialShapeClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => _dialShape(size);

  @override
  bool shouldReclip(_DialShapeClipper old) => false;
}

/// The glass's edge on the shape: bright on top where the light falls, faint below.
class _DialRim extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _dialShape(size),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: .75), Colors.white.withValues(alpha: .15)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_DialRim old) => false;
}

/// The speedometer made of glass: the app's glass cut to its shape, a light fill so it reads on
/// the dark background, and a rim.
class _GlassDialIcon extends StatelessWidget {
  const _GlassDialIcon({this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      foregroundPainter: _DialRim(),
      child: ClipPath(
        clipper: _DialShapeClipper(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            OverflowBox(
              maxWidth: size * 2,
              maxHeight: size * 2,
              child: GlassSurface(
                width: size * 2,
                height: size * 2,
                borderRadius: size * .4,
                child: const SizedBox.expand(),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withValues(alpha: .38), Colors.white.withValues(alpha: .12)],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The connect button as the sun, the speed test as a planet beside it; the test's result shows
/// there too.
class _Sun extends StatefulWidget {
  const _Sun({required this.child, required this.planet, required this.beside});
  final Widget child;

  /// Whether the planet is out: connected, the pick working.
  final bool planet;

  /// The result beside the speedometer, or in its place.
  final bool beside;

  @override
  State<_Sun> createState() => _SunState();
}

class _SunState extends State<_Sun> with TickerProviderStateMixin {
  late final _show = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: widget.planet ? 1 : 0,
  );
  late final _clock = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();

  /// Where the speedometer's centre sits from the sun's: up and to the right, clear of its light.
  static Offset get _at => _chainClock
      ? const Offset(126, 0)
      : _secClockRight
      ? const Offset(126, 0)
      : _secClock
      ? const Offset(-126, 0)
      : _secColumn
      ? const Offset(-126, 20)
      : _speedRight
      ? const Offset(126, -12)
      : const Offset(120, -118);

  /// Extra security's top centre: across from the speedometer, or above it in the column.
  static Offset get _secAt => _secClockRight
      ? const Offset(109, -63)
      : _secClock
      ? const Offset(-109, -63)
      : _secColumn
      ? const Offset(-126, -34)
      : Offset(-_at.dx, _at.dy);
  static const _icon = 22.0;

  @override
  void didUpdateWidget(_Sun old) {
    super.didUpdateWidget(old);
    if (widget.planet != old.planet) widget.planet ? _show.forward() : _show.reverse();
  }

  @override
  void dispose() {
    _show.dispose();
    _clock.dispose();
    super.dispose();
  }

  Widget _value(BuildContext c, String s, bool up, {double size = 13}) {
    return switch (s) {
      'testing' => AnimatedBuilder(
        animation: _clock,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 2; i++)
              Container(
                width: size * .28,
                height: size * .28,
                margin: EdgeInsets.symmetric(horizontal: size * .1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _primary(
                    c,
                  ).withValues(alpha: .3 + .7 * ((math.sin(_clock.value * 2 * math.pi - i * math.pi) + 1) / 2)),
                ),
              ),
          ],
        ),
      ),
      _ => _val(c, s, up, size: size),
    };
  }

  /// L8: the upload large, the download small and raised beside it, the unit under the download.
  Widget _result(BuildContext c, String s) => Row(
    key: ValueKey('result $s'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 20,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [_arr(c, true, size: 11), const SizedBox(width: 3), _value(c, s, true, size: 17)],
        ),
      ),
      const SizedBox(width: 4),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [_arr(c, false, size: 7), const SizedBox(width: 2), _value(c, s, false, size: 10)],
            ),
          ),
          if (s == 'tested') ...[const SizedBox(height: 2), _mbps(c, size: 7.5)],
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    clipBehavior: Clip.none,
    children: [
      widget.child,
      if (_glassLogo)
        const Positioned(
          left: 74 - 37,
          top: 74 - 37 - 1.5,
          child: _GlassShape(
            _logoShape,
            size: 74,
            rim: .7,
            tint: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xE644A334), Color(0xB344A334)],
            ),
          ),
        ),
      if (_chainClock) ..._chainItems(),
      if (_secLook > 0)
        Positioned(
          // extra security, where the speedometer is but on the left
          left: 74 + _secAt.dx,
          top: 74 + _secAt.dy - _icon / 2,
          child: FractionalTranslation(
            translation: const Offset(-.5, 0),
            child: Builder(builder: _secEntry),
          ),
        ),
      Positioned(
        // the speedometer's top centre; the result grows down under it
        left: 74 + _at.dx,
        top: 74 + _at.dy - _icon / 2,
        child: FractionalTranslation(
          translation: const Offset(-.5, 0),
          child: AnimatedBuilder(
            animation: _show,
            builder: (context, child) => Transform.scale(
              alignment: Alignment.topCenter,
              scale: Curves.easeOutBack.transform(_show.value),
              child: Opacity(opacity: _show.value.clamp(0.0, 1.0), child: child),
            ),
            child: ValueListenableBuilder(
              valueListenable: _video,
              builder: (context, followed, _) {
                // the extra security comparison: with it off, the speed shows as most often, not tested
                final s = _secLook > 0 && !_secOn ? 'untested' : followed;
                final untested = s != 'testing' && s != 'tested' && s != 'failed';
                final Widget content = untested
                    ? const KeyedSubtree(key: ValueKey('icon'), child: _Planet())
                    : widget.beside
                    ? Column(
                        key: const ValueKey('beside'),
                        mainAxisSize: MainAxisSize.min,
                        children: [const _Planet(), const SizedBox(height: 4), _result(context, s)],
                      )
                    : SizedBox(
                        height: _icon,
                        child: Center(widthFactor: 1, child: _result(context, s)),
                      );
                return AnimatedSize(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    layoutBuilder: (current, previous) =>
                        Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                    child: content,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ],
  );
}

/// Whether the card shows; set by the status line from the card's own data.
var _hasCard = false;

/// The connection's state above the card, with no background: a glowing dot and the words.
class _StatusLine extends StatelessWidget {
  const _StatusLine();

  @override
  Widget build(BuildContext context) => Consumer(
    builder: (context, ref, _) {
      // as the footer decides: a card while the core runs
      _hasCard =
          (ref.watch(connectionNotifierProvider).value?.isRunning ?? false) &&
          ref.watch(activeProxyCardProvider) != null;
      return _animated(context);
    },
  );

  // only with the card: it comes and goes inside the card's own animation
  Widget _animated(BuildContext context) => !_hasCard
      ? const SizedBox(width: double.infinity)
      : AnimatedBuilder(
          animation: _line,
          // 8 px above the card's glass: the line's box, then 8 into the card's 16 inset
          builder: (context, _) =>
              Transform.translate(offset: const Offset(0, 8), child: _content(context, _line.value)),
        );

  Widget _content(BuildContext context, (String, Color)? line) => Padding(
    // the text starts where the card's content starts
    padding: const EdgeInsets.symmetric(horizontal: 28),
    child: SizedBox(
      height: 26,
      width: double.infinity,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (current, previous) =>
            Stack(alignment: AlignmentDirectional.centerStart, children: [...previous, ?current]),
        child: line == null
            ? const SizedBox(key: ValueKey('none'))
            : Text(
                key: ValueKey(line.$1),
                line.$1,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: .92),
                ),
              ),
      ),
    ),
  );
}

/// How long the card takes to come in or go, and the button to glide with it.
const _cardIn = Duration(milliseconds: 550);

/// The status's mark: a small glass circle tinted the state's color, as the ping's glass is.
class _GlassDot extends StatelessWidget {
  const _GlassDot(this.color, {this.tint = true, this.look = 0});
  final Color color;

  /// False: clear glass, no color.
  final bool tint;

  /// How the color lies in the glass: 0 even, 1 from the side like the ping's glow, 2 from the
  /// centre, 3 from the bottom.
  final int look;

  @override
  Widget build(BuildContext context) => GlassSurface(
    width: 10,
    height: 10,
    borderRadius: 5,
    child: !tint
        ? const SizedBox.expand()
        : DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: look == 0 ? color.withValues(alpha: .45) : null,
              gradient: switch (look) {
                1 => LinearGradient(colors: [color.withValues(alpha: .85), color.withValues(alpha: .05)]),
                2 => RadialGradient(colors: [color.withValues(alpha: .9), color.withValues(alpha: .05)]),
                3 => LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [color.withValues(alpha: .85), color.withValues(alpha: .05)],
                ),
                _ => null,
              },
            ),
          ),
  );
}

/// The status's mark: a bright core in a soft halo of its color; while something is on its way, a
/// ring breathes out of it.
class _Beacon extends StatefulWidget {
  const _Beacon(this.color, {required this.busy});
  final Color color;
  final bool busy;

  @override
  State<_Beacon> createState() => _BeaconState();
}

class _BeaconState extends State<_Beacon> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 18,
    child: AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => CustomPaint(painter: _BeaconPainter(widget.color, widget.busy ? _pulse.value : null)),
    ),
  );
}

class _BeaconPainter extends CustomPainter {
  _BeaconPainter(this.color, this.pulse);
  final Color color;
  final double? pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    // the halo
    canvas.drawCircle(
      c,
      7,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: .45), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: c, radius: 7)),
    );
    if (pulse case final p?) {
      canvas.drawCircle(
        c,
        3.5 + 5 * Curves.easeOut.transform(p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color.withValues(alpha: .7 * (1 - p)),
      );
    }
    // the core, lit from the top
    canvas.drawCircle(
      c,
      3.6,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.3, -.4),
          colors: [Color.lerp(color, Colors.white, .65)!, color],
        ).createShader(Rect.fromCircle(center: c, radius: 3.6)),
    );
  }

  @override
  bool shouldRepaint(_BeaconPainter old) => old.pulse != pulse || old.color != color;
}

/// Under the button: what the connection is doing, then the ping while it runs.
class _UnderSun extends StatelessWidget {
  const _UnderSun();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_conn, _line]),
    builder: (context, _) {
      final conn = _conn.value;
      final t = Theme.of(context).textTheme;
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      final Widget words = switch (conn) {
        'disconnected' => Text(key: const ValueKey('tap'), 'Tap to connect', style: t.titleMedium),
        'failed' => Column(
          key: const ValueKey('failed'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Couldn’t connect', style: t.titleMedium?.copyWith(color: _red, height: 1.2)),
            Text('Tap to try again', style: t.bodyMedium?.copyWith(height: 1.2, color: muted)),
          ],
        ),
        _ => Text(
          key: ValueKey(_line.value?.$1),
          _line.value?.$1 ?? '',
          style: t.titleMedium?.copyWith(color: Colors.white.withValues(alpha: .92)),
        ),
      };
      final ping = conn == 'connected' || conn == 'noProxies';
      return AnimatedSize(
        duration: _cardIn,
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(duration: const Duration(milliseconds: 260), layoutBuilder: _stacked, child: words),
            // bare, the ping's 42 px row is mostly air: pull it up so it sits with the text
            if (ping) ...[
              SizedBox(height: _pingBare ? 0 : 10),
              Transform.translate(
                offset: Offset(0, _pingBare ? -6 : 0),
                child: _LiveStatus(_pingBare ? 'P10r' : 'P10q'),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Home with the sun and its planet, the status under the button.
class _SunHome extends StatelessWidget {
  const _SunHome({this.beside = true, this.top});

  /// The app's name and the main profile, above the button; none when null.
  final WidgetBuilder? top;

  /// The speed result beside the speedometer, or in its place.
  final bool beside;

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme(),
    child: Material(
      type: MaterialType.transparency,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(size: const Size(380, 900)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox.fromSize(
            size: _HomePhone.size,
            child: Stack(
              children: [
                const Positioned.fill(child: _HomeBackground()),
                Positioned.fill(
                  bottom: 18,
                  child: BackdropGroup(
                    child: Column(
                      children: [
                        if (top case final top?) Builder(builder: top),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedBuilder(
                                animation: Listenable.merge([_conn, _pick]),
                                builder: (context, _) => _Sun(
                                  planet: _conn.value == 'connected' && _pick.value == 'ok',
                                  beside: beside,
                                  child: const ConnectionButton(),
                                ),
                              ),
                              const SizedBox(height: 14),
                              const _UnderSun(),
                            ],
                          ),
                        ),
                        const AnimatedSize(
                          duration: _cardIn,
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: _GlassCard(),
                        ),
                        const SizedBox(height: 4),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _Round(child: Icon(Icons.add_rounded, size: 28)),
                            SizedBox(width: 10),
                            _Bar(),
                            SizedBox(width: 10),
                            _Round(child: Icon(Icons.tune_rounded, size: 28)),
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

const _blue = Color(0xFF8A9BFF);
const _greenLine = Color(0xFF5CC24A);
const _orange = Color(0xFFE5A23B);
const _red = Color(0xFFE5534B);

/// The button's amber for a pick that does not answer.
const _degraded = Color(0xFFE3A63A);

/// The video: (connection, speed or offer state, status line, seconds).
const _sunTimeline = <(String, String, (String, Color)?, double)>[
  ('disconnected', 'untested', null, 2.0),
  ('connecting', 'untested', ('Connecting…', _blue), 2.0),
  ('waiting', 'untested', ('Searching for freedom…', _blue), 2.0),
  ('connected', 'hop', ('Psiphon is connecting…', _blue), 2.5),
  ('connected', 'untested', ('Connected', _greenLine), 3.0),
  ('connected', 'testing', ('Connected', _greenLine), 2.0),
  ('connected', 'tested', ('Connected', _greenLine), 10.0),
  ('connected', 'untested', ('Connected', _greenLine), 1.5),
  ('connected', 'offer', ('Selected proxy isn’t responding', _orange), 3.0),
  ('connected', 'untested', ('Connected', _greenLine), 1.5),
  ('hotReloading', 'untested', ('Applying changes…', _blue), 2.0),
  ('connected', 'untested', ('Connected', _greenLine), 1.5),
  ('noProxies', 'untested', ('Connection failed', _orange), 2.5),
  ('disconnecting', 'untested', ('Disconnecting…', _blue), 2.0),
  ('disconnected', 'untested', null, 1.5),
  ('connecting', 'untested', ('Connecting…', _blue), 1.5),
  ('failed', 'untested', null, 3.0),
  ('disconnected', 'untested', null, 1.5),
];

// ---------- ten glass treatments for the connect button's face ----------

/// A ring drawn inside the face: [width] wide, [inset] in from the edge, its color from a sweep or
/// one color.
class _FaceRing extends CustomPainter {
  _FaceRing({this.color, this.sweep, this.width = 1.2, this.inset = .6});
  final Color? color;
  final List<Color>? sweep;
  final double width;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - inset;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    if (sweep case final colors?) {
      paint.shader = SweepGradient(
        colors: colors,
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(Rect.fromCircle(center: c, radius: r));
    } else {
      paint.color = color!;
    }
    canvas.drawCircle(c, r, paint);
  }

  @override
  bool shouldRepaint(_FaceRing old) => false;
}

Widget _circle({Color? color, Gradient? gradient}) => DecoratedBox(
  decoration: BoxDecoration(shape: BoxShape.circle, color: color, gradient: gradient),
  child: const SizedBox.expand(),
);

/// A soft white curve over the top: the light the glass catches.
Widget _topShine({double alpha = .2}) => ClipOval(
  child: Align(
    alignment: Alignment.topCenter,
    child: FractionallySizedBox(
      widthFactor: .82,
      heightFactor: .5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(bottom: Radius.elliptical(200, 60), top: Radius.circular(100)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: alpha),
              Colors.white.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    ),
  ),
);

final _faces = <(String, Widget Function(Color))>[
  ('G1  Clear (now)', (c) => const SizedBox.expand()),
  ('G2  Light on top', (c) => _topShine()),
  (
    'G3  Bright rim',
    (c) => CustomPaint(
      painter: _FaceRing(
        sweep: [
          Colors.white.withValues(alpha: .55),
          Colors.white.withValues(alpha: .08),
          Colors.white.withValues(alpha: .3),
          Colors.white.withValues(alpha: .08),
          Colors.white.withValues(alpha: .55),
        ],
        width: 1.6,
      ),
      child: const SizedBox.expand(),
    ),
  ),
  ('G4  Light frost', (c) => _circle(color: Colors.white.withValues(alpha: .1))),
  (
    'G5  Dome',
    (c) => _circle(
      gradient: RadialGradient(
        center: const Alignment(-.35, -.45),
        radius: 1,
        colors: [
          Colors.white.withValues(alpha: .2),
          Colors.white.withValues(alpha: 0),
          Colors.black.withValues(alpha: .22),
        ],
        stops: const [0, .55, 1],
      ),
    ),
  ),
  ('G6  A breath of the state color', (c) => _circle(color: c.withValues(alpha: .12))),
  (
    'G7  Light through the bottom',
    (c) => _circle(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [c.withValues(alpha: .22), c.withValues(alpha: 0)],
        stops: const [0, .6],
      ),
    ),
  ),
  (
    'G8  Shine and rim',
    (c) => Stack(
      fit: StackFit.expand,
      children: [
        _topShine(alpha: .16),
        CustomPaint(painter: _FaceRing(color: Colors.white.withValues(alpha: .22), width: 1)),
      ],
    ),
  ),
  (
    'G9  Thick glass',
    (c) => Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _FaceRing(color: Colors.white.withValues(alpha: .28), width: 1.2)),
        CustomPaint(painter: _FaceRing(color: Colors.white.withValues(alpha: .08), width: 6, inset: 10)),
        _circle(
          gradient: RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0),
              Colors.black.withValues(alpha: .18),
            ],
            stops: const [0, .78, 1],
          ),
        ),
      ],
    ),
  ),
  (
    'G10  Dome, shine and a breath of color',
    (c) => Stack(
      fit: StackFit.expand,
      children: [
        _circle(color: c.withValues(alpha: .1)),
        _circle(
          gradient: RadialGradient(
            colors: [Colors.white.withValues(alpha: 0), Colors.black.withValues(alpha: .2)],
            stops: const [.6, 1],
          ),
        ),
        _topShine(alpha: .18),
        CustomPaint(painter: _FaceRing(color: Colors.white.withValues(alpha: .18), width: 1)),
      ],
    ),
  ),
];

/// Which treatment the button under it draws.
class _FaceScope extends InheritedWidget {
  const _FaceScope({required this.face, required super.child, this.logo});
  final Widget Function(Color) face;

  /// How the logo is colored here; null keeps the painter's own choice.
  final int? logo;

  @override
  bool updateShouldNotify(_FaceScope old) => old.face != face;
}

// ---------- eight glass speed-test icons ----------

class _PathClipper extends CustomClipper<Path> {
  _PathClipper(this.shape);
  final Path Function(Size) shape;

  @override
  Path getClip(Size size) => shape(size);

  @override
  bool shouldReclip(_PathClipper old) => false;
}

class _PathRim extends CustomPainter {
  _PathRim(this.shape, {this.alpha = 1});
  final double alpha;
  final Path Function(Size) shape;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    shape(size),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: .8 * alpha),
          Colors.white.withValues(alpha: .15 * alpha),
        ],
      ).createShader(Offset.zero & size),
  );

  @override
  bool shouldRepaint(_PathRim old) => false;
}

/// The app's glass cut to [shape], with a light fill and a rim; [tint] colors the fill.
class _GlassShape extends StatelessWidget {
  const _GlassShape(this.shape, {this.size = 32, this.tint, this.rim = 1});

  /// How strong the rim is, 0 to 1.
  final double rim;
  final Path Function(Size) shape;
  final double size;
  final Gradient? tint;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      foregroundPainter: _PathRim(shape, alpha: rim),
      child: ClipPath(
        clipper: _PathClipper(shape),
        child: Stack(
          fit: StackFit.expand,
          children: [
            OverflowBox(
              maxWidth: size * 2,
              maxHeight: size * 2,
              child: GlassSurface(
                width: size * 2,
                height: size * 2,
                borderRadius: size * .4,
                child: const SizedBox.expand(),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient:
                    tint ??
                    LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white.withValues(alpha: .38), Colors.white.withValues(alpha: .12)],
                    ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The arc alone, and a bead where the needle would point.
Path _arcBead(Size size) {
  final w = size.width;
  final c = Offset(w / 2, size.height * .6);
  final outer = w * .48;
  final thick = w * .16;
  const start = math.pi * .8;
  const sweep = math.pi * 1.4;
  final mid = outer - thick / 2;
  Offset at(double a, double r) => c + Offset(math.cos(a), math.sin(a)) * r;
  final arc = Path()
    ..addArc(Rect.fromCircle(center: c, radius: outer), start, sweep)
    ..arcTo(Rect.fromCircle(center: c, radius: outer - thick), start + sweep, -sweep, false)
    ..close()
    ..addOval(Rect.fromCircle(center: at(start, mid), radius: thick / 2))
    ..addOval(Rect.fromCircle(center: at(start + sweep, mid), radius: thick / 2));
  final bead = Path()..addOval(Rect.fromCircle(center: c, radius: w * .14));
  return Path.combine(PathOperation.union, arc, bead);
}

Path _bolt(Size size) {
  final w = size.width;
  final h = size.height;
  return Path()
    ..moveTo(w * .58, h * .04)
    ..lineTo(w * .2, h * .56)
    ..lineTo(w * .46, h * .56)
    ..lineTo(w * .38, h * .96)
    ..lineTo(w * .8, h * .4)
    ..lineTo(w * .54, h * .4)
    ..close();
}

/// Down and up arrows side by side.
Path _arrowsUpDown(Size size) {
  final w = size.width;
  final h = size.height;
  Path arrow(double x, bool up) {
    final sw = w * .14;
    final head = w * .2;
    final top = h * .1;
    final bottom = h * .9;
    final p = Path();
    if (up) {
      p
        ..moveTo(x, top)
        ..lineTo(x + head, top + head * 1.1)
        ..lineTo(x + sw / 2, top + head * 1.1)
        ..lineTo(x + sw / 2, bottom)
        ..lineTo(x - sw / 2, bottom)
        ..lineTo(x - sw / 2, top + head * 1.1)
        ..lineTo(x - head, top + head * 1.1)
        ..close();
    } else {
      p
        ..moveTo(x, bottom)
        ..lineTo(x + head, bottom - head * 1.1)
        ..lineTo(x + sw / 2, bottom - head * 1.1)
        ..lineTo(x + sw / 2, top)
        ..lineTo(x - sw / 2, top)
        ..lineTo(x - sw / 2, bottom - head * 1.1)
        ..lineTo(x - head, bottom - head * 1.1)
        ..close();
    }
    return p;
  }

  return Path.combine(PathOperation.union, arrow(w * .3, false), arrow(w * .7, true));
}

/// A wide, thin gauge: a half ring and a long needle.
Path _halfGauge(Size size) {
  final w = size.width;
  final c = Offset(w / 2, size.height * .72);
  final outer = w * .48;
  final thick = w * .11;
  final ring = Path()
    ..addArc(Rect.fromCircle(center: c, radius: outer), math.pi, math.pi)
    ..arcTo(Rect.fromCircle(center: c, radius: outer - thick), 0, -math.pi, false)
    ..close();
  const a = -math.pi * .3;
  final tip = c + Offset(math.cos(a), math.sin(a)) * (outer - thick * .4);
  final dir = (tip - c) / (tip - c).distance;
  final side = Offset(-dir.dy, dir.dx) * w * .06;
  final needle = Path()
    ..moveTo((c + side).dx, (c + side).dy)
    ..lineTo(tip.dx, tip.dy)
    ..lineTo((c - side).dx, (c - side).dy)
    ..close()
    ..addOval(Rect.fromCircle(center: c, radius: w * .1));
  return Path.combine(PathOperation.union, ring, needle);
}

/// A drawn icon that looks like glass: a white body fading down, a soft shadow, a bright edge on
/// top. No backdrop of its own.
Widget _paintedGlass(IconData icon, {double size = 32}) => Stack(
  alignment: Alignment.center,
  children: [
    Transform.translate(
      offset: const Offset(0, 1.5),
      child: Icon(icon, size: size, color: Colors.black.withValues(alpha: .35)),
    ),
    ShaderMask(
      shaderCallback: (r) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white.withValues(alpha: .95), Colors.white.withValues(alpha: .45)],
      ).createShader(r),
      child: Icon(icon, size: size, color: Colors.white),
    ),
  ],
);

final _icons = <(String, Widget)>[
  ('I1  Speedometer cut from glass (now)', const _GlassShape(_dialShape)),
  ('I2  Arc and a bead', const _GlassShape(_arcBead)),
  (
    'I3  Colored glass speedometer',
    const _GlassShape(
      _dialShape,
      tint: LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [Color(0x664FC3F7), Color(0x66CE93D8)],
      ),
    ),
  ),
  ('I4  Half gauge', const _GlassShape(_halfGauge, size: 34)),
  ('I5  Glass bolt', const _GlassShape(_bolt)),
  ('I6  Down and up arrows', const _GlassShape(_arrowsUpDown)),
  ('I7  Painted glass speedometer', _paintedGlass(Icons.speed_rounded, size: 34)),
  (
    'I8  Glass bead with the speedometer',
    SizedBox.square(
      dimension: 34,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const GlassSurface(width: 34, height: 34, borderRadius: 17, child: SizedBox.expand()),
          _paintedGlass(Icons.speed_rounded, size: 22),
        ],
      ),
    ),
  ),
];

// ---------- ten ways to lay out download, upload and Mbps under the speedometer ----------

Widget _num2(BuildContext c, bool up, double size, {Color? color}) =>
    Text(formatMbps(up ? _up : _down), style: _num(c, size, color: color ?? _green(c)));

Widget _dirRow(BuildContext c, bool up, {double size = 13, double arrow = 9, bool unit = false}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    _arr(c, up, size: arrow),
    const SizedBox(width: 3),
    _num2(c, up, size),
    if (unit) ...[const SizedBox(width: 3), _mbps(c, size: 8)],
  ],
);

Widget _caps(BuildContext c, String text, {double size = 7.5}) => Text(
  text,
  style: _small(c)?.copyWith(fontSize: size, height: 1, letterSpacing: 1.2, fontWeight: FontWeight.w700),
);

final _layouts = <(String, WidgetBuilder)>[
  (
    'L1  Two rows, Mbps on upload (now)',
    (c) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_dirRow(c, false), const SizedBox(height: 2), _dirRow(c, true, unit: true)],
    ),
  ),
  (
    'L2  One row',
    (c) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [_dirRow(c, false), const SizedBox(width: 7), _dirRow(c, true, unit: true)],
    ),
  ),
  (
    'L3  Two rows, Mbps under',
    (c) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dirRow(c, false),
        const SizedBox(height: 2),
        _dirRow(c, true),
        const SizedBox(height: 3),
        _mbps(c, size: 8),
      ],
    ),
  ),
  (
    'L4  Download big, upload small',
    (c) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dirRow(c, false, size: 17, arrow: 11),
        const SizedBox(height: 2),
        _dirRow(c, true, size: 11, arrow: 8, unit: true),
      ],
    ),
  ),
  (
    'L5  Two columns',
    (c) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final up in [false, true]) ...[
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [_arr(c, up, size: 9), const SizedBox(height: 2), _num2(c, up, 14)],
              ),
              if (!up) const SizedBox(width: 10),
            ],
          ],
        ),
        const SizedBox(height: 3),
        _mbps(c, size: 8),
      ],
    ),
  ),
  (
    'L6  Colored by direction',
    (c) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _num2(c, false, 14, color: _downColor),
        const SizedBox(height: 2),
        _num2(c, true, 14, color: _upColor),
        const SizedBox(height: 3),
        _mbps(c, size: 8),
      ],
    ),
  ),
  (
    'L7  Down / up',
    (c) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _num2(c, false, 15),
            Text(' / ', style: _num(c, 13, color: _muted(c).withValues(alpha: .6))),
            _num2(c, true, 15),
          ],
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _arr(c, false, size: 8),
            const SizedBox(width: 4),
            _mbps(c, size: 8),
            const SizedBox(width: 4),
            _arr(c, true, size: 8),
          ],
        ),
      ],
    ),
  ),
  (
    'L8  Upload raised beside download',
    (c) => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dirRow(c, false, size: 17, arrow: 11),
        const SizedBox(width: 4),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_dirRow(c, true, size: 10, arrow: 7), const SizedBox(height: 2), _mbps(c, size: 7.5)],
        ),
      ],
    ),
  ),
  (
    'L9  Rows with a line between',
    (c) => IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dirRow(c, false),
          Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 3), color: Colors.white12),
          _dirRow(c, true),
          const SizedBox(height: 2),
          Align(alignment: Alignment.centerRight, child: _mbps(c, size: 7.5)),
        ],
      ),
    ),
  ),
  (
    'L10  MBPS label on top',
    (c) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _caps(c, 'MBPS'),
        const SizedBox(height: 3),
        Row(mainAxisSize: MainAxisSize.min, children: [_dirRow(c, false), const SizedBox(width: 7), _dirRow(c, true)]),
      ],
    ),
  ),
];

/// The Material speed icon's shape, drawn as a path so it can be cut from glass: a thick arc open
/// at the bottom with round ends, and a needle up and to the right with its hub.
Path _speedShape(Size size) {
  final w = size.width;
  final c = Offset(w / 2, size.height * .58);
  final outer = w * .46;
  final thick = w * .12;
  const start = math.pi * .82;
  const sweep = math.pi * 1.36;
  final mid = outer - thick / 2;
  Offset at(double a, double r) => c + Offset(math.cos(a), math.sin(a)) * r;
  final arc = Path()
    ..addArc(Rect.fromCircle(center: c, radius: outer), start, sweep)
    ..arcTo(Rect.fromCircle(center: c, radius: outer - thick), start + sweep, -sweep, false)
    ..close()
    ..addOval(Rect.fromCircle(center: at(start, mid), radius: thick / 2))
    ..addOval(Rect.fromCircle(center: at(start + sweep, mid), radius: thick / 2));
  // the needle: a long tapered blade from the hub toward the arc
  const a = -math.pi * .27;
  final tip = at(a, outer - thick - w * .03);
  final dir = (tip - c) / (tip - c).distance;
  final side = Offset(-dir.dy, dir.dx);
  final needle = Path()
    ..moveTo((c + side * w * .085).dx, (c + side * w * .085).dy)
    ..lineTo((tip + side * w * .02).dx, (tip + side * w * .02).dy)
    ..lineTo((tip - side * w * .02).dx, (tip - side * w * .02).dy)
    ..lineTo((c - side * w * .085).dx, (c - side * w * .085).dy)
    ..close()
    ..addOval(Rect.fromCircle(center: c, radius: w * .1));
  return Path.combine(PathOperation.union, arc, needle);
}

/// Builds a [Path] from SVG path data.
class _PathBuilder extends PathProxy {
  final path = Path();

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) =>
      path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void close() => path.close();
}

/// The Material "speed" icon's own outline (24 × 24), scaled to [size].
Path _materialSpeed(Size size) {
  final b = _PathBuilder();
  writeSvgPathDataToPath(
    'M20.38 8.57l-1.23 1.85a8 8 0 0 1-.22 7.58H5.07A8 8 0 0 1 15.58 6.85l1.85-1.23A10 10 0 0 0 3.35 19'
    'a2 2 0 0 0 1.72 1h13.85a2 2 0 0 0 1.74-1 10 10 0 0 0-.27-10.44z'
    'm-9.79 6.84a2 2 0 0 0 2.83 0l5.66-8.49-8.49 5.66a2 2 0 0 0 0 2.83z',
    b,
  );
  return b.path.transform(Matrix4.diagonal3Values(size.width / 24, size.height / 24, 1).storage);
}

final _i7Glass = <(String, Widget)>[
  ('I7  Painted (not glass)', _paintedGlass(Icons.speed_rounded, size: 34)),
  ('I7 in glass', const _GlassShape(_materialSpeed, size: 36)),
  (
    'I7 in glass, brighter',
    const _GlassShape(
      _materialSpeed,
      size: 36,
      tint: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x99FFFFFF), Color(0x33FFFFFF)],
      ),
    ),
  ),
];

// ---------- the top of home: the app's name and version, and the main profile ----------

const _profileName = 'My subscription';
const _usedGb = 12.4;
const _totalGb = 50.0;
const _daysLeft = 23;

TextStyle? _t(BuildContext c, double size, {FontWeight w = FontWeight.w600, Color? color}) => Theme.of(c)
    .textTheme
    .bodyMedium
    ?.copyWith(fontSize: size, fontWeight: w, height: 1.15, color: color ?? Colors.white.withValues(alpha: .92));

/// The app's logo and name, and its version.
Widget _appName(BuildContext c, {bool glassVersion = true}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    SvgPicture.asset('assets/images/logo.svg', height: 22),
    const SizedBox(width: 8),
    Text('Hiddify', style: _t(c, 18, w: FontWeight.w700)),
    const SizedBox(width: 8),
    if (glassVersion)
      GlassSurface(
        height: 20,
        borderRadius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          widthFactor: 1,
          child: Text('4.1.0', style: _t(c, 11, color: _muted(c))),
        ),
      )
    else
      Text(
        '4.1.0',
        style: _t(c, 12, w: FontWeight.w500, color: _muted(c)),
      ),
  ],
);

/// How much of the plan is used: a thin bar.
Widget _usageBar(BuildContext c, {double height = 4}) => ClipRRect(
  borderRadius: BorderRadius.circular(height),
  child: SizedBox(
    height: height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.white.withValues(alpha: .1)),
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: _usedGb / _totalGb,
          child: ColoredBox(color: _greenLine.withValues(alpha: .85)),
        ),
      ],
    ),
  ),
);

/// How much of the plan is used: a ring around the remaining days.
class _UsageRing extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2.5);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .1);
    canvas
      ..drawArc(rect, 0, 2 * math.pi, false, track)
      ..drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * _usedGb / _totalGb,
        false,
        track..color = _greenLine.withValues(alpha: .9),
      );
  }

  @override
  bool shouldRepaint(_UsageRing old) => false;
}

Widget _refresh(BuildContext c, {double size = 34}) => GlassSurface(
  width: size,
  height: size,
  borderRadius: size / 2,
  child: Center(
    child: Icon(Icons.refresh_rounded, size: size * .55, color: Colors.white.withValues(alpha: .85)),
  ),
);

Widget _nameRow(BuildContext c, {double size = 16}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Flexible(
      child: Text(_profileName, style: _t(c, size), overflow: TextOverflow.ellipsis),
    ),
    Icon(Icons.arrow_drop_down_rounded, size: 22, color: _muted(c)),
  ],
);

String get _usage => '${_usedGb.toStringAsFixed(1)} / ${_totalGb.toStringAsFixed(0)} GB';

/// T1: the name and version on their own line, then a glass card: name, usage bar, days left.
Widget _top1(BuildContext c) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(padding: const EdgeInsets.only(left: 4), child: _appName(c)),
      const SizedBox(height: 12),
      GlassSurface(
        borderRadius: 20,
        padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _nameRow(c),
                  const SizedBox(height: 8),
                  _usageBar(c),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        _usage,
                        style: _t(c, 12, w: FontWeight.w500, color: _muted(c)),
                      ),
                      const Spacer(),
                      Text(
                        '$_daysLeft days left',
                        style: _t(c, 12, w: FontWeight.w500, color: _muted(c)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _refresh(c),
          ],
        ),
      ),
    ],
  ),
);

/// T2: one glass capsule up top with the name and version; the profile in a slim glass pill
/// under it, a ring for the usage.
Widget _top2(BuildContext c) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
  child: Column(
    children: [
      GlassSurface(
        height: 38,
        borderRadius: 19,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Center(widthFactor: 1, child: _appName(c, glassVersion: false)),
      ),
      const SizedBox(height: 10),
      GlassSurface(
        height: 52,
        borderRadius: 26,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 38,
              child: CustomPaint(
                painter: _UsageRing(),
                child: Center(
                  child: Text('$_daysLeft d', style: _t(c, 10.5, w: FontWeight.w700)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _nameRow(c, size: 15),
                  Text(
                    _usage,
                    style: _t(c, 11.5, w: FontWeight.w500, color: _muted(c)),
                  ),
                ],
              ),
            ),
            _refresh(c, size: 36),
          ],
        ),
      ),
    ],
  ),
);

/// T3: the name and version with no glass; the profile card with a ring on the right.
Widget _top3(BuildContext c) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(padding: const EdgeInsets.only(left: 4), child: _appName(c, glassVersion: false)),
      const SizedBox(height: 12),
      GlassSurface(
        borderRadius: 22,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _nameRow(c, size: 17),
                  const SizedBox(height: 4),
                  Text(
                    '$_usage · $_daysLeft days left',
                    style: _t(c, 12.5, w: FontWeight.w500, color: _muted(c)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.refresh_rounded, size: 15, color: _primary(c)),
                      const SizedBox(width: 4),
                      Text(
                        'Updated 2 h ago',
                        style: _t(c, 12, w: FontWeight.w600, color: _primary(c)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox.square(
              dimension: 54,
              child: CustomPaint(
                painter: _UsageRing(),
                child: Center(
                  child: Text('${(_usedGb / _totalGb * 100).round()}%', style: _t(c, 13, w: FontWeight.w700)),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
);

/// The real main profile card, on glass instead of its own fill: nothing else changed.
class _GlassProfile extends StatelessWidget {
  const _GlassProfile();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final now = DateTime.now();
    return Theme(
      data: t.copyWith(
        cardTheme: t.cardTheme.copyWith(
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: GlassSurface(borderRadius: 16, child: SizedBox.expand())),
          ProfileTile(
            isMain: true,
            profile: ProfileEntity.remote(
              id: 'p1',
              // not marked active: the active profile's outline is the border, left out on glass
              active: false,
              name: _profileName,
              url: 'https://example.com/sub',
              lastUpdate: now.subtract(const Duration(hours: 2)),
              subInfo: SubscriptionInfo(
                upload: 2400000000,
                download: 10000000000,
                total: 50000000000,
                expire: now.add(const Duration(days: _daysLeft)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// T0: today's top, on glass: the app's name and version, and the real profile card.
Widget _top0(BuildContext c) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // the app's name and version stay hidden for now
      const _GlassProfile(),
    ],
  ),
);

final _tops = <(String, WidgetBuilder)>[
  ('T0  Today\'s profile card, on glass', _top0),
  ('T1  Name line, card with a bar', _top1),
  ('T2  Name capsule, slim pill with a ring', _top2),
  ('T3  Plain name, card with a ring', _top3),
];

// ---------- Extra security on home: six ways in, left of the button ----------

/// Which entry idea the phone shows, 1 to 6; 0 shows none.
var _secLook = 0;

/// Whether extra security is on.
var _secOn = false;

/// Extra security and the speed test in one column left of the button.
var _secColumn = false;

/// On the button's clock face: the speed test at 9, extra security at 10.
var _secClock = false;

/// The same on the right: the speed test at 3, extra security at 2.
var _secClockRight = false;

/// The Material shield (24 × 24), scaled to [size].
Path _shieldPath(Size size) {
  final b = _PathBuilder();
  // Icons.shield_rounded, the icon extra security has everywhere in the app
  writeSvgPathDataToPath(
    'M11.3 2.26l-6 2.25C4.52 4.81 4 5.55 4 6.39v4.71c0 5.05 3.41 9.76 8 10.91 4.59-1.15 8-5.86 8-10.91V6.39'
    'c0-.83-.52-1.58-1.3-1.87l-6-2.25c-.45-.18-.95-.18-1.4-.01z',
    b,
  );
  return b.path.transform(Matrix4.diagonal3Values(size.width / 24, size.height / 24, 1).storage);
}

/// A check drawn over the shield when extra security is on.
class _CheckPainter extends CustomPainter {
  _CheckPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    canvas.drawPath(
      Path()
        ..moveTo(w * .33, w * .5)
        ..lineTo(w * .45, w * .62)
        ..lineTo(w * .68, w * .38),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * .09
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => false;
}

const _secGreen = Color(0xFF5CC24A);

/// The shield cut from glass: faint when off; tinted green with a check when on.
Widget _glassShield({double size = 24, bool? on}) {
  final isOn = on ?? _secOn;
  return SizedBox.square(
    dimension: size,
    child: Stack(
      children: [
        _GlassShape(
          _shieldPath,
          size: size,
          rim: isOn ? .8 : .55,
          tint: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isOn
                ? [_secGreen.withValues(alpha: .7), _secGreen.withValues(alpha: .35)]
                : [const Color(0x26FFFFFF), const Color(0x0AFFFFFF)],
          ),
        ),
      ],
    ),
  );
}

TextStyle? _secText(BuildContext c, {Color? color, double size = 10.5}) => Theme.of(
  c,
).textTheme.labelSmall?.copyWith(fontSize: size, height: 1.1, fontWeight: FontWeight.w600, color: color ?? _muted(c));

/// The six ideas; each is drawn centred under its top-centre anchor, like the speedometer.
Widget _secEntry(BuildContext c) {
  final on = _secOn;
  final state = on ? 'On' : 'Off';
  switch (_secLook) {
    // E1: the glass shield alone; its own fill says on or off
    case 1:
      return _glassShield();
    // E2: the shield and its name in two short lines
    case 2:
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _glassShield(),
          const SizedBox(height: 4),
          Text('Extra\nsecurity', textAlign: TextAlign.center, style: _secText(c)),
        ],
      );
    // E3: the shield with a state word under it, green when on
    case 3:
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _glassShield(),
          const SizedBox(height: 4),
          Text(state, style: _secText(c, color: on ? _secGreen : _muted(c), size: 11)),
        ],
      );
    // E4: a short invitation when off, a reassurance when on
    case 4:
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _glassShield(),
          const SizedBox(height: 4),
          Text(
            on ? 'Protected' : 'Add a layer',
            style: _secText(c, color: on ? _secGreen : Colors.white.withValues(alpha: .8), size: 11),
          ),
        ],
      );
    // E5: a small glass capsule: the shield and On / Off, like a switch you can see
    case 5:
      return GlassSurface(
        height: 30,
        borderRadius: 15,
        padding: const EdgeInsets.fromLTRB(7, 0, 10, 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glassShield(size: 18),
            const SizedBox(width: 5),
            Text(state, style: _secText(c, color: on ? _secGreen : _muted(c), size: 11.5)),
          ],
        ),
      );
    // E6: the shield in a ring: dashed when off, inviting; whole and green when on
    case 6:
      return SizedBox.square(
        dimension: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(40),
              painter: on ? _FaceRing(color: _secGreen.withValues(alpha: .8), width: 1.6) : _DashedRing(),
            ),
            _glassShield(size: 22),
          ],
        ),
      );
  }
  return const SizedBox.shrink();
}

class _DashedRing extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 1;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .35);
    const n = 16;
    for (var i = 0; i < n; i++) {
      final a = 2 * math.pi * i / n;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, math.pi / n * .9, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRing old) => false;
}

const _secNames = [
  '',
  'E1  Glass shield alone',
  'E2  Shield and its name',
  'E3  Shield and On / Off',
  'E4  Invitation / reassurance',
  'E5  Glass capsule',
  'E6  Shield in a ring',
];

// ---------- twenty ways to show the same connect button ----------

/// How the logo is colored (EclipseButtonPainter.glassStyle): light, mid, as today, white.
const _logoLight = 2;
const _logoMid = 5;
const _logoToday = 1;
const _logoWhite = 3;

Widget _stack(List<Widget> layers) => Stack(fit: StackFit.expand, children: layers);

Widget _rim(Color color, {double width = 1.2}) => CustomPaint(
  painter: _FaceRing(color: color, width: width),
);

final _buttons20 = <(String, int, Widget Function(Color))>[
  ('B1  Clear, light logo (now)', _logoLight, (c) => const SizedBox.expand()),
  ('B2  Clear, white logo', _logoWhite, (c) => const SizedBox.expand()),
  ('B3  Clear, logo as today', _logoToday, (c) => const SizedBox.expand()),
  ('B4  Light frost, light logo', _logoLight, (c) => _circle(color: Colors.white.withValues(alpha: .1))),
  ('B5  Frost, mid logo', _logoMid, (c) => _circle(color: Colors.white.withValues(alpha: .2))),
  ('B6  Faint state tint, white logo', _logoWhite, (c) => _circle(color: c.withValues(alpha: .18))),
  ('B7  State tint, white logo', _logoWhite, (c) => _circle(color: c.withValues(alpha: .32))),
  (
    'B8  Tint from below, white logo',
    _logoWhite,
    (c) => _circle(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [c.withValues(alpha: .45), c.withValues(alpha: .05)],
      ),
    ),
  ),
  ('B9  Light on top', _logoLight, (c) => _topShine(alpha: .18)),
  (
    'B10  Dome',
    _logoLight,
    (c) => _circle(
      gradient: RadialGradient(
        center: const Alignment(-.35, -.45),
        radius: 1,
        colors: [
          Colors.white.withValues(alpha: .18),
          Colors.white.withValues(alpha: 0),
          Colors.black.withValues(alpha: .22),
        ],
        stops: const [0, .55, 1],
      ),
    ),
  ),
  ('B11  Bright rim', _logoLight, (c) => _rim(Colors.white.withValues(alpha: .35), width: 1.4)),
  ('B12  Rim in the state color', _logoLight, (c) => _rim(c.withValues(alpha: .75), width: 2)),
  (
    'B13  Glow inside',
    _logoLight,
    (c) => _circle(gradient: RadialGradient(colors: [c.withValues(alpha: .3), c.withValues(alpha: 0)])),
  ),
  ('B14  Smoked glass, light logo', _logoLight, (c) => _circle(color: Colors.black.withValues(alpha: .25))),
  ('B15  Smoked glass, white logo', _logoWhite, (c) => _circle(color: Colors.black.withValues(alpha: .25))),
  (
    'B16  Frost, shine and rim',
    _logoLight,
    (c) => _stack([
      _circle(color: Colors.white.withValues(alpha: .08)),
      _topShine(alpha: .16),
      _rim(Colors.white.withValues(alpha: .22), width: 1),
    ]),
  ),
  (
    'B17  Tint, shine and rim',
    _logoLight,
    (c) => _stack([
      _circle(color: c.withValues(alpha: .12)),
      _topShine(alpha: .16),
      _rim(Colors.white.withValues(alpha: .2), width: 1),
    ]),
  ),
  (
    'B18  State rim and tint, white logo',
    _logoWhite,
    (c) => _stack([_circle(color: c.withValues(alpha: .14)), _rim(c.withValues(alpha: .8), width: 2)]),
  ),
  (
    'B19  Thick glass',
    _logoLight,
    (c) => _stack([
      _rim(Colors.white.withValues(alpha: .28)),
      CustomPaint(painter: _FaceRing(color: Colors.white.withValues(alpha: .08), width: 6, inset: 10)),
    ]),
  ),
  ('B20  Milky frost, mid logo', _logoMid, (c) => _circle(color: Colors.white.withValues(alpha: .28))),
];

/// Ten brighter ways: the button is the sun, so its glass is lit from within.
final _buttonsSun = <(String, int, Widget Function(Color))>[
  (
    'L1  Glowing white core',
    _logoToday,
    (c) => _circle(
      gradient: RadialGradient(colors: [Colors.white.withValues(alpha: .75), Colors.white.withValues(alpha: .25)]),
    ),
  ),
  (
    'L2  Warm sunlight',
    _logoToday,
    (c) => _circle(
      gradient: const RadialGradient(colors: [Color(0xD9FFF8E6), Color(0x66FFE0A0)], stops: [.35, 1]),
    ),
  ),
  ('L3  Bright frost', _logoToday, (c) => _circle(color: Colors.white.withValues(alpha: .6))),
  (
    'L4  Bright frost, shine and rim',
    _logoToday,
    (c) => _stack([
      _circle(color: Colors.white.withValues(alpha: .5)),
      _topShine(alpha: .45),
      _rim(Colors.white.withValues(alpha: .8), width: 1.4),
    ]),
  ),
  (
    'L5  Lit from within in the state color',
    _logoWhite,
    (c) => _circle(
      gradient: RadialGradient(
        colors: [Color.lerp(c, Colors.white, .45)!.withValues(alpha: .95), c.withValues(alpha: .55)],
      ),
    ),
  ),
  (
    'L6  State color, white core',
    _logoToday,
    (c) => _circle(
      gradient: RadialGradient(
        colors: [Colors.white.withValues(alpha: .85), Color.lerp(c, Colors.white, .5)!.withValues(alpha: .5)],
        stops: const [.45, 1],
      ),
    ),
  ),
  (
    'L7  Pearl',
    _logoToday,
    (c) => _circle(
      gradient: const RadialGradient(
        center: Alignment(-.3, -.4),
        radius: 1,
        colors: [Color(0xF2FFFFFF), Color(0xB3EEF1FF), Color(0x80C9CFE8)],
        stops: [0, .55, 1],
      ),
    ),
  ),
  (
    'L8  Bright rim, light inside',
    _logoToday,
    (c) => _stack([
      _circle(color: Colors.white.withValues(alpha: .42)),
      _rim(Colors.white.withValues(alpha: .95), width: 2.2),
    ]),
  ),
  (
    'L9  Sunrise from below',
    _logoToday,
    (c) => _circle(
      gradient: const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0xE6FFF2D6), Color(0x99FFFFFF)],
      ),
    ),
  ),
  (
    'L10  Glowing tint, white logo',
    _logoWhite,
    (c) => _stack([
      _circle(color: c.withValues(alpha: .6)),
      _circle(
        gradient: RadialGradient(colors: [Colors.white.withValues(alpha: .35), Colors.white.withValues(alpha: 0)]),
      ),
      _rim(Colors.white.withValues(alpha: .5), width: 1.2),
    ]),
  ),
];

// ---------- extra security at 8, unblocker at 10; the one that is on becomes the button's badge ----------

/// The Hi logo in glass, tinted the state's color, instead of painted.
var _glassLogo = false;

/// The app's logo (64 × 64), scaled to [size].
Path _logoShape(Size size) {
  final b = _PathBuilder();
  for (final d in [
    'M47.1582 14.4283C47.1582 13.8368 47.4684 13.2886 47.9757 12.9842L61.4494 4.89891C62.5721 4.22529 64.0003 5.03389 '
        '64.0003 6.34306V20.2103C64.0003 21.1405 63.2461 21.8945 62.3161 21.8945H48.8424C47.9124 21.8945 47.1582 '
        '21.1405 47.1582 20.2103V14.4283Z',
    'M24.3966 26.4593C23.8893 26.7637 23.5789 27.3118 23.5789 27.9034V43.7921L23.5789 45.4751L23.5789 45.4763L23.5789 '
        '48.0001C23.5789 48.9301 22.8249 49.6001 21.8947 49.6001H18.5263C17.5962 49.6001 16.8421 48.9301 16.8421 '
        '48.0001V45.4751V34.976C16.8421 33.6669 15.4139 32.8583 14.2913 33.5319L0.817607 41.6171C0.310362 41.9216 0 '
        '42.4696 0 43.0615V60.6342C0 61.5642 0.754048 62.3184 1.68421 62.3184H15.1579C16.0881 62.3184 16.8421 61.5642 '
        '16.8421 60.6342V58.9488V56.8314C16.8421 55.9011 17.5962 55.3376 18.5263 55.3376H21.8947C22.8249 55.3376 '
        '23.5789 55.9011 23.5789 56.8314V58.9488L23.5789 60.6342C23.5789 61.5642 24.333 62.3184 25.2632 62.3184H38.7368'
        'C39.6669 62.3184 40.4211 61.5642 40.4211 60.6342V45.4763V43.7921V19.8182C40.4211 18.509 38.9928 17.7004 '
        '37.8701 18.374L24.3966 26.4593Z',
    'M47.1592 28.7999V60.7999C47.1592 61.6836 47.9132 62.3999 48.8434 62.3999H62.3171C63.2472 62.3999 64.0013 61.6836 '
        '64.0013 60.7999V28.7999C64.0013 27.9162 63.2472 27.1999 62.3171 27.1999H48.8434C47.9132 27.1999 47.1592 '
        '27.9162 47.1592 28.7999Z',
  ]) {
    writeSvgPathDataToPath(d, b);
  }
  return b.path.transform(Matrix4.diagonal3Values(size.width / 64, size.height / 64, 1).storage);
}

/// Which chain is on in the video: none, extra or unblocker.
final _chainOn = ValueNotifier('none');

/// The clock layout of this round: speed test at 3, extra security at 8, unblocker at 10.
var _chainClock = false;

const _extraColor = Color(0xFF5BD68A);
const _unblockerColor = Color(0xFFFF8A3D);

/// Where a clock hour sits from the button's centre, [r] away.
Offset _hour(double h, {double r = 126}) {
  final a = h / 12 * 2 * math.pi;
  return Offset(r * math.sin(a), -r * math.cos(a));
}

/// The badge's centre: on the button's rim, top left.
final _badgeAt = Offset.fromDirection(-3 * math.pi / 4, 74 + 2);

/// One chain's control: at its hour while off; on, it flies onto the button as its badge, in a
/// small dark disc so it reads on the white face.
class _ChainItem extends StatelessWidget {
  const _ChainItem({required this.name, required this.hour, required this.color, required this.icon});
  final String name;
  final double hour;
  final Color color;

  /// The icon, given whether the chain is on.
  final Widget Function(bool on) icon;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _chainOn,
    builder: (context, on, _) => TweenAnimationBuilder<double>(
      tween: Tween(end: on == name ? 1 : 0),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeInOutCubic,
      builder: (context, t, _) {
        final at = Offset.lerp(_hour(hour), _badgeAt, t)!;
        // an arc, not a straight line: lift toward the outside on the way
        final lift = Offset.fromDirection(at.direction, 18 * math.sin(math.pi * t));
        const disc = 30.0;
        return Positioned(
          left: 74 + at.dx + lift.dx - disc / 2,
          top: 74 + at.dy + lift.dy - disc / 2,
          child: SizedBox.square(
            dimension: disc,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // the shield sits on the button bare; the door keeps a plain dark disc, no ring
                if (name == 'unblocker')
                  Opacity(
                    opacity: t,
                    child: Container(
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1E2128)),
                    ),
                  ),
                // the bare shield grows a little as a badge, so it reads on its own; the door shrinks into its disc
                Transform.scale(scale: name == 'extra' ? 1 + .3 * t : 1 - .15 * t, child: icon(t > .5)),
              ],
            ),
          ),
        );
      },
    ),
  );
}

List<Widget> _chainItems() => [
  _ChainItem(
    name: 'extra',
    hour: 8.5,
    color: _extraColor,
    icon: (on) => _glassShield(on: on),
  ),
  _ChainItem(
    name: 'unblocker',
    hour: 9.5,
    color: _unblockerColor,
    // the app's double door, still: grey while off, orange while on, like the shield
    icon: (on) =>
        PassingDoor(size: 22, color: on ? _unblockerColor : Colors.white.withValues(alpha: .6), animate: false),
  ),
];

/// The video: (which chain is on, seconds).
const _chainTimeline = [
  ('none', 1.5),
  ('extra', 2.2),
  ('none', 1.8),
  ('unblocker', 2.2),
  ('extra', 2.2),
  ('none', 1.8),
];

// ---------- the phone ----------

class _Phone extends StatelessWidget {
  const _Phone(this.design);

  final _Design design;

  @override
  Widget build(BuildContext context) {
    final inRow = design.inRow;
    final card = Stack(
      clipBehavior: Clip.none,
      children: [
        const _GlassCard(),
        if (inRow != null)
          Positioned(
            right: _rowEnd,
            top: _rowMiddle - 30,
            height: 60,
            child: Center(child: Builder(builder: inRow)),
          ),
      ],
    );
    return Theme(
      data: _theme(),
      child: Material(
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox.fromSize(
            size: _phone,
            child: Stack(
              children: [
                const Positioned.fill(child: _HomeBackground()),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 18,
                  child: BackdropGroup(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (design.above case final above?) Builder(builder: above),
                        card,
                        if (design.below case final below?) Builder(builder: below),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const _Round(child: Icon(Icons.add_rounded, size: 28)),
                            const SizedBox(width: 10),
                            const _Bar(),
                            const SizedBox(width: 10),
                            if (design.barEnd case final barEnd?)
                              Builder(builder: barEnd)
                            else
                              const _Round(child: Icon(Icons.tune_rounded, size: 28)),
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
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  for (final mode in ['before', 'testing', 'after', 'failed']) {
    final tested = mode == 'after';
    testWidgets('speed test ideas, $mode', (tester) async {
      _tested = tested;
      _testing = mode == 'testing';
      _failed = mode == 'failed';
      await tester.runAsync(_load);
      const labelHeight = 30.0;
      final only = Platform.environment['ONLY'];
      final designs = only == null
          ? _designs
          : only == 'U'
          ? _untested
          : only == 'T'
          ? _tabs10
          : only == 'S'
          ? _tabStates
          : _designs.where((d) => d.name.startsWith(only)).toList();
      final perRow = only == null || only == 'U' || only == 'T'
          ? 5
          : only == 'S'
          ? 4
          : designs.length;
      await tester.binding.setSurfaceSize(
        Size((_phone.width + 14) * perRow + 14, (labelHeight + _phone.height + 14) * (designs.length / perRow).ceil()),
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
                      for (var row = 0; row < (designs.length / perRow).ceil(); row++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              for (final d in designs.skip(row * perRow).take(perRow))
                                Column(
                                  children: [
                                    SizedBox(
                                      height: labelHeight,
                                      child: Center(
                                        child: Text(
                                          '${d.name} · ${mode == 'before' ? 'before the test' : mode}',
                                          style: label,
                                        ),
                                      ),
                                    ),
                                    _Phone(d),
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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        await Directory(out).create(recursive: true);
        final image = await boundary.toImage(pixelRatio: 1.25);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$out/speed_ideas${only == null ? '' : '_${only.toLowerCase()}'}_$mode.png',
        ).writeAsBytes(png!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  }

  /// Pumps [child] under one container like the ideas', waits for the card, and saves it as [name].
  Future<void> shoot(WidgetTester tester, Size surface, Widget child, String name, {double ratio = 2}) async {
    await tester.runAsync(_load);
    await tester.binding.setSurfaceSize(surface);
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
        connectionNotifierProvider.overrideWith(_Conn.new),
        mainOutboundsNotifierProvider.overrideWith(_Main.new),
        statsNotifierProvider.overrideWith(_Stats.new),
      ],
    );
    addTearDown(container.dispose);
    container
      ..listen(translationsProvider, (_, _) {})
      ..listen(sharedPreferencesProvider, (_, _) {})
      ..listen(activeProxyCardProvider, (_, _) {});
    final key = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Material(
            child: RepaintBoundary(
              key: key,
              child: ColoredBox(color: Colors.black, child: child),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory(out).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: ratio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  const label = TextStyle(color: Colors.white, fontSize: 15, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);

  testWidgets('arrow ideas', (tester) async {
    const perRow = 2;
    final rows = (_arrows10.length / perRow).ceil();
    await shoot(
      tester,
      Size((_phone.width + 14) * perRow + 14, (30 + 120 + 14.0) * rows),
      Column(
        children: [
          for (var row = 0; row < rows; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final (name, arrow) in _arrows10.skip(row * perRow).take(perRow))
                    Column(
                      children: [
                        SizedBox(
                          height: 30,
                          child: Center(child: Text(name, style: label)),
                        ),
                        _CardTop(arrow),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
      'speed_arrows',
      ratio: 2.5,
    );
  });

  testWidgets('speed beside the ping', (tester) async {
    const states = ['untested', 'testing', 'tested', 'failed'];
    await shoot(
      tester,
      Size((_HomePhone.size.width + 14) * states.length + 14, _HomePhone.size.height + 30 + 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in states)
            Column(
              children: [
                SizedBox(
                  height: 30,
                  child: Center(child: Text(s, style: label)),
                ),
                _HomePhone(s),
              ],
            ),
        ],
      ),
      'speed_beside_ping',
      ratio: 1.25,
    );
  });

  for (final state in ['untested', 'testing', 'tested', 'dead']) {
    testWidgets('ping and speed ideas, $state', (tester) async {
      _dead = state == 'dead';
      addTearDown(() => _dead = false);
      const perRow = 4;
      final rows = (_status10.length / perRow).ceil();
      // only the button, its status and the line under it
      const top = 150.0;
      const height = 440.0;
      await shoot(
        tester,
        Size((_HomePhone.size.width + 14) * perRow + 14, (30 + height + 14) * rows),
        Column(
          children: [
            for (var row = 0; row < rows; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final (name, status) in _status10.skip(row * perRow).take(perRow))
                      Column(
                        children: [
                          SizedBox(
                            height: 30,
                            child: Center(
                              child: Text('$name · ${state == 'dead' ? 'switch to fastest' : state}', style: label),
                            ),
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: SizedBox(
                              width: _HomePhone.size.width,
                              height: height,
                              child: OverflowBox(
                                alignment: Alignment.topCenter,
                                maxHeight: _HomePhone.size.height,
                                child: Transform.translate(
                                  offset: const Offset(0, -top),
                                  child: _HomePhone(state, status),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
        'ping_speed_$state',
        ratio: 1.5,
      );
    });
  }

  for (final state in ['untested', 'tested']) {
    testWidgets('speed spots compared, $state', (tester) async {
      _video.value = state;
      final phones = <(String, Widget)>[
        ('Tab on the card', _HomePhone(state, null, true)),
        ('P2  Twin pills', _HomePhone(state, (c, s) => const _LiveStatus('P2'))),
        ('P10  Quality glow', _HomePhone(state, (c, s) => const _LiveStatus('P10'))),
      ];
      await shoot(
        tester,
        Size((_HomePhone.size.width + 14) * phones.length + 14, _HomePhone.size.height + 30 + 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (name, phone) in phones)
              Column(
                children: [
                  SizedBox(
                    height: 30,
                    child: Center(child: Text('$name · $state', style: label)),
                  ),
                  phone,
                ],
              ),
          ],
        ),
        'speed_compare_$state',
        ratio: 1.25,
      );
    });
  }

  testWidgets('P10 gap variants', (tester) async {
    const designs = {'P10': 'P10  divider', 'P10c': 'P10  cut at the divider'};
    const states = ['untested', 'tested', 'offer'];
    // the pill only: the button's label would say Connected beside the offer here
    const top = 360.0;
    const height = 60.0;
    _pick.value = 'ok';
    final rows = <Widget>[];
    for (final state in states) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final MapEntry(key: id, value: name) in designs.entries)
                Column(
                  children: [
                    SizedBox(
                      height: 30,
                      child: Center(child: Text('$name · $state', style: label)),
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: _HomePhone.size.width,
                        height: height,
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          maxHeight: _HomePhone.size.height,
                          child: Transform.translate(
                            offset: const Offset(0, -top),
                            child: _HomePhone(state, (c, s) => _FixedStatus(id, state)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      );
    }
    await shoot(
      tester,
      Size((_HomePhone.size.width + 14) * designs.length + 14, (height + 30 + 14) * states.length),
      Column(children: rows),
      'p10_gap',
      ratio: 2,
    );
  });

  for (final state in ['untested', 'tested', 'offer']) {
    testWidgets('home with P10c, $state', (tester) async {
      _dead = state == 'offer';
      addTearDown(() => _dead = false);
      await shoot(
        tester,
        Size(_HomePhone.size.width + 28, _HomePhone.size.height + 30 + 14),
        Column(
          children: [
            SizedBox(
              height: 30,
              child: Center(child: Text(state, style: label)),
            ),
            _HomePhone(state, (c, s) => _FixedStatus('P10c', state)),
          ],
        ),
        'home_p10c_$state',
        ratio: 1.5,
      );
    });
  }

  for (final look in [11, 12, 13, 14, 15, 16]) {
    testWidgets('offer colors, $look', (tester) async {
      _dead = true;
      _offerLook = look;
      addTearDown(() {
        _dead = false;
        _offerLook = 0;
      });
      await shoot(
        tester,
        Size(_HomePhone.size.width + 28, 90),
        SizedBox(
          height: 90,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              maxHeight: _HomePhone.size.height,
              child: Transform.translate(
                offset: const Offset(0, -350),
                child: _HomePhone('offer', (c, s) => const _FixedStatus('P10c', 'offer')),
              ),
            ),
          ),
        ),
        'offer_color_$look',
        ratio: 2,
      );
    });
  }

  for (final glass in [false, true]) {
    for (final on in [false, true]) {
      testWidgets('connect button, glass $glass, on $on', (tester) async {
        EclipseButtonPainter.glassFace = glass;
        _running = on;
        addTearDown(() {
          EclipseButtonPainter.glassFace = false;
          EclipseButtonPainter.glassStyle = 0;
          _running = true;
        });
        await shoot(
          tester,
          Size(_HomePhone.size.width + 28, 30 + 330.0),
          Column(
            children: [
              SizedBox(
                height: 30,
                child: Center(
                  child: Text('${glass ? 'Glass face' : 'Today'} · ${on ? 'connected' : 'disconnected'}', style: label),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  width: _HomePhone.size.width,
                  height: 330,
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    maxHeight: _HomePhone.size.height,
                    child: Transform.translate(
                      offset: const Offset(0, -130),
                      child: _HomePhone(
                        'tested',
                        (c, s) => on ? const _FixedStatus('P10c', 'tested') : const SizedBox(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          'button_glass_${glass ? 'glass' : 'today'}_${on ? 'on' : 'off'}',
          ratio: 2,
        );
      });
    }
  }

  for (final (style, styleName) in [
    (0, 'S1  Light frost, deeper logo (now)'),
    (1, 'S2  Milky glass, logo as today'),
    (2, 'S3  Clear dark glass, light logo'),
    (3, 'S4  Glass tinted by state, white logo'),
    (4, 'S5  Clear glass, soft glow, light logo'),
  ]) {
    testWidgets('glass button style $style', (tester) async {
      await tester.runAsync(_load);
      EclipseButtonPainter.glassFace = true;
      EclipseButtonPainter.glassStyle = 2;
      EclipseButtonPainter.hideLabel = true;
      EclipseButtonPainter.hideBadge = true;
      EclipseButtonPainter.glassStyle = style;
      addTearDown(() {
        EclipseButtonPainter.glassFace = false;
        EclipseButtonPainter.hideLabel = false;
        EclipseButtonPainter.hideBadge = false;
        EclipseButtonPainter.glassStyle = 0;
      });
      final states = <(String, ConnectionStatus, bool)>[
        ('Disconnected', const Disconnected(), false),
        ('Connecting', const Connecting(), false),
        ('Connected', const Connected(), false),
        ('Not responding', const Connected(), true),
        ('Couldn’t connect', const Disconnected(ConnectionFailure.unexpected()), false),
      ];
      const tile = Size(220, 220);
      await tester.binding.setSurfaceSize(Size((tile.width + 10) * states.length + 10, tile.height + 70));
      final containers = [
        for (final (_, status, dead) in states)
          ProviderContainer(
            overrides: [
              translationsProvider.overrideWith((ref) => AppLocale.en.build()),
              sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
              connectionNotifierProvider.overrideWith(() => _FixedConn(status)),
              mainOutboundsNotifierProvider.overrideWith(() => _FixedMain(dead)),
              statsNotifierProvider.overrideWith(_Stats.new),
            ],
          ),
      ];
      for (final container in containers) {
        addTearDown(container.dispose);
        container
          ..listen(translationsProvider, (_, _) {})
          ..listen(sharedPreferencesProvider, (_, _) {})
          ..listen(activeProxyCardProvider, (_, _) {})
          ..listen(connectionHealthProvider, (_, _) {});
      }
      final key = GlobalKey();
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
                      height: 34,
                      child: Center(child: Text(styleName, style: label)),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final (i, (name, _, _)) in states.indexed)
                          UncontrolledProviderScope(
                            container: containers[i],
                            child: Column(
                              children: [
                                SizedBox(
                                  height: 24,
                                  child: Text(name, style: label.copyWith(fontSize: 13, color: Colors.white70)),
                                ),
                                Theme(
                                  data: _theme(),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: SizedBox.fromSize(
                                      size: tile,
                                      child: Stack(
                                        children: [
                                          const Positioned.fill(child: _HomeBackground()),
                                          Center(
                                            child: BackdropGroup(
                                              child: MediaQuery(
                                                data: const MediaQueryData(
                                                  size: Size(380, 900),
                                                  disableAnimations: true,
                                                ),
                                                child: const ConnectionButton(),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/button_style_$style.png').writeAsBytes(png!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  }

  testWidgets('glass faces', (tester) async {
    await tester.runAsync(_load);
    EclipseButtonPainter.glassFace = true;
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    EclipseButtonPainter.glassStyle = 2;
    addTearDown(() {
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.debugFace = null;
    });
    final states = <(String, ConnectionStatus)>[
      ('Disconnected', const Disconnected()),
      ('Connected', const Connected()),
      ('Couldn’t connect', const Disconnected(ConnectionFailure.unexpected())),
    ];
    const tile = Size(200, 200);
    const perRow = 2;
    final rows = (_faces.length / perRow).ceil();
    final groupWidth = (tile.width + 6) * states.length;
    await tester.binding.setSurfaceSize(Size((groupWidth + 24) * perRow + 24, (tile.height + 40) * rows + 10));
    final containers = [
      for (final (_, status) in states)
        ProviderContainer(
          overrides: [
            translationsProvider.overrideWith((ref) => AppLocale.en.build()),
            sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
            connectionNotifierProvider.overrideWith(() => _FixedConn(status)),
            mainOutboundsNotifierProvider.overrideWith(() => _FixedMain(false)),
            statsNotifierProvider.overrideWith(_Stats.new),
          ],
        ),
    ];
    for (final container in containers) {
      addTearDown(container.dispose);
      container
        ..listen(translationsProvider, (_, _) {})
        ..listen(sharedPreferencesProvider, (_, _) {})
        ..listen(activeProxyCardProvider, (_, _) {})
        ..listen(connectionHealthProvider, (_, _) {});
    }
    Widget tileFor(int face, int state) => UncontrolledProviderScope(
      container: containers[state],
      child: Theme(
        data: _theme(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox.fromSize(
            size: tile,
            child: Stack(
              children: [
                const Positioned.fill(child: _HomeBackground()),
                Center(
                  child: BackdropGroup(
                    child: MediaQuery(
                      data: const MediaQueryData(size: Size(380, 900), disableAnimations: true),
                      child: _FaceScope(face: _faces[face].$2, child: const ConnectionButton()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // every button reads its face through the one hook; the tile above it says which
    EclipseButtonPainter.debugFace = (context, color) =>
        context.dependOnInheritedWidgetOfExactType<_FaceScope>()!.face(color);
    final key = GlobalKey();
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
                  for (var row = 0; row < rows; row++)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (var face = row * perRow; face < math.min(_faces.length, row * perRow + perRow); face++)
                          Column(
                            children: [
                              SizedBox(
                                height: 34,
                                child: Center(child: Text(_faces[face].$1, style: label)),
                              ),
                              Row(
                                children: [
                                  for (var state = 0; state < states.length; state++)
                                    Padding(padding: const EdgeInsets.all(3), child: tileFor(face, state)),
                                ],
                              ),
                            ],
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.25);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/glass_faces.png').writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('glass speed icons', (tester) async {
    const tile = Size(170, 110);
    // ICONS=i7: I7 painted beside I7 cut from glass
    final list = Platform.environment['ICONS'] == 'i7' ? _i7Glass : _icons;
    final perRow = list.length < 4 ? list.length : 4;
    final rows = (list.length / perRow).ceil();
    await shoot(
      tester,
      Size((tile.width + 10) * perRow + 10, (tile.height + 34) * rows + 6),
      Theme(
        data: _theme(),
        child: Column(
          children: [
            for (var row = 0; row < rows; row++)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final (name, icon) in list.skip(row * perRow).take(perRow))
                    Column(
                      children: [
                        SizedBox(
                          height: 30,
                          child: Center(child: Text(name, style: label.copyWith(fontSize: 11))),
                        ),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox.fromSize(
                            size: tile,
                            child: Stack(
                              children: [
                                const Positioned.fill(child: _HomeBackground()),
                                Center(child: BackdropGroup(child: icon)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
          ],
        ),
      ),
      Platform.environment['ICONS'] == 'i7' ? 'glass_i7' : 'glass_speed_icons',
      ratio: 3,
    );
  });

  testWidgets('speed result layouts', (tester) async {
    const tile = Size(190, 130);
    // PICK=8,10: only those layouts, with the speedometer cut from glass
    final pick = Platform.environment['PICK']?.split(',').map(int.parse).toList();
    final layouts = pick == null ? _layouts : [for (final i in pick) _layouts[i - 1]];
    final perRow = layouts.length < 5 ? layouts.length : 5;
    final rows = (layouts.length / perRow).ceil();
    await shoot(
      tester,
      Size((tile.width + 10) * perRow + 10, (tile.height + 34) * rows + 6),
      Theme(
        data: _theme(),
        child: Column(
          children: [
            for (var row = 0; row < rows; row++)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final (name, layout) in layouts.skip(row * perRow).take(perRow))
                    Column(
                      children: [
                        SizedBox(
                          height: 30,
                          child: Center(child: Text(name, style: label.copyWith(fontSize: 11))),
                        ),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox.fromSize(
                            size: tile,
                            child: Stack(
                              children: [
                                const Positioned.fill(child: _HomeBackground()),
                                Positioned(
                                  top: 18,
                                  left: 0,
                                  right: 0,
                                  child: BackdropGroup(
                                    child: Column(
                                      children: [
                                        if (pick == null) const _GlassDialIcon(size: 32) else _i7Glass[2].$2,
                                        const SizedBox(height: 4),
                                        Builder(builder: layout),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
          ],
        ),
      ),
      pick == null ? 'speed_layouts' : 'speed_layouts_pick',
      ratio: 2.5,
    );
  });

  testWidgets('home tops', (tester) async {
    // TOP=0: only that one
    final only = Platform.environment['TOP'];
    final tops = only == null ? _tops : [_tops[int.parse(only)]];
    _conn.value = 'connected';
    _video.value = 'tested';
    _pick.value = 'ok';
    _line.value = ('Connected', _greenLine);
    // the button's white face, as before the glass
    EclipseButtonPainter.glassFace = false;
    EclipseButtonPainter.glassStyle = 2;
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    EclipseButtonPainter.debugNow = () => 30;
    _mapAlpha = double.parse(Platform.environment['MAP'] ?? '.02');
    _pingBare = Platform.environment['PINGBARE'] != '0';
    _speedRight = Platform.environment['SPEEDRIGHT'] != '0';
    debugActiveProxyRowHeight = double.parse(Platform.environment['ROW'] ?? '60');
    _glassLogo = Platform.environment['GLASSLOGO'] == '1';
    EclipseButtonPainter.hideLogo = _glassLogo;
    final face = double.tryParse(Platform.environment['FACE'] ?? '');
    if (face != null) {
      // the white face, [face] opaque: the rest is the glass under it
      EclipseButtonPainter.glassFace = true;
      EclipseButtonPainter.glassStyle = 1;
      EclipseButtonPainter.debugFace = (context, color) => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: face),
        ),
      );
    }
    _chainClock = true;
    addTearDown(() {
      _glassLogo = false;
      _chainClock = false;
      EclipseButtonPainter.hideLogo = false;
      EclipseButtonPainter.debugFace = null;
    });
    addTearDown(() => debugActiveProxyRowHeight = 76);
    addTearDown(() {
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.debugNow = null;
      _conn.value = 'disconnected';
      _video.value = 'untested';
      _line.value = null;
    });
    await shoot(
      tester,
      Size((_HomePhone.size.width + 14) * tops.length + 14, _HomePhone.size.height + 44 + 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (name, top) in tops)
            Column(
              children: [
                SizedBox(
                  height: 44,
                  child: Center(child: Text(name, style: label)),
                ),
                _SunHome(top: top),
              ],
            ),
        ],
      ),
      Platform.environment['NAME'] ?? 'home_tops',
      ratio: 1.5,
    );
  });

  for (final on in [false, true]) {
    testWidgets('extra security entries, on $on', (tester) async {
      _conn.value = 'connected';
      _video.value = 'untested';
      _pick.value = 'ok';
      _line.value = ('Connected', _greenLine);
      _secOn = on;
      // the button's white face, as before the glass
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.glassStyle = 2;
      EclipseButtonPainter.hideLabel = true;
      EclipseButtonPainter.hideBadge = true;
      EclipseButtonPainter.debugNow = () => 30;
      debugActiveProxyRowHeight = 60;
      addTearDown(() {
        EclipseButtonPainter.glassFace = false;
        EclipseButtonPainter.glassStyle = 0;
        EclipseButtonPainter.hideLabel = false;
        EclipseButtonPainter.hideBadge = false;
        EclipseButtonPainter.debugNow = null;
        debugActiveProxyRowHeight = 76;
        _secLook = 0;
        _conn.value = 'disconnected';
        _line.value = null;
      });
      const top = 150.0;
      const height = 380.0;
      // one phone per idea; each sets the look while it builds
      Widget phone(int look) => Builder(
        builder: (context) {
          _secLook = look;
          return ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              width: _HomePhone.size.width,
              height: height,
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: _HomePhone.size.height,
                child: Transform.translate(
                  offset: const Offset(0, -top),
                  child: _SunHome(top: _top0),
                ),
              ),
            ),
          );
        },
      );
      await shoot(
        tester,
        Size((_HomePhone.size.width + 14) * 3 + 14, (height + 44) * 2 + 10),
        Column(
          children: [
            for (final row in [
              [1, 2, 3],
              [4, 5, 6],
            ])
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final look in row)
                    Column(
                      children: [
                        SizedBox(
                          height: 44,
                          child: Center(child: Text('${_secNames[look]} · ${on ? 'on' : 'off'}', style: label)),
                        ),
                        phone(look),
                      ],
                    ),
                ],
              ),
          ],
        ),
        'sec_entries_${on ? 'on' : 'off'}',
        ratio: 1.5,
      );
    });
  }

  testWidgets('extra security beside or in a column', (tester) async {
    _conn.value = 'connected';
    _video.value = 'tested';
    _pick.value = 'ok';
    _line.value = ('Connected', _greenLine);
    _secLook = 1;
    // the button's white face, as before the glass
    EclipseButtonPainter.glassFace = false;
    EclipseButtonPainter.glassStyle = 2;
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    EclipseButtonPainter.debugNow = () => 30;
    debugActiveProxyRowHeight = 60;
    addTearDown(() {
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.debugNow = null;
      debugActiveProxyRowHeight = 76;
      _secLook = 0;
      _secColumn = false;
      _secClock = false;
      _secClockRight = false;
      _secOn = false;
      _conn.value = 'disconnected';
      _video.value = 'untested';
      _line.value = null;
    });
    // each phone sets its own arrangement while it builds
    Widget phone(String mode, bool on) => Builder(
      builder: (context) {
        _secColumn = mode != 'side';
        _secClock = mode == 'left';
        _secClockRight = mode == 'right';
        _secOn = on;
        return const _SunHome(top: _top0);
      },
    );
    await shoot(
      tester,
      Size((_HomePhone.size.width + 14) * 6 + 14, _HomePhone.size.height + 44 + 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (mode, on) in [
            ('side', false),
            ('left', false),
            ('right', false),
            ('side', true),
            ('left', true),
            ('right', true),
          ])
            Column(
              children: [
                SizedBox(
                  height: 44,
                  child: Center(
                    child: Text(
                      '${switch (mode) {
                        'left' => 'Speed at 9, shield at 10',
                        'right' => 'Speed at 3, shield at 2',
                        _ => 'Either side',
                      }} · ${on ? 'on' : 'off'}',
                      style: label,
                    ),
                  ),
                ),
                phone(mode, on),
              ],
            ),
        ],
      ),
      Platform.environment['CLOCK'] == '1' ? 'sec_clock' : 'sec_column',
      ratio: 1.25,
    );
  });

  testWidgets('twenty buttons', (tester) async {
    final buttons = Platform.environment['SET'] == 'sun' ? _buttonsSun : _buttons20;
    await tester.runAsync(_load);
    EclipseButtonPainter.glassFace = true;
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    EclipseButtonPainter.debugFace = (context, color) =>
        context.dependOnInheritedWidgetOfExactType<_FaceScope>()!.face(color);
    // each tile's logo color, as the button would pick it for that style
    EclipseButtonPainter.debugLogo = (context, color) {
      final style = context.dependOnInheritedWidgetOfExactType<_FaceScope>()?.logo;
      final hsl = HSLColor.fromColor(color);
      final saturated = hsl.withSaturation((hsl.saturation + .12).clamp(0.0, 1.0));
      return switch (style) {
        _logoLight => hsl.withLightness(.72).toColor(),
        _logoMid => saturated.withLightness(.46).toColor(),
        _logoWhite => Colors.white,
        _ => color,
      };
    };
    addTearDown(() {
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.debugFace = null;
      EclipseButtonPainter.debugLogo = null;
    });
    final states = <ConnectionStatus>[const Disconnected(), const Connected()];
    const tile = Size(176, 176);
    const perRow = 5;
    final rows = (buttons.length / perRow).ceil();
    final group = (tile.width + 4) * states.length;
    await tester.binding.setSurfaceSize(Size((group + 16) * perRow + 16, (tile.height + 34) * rows + 8));
    final containers = [
      for (final status in states)
        ProviderContainer(
          overrides: [
            translationsProvider.overrideWith((ref) => AppLocale.en.build()),
            sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
            connectionNotifierProvider.overrideWith(() => _FixedConn(status)),
            mainOutboundsNotifierProvider.overrideWith(() => _FixedMain(false)),
            statsNotifierProvider.overrideWith(_Stats.new),
          ],
        ),
    ];
    for (final container in containers) {
      addTearDown(container.dispose);
      container
        ..listen(translationsProvider, (_, _) {})
        ..listen(sharedPreferencesProvider, (_, _) {})
        ..listen(activeProxyCardProvider, (_, _) {})
        ..listen(connectionHealthProvider, (_, _) {});
    }
    // each tile sets the logo's coloring while it builds; the button reads it then
    Widget tileFor(int i, int state) => UncontrolledProviderScope(
      container: containers[state],
      child: Theme(
        data: _theme(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox.fromSize(
            size: tile,
            child: Stack(
              children: [
                const Positioned.fill(child: _HomeBackground()),
                Center(
                  child: BackdropGroup(
                    child: MediaQuery(
                      data: const MediaQueryData(size: Size(380, 900), disableAnimations: true),
                      child: _FaceScope(face: buttons[i].$3, logo: buttons[i].$2, child: const ConnectionButton()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final key = GlobalKey();
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
                  for (var row = 0; row < rows; row++)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (var i = row * perRow; i < math.min(buttons.length, row * perRow + perRow); i++)
                          Column(
                            children: [
                              SizedBox(
                                height: 30,
                                child: Center(child: Text(buttons[i].$1, style: label.copyWith(fontSize: 13))),
                              ),
                              Row(
                                children: [
                                  for (var state = 0; state < states.length; state++)
                                    Padding(padding: const EdgeInsets.all(2), child: tileFor(i, state)),
                                ],
                              ),
                            ],
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        Platform.environment['SET'] == 'sun' ? '$out/buttons_sun.png' : '$out/buttons20.png',
      ).writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('chain badges video', (tester) async {
    await tester.runAsync(_load);
    _conn.value = 'connected';
    _video.value = 'untested';
    _pick.value = 'ok';
    _line.value = ('Connected', _greenLine);
    _chainOn.value = 'none';
    _chainClock = true;
    _fakeNow = 0;
    // the approved button: white face, solid under the logo, 20 % glass toward the rim
    EclipseButtonPainter.glassFace = true;
    EclipseButtonPainter.glassStyle = 1;
    EclipseButtonPainter.debugFace = (context, color) => const DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [Colors.white, Colors.white, Color(0xCCFFFFFF)], stops: [0, .6, 1]),
      ),
    );
    addTearDown(() {
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.debugFace = null;
    });
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    EclipseButtonPainter.debugNow = () => _fakeNow;
    debugActiveProxyRowHeight = 60;
    addTearDown(() {
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.debugNow = null;
      debugActiveProxyRowHeight = 76;
      _chainClock = false;
      _conn.value = 'disconnected';
      _line.value = null;
    });
    await tester.binding.setSurfaceSize(Size(_HomePhone.size.width + 28, _HomePhone.size.height + 28));
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
        connectionNotifierProvider.overrideWith(_Conn.new),
        mainOutboundsNotifierProvider.overrideWith(_Main.new),
        statsNotifierProvider.overrideWith(_Stats.new),
      ],
    );
    addTearDown(container.dispose);
    container
      ..listen(translationsProvider, (_, _) {})
      ..listen(sharedPreferencesProvider, (_, _) {})
      ..listen(activeProxyCardProvider, (_, _) {});
    final key = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Material(
            child: RepaintBoundary(
              key: key,
              child: const ColoredBox(
                color: Colors.black,
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: _SunHome(top: _top0),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> step(Duration d) async {
      _fakeNow += d.inMicroseconds / 1e6;
      await tester.pump(d);
    }

    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await step(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final frames = Directory('$out/chain_frames');
    await tester.runAsync(() async {
      if (frames.existsSync()) await frames.delete(recursive: true);
      await frames.create(recursive: true);
    });
    final only = Platform.environment['FRAMES'];
    var n = 0;
    for (final (on, seconds) in _chainTimeline) {
      _chainOn.value = on;
      for (var i = 0; i < seconds * 30; i++) {
        await step(const Duration(microseconds: 1000000 ~/ 30));
        final index = n++;
        if (only != null && !only.split(',').contains('$index')) continue;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${frames.path}/f_${index.toString().padLeft(4, '0')}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('glass hi logo', (tester) async {
    await tester.runAsync(_load);
    // the face is the hook's in every tile, so white, part glass, clear and smoked sit side by side
    EclipseButtonPainter.glassFace = true;
    EclipseButtonPainter.glassStyle = 1;
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    EclipseButtonPainter.hideLogo = true;
    EclipseButtonPainter.debugFace = (context, color) =>
        context.dependOnInheritedWidgetOfExactType<_FaceScope>()!.face(color);
    addTearDown(() {
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.hideLogo = false;
      EclipseButtonPainter.debugFace = null;
    });
    Widget fill(Color c) => DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    );
    final faces = <(String, Widget Function(Color))>[
      ('White face', (c) => fill(Colors.white)),
      ('White, 12 % glass', (c) => fill(Colors.white.withValues(alpha: .88))),
      ('Clear glass', (c) => const SizedBox.expand()),
      ('Smoked glass', (c) => fill(Colors.black.withValues(alpha: .25))),
    ];
    LinearGradient down(Color top, Color bottom) =>
        LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]);
    final tints = <(String, Gradient)>[
      ('Deep green', down(const Color(0xE644A334), const Color(0xB344A334))),
      ('Light green', down(const Color(0xCC7BE07A), const Color(0x9944A334))),
      ('Green to teal', down(const Color(0xD95BD68A), const Color(0xB33CC8E0))),
      ('Faint green', down(const Color(0x8044A334), const Color(0x4D44A334))),
      ('White', down(const Color(0xCCFFFFFF), const Color(0x80FFFFFF))),
    ];
    const tile = Size(176, 176);
    await tester.binding.setSurfaceSize(
      Size(130 + (tile.width + 6) * tints.length + 10, 34 + (tile.height + 6) * faces.length + 10),
    );
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
        connectionNotifierProvider.overrideWith(() => _FixedConn(const Connected())),
        mainOutboundsNotifierProvider.overrideWith(() => _FixedMain(false)),
        statsNotifierProvider.overrideWith(_Stats.new),
      ],
    );
    addTearDown(container.dispose);
    container
      ..listen(translationsProvider, (_, _) {})
      ..listen(sharedPreferencesProvider, (_, _) {})
      ..listen(activeProxyCardProvider, (_, _) {})
      ..listen(connectionHealthProvider, (_, _) {});
    Widget tileFor(Widget Function(Color) face, Gradient tint) => ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox.fromSize(
        size: tile,
        child: Stack(
          children: [
            const Positioned.fill(child: _HomeBackground()),
            Center(
              child: BackdropGroup(
                child: MediaQuery(
                  data: const MediaQueryData(size: Size(380, 900), disableAnimations: true),
                  child: _FaceScope(
                    face: face,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const ConnectionButton(),
                        // the logo where the painter draws it: half the button wide, a touch high
                        Transform.translate(
                          offset: const Offset(0, -1.5),
                          child: _GlassShape(_logoShape, size: 74, rim: .7, tint: tint),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    const small = TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    final key = GlobalKey();
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
                child: Theme(
                  data: _theme(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const SizedBox(width: 130),
                          for (final (name, _) in tints)
                            SizedBox(
                              width: tile.width + 6,
                              height: 34,
                              child: Center(child: Text(name, style: small)),
                            ),
                        ],
                      ),
                      for (final (faceName, face) in faces)
                        Row(
                          children: [
                            SizedBox(
                              width: 130,
                              child: Center(child: Text(faceName, style: small)),
                            ),
                            for (final (_, tint) in tints)
                              Padding(padding: const EdgeInsets.all(3), child: tileFor(face, tint)),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/glass_hi.png').writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('white face glass levels', (tester) async {
    await tester.runAsync(_load);
    EclipseButtonPainter.glassFace = true;
    EclipseButtonPainter.glassStyle = 1;
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    EclipseButtonPainter.debugFace = (context, color) =>
        context.dependOnInheritedWidgetOfExactType<_FaceScope>()!.face(color);
    addTearDown(() {
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.debugFace = null;
    });
    // how much of the white face is glass
    final levels =
        Platform.environment['LEVELS']?.split(',').map(int.parse).toList() ?? const [0, 5, 10, 15, 20, 30, 40];
    final states = <(String, ConnectionStatus)>[
      ('Disconnected', const Disconnected()),
      ('Connected', const Connected()),
    ];
    const tile = Size(176, 176);
    await tester.binding.setSurfaceSize(
      Size(120 + (tile.width + 6) * levels.length + 10, 34 + (tile.height + 6) * states.length + 10),
    );
    final containers = [
      for (final (_, status) in states)
        ProviderContainer(
          overrides: [
            translationsProvider.overrideWith((ref) => AppLocale.en.build()),
            sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
            connectionNotifierProvider.overrideWith(() => _FixedConn(status)),
            mainOutboundsNotifierProvider.overrideWith(() => _FixedMain(false)),
            statsNotifierProvider.overrideWith(_Stats.new),
          ],
        ),
    ];
    for (final container in containers) {
      addTearDown(container.dispose);
      container
        ..listen(translationsProvider, (_, _) {})
        ..listen(sharedPreferencesProvider, (_, _) {})
        ..listen(activeProxyCardProvider, (_, _) {})
        ..listen(connectionHealthProvider, (_, _) {});
    }
    Widget tileFor(int level, int state) => UncontrolledProviderScope(
      container: containers[state],
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox.fromSize(
          size: tile,
          child: Stack(
            children: [
              const Positioned.fill(child: _HomeBackground()),
              Center(
                child: BackdropGroup(
                  child: MediaQuery(
                    data: const MediaQueryData(size: Size(380, 900), disableAnimations: true),
                    child: _FaceScope(
                      // RING=1: white stays solid under the logo, the glass only toward the rim
                      face: (c) => DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Platform.environment['RING'] == '1'
                              ? null
                              : Colors.white.withValues(alpha: 1 - level / 100),
                          gradient: Platform.environment['RING'] == '1'
                              ? RadialGradient(
                                  colors: [
                                    Colors.white,
                                    Colors.white,
                                    Colors.white.withValues(alpha: 1 - level / 100),
                                  ],
                                  stops: const [0, .6, 1],
                                )
                              : null,
                        ),
                      ),
                      child: const ConnectionButton(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    const small = TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black,
              child: Theme(
                data: _theme(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 120),
                        for (final level in levels)
                          SizedBox(
                            width: tile.width + 6,
                            height: 34,
                            child: Center(child: Text(level == 0 ? 'White (now)' : '$level % glass', style: small)),
                          ),
                      ],
                    ),
                    for (var state = 0; state < states.length; state++)
                      Row(
                        children: [
                          SizedBox(
                            width: 120,
                            child: Center(child: Text(states[state].$1, style: small)),
                          ),
                          for (final level in levels)
                            Padding(padding: const EdgeInsets.all(3), child: tileFor(level, state)),
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
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        Platform.environment['RING'] == '1' ? '$out/face_levels_ring.png' : '$out/face_levels.png',
      ).writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('status dot, tinted and clear', (tester) async {
    Widget line(String text, Color color, {required int look}) => SizedBox(
      width: 280,
      height: 44,
      child: Stack(
        children: [
          const Positioned.fill(child: _HomeBackground()),
          Center(
            child: BackdropGroup(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GlassDot(color, look: look),
                  const SizedBox(width: 9),
                  Text(text, style: label.copyWith(fontSize: 14, color: Colors.white.withValues(alpha: .92))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    await shoot(
      tester,
      const Size(4 * 290 + 20, 4 * 52 + 40),
      Theme(
        data: _theme(),
        child: Column(
          children: [
            const SizedBox(
              height: 30,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Text('Even', style: label),
                  Text('From the side', style: label),
                  Text('From the centre', style: label),
                  Text('From the bottom', style: label),
                ],
              ),
            ),
            for (final (text, color) in [
              ('Connecting…', _blue),
              ('Connected', _greenLine),
              ('Selected proxy isn’t responding', _orange),
              ('Disconnecting…', _blue),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [for (var look = 0; look < 4; look++) line(text, color, look: look)],
                ),
              ),
          ],
        ),
      ),
      'status_dot',
      ratio: 2.5,
    );
  });

  testWidgets('sun video', (tester) async {
    await tester.runAsync(_load);
    // FACES=4,5,6: one phone per glass treatment, side by side
    final faces = Platform.environment['FACES']?.split(',').map(int.parse).toList();
    final both = Platform.environment['SPEEDAT'] == 'both';
    final phones = both ? 2 : faces?.length ?? 1;
    await tester.binding.setSurfaceSize(
      Size((_HomePhone.size.width + 14) * phones + 14, _HomePhone.size.height + 28 + (faces == null && !both ? 0 : 30)),
    );
    if (faces != null) {
      EclipseButtonPainter.debugFace = (context, color) =>
          context.dependOnInheritedWidgetOfExactType<_FaceScope>()!.face(color);
    }
    addTearDown(() => EclipseButtonPainter.debugFace = null);
    _conn.value = 'disconnected';
    _video.value = 'untested';
    _pick.value = 'ok';
    _line.value = null;
    _fakeNow = 0;
    EclipseButtonPainter.hideLabel = true;
    EclipseButtonPainter.hideBadge = true;
    // the button's white face, as before the glass
    EclipseButtonPainter.glassFace = false;
    EclipseButtonPainter.glassStyle = 2;
    EclipseButtonPainter.debugNow = () => _fakeNow;
    debugActiveProxyRowHeight = 60;
    addTearDown(() => debugActiveProxyRowHeight = 76);
    addTearDown(() {
      EclipseButtonPainter.hideLabel = false;
      EclipseButtonPainter.hideBadge = false;
      EclipseButtonPainter.glassFace = false;
      EclipseButtonPainter.glassStyle = 0;
      EclipseButtonPainter.debugNow = null;
    });
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
        connectionNotifierProvider.overrideWith(_LiveConn.new),
        mainOutboundsNotifierProvider.overrideWith(_LiveMain.new),
        statsNotifierProvider.overrideWith(_Stats.new),
      ],
    );
    addTearDown(container.dispose);
    container
      ..listen(translationsProvider, (_, _) {})
      ..listen(sharedPreferencesProvider, (_, _) {})
      ..listen(activeProxyCardProvider, (_, _) {});
    final key = GlobalKey();
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
                child: both
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (final (beside, name) in [(true, 'Beside the speedometer'), (false, 'In its place')])
                            Column(
                              children: [
                                SizedBox(
                                  height: 44,
                                  child: Center(child: Text(name, style: label)),
                                ),
                                _SunHome(beside: beside),
                              ],
                            ),
                        ],
                      )
                    : faces == null
                    ? const Padding(padding: EdgeInsets.all(14), child: _SunHome())
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (final face in faces)
                            Column(
                              children: [
                                SizedBox(
                                  height: 44,
                                  child: Center(child: Text(_faces[face].$1, style: label)),
                                ),
                                _FaceScope(face: _faces[face].$2, child: const _SunHome()),
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
    Future<void> step(Duration d) async {
      _fakeNow += d.inMicroseconds / 1e6;
      await tester.pump(d);
    }

    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await step(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final frames = Directory('$out/sun_frames');
    await tester.runAsync(() async {
      if (frames.existsSync()) await frames.delete(recursive: true);
      await frames.create(recursive: true);
    });
    final only = Platform.environment['FRAMES'];
    var n = 0;
    for (final (conn, speed, line, seconds) in _sunTimeline) {
      _conn.value = conn;
      _video.value = speed == 'hop' ? 'untested' : speed;
      _pick.value = speed == 'offer' || speed == 'hop' ? speed : 'ok';
      _line.value = line;
      for (var i = 0; i < seconds * 30; i++) {
        await step(const Duration(microseconds: 1000000 ~/ 30));
        final index = n++;
        // FRAMES=a,b,c saves only those frames, for a quick look
        if (only != null && !only.split(',').contains('$index')) continue;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: faces == null && !both ? 1.5 : 1.0);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${frames.path}/f_${index.toString().padLeft(4, '0')}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('ping and speed video', (tester) async {
    await tester.runAsync(_load);
    const designs = {'P2': 'P2  Twin pills', 'P10': 'P10  Quality glow'};
    const top = 150.0;
    const height = 330.0;
    await tester.binding.setSurfaceSize(Size((_HomePhone.size.width + 14) * designs.length + 14, height + 30 + 14));
    _video.value = 'untested';
    _pick.value = 'ok';
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        sharedPreferencesProvider.overrideWith((ref) => _Prefs()),
        connectionNotifierProvider.overrideWith(_Conn.new),
        mainOutboundsNotifierProvider.overrideWith(_LiveMain.new),
        statsNotifierProvider.overrideWith(_Stats.new),
      ],
    );
    addTearDown(container.dispose);
    container
      ..listen(translationsProvider, (_, _) {})
      ..listen(sharedPreferencesProvider, (_, _) {})
      ..listen(activeProxyCardProvider, (_, _) {});
    final key = GlobalKey();
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
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final MapEntry(key: id, value: name) in designs.entries)
                      Column(
                        children: [
                          SizedBox(
                            height: 30,
                            child: Center(child: Text(name, style: label)),
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: SizedBox(
                              width: _HomePhone.size.width,
                              height: height,
                              child: OverflowBox(
                                alignment: Alignment.topCenter,
                                maxHeight: _HomePhone.size.height,
                                child: Transform.translate(
                                  offset: const Offset(0, -top),
                                  child: _HomePhone('untested', (c, s) => _LiveStatus(id)),
                                ),
                              ),
                            ),
                          ),
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
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final frames = Directory('$out/status_frames');
    await tester.runAsync(() async {
      if (frames.existsSync()) await frames.delete(recursive: true);
      await frames.create(recursive: true);
    });
    var n = 0;
    String path(int i) => '${frames.path}/f_${i.toString().padLeft(4, '0')}.png';
    for (final (state, seconds) in _statusTimeline) {
      _video.value = state;
      _pick.value = state == 'dead' || state == 'offer' ? state : 'ok';
      for (var i = 0; i < seconds * 30; i++) {
        await tester.pump(const Duration(milliseconds: 1000 ~/ 30));
        // once a still state has settled, its frames are all the same: copy the last one
        final still = state != 'testing' && i >= 30;
        await tester.runAsync(() async {
          if (still) {
            await File(path(n - 1)).copy(path(n));
            n++;
            return;
          }
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(path(n++)).writeAsBytes(png!.buffer.asUint8List());
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('speed tab video', (tester) async {
    await tester.runAsync(_load);
    const chains = ['extraSecurity', 'unblocker', 'off'];
    const names = {'extraSecurity': 'Extra security', 'unblocker': 'Unblocker', 'off': 'Proxy only'};
    const labelHeight = 30.0;
    await tester.binding.setSurfaceSize(
      Size((_phone.width + 14) * chains.length + 14, _phone.height + labelHeight + 14),
    );
    final containers = {
      for (final chain in chains)
        chain: ProviderContainer(
          overrides: [
            translationsProvider.overrideWith((ref) => AppLocale.en.build()),
            sharedPreferencesProvider.overrideWith((ref) => _Prefs(chain)),
            connectionNotifierProvider.overrideWith(_Conn.new),
            mainOutboundsNotifierProvider.overrideWith(() => _Main(chain)),
          ],
        ),
    };
    for (final container in containers.values) {
      addTearDown(container.dispose);
      container
        ..listen(translationsProvider, (_, _) {})
        ..listen(sharedPreferencesProvider, (_, _) {})
        ..listen(activeProxyCardProvider, (_, _) {});
    }
    final key = GlobalKey();
    _tabState.value = 'untested';
    const label = TextStyle(color: Colors.white, fontSize: 15, fontFamily: 'Segoe UI', fontWeight: FontWeight.w600);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final chain in chains)
                    UncontrolledProviderScope(
                      container: containers[chain]!,
                      child: Column(
                        children: [
                          SizedBox(
                            height: labelHeight,
                            child: Center(child: Text(names[chain]!, style: label)),
                          ),
                          _Phone(_Design('tab', above: (c) => const _Spot(_TabSpeed()))),
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
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final frames = Directory('$out/tab_frames');
    await tester.runAsync(() async {
      if (frames.existsSync()) await frames.delete(recursive: true);
      await frames.create(recursive: true);
    });
    var n = 0;
    for (final (state, seconds) in _tabTimeline) {
      _tabState.value = state;
      for (var i = 0; i < seconds * 30; i++) {
        await tester.pump(const Duration(milliseconds: 1000 ~/ 30));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${frames.path}/f_${(n++).toString().padLeft(4, '0')}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
