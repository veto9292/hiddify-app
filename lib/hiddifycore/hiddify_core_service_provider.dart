import 'dart:async';

import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'hiddify_core_service_provider.g.dart';

@Riverpod(keepAlive: true)
HiddifyCoreService hiddifyCoreService(Ref ref) {
  final service = HiddifyCoreService(ref);
  ref.onDispose(() => unawaited(service.core.dispose()));
  return service;
}
