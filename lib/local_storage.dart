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

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<List<SleepEvent>> loadEvents() async {
    return _decodeList(await _prefs.getString(_eventsKey), SleepEvent.fromJson);
  }

  Future<List<SleepSession>> loadSessions() async {
    return _decodeList(await _prefs.getString(_sessionsKey), SleepSession.fromJson);
  }

  Future<void> saveEvents(List<SleepEvent> events) async {
    await _prefs.setString(
      _eventsKey,
      jsonEncode(events.map((event) => event.toJson()).toList()),
    );
  }

  Future<void> saveSessions(List<SleepSession> sessions) async {
    await _prefs.setString(
      _sessionsKey,
      jsonEncode(sessions.map((session) => session.toJson()).toList()),
    );
  }

  Future<void> clearAllData() async {
    await _prefs.remove(_eventsKey);
    await _prefs.remove(_sessionsKey);
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
