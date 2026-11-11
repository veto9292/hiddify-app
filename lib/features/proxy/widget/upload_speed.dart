import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/widget/glass_surface.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The megabytes an upload test can send through each proxy.
const uploadTestSizes = [1, 5, 10, 50];

/// The bytes an upload test sends through each proxy, as the settings name.
int uploadTestBytes(Ref ref) => ref.read(ConfigOptions.uploadTestSize).clamp(1, 50) << 20;

/// Asks how many megabytes an upload test sends through each proxy, and keeps the answer.
Future<void> chooseUploadTestSize(WidgetRef ref) async {
  final t = ref.read(translationsProvider).requireValue;
  final size = await ref
      .read(dialogNotifierProvider.notifier)
      .showSettingRadio<int>(
        title: t.pages.settings.general.uploadTestSize,
        values: uploadTestSizes,
        value: ref.read(ConfigOptions.uploadTestSize),
        defaultValue: uploadTestSizes.first,
        t: {for (final n in uploadTestSizes) '$n': t.pages.settings.general.megabytes(n: n)},
      );
  if (size != null) await ref.read(ConfigOptions.uploadTestSize.notifier).update(size);
}

/// Megabits a second of [bytesPerSecond], as a speed test reports it: three decimals below 1, so a
/// slow proxy is not shown as 0 (40 kbit/s is 0.040), one below 10, none above.
String formatMbps(int bytesPerSecond) {
  final value = bytesPerSecond * 8 / 1e6;
  // under 1, two decimals, cut rather than rounded: 0.965 shows as 0.96
  if (value < 1) return ((value * 100).floor() / 100).toStringAsFixed(2);
  return value < 10 ? value.toStringAsFixed(1) : value.round().toString();
}

/// The color of an upload speed, as pings have theirs: green for 10 Mbit/s or more, orange for 2
/// or more, red below.
Color uploadSpeedColor(BuildContext context, int bytesPerSecond) {
  final value = bytesPerSecond * 8 / 1e6;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (value) {
    >= 10 => dark ? Colors.lightGreen : Colors.green,
    >= 2 => dark ? Colors.orange : Colors.deepOrangeAccent,
    _ => dark ? Colors.redAccent : Colors.red,
  };
}

/// A proxy's upload speed ([speed] bytes a second; 0 untested, -1 failed), and its download speed
/// ([downloadSpeed]) once tested: a spinner while one is [testing], the gauge alone before the first
/// test, the gauge with one cross when both failed. A speed from an earlier run ([cached],
/// [downloadCached]) shows faded until tested again. A tap tests the upload ([onTest]), or both when
/// both show; a long press the download ([onDownloadTest]), or without it sets how much a test
/// sends. [dense] fits it under
/// a proxy row's ping; else it is a pill.
class UploadSpeedChip extends ConsumerWidget {
  const UploadSpeedChip({
    super.key,
    required this.speed,
    required this.testing,
    this.cached = false,
    this.onTest,
    this.dense = false,
    this.downloadSpeed = 0,
    this.downloadTesting = false,
    this.downloadCached = false,
    this.onDownloadTest,
  });

  final int speed;
  final bool testing;
  final bool cached;
  final VoidCallback? onTest;
  final bool dense;
  final int downloadSpeed;
  final bool downloadTesting;
  final bool downloadCached;
  final VoidCallback? onDownloadTest;

  /// How much a speed from an earlier run fades.
  static const _cachedOpacity = .45;

  /// Below this screen width, a pill with both speeds shows them one over the other.
  static const _stackBelow = 480.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final showUp = speed != 0 || testing;
    final showDown = downloadSpeed != 0 || downloadTesting;
    final busy = testing || downloadTesting;
    // both tested, both failed: one cross says it
    final bothFailed = !busy && speed < 0 && downloadSpeed < 0;
    Color colorOf(int value, bool busy) => busy
        ? s.primary
        : value < 0
        ? s.error
        : value == 0
        ? s.onSurfaceVariant
        : uploadSpeedColor(context, value);
    final iconSize = dense ? 13.0 : 17.0;
    final number = (dense ? theme.textTheme.labelSmall : theme.textTheme.titleSmall)?.copyWith(
      fontWeight: dense ? FontWeight.w700 : FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final unit = dense
        ? theme.textTheme.labelSmall?.copyWith(fontSize: 9, color: s.onSurfaceVariant, letterSpacing: .3)
        : theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant);

    // once tested, the arrows say what each number is: the gauge shows only before the first test;
    // both directions under a row's ping leave little room, so the unit gets smaller
    final both = showUp && showDown && !bothFailed;
    final gauge = !showUp && !showDown;
    Widget faded(bool old, Widget child) => old ? Opacity(opacity: _cachedOpacity, child: child) : child;

    // one direction: its arrow, then its value, a spinner, or a cross; faded when from an earlier run
    Widget part(int value, bool partBusy, IconData arrow, bool old, {required bool first}) {
      final color = colorOf(value, partBusy);
      return faded(
        old && !partBusy,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!first) Gap(dense ? 3 : 5),
            Icon(arrow, size: iconSize - 3, color: color),
            if (partBusy)
              SizedBox.square(
                dimension: iconSize - 4,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
              )
            else if (value < 0)
              Icon(Icons.close_rounded, size: iconSize - 1, color: color)
            else if (value > 0)
              Text(formatMbps(value), style: number?.copyWith(color: color)),
          ],
        ),
      );
    }

    final allOld = (!showUp || cached) && (!showDown || downloadCached) && !busy;
    // a pill on a small screen has no room for both on one line: the gauge, then a line each
    final stacked = !dense && both && MediaQuery.sizeOf(context).width < _stackBelow;
    Widget line(int value, bool lineBusy, IconData arrow, bool old) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        part(value, lineBusy, arrow, old, first: true),
        if (value > 0) faded(old, Text(' Mbps', style: unit?.copyWith(fontSize: 10))),
      ],
    );
    final Widget content = stacked
        ? Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.ltr,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  line(speed, testing, Icons.arrow_upward_rounded, cached),
                  line(downloadSpeed, downloadTesting, Icons.arrow_downward_rounded, downloadCached),
                ],
              ),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.ltr,
            children: bothFailed
                ? [
                    faded(
                      cached && downloadCached,
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.speed_rounded, size: iconSize, color: s.error),
                          const Gap(2),
                          Icon(Icons.close_rounded, size: iconSize - 1, color: s.error),
                        ],
                      ),
                    ),
                  ]
                : [
                    if (gauge)
                      faded(
                        allOld && (showUp || showDown),
                        Icon(
                          Icons.speed_rounded,
                          size: iconSize,
                          color: busy ? s.primary : colorOf(showUp ? speed : downloadSpeed, false),
                        ),
                      ),
                    if (showUp) part(speed, testing, Icons.arrow_upward_rounded, cached, first: !gauge),
                    if (showDown)
                      part(
                        downloadSpeed,
                        downloadTesting,
                        Icons.arrow_downward_rounded,
                        downloadCached,
                        first: !gauge && !showUp,
                      ),
                    if (speed > 0 || downloadSpeed > 0)
                      faded(allOld, Text(' Mbps', style: dense && both ? unit?.copyWith(fontSize: 8) : unit)),
                  ],
          );

    final chip = InkWell(
      borderRadius: BorderRadius.circular(dense ? 6 : (stacked ? 14 : 16)),
      // with both speeds shown, a tap tests both again; the core tests one proxy's two in turn
      onTap: testing
          ? null
          : both && onDownloadTest != null && !downloadTesting
          ? () {
              onDownloadTest!();
              onTest?.call();
            }
          : onTest,
      onLongPress: onDownloadTest == null
          ? () => chooseUploadTestSize(ref)
          : downloadTesting
          ? null
          : onDownloadTest,
      child: Padding(
        padding: dense
            ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
            : stacked
            ? const EdgeInsetsDirectional.fromSTEB(10, 4, 12, 4)
            : EdgeInsets.symmetric(horizontal: !showUp && !showDown ? 8 : 11),
        // a row's room is fixed: big numbers shrink rather than overflow
        child: dense
            ? FittedBox(fit: BoxFit.scaleDown, child: content)
            : stacked
            ? content
            : SizedBox(height: 32, child: content),
      ),
    );
    return Tooltip(
      message: onDownloadTest == null
          ? t.pages.proxies.upload.test
          : both
          ? t.pages.proxies.upload.hintBoth
          : t.pages.proxies.upload.hint,
      child: dense
          ? chip
          : Material(
              color: s.onSurface.withValues(alpha: .06),
              // two lines tall, a rounded card rather than a pill
              shape: stacked ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)) : const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: AnimatedSize(duration: const Duration(milliseconds: 300), curve: Curves.easeOut, child: chip),
            ),
    );
  }
}

/// The home card's speed test, on glass. Before the first test it is the gauge icon alone; when a
/// test starts the glass grows from it into a capsule of two halves, each its arrow then its value,
/// with "Mbps" below: two dots while a half is measured, its number once known, faded and
/// blinking softly when from an earlier run, and a short red dash when it failed, which the dots
/// become once. A tap tests both; a long press sets how much a test sends.
class SpeedCapsule extends HookConsumerWidget {
  const SpeedCapsule({
    super.key,
    required this.upload,
    required this.uploadTesting,
    required this.uploadCached,
    required this.download,
    required this.downloadTesting,
    required this.downloadCached,
    required this.onTest,
    this.chevron = true,
  });

  /// Whether it stands in for its row's chevron: shows it until the first test, then takes its place.
  final bool chevron;

  /// Bytes a second; 0 untested, below 0 failed.
  final int upload;
  final bool uploadTesting;
  final bool uploadCached;
  final int download;
  final bool downloadTesting;
  final bool downloadCached;

  /// Tests both directions.
  final VoidCallback onTest;

  static const height = 30.0;
  static const _height = height;

  /// How far the pill stands in from the widget's end.
  static const _pillInset = 6.0;

  /// How long the chevron takes to fold away as the icon slides into its place.
  static const _slide = Duration(milliseconds: 220);

  /// One loop of the clock that drives the dots (1 s) and the blink (1.4 s).
  static const _loop = 7.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final busy = uploadTesting || downloadTesting;
    final untested = upload == 0 && download == 0 && !busy;
    // the dots and the blink run only while something moves
    final moving = busy || (uploadCached && upload > 0) || (downloadCached && download > 0);
    final clock = useAnimationController(duration: const Duration(seconds: 7));
    useEffect(() {
      moving ? clock.repeat() : clock.stop();
      return null;
    }, [moving]);

    final big = theme.textTheme.labelLarge?.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      height: 1,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final small = big?.copyWith(fontSize: 11, fontWeight: FontWeight.w600);
    // one direction: its arrow, then its number (or the dots, or the failed dash); upload, the lesser
    // one, smaller
    Widget half(int value, bool testing, bool cached, {required bool up}) {
      final number = up ? small : big;
      final Widget content = switch (value) {
        _ when testing => _Dots(clock: clock, color: s.primary, size: number?.fontSize ?? 14),
        < 0 => _FailedDash(dots: s.primary, color: s.error, size: number?.fontSize ?? 14),
        0 => Text('–', style: number?.copyWith(color: s.onSurfaceVariant)),
        _ => AnimatedBuilder(
          animation: clock,
          // an earlier run's number: faded, and it blinks softly
          builder: (context, child) => Opacity(
            opacity: cached ? .25 + .35 * ((math.sin(clock.value * _loop * 2 * math.pi / 1.4) + 1) / 2) : 1,
            child: child,
          ),
          child: Text(formatMbps(value), style: number?.copyWith(color: uploadSpeedColor(context, value))),
        ),
      };
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: up ? 9 : 12,
            color: s.onSurfaceVariant,
          ),
          const SizedBox(width: 2),
          content,
        ],
      );
    }

    // Not measured yet: the icon alone with the row's chevron beside it; the tooltip names it. When a
    // test starts the chevron folds away and the icon slides into its place, then the glass grows to
    // the left from there into the capsule: up | down, with the unit under it. The capsule then stands
    // in the chevron's place.
    final grown = useState(!untested);
    useEffect(() {
      if (untested) {
        grown.value = false;
        return null;
      }
      if (grown.value) return null;
      final timer = Timer(_slide, () => grown.value = true);
      return timer.cancel;
    }, [untested]);
    final Widget inside = !grown.value
        ? SizedBox(
            key: const ValueKey('icon'),
            height: _height,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 11 + _pillInset, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed_rounded, size: 18, color: s.primary),
                  const SizedBox(width: 5),
                  Text(
                    t.dialogs.proxyInfo.speed,
                    style: theme.textTheme.labelMedium?.copyWith(color: s.primary, height: 1),
                  ),
                ],
              ),
            ),
          )
        : Padding(
            key: const ValueKey('capsule'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            // download large on top; under it upload, small, with the unit; both on the end
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                half(download, downloadTesting, downloadCached, up: false),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    half(upload, uploadTesting, uploadCached, up: true),
                    const SizedBox(width: 4),
                    Text(
                      'Mbps',
                      style: theme.textTheme.labelSmall?.copyWith(fontSize: 10, height: 1, color: s.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          );
    // the glass shows only before the first test; once a test starts it fades away and the numbers
    // stand on their own
    final glass = Stack(
      children: [
        Positioned.fill(
          // the pill stands a little in from the edge
          right: _pillInset,
          child: AnimatedOpacity(
            opacity: grown.value ? 0 : 1,
            duration: const Duration(milliseconds: 250),
            child: const GlassSurface(borderRadius: _height / 2, child: SizedBox.expand()),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          // the right edge stays put, so the capsule grows to the left
          alignment: Alignment.centerRight,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            // what leaves goes at once: the gauge icon must not linger inside the growing capsule
            reverseDuration: Duration.zero,
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
            child: inside,
          ),
        ),
      ],
    );
    // one structure for every state, so the glass keeps its animations across them
    final capsule = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        glass,
        AnimatedSize(
          duration: _slide,
          curve: Curves.easeInOutCubic,
          alignment: AlignmentDirectional.centerStart,
          child: untested && chevron
              ? Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  child: Icon(Icons.chevron_right_rounded, color: s.onSurfaceVariant),
                )
              : const SizedBox(height: 24),
        ),
      ],
    );

    return Tooltip(
      message: t.pages.proxies.speedTest.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : onTest,
        onLongPress: () => chooseUploadTestSize(ref),
        child: capsule,
      ),
    );
  }
}

/// Two dots that light up in turn while a value is measured.
class _Dots extends StatelessWidget {
  const _Dots({required this.clock, required this.color, required this.size});
  final Animation<double> clock;
  final Color color;

  /// The font size of the number they stand in for; the dots scale with it.
  final double size;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: clock,
      builder: (context, _) {
        final t = clock.value * SpeedCapsule._loop;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 2; i++)
              Container(
                width: size * .28,
                height: size * .28,
                margin: EdgeInsets.symmetric(horizontal: size * .1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .3 + .7 * ((math.sin(t * 2 * math.pi - i * math.pi) + 1) / 2)),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// A failed value: the two dots slide together and stretch into a red dash, once.
class _FailedDash extends HookWidget {
  const _FailedDash({required this.dots, required this.color, required this.size});
  final Color dots;
  final Color color;

  /// The font size of the number it stands in for; the dash scales with it.
  final double size;

  @override
  Widget build(BuildContext context) {
    final grow = useAnimationController(duration: const Duration(milliseconds: 500));
    useEffect(() {
      grow.forward();
      return null;
    }, const []);
    return AnimatedBuilder(
      animation: grow,
      builder: (context, _) => CustomPaint(
        size: Size(size * 1.5, size),
        painter: _DashPainter(Curves.easeInOutCubic.transform(grow.value), dots, color, size / 14),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.p, this.dots, this.color, this.scale);
  final double p;

  /// The number's size over the 14 the lengths below are drawn for.
  final double scale;
  final Color dots;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (p < .5) {
      final k = p * 2;
      for (final i in [-.5, .5]) {
        canvas.drawCircle(
          c + Offset(i * 5.5 * scale * (1 - k), 0),
          2 * scale,
          Paint()..color = Color.lerp(dots, color, k)!,
        );
      }
      return;
    }
    final w = math.max(5 * scale * (p - .5) * 2, .5);
    canvas.drawLine(
      c + Offset(-w, 0),
      c + Offset(w, 0),
      Paint()
        ..color = color
        ..strokeWidth = 1.8 * scale
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.p != p || old.color != color || old.scale != scale;
}
