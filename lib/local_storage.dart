import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sleep_models.dart';

/// Persists the small Luma index locally. Audio remains in app-private files;
/// this store contains only metadata and event markers.
class LocalSleepStorage {
  static const _eventsKey = 'luma_sleep_events_v1';
  static const _sessionsKey = 'luma_sleep_sessions_v1';

  SharedPreferencesAsync? _prefs;

  SharedPreferencesAsync? get _preferences {
    try {
      return _prefs ??= SharedPreferencesAsync();
    } catch (_) {
      // Tests or an unavailable platform backend can use the UI without storage.
      return null;
    }
  }

  Future<List<SleepEvent>> loadEvents() async {
    final preferences = _preferences;
    if (preferences == null) return <SleepEvent>[];
    return _decodeList(await preferences.getString(_eventsKey), SleepEvent.fromJson);
  }

  Future<List<SleepSession>> loadSessions() async {
    final preferences = _preferences;
    if (preferences == null) return <SleepSession>[];
    return _decodeList(await preferences.getString(_sessionsKey), SleepSession.fromJson);
  }

  Future<void> saveEvents(List<SleepEvent> events) async {
    final preferences = _preferences;
    if (preferences == null) return;
    await preferences.setString(
      _eventsKey,
      jsonEncode(events.map((event) => event.toJson()).toList()),
    );
  }

  Future<void> saveSessions(List<SleepSession> sessions) async {
    final preferences = _preferences;
    if (preferences == null) return;
    await preferences.setString(
      _sessionsKey,
      jsonEncode(sessions.map((session) => session.toJson()).toList()),
    );
  }

  Future<void> clearAllData() async {
    final preferences = _preferences;
    if (preferences != null) {
      await preferences.remove(_eventsKey);
      await preferences.remove(_sessionsKey);
    }
    await _deleteLocalRecordings();
  }

  List<T> _decodeList<T>(String? encoded, T Function(Map<String, dynamic>) fromJson) {
    if (encoded == null || encoded.isEmpty) return <T>[];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return <T>[];
      return decoded
          .whereType<Map>()
          .map((item) => fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return <T>[];
    }
  }

  Future<void> _deleteLocalRecordings() async {
    final directories = <Directory>[];
    try {
      directories.add(await getApplicationDocumentsDirectory());
    } catch (_) {}
    try {
      directories.add(await getApplicationSupportDirectory());
    } catch (_) {}

    for (final directory in directories) {
      if (!await directory.exists()) continue;
      try {
        await for (final entity in directory.list()) {
          if (entity is File && _isLumaRecording(entity.path)) {
            await entity.delete();
          }
        }
      } catch (_) {
        // A missing directory or locked file should not block the clear action.
      }
    }
  }

  bool _isLumaRecording(String path) {
    final name = path.split(Platform.pathSeparator).last;
    return name.startsWith('luma_sleep_') && name.endsWith('.m4a');
  }
}
