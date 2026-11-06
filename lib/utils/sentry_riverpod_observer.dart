import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sentry/sentry.dart';

final class SentryRiverpodObserver extends ProviderObserver {
  void addBreadcrumb(String message, {Map<String, dynamic>? data}) {
    Sentry.addBreadcrumb(Breadcrumb(category: "Provider", message: message, data: data));
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    final provider = context.provider;
    super.didAddProvider(context, value);
    addBreadcrumb(
      'Provider [${provider.name ?? provider.runtimeType}] was ADDED',
      data: value != null ? {"initial-value": value} : null,
    );
  }

  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) {
    final provider = context.provider;
    super.didUpdateProvider(context, previousValue, newValue);
    addBreadcrumb(
      'Provider [${provider.name ?? provider.runtimeType}] was UPDATED',
      data: {"new-value": newValue, "old-value": previousValue},
    );
  }
}
