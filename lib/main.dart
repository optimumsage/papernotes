import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/local/database.dart';
import 'data/settings_service.dart';
import 'providers/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Bootstrap the singletons the provider graph depends on.
  final prefs = await SharedPreferences.getInstance();
  final database = AppDatabase();
  final initialSettings = await SettingsService(prefs).load();

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(database),
        initialSettingsProvider.overrideWithValue(initialSettings),
      ],
      child: const PaperNotesApp(),
    ),
  );
}
