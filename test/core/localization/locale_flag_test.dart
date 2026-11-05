import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/locale_extensions.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:world_flags/world_flags.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every language has a flag, and no two share one', () {
    final codes = AppLocale.values.map((e) => e.flagCountryCode).toList();
    for (final (i, locale) in AppLocale.values.indexed) {
      expect(codes[i], hasLength(2), reason: '${locale.name} has no flag');
    }
    expect(codes.toSet(), hasLength(codes.length));
  });

  test("every language's flag is drawn", () {
    for (final locale in AppLocale.values) {
      // IPCountryFlag draws Iran with the lion and sun from the app's assets
      if (locale.flagCountryCode == 'ir') continue;
      expect(WorldCountry.maybeFromCodeShort(locale.flagCountryCode), isNotNull, reason: locale.name);
    }
  });
}
