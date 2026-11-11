import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/core/widget/adaptive_menu.dart';
import 'package:hiddify/core/widget/unique_keys_layout.dart';
import 'package:hiddify/features/chain/model/chain_enum.dart';
import 'package:hiddify/features/chain/overview/chain_mode_icon.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/features/proxy/widget/proxy_type_label.dart';
import 'package:hiddify/features/proxy/widget/upload_speed.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ActiveProxyFooter extends HookConsumerWidget with InfraLogger {
  const ActiveProxyFooter({super.key, this.speedInCorner = false, this.hideSpeedTest = false});

  /// TEMP design option: no speed test on the card, for designs that show it elsewhere.
  final bool hideSpeedTest;

  /// TEMP design option: the speed test as a badge on the card's top-end corner instead
  /// of in the proxy row.
  final bool speedInCorner;

  /// Same window as ConnectionButton's held connected look: a brief Disconnected
  /// blip on resume must not collapse this footer or the connect button jumps.
  static const _hold = Duration(milliseconds: 1500);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(
      connectionNotifierProvider.select((value) => value.value ?? const Disconnected()),
    );

    final activeCard = ref.watch(activeProxyCardProvider);

    final heldCard = useRef<ActiveProxyCardData?>(null);
    final until = useRef<DateTime?>(null);
    final rebuild = useState(0);

    // Intentional disconnect and a new Connecting must clear immediately — otherwise
    // a held card with an empty IP shows "Unknown IP" under Connecting… (#2395).
    // Only hold across a Connected→Disconnected blip (e.g. resume).
    final clearCard =
        connectionState is Disconnecting || connectionState is Disconnected || connectionState is Connecting;
    final live = connectionState.isRunning && activeCard != null;
    ActiveProxyCardData? card;
    if (live) {
      heldCard.value = activeCard;
      until.value = null;
      card = activeCard;
    } else if (clearCard) {
      heldCard.value = null;
      until.value = null;
      card = null;
    } else if (heldCard.value != null) {
      until.value ??= DateTime.now().add(_hold);
      if (DateTime.now().isBefore(until.value!)) {
        card = heldCard.value;
      } else {
        heldCard.value = null;
        until.value = null;
      }
    }
    useEffect(() {
      final end = until.value;
      if (end == null) return null;
      final timer = Timer(end.difference(DateTime.now()), () => rebuild.value++);
      return timer.cancel;
    }, [until.value]);

    if (card == null) {
      return const SizedBox.shrink();
    }
    final cardWidget = Card(
      margin: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      // with the speed test hidden, the row is as it is with the test in the corner: no capsule
      child: _Steps(card, speedInCorner: speedInCorner || hideSpeedTest),
    );
    if (hideSpeedTest || !speedInCorner || card.serverStatus != StepStatus.connected) return cardWidget;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        cardWidget,
        // on the card's top edge, clear of its rounded corner
        PositionedDirectional(top: 16 - SpeedCapsule.height / 2, end: 32, child: _SpeedTest(card.server, inRow: false)),
      ],
    );
  }
}

/// How fast the proxy in use uploads and downloads; a tap measures both.
class _SpeedTest extends ConsumerWidget {
  const _SpeedTest(this.server, {this.inRow = true});
  final OutboundInfo server;

  /// In the proxy row it brings the row's chevron; on the card's corner it has none.
  final bool inRow;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SpeedCapsule(
    upload: server.uploadSpeed.toInt(),
    uploadTesting: server.uploadTesting,
    uploadCached: server.uploadSpeedCached,
    download: server.downloadSpeed.toInt(),
    downloadTesting: server.downloadTesting,
    downloadCached: server.downloadSpeedCached,
    chevron: inRow,
    onTest: () {
      final active = ref.read(activeProxyNotifierProvider.notifier);
      active.uploadTest();
      active.downloadTest();
    },
  );
}

// ---------- the steps: one row each, in the order they connect, joined by a rail ----------

/// One row's height, and the column its flag sits in; the flags are the rail's nodes.
/// TEMP design test: the main row's height, to try it shorter.
double debugActiveProxyRowHeight = 76;
double get _rowHeight => debugActiveProxyRowHeight;
const _railWidth = 56.0;
const _flagSize = 36.0;

/// The hop row: one line, so shorter, with a smaller flag.
const _hopRowHeight = 44.0;

const _hopFlagSize = 28.0;

/// The hop flag (and so its badge) against the main one.
const _hopScale = _hopFlagSize / _flagSize;

/// The gap after a row's last widget, the same in every row, so the hop's chip and the speed test
/// line up at the end.
const _endInset = 16.0;

Color _green(BuildContext context) => Theme.of(context).extension<ConnectionButtonTheme>()!.connectedColor!;

class _Steps extends StatelessWidget {
  const _Steps(this.card, {this.speedInCorner = false});
  final ActiveProxyCardData card;
  final bool speedInCorner;

  @override
  Widget build(BuildContext context) {
    final hopStatus = card.hopStatus;
    if (hopStatus == null) return _ProxyRow(card, speedInCorner: speedInCorner);
    // unblocker carries the server's traffic, extra security dials through the server
    final unblocker = card.chain.isUnblocker();
    // the rail stops this far from each flag, which draws 8 px smaller than its box
    const gap = 5.0;
    final (h1, f1, h2, f2) = unblocker
        ? (_hopRowHeight, _hopFlagSize, _rowHeight, _flagSize)
        : (_rowHeight, _flagSize, _hopRowHeight, _hopFlagSize);
    final top = h1 / 2 + (f1 - 8) / 2 + gap;
    final bottom = h1 + h2 / 2 - (f2 - 8) / 2 - gap;
    return Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: unblocker
              ? [_HopRow(card), _ProxyRow(card, speedInCorner: speedInCorner)]
              : [_ProxyRow(card, speedInCorner: speedInCorner), _HopRow(card)],
        ),
        PositionedDirectional(
          start: _railWidth / 2 - 1.5,
          width: 3,
          top: top,
          height: bottom - top,
          child: _Rail(unblocker ? card.serverStatus : hopStatus),
        ),
      ],
    );
  }
}

/// A step's row: its flag with the state badge, two lines of text, and a chevron; or, with
/// [trailing], [title] alone on one line and the trailing widget in place of the chevron.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.color,
    required this.onTap,
    required this.flag,
    required this.status,
    required this.title,
    this.subtitle = const SizedBox.shrink(),
    this.height,
    this.trailing,
    this.end,
    this.onLongPress,
    this.afterCheck,
  });

  /// Takes the state badge's place once the step has connected and its check has gone.
  final Widget? afterCheck;

  final double? height;
  final Widget? trailing;

  /// Before the chevron of a row without [trailing]: the upload speed of the proxy in use.
  final Widget? end;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget flag;
  final StepStatus status;
  final Widget title;
  final Widget subtitle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          height: height ?? _rowHeight,
          child: Row(
            children: [
              SizedBox(
                width: _railWidth,
                child: Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      flag,
                      // the hop's smaller flag gets a badge smaller in proportion
                      if (trailing == null)
                        PositionedDirectional(end: -3, top: -3, child: StepStateBadge(status, after: afterCheck))
                      else
                        PositionedDirectional(
                          end: -3 * _hopScale,
                          top: -3 * _hopScale,
                          child: SizedBox.square(
                            dimension: FlagBadge.size * _hopScale,
                            child: FittedBox(child: StepStateBadge(status, after: afterCheck)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: trailing == null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, const Gap(2), subtitle],
                      )
                    : Align(alignment: AlignmentDirectional.centerStart, child: title),
              ),
              if (trailing case final trailing?) ...[
                const Gap(8),
                trailing,
                const Gap(_endInset),
              ] else ...[
                // the speed test brings the chevron itself, and takes its place once it has run
                if (end case final end?) ...[
                  const Gap(8),
                  end,
                ] else
                  Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const Gap(_endInset),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A step's problem, in place of its second line.
class _Problem extends StatelessWidget {
  const _Problem(this.message, {this.error = true});
  final String message;

  /// False while it is only slow.
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      message,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        color: error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Shows [first] and [second] in turn, a few seconds each, with a crossfade; it starts on [first].
class _Alternating extends HookWidget {
  const _Alternating(this.first, this.second);
  final Widget first;
  final Widget second;

  static const _period = Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    final showFirst = useState(true);
    useEffect(() {
      final timer = Timer.periodic(_period, (_) => showFirst.value = !showFirst.value);
      return timer.cancel;
    }, const []);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      layoutBuilder: (current, previous) =>
          Stack(alignment: AlignmentDirectional.centerStart, children: [...previous, ?current]),
      child: KeyedSubtree(key: ValueKey(showFirst.value), child: showFirst.value ? first : second),
    );
  }
}

TextStyle? _nameStyle(BuildContext context, StepStatus status) => Theme.of(context).textTheme.titleMedium?.copyWith(
  fontSize: 14,
  // a step that waits for the one before it is dimmed
  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: status == StepStatus.waiting ? .45 : 1),
);

// ---------- the proxy row: how the server was picked, its name, IP and protocol ----------

class _ProxyRow extends ConsumerWidget {
  const _ProxyRow(this.card, {this.speedInCorner = false});
  final ActiveProxyCardData card;
  final bool speedInCorner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final server = card.server;
    final status = card.serverStatus;
    final connected = status == StepStatus.connected;
    final muted = theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant);
    final nameStyle = _nameStyle(context, status);
    final group = card.group;

    Future<void> urlTest() => ref.read(activeProxyNotifierProvider.notifier).urlTest("");

    return _StepRow(
      color: theme.cardTheme.color ?? s.surfaceContainerLow,
      onTap: () => context.goNamed('proxies'),
      end: connected && !speedInCorner ? _SpeedTest(server) : null,
      flag: InkWell(
        onTap: () async {
          await urlTest();
          await ref.read(dialogNotifierProvider.notifier).showProxyInfo(outboundInfo: server);
        },
        borderRadius: BorderRadius.circular(8),
        child: _FlagSlot(
          connected ? server : null,
          size: _flagSize,
          dim: status == StepStatus.waiting || status == StepStatus.failed,
          showOrganization: false,
        ),
      ),
      afterCheck: connected && server.hasIp ? LogoBadge.host(server.ipinfo.org) : null,
      status: status,
      title: Semantics(
        label: t.pages.proxies.activeProxy,
        child: group == null
            ? Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle)
            : Row(
                children: [
                  Icon(
                    switch (group) {
                      lowestGroupTag => Icons.bolt_rounded,
                      balanceGroupTag => Icons.call_split_rounded,
                      _ => Icons.layers_outlined,
                    },
                    size: 13,
                    color: s.primary,
                  ),
                  const Gap(2),
                  Text(group, style: theme.textTheme.labelMedium?.copyWith(color: s.primary, letterSpacing: .3)),
                  Text('  ·  ', style: theme.textTheme.labelMedium?.copyWith(color: s.outline)),
                  Flexible(
                    child: group == balanceGroupTag
                        ? const _StrategyChip()
                        : Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
                  ),
                ],
              ),
      ),
      subtitle: switch (status) {
        // lowest picks the best server, so lowest failing means none answers
        StepStatus.failed => _Problem(
          group == lowestGroupTag ? t.pages.proxies.noneResponding : t.pages.proxies.notResponding,
        ),
        StepStatus.waiting => ProxyTypeLabel(server.type, style: muted),
        _ => Row(
          children: [
            // The config's IP is the final one only with unblocker; with no chain it is the only one.
            _IpSlot(connected ? server : null, boneWidth: 64, isFinal: card.chain.isUnblocker(), onLongPress: urlTest),
            Flexible(
              child: ProxyTypeLabel(server.type, prefix: '  ·  ', style: muted),
            ),
          ],
        ),
      },
    );
  }
}

// ---------- the hop row: its IP, then the chain type in a chip with its mode as a badge. A tap
// shows the hop's proxy info, a long press its configuration. ----------

class _HopRow extends ConsumerWidget {
  const _HopRow(this.card);
  final ActiveProxyCardData card;

  static const _chipHeight = 28.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final status = card.hopStatus!;
    final type = card.chain.isUnblocker() ? ChainType.unblocker : ChainType.extraSecurity;
    final (main, _) = type.colors(card.hopMode);
    final light = theme.brightness == Brightness.light;
    final color = Color.alphaBlend(main.withValues(alpha: light ? .20 : .16), s.surfaceContainerHigh);
    // the chain's own color is too pale for text on its light band; a deeper shade of it reads
    final ink = light ? Color.lerp(main, Colors.black, .45)! : main;
    final down = status == StepStatus.waiting || status == StepStatus.failed;
    final hop = card.hop;
    // the core still setting the hop up (or not listing it yet): its live state in place of the flag
    // and the IP; once the core says ready, the flag and the IP wait for the first ping as usual
    final live = status == StepStatus.slow || (status == StepStatus.connecting && hop?.status != Status.READY);
    return _StepRow(
      color: color,
      onTap: hop == null
          ? () => context.goNamed('chainOptions')
          : () => ref.read(dialogNotifierProvider.notifier).showProxyInfo(outboundInfo: hop),
      onLongPress: () => context.goNamed('chainOptions'),
      height: _hopRowHeight,
      // while the hop connects, its live state as a moving icon in the flag's place
      flag: switch (status) {
        _ when live => SizedBox.square(
          dimension: _hopFlagSize,
          child: Center(
            child: _HopStateIcon(slow: status == StepStatus.slow, core: hop?.status, color: main),
          ),
        ),
        _ => _FlagSlot(
          status == StepStatus.connected ? card.hop : null,
          size: _hopFlagSize,
          dim: down,
          showOrganization: false,
        ),
      },
      status: status,
      // the hop's own mark (WARP, Psiphon, a profile) in the check's place once it connects
      afterCheck: LogoBadge.hop(card.hopMode),
      title: switch (status) {
        StepStatus.waiting => const SizedBox.shrink(),
        // slow: the warning comes and goes, and in between the row says what the hop is doing
        StepStatus.slow => _Alternating(
          _Problem(t.connection.slow, error: false),
          ProxyTypeLabel(
            hop?.type ?? card.hopMode.present(t),
            style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant),
          ),
        ),
        StepStatus.failed => _Problem(t.connection.failed),
        // while it connects, what the hop runs and what it is doing, as the core names it ("Psiphon ⏳
        // Connecting...", "WARP · Auto 🔑 Registering..."), in place of the IP's placeholder
        StepStatus.connecting when live => ProxyTypeLabel(
          hop?.type ?? card.hopMode.present(t),
          style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant),
        ),
        _ => _IpSlot(status == StepStatus.connected ? hop : null, boneWidth: 64, isFinal: card.chain.isExtraSecurity()),
      },
      trailing: Container(
        height: _chipHeight,
        padding: const EdgeInsetsDirectional.only(start: 6, end: 10),
        decoration: BoxDecoration(
          color: main.withValues(alpha: .18),
          borderRadius: BorderRadius.circular(_chipHeight / 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: _chipHeight - 10,
              child: FittedBox(
                child: ChainTypeIcon(type: type, mode: card.hopMode, animate: !down),
              ),
            ),
            const Gap(4),
            Text(type.present(t), style: theme.textTheme.labelMedium?.copyWith(color: ink, letterSpacing: .3)),
          ],
        ),
      ),
    );
  }
}

/// A connecting hop's live state on a small tile: an hourglass that flips while it connects, a clock
/// when it is slow, a pulsing fingerprint while WARP registers, a circling magnifier while it
/// searches, spinning arrows while it reconnects.
class _HopStateIcon extends HookWidget {
  const _HopStateIcon({required this.slow, required this.core, required this.color});
  final bool slow;
  final Status? core;
  final Color color;

  static const _tile = 22.0;

  /// One loop holds every motion: the clock's hour hand takes the longest, 36 s.
  static const _loop = 36.0;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final clock = useAnimationController(duration: const Duration(seconds: 36));
    useEffect(() {
      clock.repeat();
      return null;
    }, const []);
    final amber = Colors.amber.shade300;
    return RepaintBoundary(
      child: Container(
        width: _tile,
        height: _tile,
        decoration: BoxDecoration(color: s.onSurface.withValues(alpha: .08), borderRadius: BorderRadius.circular(4)),
        child: Center(
          child: AnimatedBuilder(
            animation: clock,
            builder: (context, _) {
              final t = clock.value * _loop;
              Icon icon(IconData data) => Icon(data, size: 15, color: color);
              return switch (core) {
                _ when slow => CustomPaint(size: const Size.square(15), painter: _ClockPainter(t, amber)),
                Status.REGISTERING => Opacity(
                  opacity: .55 + .45 * ((math.sin(t * 2 * math.pi / 1.6) + 1) / 2),
                  child: Icon(Icons.fingerprint_rounded, size: 16, color: color),
                ),
                Status.SEARCHING => Transform.translate(
                  offset: Offset(math.cos(t * 2 * math.pi / 1.6), math.sin(t * 2 * math.pi / 1.6)) * 3,
                  child: icon(Icons.search_rounded),
                ),
                Status.RECONNECTING => Transform.rotate(angle: -t * 2 * math.pi / 1.2, child: icon(Icons.sync_rounded)),
                // a half turn every 1.6 s: it turns in the first half, then rests
                _ => Transform.rotate(
                  angle:
                      math.pi * (t ~/ 1.6) +
                      math.pi * Curves.easeInOutCubic.transform(((t % 1.6) / 1.6 * 2).clamp(0.0, 1.0)),
                  child: icon(Icons.hourglass_top_rounded),
                ),
              };
            },
          ),
        ),
      ),
    );
  }
}

/// A clock face with two hands: the minute hand goes round every 3 s, the hour hand twelve times
/// slower. Both stay clear of the rim.
class _ClockPainter extends CustomPainter {
  _ClockPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 1;
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, pen..strokeWidth = 1.6);
    Offset tip(double turns, double length) =>
        c + Offset(math.sin(turns * 2 * math.pi), -math.cos(turns * 2 * math.pi)) * length;
    canvas.drawLine(c, tip(t / 3, r * .55), pen..strokeWidth = 1.4);
    canvas.drawLine(c, tip(.25 + t / 36, r * .38), pen..strokeWidth = 1.8);
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.t != t || old.color != color;
}

// ---------- a step's state: a badge on its flag, and the rail to the next step ----------

/// A round mark on a flag's top-end corner: one filled disc, no ring, with a white mark in it. Every
/// mark on the card uses it (the step's state, the host's logo, the hop's logo), so they all look
/// alike: the same size, the same place, and nothing of the flag shows through.
class FlagBadge extends StatelessWidget {
  const FlagBadge({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  static const size = 18.0;

  /// The white mark inside: about 60 % of the disc.
  static const markSize = 11.0;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: SizedBox.square(
      dimension: markSize,
      child: Center(child: child),
    ),
  );
}

/// The step's state on its flag: waiting, connecting (a spinner), connected (a check), failed.
class StepStateBadge extends StatelessWidget {
  const StepStateBadge(this.status, {this.after});
  final StepStatus status;

  /// What takes the check's place once it has gone, such as the host's or the hop's logo.
  final Widget? after;

  /// How long the green check stays once a step connects, before it fades away.
  static const _checkHold = Duration(milliseconds: 1500);

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final badge = AnimatedSwitcher(
      layoutBuilder: uniqueKeysLayout(),
      duration: const Duration(milliseconds: 250),
      child: switch (status) {
        StepStatus.waiting => FlagBadge(
          key: const ValueKey('waiting'),
          color: s.surfaceContainerHighest,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: s.onSurface.withValues(alpha: .35), width: 1.5),
            ),
          ),
        ),
        StepStatus.connecting || StepStatus.slow => FlagBadge(
          key: const ValueKey('connecting'),
          color: s.surfaceContainerHighest,
          child: CircularProgressIndicator(strokeWidth: 1.8, backgroundColor: s.onSurface.withValues(alpha: .15)),
        ),
        StepStatus.connected => FlagBadge(
          key: const ValueKey('connected'),
          color: _green(context),
          // drawn, not the font's glyph, which sits off the disc's centre
          child: const CustomPaint(size: Size.square(FlagBadge.markSize), painter: _CheckPainter()),
        ).animate().scaleXY(begin: .4, end: 1, duration: 400.ms, curve: Curves.easeOutBack),
        StepStatus.failed => FlagBadge(
          key: const ValueKey('failed'),
          color: s.error,
          child: Icon(Icons.priority_high_rounded, size: FlagBadge.markSize, color: s.onError),
        ),
      },
    );
    // a connected step needs no mark: the check shrinks away after a moment, and [after], if any,
    // pops up in its place
    if (status != StepStatus.connected) return badge;
    final gone = badge
        .animate()
        .fadeOut(delay: _checkHold, duration: 350.ms)
        .scaleXY(begin: 1, end: .4, delay: _checkHold, duration: 350.ms, curve: Curves.easeIn);
    final after = this.after;
    if (after == null) return gone;
    return Stack(
      alignment: Alignment.center,
      children: [
        gone,
        after
            .animate()
            .fadeIn(delay: _checkHold + 250.ms, duration: 250.ms)
            .scaleXY(begin: .4, end: 1, delay: _checkHold + 250.ms, duration: 400.ms, curve: Curves.easeOutBack),
      ],
    );
  }
}

/// A white check whose bounding box is centred in the square it paints.
class _CheckPainter extends CustomPainter {
  const _CheckPainter();

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(double x, double y) => Offset(size.width * x, size.height * y);
    canvas.drawPath(
      Path()
        ..moveTo(at(.18, .52).dx, at(.18, .52).dy)
        ..lineTo(at(.40, .74).dx, at(.40, .74).dy)
        ..lineTo(at(.82, .30).dx, at(.82, .30).dy),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => false;
}

/// A logo in the check's place: a [FlagBadge] in the brand's color with the logo in white, or a
/// mode's icon in white on its color.
class LogoBadge extends StatelessWidget {
  const LogoBadge({this.logo, this.mode});
  final OrgIconData? logo;
  final ChainMode? mode;

  /// The host provider's logo, or null if the app has none for [organization].
  static LogoBadge? host(String organization) {
    final org = organization.toLowerCase();
    for (final entry in organizationData.entries) {
      if (org.contains(entry.key)) return LogoBadge(logo: entry.value);
    }
    return null;
  }

  /// Psiphon's mark (its 2026 "P", from psiphon.ca), on the orange of its app icon.
  static const _psiphon = OrgIconData('assets/images/orgs/psiphon.png', Color(0xFFF79A4A));

  /// The hop's own mark: WARP is Cloudflare's, so its cloud; Psiphon its "P"; a profile its icon.
  factory LogoBadge.hop(ChainMode mode) => switch (mode) {
    ChainMode.warp => LogoBadge(logo: organizationData['cloudflare']),
    ChainMode.psiphon => const LogoBadge(logo: _psiphon),
    _ => LogoBadge(mode: mode),
  };

  @override
  Widget build(BuildContext context) {
    final logo = this.logo;
    if (logo == null) {
      final mode = this.mode!;
      return FlagBadge(
        color: mode.color(),
        child: Icon(mode.icon(), size: FlagBadge.markSize, color: Colors.white),
      );
    }
    // the logos are one-color marks, drawn in white
    return FlagBadge(
      color: logo.color,
      child: logo.asset.endsWith('.svg')
          ? SvgPicture.asset(logo.asset, colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn))
          : Image.asset(logo.asset, color: Colors.white, colorBlendMode: BlendMode.srcIn),
    );
  }
}

/// The line between the two flags, showing the second step: grey while it waits, dashes marching
/// down while it connects, filling green from the top once it connects, red-tinted if it failed.
class _Rail extends HookWidget {
  const _Rail(this.next);
  final StepStatus next;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final moving = next == StepStatus.connecting || next == StepStatus.slow;
    final connected = next == StepStatus.connected;
    // one dash and its gap per loop
    final march = useAnimationController(duration: const Duration(milliseconds: 360));
    // a card that shows up already connected starts full
    final fill = useAnimationController(duration: const Duration(milliseconds: 400), initialValue: connected ? 1 : 0);
    useEffect(() {
      if (moving) {
        march.repeat();
      } else {
        march.stop();
      }
      return null;
    }, [moving]);
    useEffect(() {
      if (connected) {
        fill.forward();
      } else {
        fill.value = 0;
      }
      return null;
    }, [connected]);
    // once connected, a spark of current runs up the wire every few seconds: data on its way
    final spark = useAnimationController(duration: _RailPainter.sparkLoop);
    useEffect(() {
      if (connected) {
        spark.repeat();
      } else {
        spark
          ..stop()
          ..value = 0;
      }
      return null;
    }, [connected]);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _RailPainter(
        next: next,
        march: march,
        fill: fill,
        spark: spark,
        track: s.onSurface.withValues(alpha: .15),
        dash: s.primary,
        // emerald: livelier than the connect button's green, which stays as it is
        green: dark ? const Color(0xFF34D399) : const Color(0xFF10B981),
        error: s.error.withValues(alpha: .5),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.next,
    required this.march,
    required this.fill,
    required this.spark,
    required this.track,
    required this.dash,
    required this.green,
    required this.error,
  }) : super(repaint: Listenable.merge([march, fill, spark]));

  final StepStatus next;
  final Animation<double> march;
  final Animation<double> fill;
  final Animation<double> spark;

  /// One spark and the rest after it.
  static const sparkLoop = Duration(milliseconds: 3200);

  /// The share of [sparkLoop] the spark takes to run from the bottom to the top.
  static const _run = .28;
  final Color track;
  final Color dash;
  final Color green;
  final Color error;

  static const _dash = 5.0;
  static const _space = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.width / 2);
    final rail = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas
      ..save()
      ..clipRRect(rail)
      ..drawRRect(rail, Paint()..color = next == StepStatus.failed ? error : track);
    switch (next) {
      case StepStatus.connecting || StepStatus.slow:
        final paint = Paint()..color = dash;
        for (var y = march.value * (_dash + _space) - _dash - _space; y < size.height; y += _dash + _space) {
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, y, size.width, _dash), radius), paint);
        }
      case StepStatus.connected:
        final height = size.height * Curves.easeOutCubic.transform(fill.value);
        canvas.drawRect(Rect.fromLTWH(0, 0, size.width, height), Paint()..color = green);
      case StepStatus.waiting || StepStatus.failed:
        break;
    }
    canvas.restore();
    if (next == StepStatus.connected && fill.value == 1 && spark.value < _run) _paintSpark(canvas, size);
  }

  /// A bright head with a fading tail rising from the bottom flag to the top one, inside the wire
  /// only: nothing spills round it.
  void _paintSpark(Canvas canvas, Size size) {
    final t = Curves.easeInOutCubic.transform(spark.value / _run);
    final head = size.height * (1 - t);
    const tail = 22.0;
    // fade in at the bottom, out as it reaches the top
    final strength = (math.min(t / .15, 1) * math.min((1 - t) / .25, 1)).clamp(0.0, 1.0);
    final colors = [Colors.white, green, green.withValues(alpha: 0)];
    final radius = Radius.circular(size.width / 2);
    final core = Rect.fromLTWH(0, head, size.width, tail);
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(Offset.zero & size, radius))
      ..drawRect(
        core,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [for (final c in colors) c.withValues(alpha: c.a * strength)],
            stops: const [0, .25, 1],
          ).createShader(core),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.next != next || old.track != track || old.dash != dash || old.green != green || old.error != error;
}

/// Balance's strategy as a small button; its menu switches the strategy.
class _StrategyChip extends ConsumerWidget {
  const _StrategyChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final current = ref.watch(ConfigOptions.balancerStrategy);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: AdaptiveMenu(
        items: [
          for (final strategy in BalancerStrategy.values)
            AdaptiveMenuItem(
              title: strategy.present(t),
              leadingIcon: Icon(strategy == current ? Icons.check_rounded : null, size: 18),
              onTap: () => ref.read(ConfigOptions.balancerStrategy.notifier).update(strategy),
            ),
        ],
        builder: (context, toggleVisibility, _) => Material(
          color: s.primary.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: toggleVisibility,
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              // short, so the row is no taller than with a plain name
              height: 20,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 2, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        current.present(t),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontSize: 13, height: 1.2),
                      ),
                    ),
                    Icon(Icons.arrow_drop_down_rounded, size: 16, color: s.onSurface),
                  ],
                ),
              ),
            ),
          ),
        ),
        child: null,
      ),
    );
  }
}

// ---------- IPs: a skeleton while loading, a pop when they arrive ----------

/// A grey placeholder, breathing, with a tinted light sweeping across it.
class _Bone extends StatelessWidget {
  const _Bone({required this.width, required this.height, required this.radius});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return RepaintBoundary(
      // both loops repaint the bone alone, not the card round it
      child:
          Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: s.onSurface.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(radius),
                ),
              )
              .animate(onPlay: (c) => c.repeat())
              .shimmer(duration: 1300.ms, color: s.primary.withValues(alpha: .45), angle: .6)
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .fade(begin: .55, end: 1, duration: 900.ms, curve: Curves.easeInOut),
    );
  }
}

/// The flag of [info]'s IP: a placeholder until this run's IP arrives (a failed lookup is retried
/// with the next ping), a faint square while [dim] (its step waits or failed). On arrival it pops in
/// and sends out a ring.
class _FlagSlot extends StatelessWidget {
  const _FlagSlot(this.info, {required this.size, this.dim = false, this.showOrganization = true});
  final OutboundInfo? info;
  final double size;
  final bool dim;

  /// False when the row draws the host provider's logo as its own badge.
  final bool showOrganization;

  /// The main flag's 8 px corner at 36 px, in proportion at other sizes.
  double get radius => size * 8 / 36;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final info = this.info;
    final inner = size - 8; // IPCountryFlag draws the flag 8 px smaller than its box
    return SizedBox.square(
      dimension: size,
      child: RepaintBoundary(
        // the pop and the ring repaint the slot alone
        child: AnimatedSwitcher(
          layoutBuilder: uniqueKeysLayout(),
          duration: const Duration(milliseconds: 250),
          child: switch (info) {
            OutboundInfo(hasIp: true) => Stack(
              key: const ValueKey('flag'),
              alignment: Alignment.center,
              children: [
                IPCountryFlag(
                      countryCode: info.ipinfo.countryCode,
                      organization: showOrganization ? info.ipinfo.org : null,
                      size: size,
                    )
                    // it settles in from slightly smaller and blurred, then a soft light glides
                    // across it once
                    .animate()
                    .fadeIn(duration: 300.ms)
                    .scaleXY(begin: .85, end: 1, duration: 450.ms, curve: Curves.easeOutCubic)
                    .blurXY(begin: 4, end: 0, duration: 350.ms)
                    .shimmer(delay: 250.ms, duration: 900.ms, color: Colors.white.withValues(alpha: .55), angle: .6),
              ],
            ),
            _ when dim => Center(
              key: const ValueKey('dim'),
              child: Container(
                width: inner,
                height: inner,
                decoration: BoxDecoration(
                  color: s.onSurface.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ),
            _ => Center(
              key: const ValueKey('bone'),
              child: _Bone(width: inner, height: inner, radius: inner / 4),
            ),
          },
        ),
      ),
    );
  }
}

/// [info]'s IP: a placeholder until this run's IP arrives. On arrival it slides up; the final IP is
/// green and first shows "Final IP" in its place.
class _IpSlot extends StatelessWidget {
  const _IpSlot(this.info, {required this.boneWidth, required this.isFinal, this.onLongPress});
  final OutboundInfo? info;
  final double boneWidth;
  final bool isFinal;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      layoutBuilder: uniqueKeysLayout(AlignmentDirectional.centerStart),
      child: switch (info) {
        OutboundInfo(hasIp: true) =>
          KeyedSubtree(
                key: const ValueKey('ip'),
                child: isFinal
                    ? _FinalIpSwap(ip: info.ipinfo.ip, onLongPress: onLongPress)
                    : IPText(ip: info.ipinfo.ip, onLongPress: onLongPress ?? () {}, constrained: true),
              )
              .animate(delay: 120.ms)
              .fadeIn(duration: 300.ms)
              .slideY(begin: .6, end: 0, duration: 350.ms, curve: Curves.easeOutCubic),
        _ => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _Bone(width: boneWidth, height: 9, radius: 4.5),
        ),
      },
    );
  }
}

/// The final IP, in green. Like the QR dialog's "Copied": "Final IP" shows first in its place for
/// [_hold], then the IP slides in, once. Keeps the wider size, so nothing beside it moves.
class _FinalIpSwap extends ConsumerStatefulWidget {
  const _FinalIpSwap({required this.ip, this.onLongPress});
  final String ip;
  final VoidCallback? onLongPress;

  static const _hold = Duration(milliseconds: 2600);

  @override
  ConsumerState<_FinalIpSwap> createState() => _FinalIpSwapState();
}

class _FinalIpSwapState extends ConsumerState<_FinalIpSwap> {
  var _words = true;
  late final Timer _toIp;

  @override
  void initState() {
    super.initState();
    _toIp = Timer(_FinalIpSwap._hold, () => setState(() => _words = false));
  }

  @override
  void dispose() {
    _toIp.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    // the QR dialog's green: M3 has no success role
    final green = theme.brightness == Brightness.dark ? Colors.green.shade300 : Colors.green.shade800;
    const duration = Duration(milliseconds: 300);
    Widget slot(Widget child, {required bool visible, required Offset hiddenOffset}) => IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : hiddenOffset,
          duration: duration,
          child: AnimatedOpacity(opacity: visible ? 1 : 0, duration: duration, child: child),
        ),
      ),
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        slot(
          Theme(
            // IPText draws in labelMedium
            data: theme.copyWith(
              textTheme: theme.textTheme.copyWith(labelMedium: theme.textTheme.labelMedium?.copyWith(color: green)),
            ),
            child: IPText(ip: widget.ip, onLongPress: widget.onLongPress ?? () {}, constrained: true),
          ),
          visible: !_words,
          hiddenOffset: const Offset(0, -0.4),
        ),
        slot(
          Text(
            t.pages.settings.chain.finalIp,
            maxLines: 1,
            style: theme.textTheme.labelMedium?.copyWith(color: green, fontSize: 11),
          ),
          visible: _words,
          hiddenOffset: const Offset(0, 0.4),
        ),
      ],
    );
  }
}

// class _StatsColumn extends HookConsumerWidget {
//   const _StatsColumn();

//   @override
//   Widget build(BuildContext context, WidgetRef ref) {
//     final t = ref.watch(translationsProvider).requireValue;
//     final stats = ref.watch(statsNotifierProvider).value;

//     return Directionality(
//       textDirection: TextDirection.values[(Directionality.of(context).index + 1) % TextDirection.values.length],
//       child: Flexible(
//         child: Column(
//           children: [
//             _InfoProp(
//               icon: Icons.swap_vert_rounded,
//               text: (stats?.downlinkTotal ?? 0).size(),
//               semanticLabel: t.stats.totalTransferred,
//             ),
//             const Gap(8),
//             _InfoProp(
//               icon: Icons.vertical_align_bottom_rounded,
//               text: (stats?.downlink ?? 0).speed(),
//               semanticLabel: t.stats.speed,
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }

// class _InfoProp extends StatelessWidget {
//   const _InfoProp({
//     required this.icon,
//     required this.text,
//     this.semanticLabel,
//   });

//   final IconData icon;
//   final String text;
//   final String? semanticLabel;

//   @override
//   Widget build(BuildContext context) {
//     return Semantics(
//       label: semanticLabel,
//       child: Row(
//         children: [
//           Icon(icon),
//           const Gap(8),
//           Flexible(
//             child: Text(
//               text,
//               style: Theme.of(context).textTheme.labelMedium?.copyWith(fontFamily: FontFamily.emoji),
//               overflow: TextOverflow.ellipsis,
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }
