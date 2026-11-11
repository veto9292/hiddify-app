// TEMP design test: the proxies page, round 2 (idea 9 animated, with the chain). Not part of the app.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:circle_flags/circle_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/chain/model/chain_enum.dart';
import 'package:hiddify/features/chain/overview/chain_mode_icon.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/widget/proxy_tile.dart';
import 'package:hiddify/features/proxy/widget/proxy_type_label.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vgc;

/// The video's clock in ms; every drawing reads it, so frames are exact.
final _now = ValueNotifier(0);
double _loop(int period, [int shift = 0]) => ((_now.value + shift) % period) / period;
double _ease(double v) => -(cos(pi * v.clamp(0.0, 1.0)) - 1) / 2;

/// The hop connects at this time of the video.
const _hopUpAt = 2000;
bool get _hopUp => _now.value >= _hopUpAt;

OutboundInfo _p(String tag, String type, String cc, int delay) => OutboundInfo(
  tag: tag,
  tagDisplay: tag,
  type: type,
  urlTestDelay: delay,
  ipinfo: IpInfo(countryCode: cc, ip: cc.isEmpty ? '' : '1.2.3.4'),
);

final _servers = [
  _p('M-NL', 'VLESS', 'NL', 182),
  _p('M-DE', 'VLESS', 'DE', 210),
  _p('T-FR', 'Shadowsocks', 'FR', 335),
  _p('M-US', 'VLESS', 'US', 640),
  _p('M-PL', 'Trojan', 'PL', 1120),
  _p('T-US 2', 'Shadowsocks', '', 65535),
];

Widget _rows(BuildContext c) => Column(
  children: [
    for (final s in _servers) SizedBox(height: 72, child: ProxyTile(s, key: ValueKey(s.tag), selected: false, onTap: () {})),
  ],
);

// ---------- the moving picture of a mode ----------

enum _Hop { none, before, after }

/// You on the left, the servers on the right. Fastest: one line to the server it picked, a light
/// running along it. Balance: a line to every server, the light visiting them in turn. A chain hop
/// sits on the way: before the servers (unblocker) or after them (extra security). While the hop
/// connects, the light stops at it.
class _Route extends CustomPainter {
  _Route(this.context, {required this.fan, required this.on, this.hop = _Hop.none, this.servers = 4});
  final BuildContext context;
  final bool fan;
  final bool on;
  final _Hop hop;
  final int servers;

  @override
  void paint(Canvas cv, Size size) {
    final s = Theme.of(context).colorScheme;
    final lit = on ? s.primary : s.onSurfaceVariant;
    final faint = s.outlineVariant;
    final hopColor = ChainType.unblocker.colors(ChainMode.psiphon).$1;
    final secColor = ChainType.extraSecurity.colors(ChainMode.warp).$1;
    final h = size.height;
    final you = Offset(6, h / 2);
    final serverX = hop == _Hop.after ? size.width * .62 : size.width - 6;
    final ys = [for (var i = 0; i < servers; i++) 5 + i * (h - 10) / (servers - 1)];
    final hopAt = hop == _Hop.before ? Offset(size.width * .36, h / 2) : Offset(size.width - 7, h / 2);
    final start = hop == _Hop.before ? hopAt : you;
    final up = hop == _Hop.none || _hopUp;

    Paint line(Color c, [double w = 1.6]) => Paint()
      ..color = c
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // which servers the traffic goes to: Fastest one, Balance all, the light visiting one at a time
    final turn = fan ? (_now.value ~/ 900) % servers : 0;
    final v = fan ? (_now.value % 900) / 900 : _loop(1300);

    if (hop == _Hop.before) cv.drawLine(you, hopAt, line(up ? hopColor : faint, 2));
    for (var i = 0; i < servers; i++) {
      final to = Offset(serverX, ys[i]);
      final used = (fan || i == 0) && up;
      cv.drawLine(start, to, line(used ? lit.withValues(alpha: fan && i != turn ? .45 : 1) : faint));
      if (hop == _Hop.after && (fan || i == 0)) cv.drawLine(to, hopAt, line(up ? secColor.withValues(alpha: .7) : faint));
      cv.drawCircle(to, 3.6, Paint()..color = used ? lit : faint);
    }
    cv.drawCircle(you, 4.2, Paint()..color = s.onSurface);

    // the light: through the hop first when it is before, stopped at the hop while it connects
    final glow = Paint()..color = on ? s.primary : s.onSurface;
    if (hop == _Hop.before) {
      final pre = (v * 2).clamp(0.0, 1.0);
      final post = ((v - .5) * 2).clamp(0.0, 1.0);
      if (!up) {
        cv.drawCircle(Offset.lerp(you, hopAt, _ease(_loop(1100)))!, 2.6, Paint()..color = hopColor);
      } else if (v < .5) {
        cv.drawCircle(Offset.lerp(you, hopAt, pre)!, 2.6, glow);
      } else {
        cv.drawCircle(Offset.lerp(hopAt, Offset(serverX, ys[turn]), post)!, 2.6, glow);
      }
    } else if (hop == _Hop.after) {
      final to = Offset(serverX, ys[turn]);
      if (v < .6) {
        cv.drawCircle(Offset.lerp(you, to, v / .6)!, 2.6, glow);
      } else if (up) {
        cv.drawCircle(Offset.lerp(to, hopAt, (v - .6) / .4)!, 2.6, Paint()..color = secColor);
      }
    } else {
      cv.drawCircle(Offset.lerp(you, Offset(serverX, ys[turn]), _ease(v))!, 2.6, glow);
    }

    // the hop: a ring that breathes while it connects, filled once it is up
    if (hop != _Hop.none) {
      final c = hop == _Hop.before ? hopColor : secColor;
      if (up) {
        cv.drawCircle(hopAt, 5.5, Paint()..color = c);
      } else {
        final b = (sin(_loop(1000) * 2 * pi) + 1) / 2;
        cv.drawCircle(hopAt, 5 + b * 2, line(c.withValues(alpha: .4 + .6 * b), 1.6));
      }
    }
  }

  @override
  bool shouldRepaint(_Route old) => true;
}

Widget _route(BuildContext c, {required bool fan, required bool on, _Hop hop = _Hop.none, double w = 64, double h = 34}) =>
    CustomPaint(size: Size(w, h), painter: _Route(c, fan: fan, on: on, hop: hop));

// ---------- the mode cards ----------

Widget _modeCard(
  BuildContext c, {
  required bool fan,
  required bool on,
  _Hop hop = _Hop.none,
  bool tall = true,
}) {
  final s = Theme.of(c).colorScheme;
  final th = Theme.of(c).textTheme;
  return AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: on ? s.primaryContainer : s.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: on ? s.primary : Colors.transparent, width: 1.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(fan ? Icons.call_split_rounded : Icons.bolt_rounded, size: 18, color: on ? s.primary : s.onSurfaceVariant),
            const Gap(4),
            Text(fan ? 'Balance' : 'Fastest', style: th.titleSmall),
            const Spacer(),
            if (on) Icon(Icons.check_circle_rounded, size: 18, color: s.primary),
          ],
        ),
        if (tall) ...[const Gap(8), Center(child: _route(c, fan: fan, on: on, hop: hop, w: 120, h: 40))],
        const Gap(8),
        fan
            ? Text('Round robin · 5', style: th.labelMedium?.copyWith(color: s.onSurfaceVariant))
            : Row(
                children: [
                  IPCountryFlag(countryCode: 'NL', size: 18),
                  const Gap(4),
                  Text('M-NL  ', style: th.labelMedium),
                  Text('182', style: th.labelMedium?.copyWith(color: Colors.lightGreen, fontWeight: FontWeight.w600)),
                ],
              ),
      ],
    ),
  );
}

Widget _cards(BuildContext c, {bool balanceOn = true, _Hop hop = _Hop.none}) => Padding(
  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
  child: Row(
    children: [
      Expanded(child: _modeCard(c, fan: false, on: !balanceOn, hop: hop)),
      const Gap(10),
      Expanded(child: _modeCard(c, fan: true, on: balanceOn, hop: hop)),
    ],
  ),
);

Widget _section(BuildContext c, String title) {
  final th = Theme.of(c);
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
    child: Row(
      children: [
        Text(title, style: th.textTheme.titleSmall?.copyWith(color: th.colorScheme.primary)),
        const Spacer(),
        Text('${_servers.length}', style: th.textTheme.labelMedium?.copyWith(color: th.colorScheme.outline)),
      ],
    ),
  );
}

// ---------- the chain ----------

/// While the hop connects, as on the home card: an hourglass that turns half a turn every 1.6 s
/// on a small tile, and the core's own label ("Psiphon ⏳ Connecting...").
Widget _hourglass(BuildContext c, Color color) {
  final t = _now.value / 1000;
  final turn = pi * (t ~/ 1.6) + pi * Curves.easeInOutCubic.transform(((t % 1.6) / 1.6 * 2).clamp(0.0, 1.0));
  return Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      color: Theme.of(c).colorScheme.onSurface.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Center(child: Transform.rotate(angle: turn, child: Icon(Icons.hourglass_top_rounded, size: 15, color: color))),
  );
}

Widget _coreLabel(BuildContext c) => ProxyTypeLabel(
  'Psiphon ⏳ Connecting...',
  style: Theme.of(c).textTheme.labelMedium?.copyWith(color: Theme.of(c).colorScheme.onSurfaceVariant),
);

/// The hop as a strip: its icon, its name, and its state (connecting, then its flag and ping).
Widget _hopStrip(BuildContext c, {bool rowLike = false}) {
  final s = Theme.of(c).colorScheme;
  final th = Theme.of(c).textTheme;
  final (main, _) = ChainType.unblocker.colors(ChainMode.psiphon);
  final state = _hopUp
      ? Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IPCountryFlag(countryCode: 'DE', size: 16),
            const Gap(4),
            Text('310', style: th.labelMedium?.copyWith(color: Colors.lightGreen, fontWeight: FontWeight.w600)),
          ],
        )
      : _hourglass(c, main);
  return Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: EdgeInsets.symmetric(horizontal: 12, vertical: rowLike ? 12 : 8),
    decoration: BoxDecoration(
      color: main.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(rowLike ? 16 : 12),
      border: Border.all(color: main.withValues(alpha: _hopUp ? .5 : .25)),
    ),
    child: Row(
      children: [
        ChainTypeIcon(type: ChainType.unblocker, mode: ChainMode.psiphon, animate: _hopUp),
        const Gap(8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Proxy unblocker', style: th.titleSmall),
              if (rowLike)
                _hopUp
                    ? Row(
                        children: [
                          const ChainModeIcon(mode: ChainMode.psiphon, size: 13),
                          const Gap(4),
                          Text('Psiphon', style: th.bodySmall?.copyWith(color: s.onSurfaceVariant)),
                        ],
                      )
                    : _coreLabel(c),
            ],
          ),
        ),
        AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: KeyedSubtree(key: ValueKey(_hopUp), child: state)),
      ],
    ),
  );
}

/// The way the traffic goes, as one line of steps: You → the hop → the servers.
Widget _rail(BuildContext c) {
  final s = Theme.of(c).colorScheme;
  final th = Theme.of(c).textTheme;
  final (main, _) = ChainType.unblocker.colors(ChainMode.psiphon);
  Widget step(Widget icon, String label, {Color? color}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      icon,
      const Gap(2),
      Text(label, style: th.labelSmall?.copyWith(color: color ?? s.onSurfaceVariant)),
    ],
  );
  Widget link(bool live) => Expanded(
    child: SizedBox(
      height: 14,
      child: CustomPaint(
        painter: _Dash(live ? s.primary : s.outlineVariant, live ? _loop(900) : null),
      ),
    ),
  );
  return Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(color: s.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
    child: Row(
      children: [
        step(Icon(Icons.smartphone_rounded, size: 20, color: s.onSurface), 'You'),
        link(true),
        step(
          Stack(
            clipBehavior: Clip.none,
            children: [
              ChainTypeIcon(type: ChainType.unblocker, mode: ChainMode.psiphon, animate: _hopUp),
              if (!_hopUp) Positioned(right: -14, bottom: -6, child: Transform.scale(scale: .7, child: _hourglass(c, main))),
            ],
          ),
          'Psiphon',
          color: main,
        ),
        link(_hopUp),
        step(Icon(Icons.call_split_rounded, size: 20, color: _hopUp ? s.primary : s.outline), 'Balance'),
      ],
    ),
  );
}

/// A dashed link; with [run] its dashes flow from left to right.
class _Dash extends CustomPainter {
  _Dash(this.color, this.run);
  final Color color;
  final double? run;

  @override
  void paint(Canvas cv, Size size) {
    final y = size.height / 2 - 6;
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const dash = 5.0, gap = 4.0;
    final shift = (run ?? 0) * (dash + gap);
    for (var x = -dash + shift + 6; x < size.width - 6; x += dash + gap) {
      cv.drawLine(Offset(max(6, x), y), Offset(min(size.width - 6, x + dash), y), p);
    }
  }

  @override
  bool shouldRepaint(_Dash old) => true;
}

// ---------- the five pages ----------

final _pages = <(String, Widget Function(BuildContext))>[
  (
    'A · cards as 9, now moving',
    (c) => ListView(children: [_cards(c), _section(c, 'Servers'), _rows(c)]),
  ),
  (
    'B · chain: a steps line on top',
    (c) => ListView(children: [_rail(c), _cards(c), _section(c, 'Servers'), _rows(c)]),
  ),
  (
    'C · chain: the hop inside each picture',
    (c) => ListView(children: [_cards(c, hop: _Hop.before), _section(c, 'Servers'), _rows(c)]),
  ),
  (
    'D · chain: the hop as its own card',
    (c) => ListView(children: [_hopStrip(c, rowLike: true), _cards(c, hop: _Hop.before), _section(c, 'Servers'), _rows(c)]),
  ),
  (
    'E · one big route, tap a mode to switch',
    (c) {
      // the user switches to Fastest at 3.5 s: the fan folds into one line
      final balance = _now.value < 3500;
      final s = Theme.of(c).colorScheme;
      return ListView(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            decoration: BoxDecoration(color: s.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
            child: Column(
              children: [
                _route(c, fan: balance, on: true, hop: _Hop.before, w: 300, h: 70),
                const Gap(10),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.bolt_rounded), label: Text('Fastest')),
                    ButtonSegment(value: true, icon: Icon(Icons.call_split_rounded), label: Text('Balance')),
                  ],
                  selected: {balance},
                  onSelectionChanged: (_) {},
                ),
              ],
            ),
          ),
          _section(c, 'Servers'),
          _rows(c),
        ],
      );
    },
  ),
];

// ---------- setup ----------

Future<ByteData> _file(String path) => File(path).readAsBytes().then((b) => ByteData.sublistView(b));

Future<void> _loadFonts() async {
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
  await (FontLoader('Segoe UI Emoji')..addFont(_file('C:/Windows/Fonts/seguiemj.ttf'))).load();
  await (FontLoader('Segoe UI Symbol')..addFont(_file('C:/Windows/Fonts/seguisym.ttf'))).load();
}

Future<ByteData> _compile(String xml, String name) async {
  final bytes = vgc.encodeSvg(
    xml: xml,
    debugName: name,
    enableClippingOptimizer: false,
    enableMaskingOptimizer: false,
    enableOverdrawOptimizer: false,
  );
  return bytes.buffer.asByteData();
}

/// Flags and the logo, compiled ahead: a test frame can't wait for them to load.
Future<void> _loadSvgs() async {
  for (final cc in ['NL', 'FR', 'DE', 'US', 'PL']) {
    final xml = await rootBundle.loadString('packages/circle_flags/assets/svg/${cc.toLowerCase()}.svg');
    final data = await _compile(xml, cc);
    await svg.cache.putIfAbsent(CircleFlag(cc).loader.cacheKey(null), () => Future.value(data));
  }
  const logo = 'assets/images/logo.svg';
  final data = await _compile(await rootBundle.loadString(logo), 'logo');
  await svg.cache.putIfAbsent(const SvgAssetLoader(logo).cacheKey(null), () => Future.value(data));
}

ThemeData _theme() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0078D4), brightness: Brightness.dark);
  final base = AppTheme(AppThemeMode.system, FontFamily.emoji).darkTheme(scheme);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: ['Segoe UI', 'Segoe UI Emoji', 'Segoe UI Symbol']),
  );
}

void main() {
  final out = Platform.environment['ITEM_OUT']!;

  testWidgets('proxies page round 2', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(_loadFonts);
    await tester.runAsync(_loadSvgs);
    final t = (await tester.runAsync(() => AppLocale.en.build()))!;
    final theme = _theme();
    const pw = 360.0, ph = 720.0, gap = 28.0;
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(Size(_pages.length * (pw + gap) + 48, ph + 44 + 48));
    final container = ProviderContainer(overrides: [translationsProvider.overrideWith((ref) => t)]);
    await tester.runAsync(() => container.read(translationsProvider.future));
    await tester.runAsync(() => container.read(sharedPreferencesProvider.future));

    Widget phone(String name, Widget Function(BuildContext) body) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: 44, child: Text(name, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.outline))),
        Container(
          width: pw,
          height: ph,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: theme.colorScheme.outlineVariant)),
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Proxies'),
              actions: [
                IconButton(onPressed: () {}, icon: const Icon(Icons.sort_rounded)),
                IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert_rounded)),
              ],
            ),
            floatingActionButton: FloatingActionButton(onPressed: () {}, child: const Icon(Icons.flash_on_rounded)),
            body: ValueListenableBuilder(valueListenable: _now, builder: (context, _, _) => Builder(builder: body)),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final (name, body) in _pages) ...[phone(name, body), const Gap(gap)]],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() => Directory('$out/frames').create(recursive: true));
    var n = 0;
    for (var ms = 0; ms < 6000; ms += 40) {
      _now.value = ms;
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(() async {
        final frame = await boundary.toImage(pixelRatio: 1.2);
        final png = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/frames/f_${(n++).toString().padLeft(3, '0')}.png').writeAsBytes(png!.buffer.asUint8List());
      });
    }
  });
}
