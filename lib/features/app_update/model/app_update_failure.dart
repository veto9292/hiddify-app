import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';

part 'app_update_failure.freezed.dart';

// one case, so freezed 4 would build copyWith on the abstract base class
@Freezed(copyWith: false)
sealed class AppUpdateFailure with _$AppUpdateFailure, Failure {
  const AppUpdateFailure._();

  @With<UnexpectedFailure>()
  const factory AppUpdateFailure.unexpected([Object? error, StackTrace? stackTrace]) = AppUpdateUnexpectedFailure;

  @override
  ({String type, String? message}) present(TranslationsEn t) {
    return switch (this) {
      AppUpdateUnexpectedFailure() => (type: t.errors.unexpected, message: null),
    };
  }
}
