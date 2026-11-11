// TEMP design test: the speed button joined to the proxy card like a drop: the card and the button
// are one glass shape with a curved neck, at three spots, before and after the test, dark, on home's
// background. Not part of the app.
// Run: OUT=build/glass_design flutter test test/_speed_drop_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
import 'package:hiddify/features/proxy/widget/upload_speed.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bytes a second, as the core reports them: 27 and 102 Mbps.
const _up = 3400000;
const _down = 12800000;

/// Whether the test has run: each idea draws its before-test look when false.
var _tested = true;

/// The download needle's full scale, in Mbps.
const _scale = 200.0;

const _phone = Size(380, 600);
const _barHeight = 64.0;

/// Where the proxy row's end sits in the card: its vertical middle, and the room the chevron keeps.
const _rowMiddle = 16 + 38.0;
const _rowEnd = 16 + 16 + 24 + 8.0;

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
              ipinfo: IpInfo(ip: '45.12.3.9', countryCode: 'de', org: 'Hetzner Online GmbH'),
            ),
          ],
        ),
      ],
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
      color: Colors.white.withValues(alpha: .10),
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
                      color: Colors.white.withValues(alpha: .10),
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

// ---------- the drop: the card's glass and the speed button as one shape ----------

/// Where the drop sits on the card.
enum _Spot { topEnd, bottomCenter, rowEnd }

const _spotNames = {
  _Spot.topEnd: '1  top edge',
  _Spot.bottomCenter: '2  bottom edge',
  _Spot.rowEnd: '3  end of the proxy row',
};

/// The drop's size: a circle before the test, a capsule after it.
const _dropHeight = 38.0;
const _capsuleWidth = 112.0;

/// The drop's (length along the edge, thickness out of it): on the row's end the tested drop is a
/// tall pill with the numbers stacked, so the text stays upright.
(double, double) _dropSize(_Spot spot, {required bool capsule}) => !capsule
    ? (_dropHeight, _dropHeight)
    : spot == _Spot.rowEnd
    ? (66, 46)
    : (_capsuleWidth, _dropHeight);

/// The gap between the card's edge and the drop, and the neck's fillet radius.
const _gap = 3.0;
const _fillet = 9.0;

/// The card's glass rectangle inside its 16 px margin, and its corner.
const _cardRadius = 20.0;

/// The card plus a drop on one of its edges, joined by a neck whose sides curve in like two drops
/// touching, as one path. Built in a frame where the card's edge is y = 0 and the card lies below;
/// the drop sits above, centred at [along]; the frame is then turned onto the right edge.
Path _dropPath(Rect card, _Spot spot, {required bool capsule}) {
  final (w, thick) = _dropSize(spot, capsule: capsule);
  final r = thick / 2;
  // the edge, the drop's centre along it, and how the local frame maps onto the card
  final (double edgeLength, double along, Matrix4 toCard) = switch (spot) {
    _Spot.topEnd => (card.width, card.width - 24 - w / 2, Matrix4.translationValues(card.left, card.top, 0)),
    _Spot.bottomCenter => (
      card.width,
      card.width / 2,
      Matrix4.translationValues(card.left, card.bottom, 0)..multiply(Matrix4.diagonal3Values(1, -1, 1)),
    ),
    // the right edge, its y running down the card: x' = right - y, y' = top + x
    _Spot.rowEnd => (
      card.height,
      math.max(38, w / 2 + 6),
      Matrix4.translationValues(card.right, card.top, 0)..multiply(Matrix4.rotationZ(math.pi / 2)),
    ),
  };
  final cy = -_gap - r;
  // the drop's two end circles (the same one for a circle)
  final cl = along - (w / 2 - r);
  final cr = along + (w / 2 - r);
  final drop = Path()
    ..addRRect(RRect.fromRectAndRadius(Rect.fromLTRB(cl - r, cy - r, cr + r, cy + r), Radius.circular(r)));
  // each fillet circle touches the card's edge and its end circle
  final dy = cy - (-_fillet);
  final dx = math.sqrt(math.max((r + _fillet) * (r + _fillet) - dy * dy, 0));
  final fl = Offset(cl - dx, -_fillet);
  final fr = Offset(cr + dx, -_fillet);
  final bridge = Path.combine(
    PathOperation.difference,
    Path()..addRect(Rect.fromLTRB(fl.dx, -_fillet - 1, fr.dx, 1)),
    Path()
      ..addOval(Rect.fromCircle(center: fl, radius: _fillet))
      ..addOval(Rect.fromCircle(center: fr, radius: _fillet)),
  );
  final local = Path.combine(PathOperation.union, drop, bridge);
  final placed = local.transform(toCard.storage);
  final body = Path()..addRRect(RRect.fromRectAndRadius(card, const Radius.circular(_cardRadius)));
  if (edgeLength <= 0 || card.height <= 0) return Path();
  return Path.combine(PathOperation.union, body, placed);
}

/// The drop's centre on the card, for its content.
Offset _dropCentre(Rect card, _Spot spot, {required bool capsule}) {
  final (w, thick) = _dropSize(spot, capsule: capsule);
  final out = _gap + thick / 2;
  return switch (spot) {
    _Spot.topEnd => Offset(card.right - 24 - w / 2, card.top - out),
    _Spot.bottomCenter => Offset(card.center.dx, card.bottom + out),
    _Spot.rowEnd => Offset(card.right + out, card.top + math.max(38, w / 2 + 6)),
  };
}

/// The dark face of the app's glass: blur, then the iOS 27 color matrix (GlassSurface's dark preset).
final _glassFilter = ui.ImageFilter.compose(
  outer: const ColorFilter.matrix([
    0.90321775, -0.342402, -0.03456575, 0, 44.22421191, //
    -0.10178225, 0.662598, -0.03456575, 0, 44.22421191, //
    -0.10178225, -0.342402, 0.97043425, 0, 44.22421191, //
    0, 0, 0, 1, 0,
  ]),
  inner: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5, tileMode: TileMode.mirror),
);

class _PathClipper extends CustomClipper<Path> {
  _PathClipper(this.path);
  final Path path;
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(_PathClipper old) => old.path != path;
}

/// The one glass shape's edge: a thin dark line outside, a soft light line inside, brighter at the top.
class _EdgePainter extends CustomPainter {
  _EdgePainter(this.path);
  final Path path;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = path.getBounds();
    canvas
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.black.withValues(alpha: .45),
      )
      ..save()
      ..clipPath(path)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..blendMode = BlendMode.plus
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white.withValues(alpha: .35), Colors.white.withValues(alpha: .08)],
          ).createShader(bounds),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.path != path;
}

/// The real card (its own speed test hidden, its Card see-through) over one glass shape: the card and
/// the drop, joined.
class _DropCard extends StatelessWidget {
  const _DropCard(this.spot, {required this.tested});

  final _Spot spot;
  final bool tested;

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
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(_cardRadius)),
        ),
      ),
      child: Padding(
        // the row-end drop needs room beside the card
        padding: EdgeInsets.only(right: spot == _Spot.rowEnd ? 42 : 0),
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            clipBehavior: Clip.none,
            children: [
              const ActiveProxyFooter(hideSpeedTest: true),
              Positioned.fill(
                child: _DropLayer(spot: spot, tested: tested),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the glass under the card's content: drawn as a sibling behind would need the card's size
/// first, so this lays itself over the card and draws the glass first, the content showing through.
class _DropLayer extends StatelessWidget {
  const _DropLayer({required this.spot, required this.tested});

  final _Spot spot;
  final bool tested;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final card = (Offset.zero & box.biggest).deflate(16);
      final path = _dropPath(card, spot, capsule: tested);
      final centre = _dropCentre(card, spot, capsule: tested);
      final s = Theme.of(context).colorScheme;
      final Widget content = tested && spot == _Spot.rowEnd
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dir(context, up: true, size: 12, arrow: 9),
                const SizedBox(height: 4),
                _dir(context, up: false, size: 12, arrow: 9),
              ],
            )
          : tested
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dir(context, up: true, size: 13, arrow: 10),
                Container(
                  width: 1,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: s.onSurface.withValues(alpha: .15),
                ),
                _dir(context, up: false, size: 13, arrow: 10),
              ],
            )
          : Icon(Icons.speed_rounded, size: 20, color: s.primary);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          // the glass goes under the card's content, which is drawn by the card below this layer
          // in paint order only if this layer is behind: see _Phone, which stacks glass first
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(foregroundPainter: _EdgePainter(path))),
          ),
          Positioned(
            left: centre.dx - 70,
            top: centre.dy - 35,
            width: 140,
            height: 70,
            child: Center(child: content),
          ),
        ],
      );
    },
  );
}

/// The glass itself (blur and color), behind everything of the card.
class _DropGlass extends StatelessWidget {
  const _DropGlass({required this.spot, required this.tested});

  final _Spot spot;
  final bool tested;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(right: spot == _Spot.rowEnd ? 42 : 0),
    child: LayoutBuilder(
      builder: (context, box) {
        final card = (Offset.zero & box.biggest).deflate(16);
        return OverflowBox(
          maxWidth: box.maxWidth + 120,
          maxHeight: box.maxHeight + 120,
          child: Padding(
            padding: const EdgeInsets.all(60),
            child: ClipPath(
              clipper: _PathClipper(_dropPath(card, spot, capsule: tested)),
              clipBehavior: Clip.antiAlias,
              child: BackdropFilter(filter: _glassFilter, child: const SizedBox.expand()),
            ),
          ),
        );
      },
    ),
  );
}

class _Phone extends StatelessWidget {
  const _Phone(this.spot, {required this.tested});

  final _Spot spot;
  final bool tested;

  @override
  Widget build(BuildContext context) => Theme(
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // the glass first, then the card's content over it
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: _DropGlass(spot: spot, tested: tested),
                        ),
                        _DropCard(spot, tested: tested),
                      ],
                    ),
                    SizedBox(height: spot == _Spot.bottomCenter ? 34 : 4),
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
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  final out = Platform.environment['OUT'] ?? 'build/glass_design';

  testWidgets('speed test drops', (tester) async {
    await tester.runAsync(_load);
    const labelHeight = 30.0;
    await tester.binding.setSurfaceSize(
      Size((_phone.width + 14) * _Spot.values.length + 14, (labelHeight + _phone.height + 14) * 2),
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
                    for (final tested in [false, true])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (final spot in _Spot.values)
                              Column(
                                children: [
                                  SizedBox(
                                    height: labelHeight,
                                    child: Center(
                                      child: Text(
                                        '${_spotNames[spot]} · ${tested ? 'tested' : 'before the test'}',
                                        style: label,
                                      ),
                                    ),
                                  ),
                                  _Phone(spot, tested: tested),
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
      await File('$out/speed_drops.png').writeAsBytes(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
