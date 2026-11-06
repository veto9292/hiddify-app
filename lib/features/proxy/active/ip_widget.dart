import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/utils/ip_utils.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class IPText extends HookConsumerWidget {
  const IPText({required this.ip, required this.onLongPress, this.constrained = false, super.key});

  final String ip;
  final VoidCallback onLongPress;
  final bool constrained;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final isVisible = useState(false);
    final textTheme = Theme.of(context).textTheme;
    final ipStyle = (constrained ? textTheme.labelMedium : textTheme.labelLarge)?.copyWith(
      fontFamily: FontFamily.emoji,
    );

    return Semantics(
      label: t.pages.proxies.ipInfo.address,
      child: InkWell(
        onTap: () {
          isVisible.value = !isVisible.value;
          if (isVisible.value) {
            ref.read(hapticServiceProvider.notifier).mediumImpact();
          }
        },
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: AnimatedCrossFade(
            firstChild: Text(ip, style: ipStyle, textDirection: TextDirection.ltr, overflow: TextOverflow.ellipsis),
            secondChild: Padding(
              padding: constrained ? EdgeInsets.zero : const EdgeInsetsDirectional.only(end: 48),
              child: Text(
                obscureIp(ip),
                semanticsLabel: t.common.hidden,
                style: ipStyle,
                textDirection: TextDirection.ltr,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            crossFadeState: isVisible.value ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 200),
          ),
        ),
      ),
    );
  }
}

class UnknownIPText extends HookConsumerWidget {
  const UnknownIPText({required this.text, required this.onTap, this.constrained = false, super.key});

  final String text;
  final VoidCallback onTap;
  final bool constrained;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final textTheme = Theme.of(context).textTheme;
    final style = constrained ? textTheme.bodySmall : textTheme.labelMedium;

    return Semantics(
      label: t.pages.proxies.ipInfo.address,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(text, style: style, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class IPCountryFlag extends HookConsumerWidget {
  const IPCountryFlag({
    required this.countryCode,
    this.organization,
    this.size = 16,
    this.radius = 8,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final String? countryCode;
  final double size;

  /// The flag's corner radius.
  final double radius;

  final EdgeInsetsGeometry padding;

  final String? organization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return Semantics(
      label: t.pages.proxies.ipInfo.country,
      child: Padding(
        padding: padding,
        child: (countryCode?.isEmpty ?? true)
            ? Icon(Icons.help_outline_rounded, size: size)
            : SizedBox(
                width: size,
                height: size,
                child: Stack(
                  textDirection: Directionality.of(context),
                  alignment: Alignment.center,
                  children: [
                    // a rounded-rect clip, not the package's path clip: the flag's raster is
                    // shared by every tile, so the clip was what each one paid for
                    ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: countryFlag(countryCode!, size: size - 8, shape: null),
                    ),
                    if (organization != null)
                      Positioned.directional(
                        textDirection: Directionality.of(context),
                        bottom: 0,
                        end: 0,
                        child: OrganisationFlag(organization: organization!, size: size / 2.5),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The flag of [countryCode] as a [size] square, clipped to [shape] (square when null). Iran shows
/// the lion and sun, which country_flags doesn't have; every other country comes from
/// country_flags, its rectangle cropped to the square.
Widget countryFlag(String countryCode, {double size = 48, ShapeBorder? shape = const CircleBorder()}) {
  final Widget flag = countryCode.toLowerCase() == "ir"
      ? Assets.images.irShir.svg(width: size, height: size, fit: BoxFit.cover)
      : CountryFlag.fromCountryCode(countryCode, theme: ImageTheme(width: size, height: size));
  if (shape == null) return flag;
  // the text direction resolves directional shapes, such as the routing page's BorderRadiusDirectional
  return Builder(
    builder: (context) => ClipPath(
      clipper: ShapeBorderClipper(shape: shape, textDirection: Directionality.maybeOf(context)),
      child: flag,
    ),
  );
}

class OrgIconData {
  /// The provider's logo, a one-color SVG from Simple Icons in the app's assets.
  final String asset;
  final Color color;

  const OrgIconData(this.asset, this.color);
}

// Map of organization keywords to icon and color
const Map<String, OrgIconData> organizationData = {
  "cloudflare": OrgIconData("assets/images/orgs/cloudflare.svg", Color(0xFFF38020)),
  "azure": OrgIconData("assets/images/orgs/microsoftazure.svg", Color(0xFF0078D4)),
  "amazon": OrgIconData("assets/images/orgs/amazonaws.svg", Color(0xFF232F3E)),
  "oracle": OrgIconData("assets/images/orgs/oracle.svg", Color(0xFFF80000)),
  "hetzner": OrgIconData("assets/images/orgs/hetzner.svg", Color(0xFFD50C2D)),
  "ovh": OrgIconData("assets/images/orgs/ovh.svg", Color(0xFF123F6D)),
  "fastly": OrgIconData("assets/images/orgs/fastly.svg", Color(0xFFFF282D)),
  "digitalocean": OrgIconData("assets/images/orgs/digitalocean.svg", Color(0xFF0080FF)),
  "alibaba": OrgIconData("assets/images/orgs/alibabacloud.svg", Color(0xFFFF6A00)),
  "google": OrgIconData("assets/images/orgs/googlecloud.svg", Color(0xFF4285F4)),
  "starlink": OrgIconData("assets/images/orgs/satellite.svg", Color(0xFF000000)),
};

class OrganisationFlag extends HookConsumerWidget {
  const OrganisationFlag({required this.organization, this.size = 24, super.key});

  final String organization;
  final double size;

  // Function to create flag widget with icon and color
  Widget getFlagWidget({
    required Widget widget,
    required String organization,
    required double size,
    required String label,
    required Color color,
  }) {
    return Semantics(
      label: "$label $organization",
      child: Container(
        width: size,
        height: size,

        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(100)),
        // padding: const ,
        child: widget,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    for (final entry in organizationData.entries) {
      if (organization.toLowerCase().contains(entry.key)) {
        return getFlagWidget(
          widget: SvgPicture.asset(
            entry.value.asset,
            width: size - 6,
            height: size - 6,
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
          ),
          color: entry.value.color,
          organization: organization,
          size: size,
          label: t.pages.proxies.ipInfo.organization,
        );
      }
    }

    // Return empty widget if no match is found
    return const SizedBox.shrink();
  }
}
