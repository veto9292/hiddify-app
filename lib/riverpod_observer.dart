import 'dart:developer';

import 'package:hooks_riverpod/hooks_riverpod.dart';

final class RiverpodObserver extends ProviderObserver {
  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    final provider = context.provider;
    log('didAddProvider : ${provider.name ?? provider.runtimeType} : $value');
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    final provider = context.provider;
    log('didDisposeProvider : ${provider.name ?? provider.runtimeType}');
  }

  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) {
    final provider = context.provider;
    log('didUpdateProvider : ${provider.name ?? provider.runtimeType} : $previousValue -> $newValue');
  }
}
