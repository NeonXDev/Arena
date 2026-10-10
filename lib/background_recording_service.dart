import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'local_storage.dart';
import 'sleep_models.dart';

const String _stopNotificationAction = 'stop_sleep';

/// The callback used by Android's foreground service isolate.
@pragma('vm:entry-point')
void startSleepRecordingService() {
  FlutterForegroundTask.setTaskHandler(SleepRecordingTaskHandler());
}

class SleepRecordingTaskHandler extends TaskHandler {
  AudioRecorder? _recorder;
  Timer? _amplitudeTimer;
  DateTime? _lastEvent;
  bool _monitorEnabled = true;
  double _threshold = -31;
  final LocalSleepStorage _storage = LocalSleepStorage();
  final List<SleepEvent> _events = [];
  Future<void> _eventSaveQueue = Future<void>.value();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final sensitivity = await FlutterForegroundTask.getData<int>(key: 'sensitivity') ?? 2;
    _threshold = _thresholdForSensitivity(sensitivity);
    _monitorEnabled = await FlutterForegroundTask.getData<bool>(key: 'monitorEnabled') ?? true;
    try {
      _events.addAll(await _storage.loadEvents());
    } catch (_) {
      // Recording must not fail because the optional event index is unavailable.
    }

    final recorder = AudioRecorder();
    if (!await recorder.hasPermission(request: false)) {
      FlutterForegroundTask.sendDataToMain(<String, dynamic>{
        'type': 'service_error',
        'message': 'Microphone permission was not granted.',
      });
      await recorder.dispose();
      await FlutterForegroundTask.stopService();
      return;
    }

    try {
      final directory = await getApplicationSupportDirectory();
      final fileName = 'luma_sleep_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final path = '${directory.path}/$fileName';
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      if (!await recorder.isRecording()) {
        throw StateError('The Android recorder did not enter the recording state.');
      }
      _recorder = recorder;
      FlutterForegroundTask.sendDataToMain(<String, dynamic>{
        'type': 'recording_started',
        'path': path,
      });
      _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
        _readAmplitude();
      });
      FlutterForegroundTask.updateService(
        notificationText: 'Listening for sleep sounds',
        notificationButtons: const [
          NotificationButton(id: _stopNotificationAction, text: 'Stop'),
        ],
      );
    } catch (error) {
      await recorder.dispose();
      FlutterForegroundTask.sendDataToMain(<String, dynamic>{
        'type': 'service_error',
        'message': 'Could not start the background microphone.',
        'error': error.toString(),
      });
      await FlutterForegroundTask.stopService();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // The foreground service stays alive through this repeat callback. Audio
    // capture and amplitude checks run from _amplitudeTimer above.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    final recorder = _recorder;
    _recorder = null;
    try {
      await recorder?.stop().timeout(const Duration(seconds: 3));
    } catch (_) {
      // A recorder can fail to flush on some devices; do not block service shutdown.
    }
    try {
      await recorder?.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {
      // The service is already being torn down; there is nothing else to do.
    }
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      'type': 'service_stopped',
      'isTimeout': isTimeout,
    });
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final type = data['type'];
    if (type == 'monitorEnabled' && data['value'] is bool) {
      _monitorEnabled = data['value'] as bool;
    }
    if (type == 'sensitivity' && data['value'] is int) {
      _threshold = _thresholdForSensitivity(data['value'] as int);
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == _stopNotificationAction) {
      FlutterForegroundTask.stopService();
    }
  }

  Future<void> _readAmplitude() async {
    if (!_monitorEnabled) return;
    final recorder = _recorder;
    if (recorder == null) return;

    try {
      final amplitude = await recorder.getAmplitude();
      if (!identical(recorder, _recorder)) return;
      // Use the peak as well as the average so short sounds are not missed
      // between the 900 ms monitoring samples.
      final current = math.max(amplitude.current, amplitude.max).toDouble();
      if (current.isNaN || current < _threshold) return;

      final now = DateTime.now();
      if (_lastEvent != null && now.difference(_lastEvent!).inSeconds < 5) return;
      _lastEvent = now;
      final possibleSnore = current > -20;
      final event = SleepEvent(
        time: now,
        kind: possibleSnore ? 'Possible snore' : 'Sound detected',
        detail: possibleSnore
            ? 'Louder volume pattern detected'
            : 'Ambient sound above your threshold',
        decibels: math.max(0.0, 60 + current).toDouble(),
        isSnore: possibleSnore,
      );
      final persisted = await _persistEvent(event);
      FlutterForegroundTask.sendDataToMain(<String, dynamic>{
        'type': 'sound_event',
        'timestamp': now.millisecondsSinceEpoch,
        'isSnore': possibleSnore,
        'decibels': event.decibels,
        'persisted': persisted,
      });
    } catch (_) {
      // Some devices do not expose amplitude immediately after start.
    }
  }

  Future<bool> _persistEvent(SleepEvent event) async {
    _events.insert(0, event);
    if (_events.length > 500) _events.removeLast();

    final snapshot = List<SleepEvent>.from(_events);
    final nextWrite = _eventSaveQueue.then((_) => _storage.saveEvents(snapshot));
    _eventSaveQueue = nextWrite.catchError((_) {});
    try {
      await nextWrite;
      return true;
    } catch (_) {
      return false;
    }
  }

  double _thresholdForSensitivity(int sensitivity) {
    switch (sensitivity) {
      case 1:
        return -24;
      case 3:
        return -38;
      default:
        return -31;
    }
  }
}
