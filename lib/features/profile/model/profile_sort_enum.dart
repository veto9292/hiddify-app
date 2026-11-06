import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';

enum ProfilesSort {
  lastUpdate,
  name;

  String present(TranslationsEn t) {
    return switch (this) {
      lastUpdate => t.dialogs.sortProfiles.sort.lastUpdate,
      name => t.dialogs.sortProfiles.sort.name,
    };
  }

  /// Human-readable label for the current sort direction, worded per type.
  String directionLabel(TranslationsEn t, SortMode mode) {
    return switch (this) {
      lastUpdate =>
        mode == SortMode.descending
            ? t.dialogs.sortProfiles.direction.newestFirst
            : t.dialogs.sortProfiles.direction.oldestFirst,
      name => mode == SortMode.ascending ? "A → Z" : "Z → A",
    };
  }

  IconData get icon => switch (this) {
    lastUpdate => Icons.history_rounded,
    name => Icons.sort_by_alpha_rounded,
  };
}

enum SortMode { ascending, descending }
