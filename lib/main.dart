// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_recording_service.dart';
import 'local_storage.dart';
import 'sleep_models.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(LumaSleepApp());
}

/// Entry point used by flutter_overlay_window on Android.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(_SleepOverlayApp());
}

class AppColors {
  static bool lightMode = false;

  static Color get ink => lightMode ? Color(0xFF171A2B) : Color(0xFFF5F7FF);
  static Color get muted => lightMode ? Color(0xFF65708B) : Color(0xFF98A0BC);
  static Color get background => lightMode ? Color(0xFFF5F7FC) : Color(0xFF0A0D18);
  static Color get surface => lightMode ? Color(0xFFFFFFFF) : Color(0xFF111627);
  static Color get surfaceRaised => lightMode ? Color(0xFFEEF0F8) : Color(0xFF171D31);
  static Color get border => lightMode ? Color(0xFFDDE1EE) : Color(0xFF252D47);
  static Color get lavender => lightMode ? Color(0xFF6F60D7) : Color(0xFFAC9CFF);
  static Color get lavenderBright => lightMode ? Color(0xFF5143B7) : Color(0xFFD0C7FF);
  static Color get mint => lightMode ? Color(0xFF187A4B) : Color(0xFFB6F5D0);
  static Color get amber => lightMode ? Color(0xFF9A6500) : Color(0xFFFFD58C);
  static Color get coral => lightMode ? Color(0xFFB5342D) : Color(0xFFFF9B93);
  static Color get blue => lightMode ? Color(0xFF286DAD) : Color(0xFF86C7FF);
}

enum AppTab { tonight, insights, recordings, settings }

class LumaSleepApp extends StatefulWidget {
  const LumaSleepApp({super.key});

  @override
  State<LumaSleepApp> createState() => _LumaSleepAppState();
}

class _LumaSleepAppState extends State<LumaSleepApp> {
  bool _lightMode = AppColors.lightMode;
  SharedPreferencesAsync? _preferences;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
  }

  Future<void> _loadAppearance() async {
    try {
      final preferences = _preferences ??= SharedPreferencesAsync();
      final saved = await preferences.getBool('luma_light_mode');
      if (!mounted || saved == null) return;
      AppColors.lightMode = saved;
      setState(() => _lightMode = saved);
    } catch (_) {
      // Tests or an unavailable preferences backend should not block the UI.
    }
  }

  void _setLightMode(bool value) {
    AppColors.lightMode = value;
    setState(() => _lightMode = value);
    unawaited(_persistAppearance(value));
  }

  Future<void> _persistAppearance(bool value) async {
    try {
      final preferences = _preferences ??= SharedPreferencesAsync();
      await preferences.setBool('luma_light_mode', value);
    } catch (_) {
      // Appearance still changes for this run if persistence is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = _lightMode ? ThemeData.light(useMaterial3: true) : ThemeData.dark(useMaterial3: true);
    final scheme = _lightMode
        ? ColorScheme.light(
            primary: AppColors.lavender,
            onPrimary: Colors.white,
            secondary: AppColors.mint,
            onSecondary: Colors.white,
            surface: AppColors.surface,
            onSurface: AppColors.ink,
          )
        : ColorScheme.dark(
            primary: AppColors.lavender,
            onPrimary: AppColors.background,
            secondary: AppColors.mint,
            onSecondary: AppColors.background,
            surface: AppColors.surface,
            onSurface: AppColors.ink,
          );
    return MaterialApp(
      title: 'Luma Sleep',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: scheme,
        textTheme: base.textTheme.apply(
          bodyColor: AppColors.ink,
          displayColor: AppColors.ink,
          fontFamily: 'Arial',
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: AppColors.surface,
          indicatorColor: AppColors.lavender.withValues(alpha: .18),
          height: 72,
          labelTextStyle: MaterialStatePropertyAll(
            base.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surfaceRaised,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: WithForegroundTask(
        child: SleepHomePage(
          lightMode: _lightMode,
          onLightModeChanged: _setLightMode,
        ),
      ),
    );
  }
}

class SleepHomePage extends StatefulWidget {
  SleepHomePage({
    super.key,
    required this.lightMode,
    required this.onLightModeChanged,
  });

  final bool lightMode;
  final ValueChanged<bool> onLightModeChanged;

  @override
  State<SleepHomePage> createState() => _SleepHomePageState();
}

class _SleepHomePageState extends State<SleepHomePage> with WidgetsBindingObserver {
  AppTab _activeTab = AppTab.tonight;
  bool _isTracking = false;
  bool _isStarting = false;
  bool _soundMonitorEnabled = true;
  bool _overlayEnabled = false;
  bool _overlayVisible = false;
  int _sensitivity = 2;
  Duration _elapsed = Duration.zero;
  DateTime? _sessionStarted;
  AudioRecorder? _recorder;
  Timer? _sessionTimer;
  Timer? _amplitudeTimer;
  Timer? _stopWatchdog;
  DateTime? _lastEvent;
  bool _foregroundServiceInitialized = false;
  bool _usingForegroundService = false;
  bool _isStopping = false;
  bool _stopCleanupInFlight = false;
  bool _isLoadingData = true;
  String? _activeAudioPath;
  Completer<String>? _foregroundRecordingStarted;
  StreamSubscription<dynamic>? _overlaySubscription;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingAudioPath;
  bool _isLoadingAudio = false;
  final LocalSleepStorage _storage = LocalSleepStorage();
  Future<void> _eventSaveQueue = Future<void>.value();
  final List<SleepEvent> _events = [];
  final List<SleepSession> _sessions = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      _overlaySubscription = FlutterOverlayWindow.overlayListener.listen(_handleOverlayMessage);
      FlutterForegroundTask.addTaskDataCallback(_handleForegroundTaskData);
      _initForegroundService();
    }
    _loadLocalData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isStopping) {
      // The foreground task persists sound markers from its own isolate while
      // this isolate is backgrounded. Reload them when the UI is visible again.
      unawaited(_loadLocalData());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionTimer?.cancel();
    _amplitudeTimer?.cancel();
    _stopWatchdog?.cancel();
    _overlaySubscription?.cancel();
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_handleForegroundTaskData);
    }
    _recorder?.dispose();
    unawaited(_audioPlayer.dispose());
    super.dispose();
  }

  Future<void> _loadLocalData() async {
    try {
      final events = await _storage.loadEvents();
      final sessions = await _storage.loadSessions();
      if (!mounted) return;
      setState(() {
        _events
          ..clear()
          ..addAll(events);
        _sessions
          ..clear()
          ..addAll(sessions);
        _isLoadingData = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingData = false);
    }
  }

  Future<void> _saveEvents() {
    // Sound events can arrive while the previous preference write is still in
    // flight. Serialize the snapshots so a later write cannot be overwritten
    // by an older one.
    final snapshot = List<SleepEvent>.from(_events);
    final nextWrite = _eventSaveQueue.then((_) => _storage.saveEvents(snapshot));
    _eventSaveQueue = nextWrite.catchError((_) {});
    return _eventSaveQueue;
  }

  Future<void> _saveSessions() => _storage.saveSessions(List<SleepSession>.from(_sessions));

  void _handleOverlayMessage(dynamic message) {
    if (message == 'stop_tracking') {
      _stopTracking();
    } else if (message == 'close_overlay') {
      _hideSleepOverlay();
    }
  }

  void _handleForegroundTaskData(Object data) {
    if (data is! Map) return;
    final type = data['type'];
    if (type == 'recording_started' && data['path'] is String) {
      final path = data['path'] as String;
      _activeAudioPath = path;
      final completer = _foregroundRecordingStarted;
      if (completer != null && !completer.isCompleted) {
        completer.complete(path);
      }
    } else if (type == 'sound_event') {
      final timestamp = data['timestamp'];
      final isSnore = data['isSnore'] == true;
      final decibels = data['decibels'];
      if (timestamp is! int || decibels is! num || !mounted) return;
      final eventTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      setState(() {
        _events.insert(
          0,
          SleepEvent(
            time: eventTime,
            kind: isSnore ? 'Possible snore' : 'Sound detected',
            detail: isSnore
                ? 'Louder volume pattern detected'
                : 'Ambient sound above your threshold',
            decibels: decibels.toDouble(),
            isSnore: isSnore,
          ),
        );

      });
      if (data['persisted'] != true) {
        _saveEvents();
      }
    } else if (type == 'service_error') {
      final message = data['message'] as String? ?? 'Background recording stopped.';
      final completer = _foregroundRecordingStarted;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(StateError(message), StackTrace.current);
      }
      if (mounted) _showSnack(message);
    } else if (type == 'service_stopped' && _isTracking && !_isStopping) {
      // The notification Stop action can end the service without going
      // through the in-app button. Finalize the session locally as well.
      _stopTracking(serviceAlreadyStopped: true);
    }
  }

  Future<void> _initForegroundService() async {
    if (_foregroundServiceInitialized) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'luma_sleep',
          channelName: 'Luma Sleep',
          channelDescription: 'Keeps sleep sound monitoring active in the background.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(1000),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );
      _foregroundServiceInitialized = true;
    } catch (_) {
      // The service is unavailable on unsupported platforms, but the dashboard can still open.
    }
  }

  Future<void> _requestBackgroundPermissions() async {
    if (!Platform.isAndroid) return;

    try {
      // Android 13+ can hide the foreground-service notification when this is
      // denied. Ask before starting so the user sees the service that protects
      // the microphone session. Older Android versions report this as granted.
      final notificationPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (_) {
      // A denied notification prompt must not prevent microphone recording.
    }

    try {
      // Do this while the app is visible. Android may show a system settings
      // dialog, and the exemption helps OEMs keep the service alive overnight.
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {
      // Some vendors do not expose this exemption. The foreground service
      // still provides the platform-supported background execution path.
    }
  }

  Future<String> _startAndroidRecordingService() async {
    await _initForegroundService();
    await _requestBackgroundPermissions();
    await FlutterForegroundTask.saveData(key: 'sensitivity', value: _sensitivity);
    await FlutterForegroundTask.saveData(key: 'monitorEnabled', value: _soundMonitorEnabled);

    // startService can report success before the background isolate has
    // actually opened the microphone. Wait for an explicit handshake so we
    // never show a countdown for a session that is not recording.
    final completer = Completer<String>();
    _foregroundRecordingStarted = completer;
    try {
      final result = await FlutterForegroundTask.startService(
        serviceId: 1905,
        notificationTitle: 'Luma Sleep',
        notificationText: 'Starting sleep sound monitoring…',
        notificationButtons: const [
          NotificationButton(id: 'stop_sleep', text: 'Stop'),
        ],
        callback: startSleepRecordingService,
      );
      if (result is ServiceRequestFailure) {
        throw result.error;
      }
      return await completer.future.timeout(Duration(seconds: 12));
    } finally {
      if (identical(_foregroundRecordingStarted, completer)) {
        _foregroundRecordingStarted = null;
      }
    }
  }

  Future<void> _startLocalRecording(AudioRecorder recorder) async {
    final directory = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${directory.path}/luma_sleep_$stamp.m4a';
    await recorder.start(
      RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: path,
    );
    if (!await recorder.isRecording()) {
      throw StateError('The local recorder did not enter the recording state.');
    }
    _recorder = recorder;
    _activeAudioPath = path;
  }

  Future<void> _startTracking() async {
    if (_isStarting || _isTracking || _isStopping || _stopCleanupInFlight) return;
    setState(() => _isStarting = true);
    _usingForegroundService = false;

    final recorder = AudioRecorder();
    var usingForegroundService = false;
    try {
      final hasPermission = await recorder.hasPermission();
      if (!hasPermission) {
        if (mounted) {
          setState(() => _isStarting = false);
          _showSnack('Microphone access is needed to listen for sound.');
        }
        await recorder.dispose();
        return;
      }

      if (Platform.isAndroid) {
        try {
          final foregroundPath = await _startAndroidRecordingService();
          _activeAudioPath = foregroundPath;
          await recorder.dispose();
          _usingForegroundService = true;
          usingForegroundService = true;
        } catch (_) {
          // If the native foreground-service configuration is missing, still
          // allow tracking in the app instead of leaving the button stuck.
          try {
            await FlutterForegroundTask.stopService().timeout(Duration(seconds: 3));
          } catch (_) {}
          await _startLocalRecording(recorder);
          _usingForegroundService = false;
        }
      } else {
        await _startLocalRecording(recorder);
      }

      if (!mounted) {
        await recorder.dispose();
        return;
      }

      _sessionStarted = DateTime.now();
      _lastEvent = null;
      setState(() {
        _isTracking = true;
        _isStarting = false;
        _elapsed = Duration.zero;
      });
      _startTimers();
      _showSleepOverlayIfEnabled();
      _showSnack(
        usingForegroundService
            ? 'Sleep tracking is on and protected by a foreground service.'
            : 'Sleep tracking is on for this app session.',
      );
    } catch (error) {
      debugPrint('Luma startTracking error: $error');
      await recorder.dispose();
      if (mounted) {
        setState(() => _isStarting = false);
        _showSnack('Could not start microphone tracking. Check microphone permission and try again.');
      }
    }
  }

  void _startTimers() {
    _sessionTimer?.cancel();
    _amplitudeTimer?.cancel();
    _sessionTimer = Timer.periodic(Duration(seconds: 1), (_) {
      if (!mounted || _sessionStarted == null) return;
      setState(() {
        _elapsed = DateTime.now().difference(_sessionStarted!);
      });
      _publishOverlayTime();
    });
    if (_recorder != null) {
      _amplitudeTimer = Timer.periodic(Duration(milliseconds: 900), (_) {
        _readAmplitude();
      });
    }
  }

  Future<void> _showSleepOverlayIfEnabled() async {
    if (!_overlayEnabled) return;
    try {
      var granted = await FlutterOverlayWindow.isPermissionGranted();
      if (!granted) {
        granted = await FlutterOverlayWindow.requestPermission() ?? false;
      }
      if (!granted || !_isTracking) {
        if (mounted && !granted) {
          _showSnack('Allow “display over other apps” to use the floating control.');
        }
        return;
      }
      if (await FlutterOverlayWindow.isActive()) {
        if (mounted) setState(() => _overlayVisible = true);
        return;
      }
      await FlutterOverlayWindow.showOverlay(
        height: 116,
        width: 292,
        alignment: OverlayAlignment.topRight,
        positionGravity: PositionGravity.auto,
        enableDrag: true,
        overlayTitle: 'Luma Sleep',
        overlayContent: 'Sleep tracking is active',
      );
      if (mounted) {
        setState(() => _overlayVisible = true);
        _publishOverlayTime();
      }
    } catch (_) {
      // Overlay windows are Android-only; tracking still works without one.
      if (mounted) _showSnack('Floating controls are available on Android only.');
    }
  }

  Future<void> _hideSleepOverlay() async {
    // Do not call the overlay plugin when no overlay was opened. Some Android
    // versions can leave closeOverlay waiting forever after a denied or stale
    // overlay permission, which must never block ending a sleep session.
    if (!_overlayVisible) return;
    try {
      await FlutterOverlayWindow.closeOverlay().timeout(Duration(seconds: 2));
    } catch (_) {
      // Ignore a missing, stale, or slow overlay; tracking still ends.
    }
    if (mounted) setState(() => _overlayVisible = false);
  }

  Future<void> _publishOverlayTime() async {
    if (!_overlayVisible) return;
    try {
      await FlutterOverlayWindow.shareData('elapsed:${_formatElapsed(_elapsed)}');
    } catch (_) {
      // The main tracker remains usable if the overlay engine is unavailable.
    }
  }

  Future<void> _readAmplitude() async {
    if (!_isTracking || !_soundMonitorEnabled) return;
    final recorder = _recorder;
    if (recorder == null) return;

    try {
      final amplitude = await recorder.getAmplitude();
      if (!mounted || !_isTracking || !identical(recorder, _recorder)) return;
      // Use the peak as well as the average so short sounds are not missed
      // between the 900 ms monitoring samples.
      final current = math.max(amplitude.current, amplitude.max).toDouble();
      if (current.isNaN || current < _detectionThreshold) return;
      final now = DateTime.now();
      if (_lastEvent != null && now.difference(_lastEvent!).inSeconds < 5) {
        return;
      }
      _lastEvent = now;
      final likelySnore = current > -20;
      if (!mounted) return;
      setState(() {
        _events.insert(
          0,
          SleepEvent(
            time: now,
            kind: likelySnore ? 'Possible snore' : 'Sound detected',
            detail: likelySnore
                ? 'Louder volume pattern detected'
                : 'Ambient sound above your threshold',
            decibels: math.max(0.0, 60 + current).toDouble(),
            isSnore: likelySnore,
          ),
        );

      });
      _saveEvents();
    } catch (_) {
      // Some platforms do not expose amplitude until the recorder is ready.
    }
  }

  double get _detectionThreshold {
    switch (_sensitivity) {
      case 1:
        return -24;
      case 3:
        return -38;
      default:
        return -31;
    }
  }

  void _setSoundMonitorEnabled(bool value) {
    setState(() => _soundMonitorEnabled = value);
    if (_usingForegroundService && _isTracking) {
      FlutterForegroundTask.sendDataToTask(<String, dynamic>{
        'type': 'monitorEnabled',
        'value': value,
      });
    }
  }

  void _setSensitivity(int value) {
    setState(() => _sensitivity = value);
    if (_usingForegroundService && _isTracking) {
      FlutterForegroundTask.sendDataToTask(<String, dynamic>{
        'type': 'sensitivity',
        'value': value,
      });
    }
  }

  Future<void> _stopTracking({bool serviceAlreadyStopped = false}) async {
    if ((!_isTracking && !_isStopping) || _isStopping || _stopCleanupInFlight) return;

    _isStopping = true;
    _stopCleanupInFlight = true;
    _stopWatchdog?.cancel();
    _stopWatchdog = Timer(Duration(seconds: 8), () {
      if (!_stopCleanupInFlight) return;
      _stopCleanupInFlight = false;
      _isStopping = false;
      if (mounted) {
        setState(() {});
        _showSnack('Stop requested. The recording will finish saving in the background.');
      }
    });
    _sessionTimer?.cancel();
    _amplitudeTimer?.cancel();
    final startedAt = _sessionStarted;
    final endedAt = DateTime.now();
    final recorder = _recorder;
    final usingForegroundService = _usingForegroundService;
    _recorder = null;
    String? finishedAudioPath = _activeAudioPath;

    // Send the native stop request before any persistence or overlay cleanup.
    // The request can run while the UI finalizes the local session metadata.
    final Future<ServiceRequestResult>? serviceStopRequest =
        usingForegroundService && !serviceAlreadyStopped
            ? FlutterForegroundTask.stopService()
            : null;

    // Update the dashboard before awaiting native shutdown. This keeps the
    // End session button responsive even if a device takes time to stop its
    // foreground service or flush the microphone file.
    if (mounted) {
      setState(() {
        _isTracking = false;
        _isStopping = false;
        _elapsed = Duration.zero;
        _sessionStarted = null;
      });
      _showSnack('Ending sleep session…');
    }
    await _hideSleepOverlay();

    // Save the session independently of native recorder shutdown. A device
    // may delay or fail the final stop call, but the user should still be able
    // to end the visible session and keep its metadata.
    if (startedAt != null) {
      _sessions.insert(
        0,
        SleepSession(
          startedAt: startedAt,
          endedAt: endedAt,
          audioPath: finishedAudioPath,
        ),
      );
      if (_sessions.length > 30) _sessions.removeLast();
      try {
        await _saveSessions().timeout(Duration(seconds: 3));
      } catch (_) {
        // Do not let a storage failure prevent the microphone from stopping.
      }
    }

    try {
      if (usingForegroundService) {
        if (serviceStopRequest != null) {
          final result = await serviceStopRequest.timeout(Duration(seconds: 5));
          if (result is ServiceRequestFailure) throw result.error;
        }
      } else if (recorder != null) {
        finishedAudioPath = await recorder.stop().timeout(Duration(seconds: 5)) ?? finishedAudioPath;
        await recorder.dispose().timeout(Duration(seconds: 3));
      }
    } catch (_) {
      // The UI session is already ended. Native shutdown can finish later or
      // be retried by the operating system without blocking the user.
    }

    _activeAudioPath = null;
    _usingForegroundService = false;
    _isStopping = false;
    _stopCleanupInFlight = false;
    _stopWatchdog?.cancel();
    _stopWatchdog = null;
    if (mounted) {
      setState(() {});
      _showSnack('Your sleep recording has been saved.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surfaceRaised,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
  }

  void _onTabChanged(int index) {
    setState(() => _activeTab = AppTab.values[index]);
  }

  String _formatElapsed(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _activeTab.index,
        children: [
          _buildTonight(),
          _buildInsights(),
          _buildRecordings(),
          _buildSettings(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _activeTab.index,
        onDestinationSelected: _onTabChanged,
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.nights_stay_outlined),
            selectedIcon: Icon(Icons.nights_stay_rounded),
            label: 'Tonight',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Insights',
          ),
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_outlined),
            selectedIcon: Icon(Icons.graphic_eq_rounded),
            label: 'Sounds',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_rounded),
            selectedIcon: Icon(Icons.tune_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildTonight() {
    return SafeArea(
      child: CustomScrollView(
        physics: BouncingScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildHeader(),
                SizedBox(height: 30),
                _eyebrow(_todayLabel()),
                SizedBox(height: 8),
                Text(
                  'Good evening',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.8,
                      ),
                ),
                SizedBox(height: 6),
                Text(
                  _isTracking
                      ? 'Luma is quietly listening in the background.'
                      : 'Let’s make tonight your best rest yet.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.muted,
                        height: 1.4,
                      ),
                ),
                SizedBox(height: 22),
                _buildTrackingCard(),
                SizedBox(height: 26),
                _sectionHeading('Last night', 'View report', () {
                  _onTabChanged(AppTab.insights.index);
                }),
                SizedBox(height: 12),
                _buildLastNightCard(),
                SizedBox(height: 26),
                _sectionHeading('Sound monitor', 'How it works', () {
                  _showSoundInfo();
                }),
                SizedBox(height: 12),
                _buildSoundMonitorCard(),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.lavender.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.lavender.withValues(alpha: .16)),
          ),
          child: Icon(Icons.nightlight_round, color: AppColors.lavenderBright, size: 22),
        ),
        SizedBox(width: 11),
        Text(
          'luma',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -.7,
              ),
        ),
        Spacer(),
      ],
    );
  }

  Widget _buildTrackingCard() {
    return Container(
      padding: EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF22264A), Color(0xFF151A32)],
        ),
        border: Border.all(color: AppColors.lavender.withValues(alpha: .22)),
        boxShadow: [
          BoxShadow(color: AppColors.lavender.withValues(alpha: .09), blurRadius: 34, offset: Offset(0, 14)),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -28,
            top: -34,
            child: Container(
              width: 145,
              height: 145,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.lavender.withValues(alpha: .09), width: 22),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _statusDot(_isTracking ? AppColors.mint : AppColors.lavender),
                  SizedBox(width: 8),
                  Text(
                    _isTracking
                        ? 'TRACKING YOUR SLEEP'
                        : _stopCleanupInFlight
                            ? 'FINISHING RECORDING'
                            : 'READY FOR TONIGHT',
                    style: TextStyle(
                      color: AppColors.lavenderBright,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.25,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 22),
              Text(
                _isTracking ? _formatElapsed(_elapsed) : '—',
                style: TextStyle(
                  fontSize: 42,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.5,
                ),
              ),
              SizedBox(height: 8),
              Text(
                _isTracking
                    ? 'listening since ${_formatStartTime()}'
                    : _stopCleanupInFlight
                        ? 'saving the recording'
                        : 'no session recorded yet',
                style: TextStyle(color: AppColors.muted, fontSize: 14),
              ),
              SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: _isTracking
                        ? OutlinedButton.icon(
                            onPressed: _stopTracking,
                            icon: Icon(Icons.stop_rounded, size: 18),
                            label: Text('End session'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.coral,
                              side: BorderSide(color: AppColors.coral.withValues(alpha: .55)),
                              padding: EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                            ),
                          )
                        : FilledButton.icon(
                            onPressed: _isStarting || _isStopping || _stopCleanupInFlight ? null : _startTracking,
                            icon: _isStarting || _isStopping
                                ? SizedBox(
                                    height: 17,
                                    width: 17,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.background),
                                  )
                                : Icon(Icons.play_arrow_rounded, size: 20),
                            label: Text(
                              _isStarting
                                  ? 'Starting…'
                                  : _isStopping
                                      ? 'Stopping…'
                                      : 'Start sleep tracking',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.mint,
                              foregroundColor: AppColors.background,
                              disabledBackgroundColor: AppColors.mint.withValues(alpha: .7),
                              padding: EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                              textStyle: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatStartTime() {
    if (_sessionStarted == null) return '--:--';
    final hour = _sessionStarted!.hour;
    final minute = _sessionStarted!.minute.toString().padLeft(2, '0');
    final suffix = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour % 12 == 0 ? 12 : hour % 12;
    return '$displayHour:$minute $suffix';
  }

  String _todayLabel() {
    final weekdays = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
    final months = ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'];
    final now = DateTime.now();
    return '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}';
  }

  String _sessionDate(DateTime value) {
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return '${weekdays[value.weekday - 1]} night';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours == 0) return '${minutes}m';
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  }

  Widget _loadingCard() {
    return Container(
      height: 104,
      decoration: _cardDecoration(),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.lavender)),
    );
  }

  Widget _emptyCard({required IconData icon, required String title, required String subtitle, required Color color}) {
    return Container(
      padding: EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: color.withValues(alpha: .11), borderRadius: BorderRadius.circular(15)),
            child: Icon(icon, color: color),
          ),
          SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                SizedBox(height: 5),
                Text(subtitle, style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLastNightCard() {
    if (_isLoadingData) return _loadingCard();
    if (_sessions.isEmpty) {
      return _emptyCard(
        icon: Icons.bedtime_rounded,
        title: 'No sleep nights yet',
        subtitle: 'Start a session tonight and your first report will appear here.',
        color: AppColors.mint,
      );
    }

    final session = _sessions.first;
    final score = math.min(100, (session.duration.inMinutes / 480 * 100).round());
    return Container(
      padding: EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: AppColors.mint.withValues(alpha: .11), borderRadius: BorderRadius.circular(15)),
                child: Icon(Icons.bedtime_rounded, color: AppColors.mint),
              ),
              SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_sessionDate(session.startedAt), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    SizedBox(height: 4),
                    Text('${_eventTime(session.startedAt)} – ${_eventTime(session.endedAt)}', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  ],
                ),
              ),
              _scoreRing('$score', AppColors.mint, progress: score / 100),
            ],
          ),
          SizedBox(height: 18),
          Container(height: 1, color: AppColors.border),
          SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _InlineMetric(label: 'Time tracked', value: _formatDuration(session.duration), icon: Icons.schedule_rounded),
              _InlineMetric(label: 'Sound events', value: '${_events.length}', icon: Icons.graphic_eq_rounded),
              _InlineMetric(label: 'Status', value: 'Saved', icon: Icons.check_circle_outline_rounded),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSoundMonitorCard() {
    final event = _events.isNotEmpty ? _events.first : null;
    return Container(
      padding: EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.lavender.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(Icons.graphic_eq_rounded, color: AppColors.lavenderBright),
              ),
              SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sound detection', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    SizedBox(height: 4),
                    Text('Luma listens for snoring and room noise', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  ],
                ),
              ),
              Switch.adaptive(
                value: _soundMonitorEnabled,
                onChanged: _setSoundMonitorEnabled,
                activeColor: AppColors.mint,
              ),
            ],
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(
                  event?.isSnore == true ? Icons.air_rounded : Icons.multitrack_audio_rounded,
                  size: 18,
                  color: event == null ? AppColors.muted : AppColors.amber,
                ),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    event == null ? 'No sound events recorded yet' : 'Latest · ${event.kind.toLowerCase()}',
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ),
                Text(
                  event == null ? '--' : '${event.decibels.round()} dB',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsights() {
    return SafeArea(
      child: CustomScrollView(
        physics: BouncingScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildPageHeader('Insights', 'The little patterns add up.'),
                SizedBox(height: 26),
                _buildInsightScoreCard(),
                SizedBox(height: 24),
                _sectionTitle('Sleep cycles'),
                SizedBox(height: 12),
                _buildSleepCycleChart(),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsightScoreCard() {
    if (_isLoadingData) return _loadingCard();
    if (_sessions.isEmpty) {
      return _emptyCard(
        icon: Icons.insights_rounded,
        title: 'No sleep score yet',
        subtitle: 'Complete a sleep session to get a score based on your own duration and sound data.',
        color: AppColors.mint,
      );
    }

    final session = _sessions.first;
    final score = math.min(100, (session.duration.inMinutes / 480 * 100).round());
    return Container(
      padding: EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF212747), Color(0xFF151A2D)],
        ),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 112,
            height: 112,
            child: CustomPaint(
              painter: _ScorePainter(progress: score / 100, color: AppColors.mint),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$score', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, height: 1)),
                    SizedBox(height: 4),
                    Text('SCORE', style: TextStyle(color: AppColors.muted, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1)),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your first report', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                SizedBox(height: 7),
                Text('${_formatDuration(session.duration)} tracked on ${_sessionDate(session.startedAt)}.', style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45)),
                SizedBox(height: 13),
                Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, color: AppColors.mint, size: 17),
                    SizedBox(width: 5),
                    Text('Stored on this device', style: TextStyle(color: AppColors.mint, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSleepCycleChart() {
    if (_isLoadingData) return _loadingCard();
    if (_sessions.isEmpty) {
      return _emptyCard(
        icon: Icons.bar_chart_rounded,
        title: 'Sleep cycle graph will appear here',
        subtitle: 'Complete a session to see an estimate based on 90-minute blocks of tracked time.',
        color: AppColors.blue,
      );
    }

    final chartSessions = _sessions.take(7).toList().reversed.toList();
    var maxCycles = 1;
    for (final session in chartSessions) {
      final cycles = _estimatedCycleCount(session);
      if (cycles > maxCycles) maxCycles = cycles;
    }

    return Container(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 15),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Estimated sleep cycles', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.blue.withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('90 MIN BLOCKS', style: TextStyle(color: AppColors.blue, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: .6)),
              ),
            ],
          ),
          SizedBox(height: 5),
          Text(
            'A duration-based estimate, not REM, light, or deep-stage detection.',
            style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.35),
          ),
          SizedBox(height: 18),
          SizedBox(
            height: 164,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: chartSessions.map((session) {
                final cycles = _estimatedCycleCount(session);
                final ratio = math.max(.08, cycles / maxCycles).toDouble();
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Column(
                      children: [
                        Text(
                          '$cycles',
                          style: TextStyle(color: AppColors.lavenderBright, fontSize: 11, fontWeight: FontWeight.w800),
                        ),
                        SizedBox(height: 7),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              widthFactor: .56,
                              heightFactor: ratio,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [AppColors.blue, AppColors.lavender.withValues(alpha: .62)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: 7),
                        Container(height: 1, color: AppColors.border),
                        SizedBox(height: 7),
                        Text(
                          _shortSessionDate(session.startedAt),
                          style: TextStyle(color: AppColors.muted, fontSize: 10, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: AppColors.blue, shape: BoxShape.circle)),
              SizedBox(width: 7),
              Text(
                '${chartSessions.length} ${chartSessions.length == 1 ? 'night' : 'nights'} recorded',
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              Spacer(),
              Text(
                'Up to $maxCycles cycles',
                style: TextStyle(color: AppColors.lavenderBright, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _estimatedCycleCount(SleepSession session) {
    final cycles = (session.duration.inMinutes / 90).round();
    return cycles < 1 ? 1 : cycles;
  }

  String _shortSessionDate(DateTime value) {
    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[value.weekday - 1];
  }

  Future<void> _toggleAudioPlayback(SleepSession session) async {
    final path = session.audioPath;
    if (path == null || path.isEmpty) {
      _showSnack('This session does not have a saved audio file.');
      return;
    }

    final file = File(path);
    if (!await file.exists()) {
      _showSnack('This recording is no longer available on the device.');
      return;
    }

    try {
      if (_playingAudioPath == path) {
        if (_audioPlayer.playing) {
          await _audioPlayer.pause();
        } else {
          if (_audioPlayer.processingState == ProcessingState.completed) {
            await _audioPlayer.seek(Duration.zero);
          }
          unawaited(_playLoadedAudio());
        }
        return;
      }

      if (mounted) setState(() {
        _playingAudioPath = path;
        _isLoadingAudio = true;
      });
      await _audioPlayer.setFilePath(path);
      if (mounted) setState(() => _isLoadingAudio = false);
      unawaited(_playLoadedAudio());
    } catch (_) {
      if (mounted) {
        setState(() {
          _playingAudioPath = null;
          _isLoadingAudio = false;
        });
      }
      _showSnack('Could not play this recording.');
      return;
    }

    if (mounted) setState(() => _isLoadingAudio = false);
  }

  Future<void> _playLoadedAudio() async {
    try {
      await _audioPlayer.play();
    } catch (_) {
      if (mounted) {
        setState(() {
          _playingAudioPath = null;
          _isLoadingAudio = false;
        });
        _showSnack('Playback could not start.');
      }
    }
  }

  Widget _buildPlaybackButton(SleepSession session) {
    final path = session.audioPath;
    return StreamBuilder<PlayerState>(
      stream: _audioPlayer.playerStateStream,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final isCurrent = path != null && path == _playingAudioPath;
        final isLoading = isCurrent &&
            (_isLoadingAudio ||
                state?.processingState == ProcessingState.loading ||
                state?.processingState == ProcessingState.buffering);
        final isPlaying = isCurrent && state?.playing == true;

        return IconButton(
          tooltip: path == null
              ? 'No audio file saved'
              : isPlaying
                  ? 'Pause recording'
                  : 'Play recording',
          onPressed: path == null ? null : () => _toggleAudioPlayback(session),
          icon: isLoading
              ? SizedBox(
                  width: 19,
                  height: 19,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.lavenderBright),
                )
              : Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: path == null ? AppColors.border : AppColors.lavenderBright,
                ),
        );
      },
    );
  }

  Widget _buildSavedRecordings() {
    if (_isLoadingData) return _loadingCard();
    if (_sessions.isEmpty) {
      return _emptyCard(
        icon: Icons.mic_none_rounded,
        title: 'No recordings yet',
        subtitle: 'Complete a sleep session to play its private audio recording here.',
        color: AppColors.blue,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('SAVED RECORDINGS', style: TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
            ),
            Text('${_sessions.length} sessions', style: TextStyle(color: AppColors.lavenderBright, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
        SizedBox(height: 12),
        ..._sessions.take(8).map(_buildRecordingTile),
      ],
    );
  }

  Widget _buildRecordingTile(SleepSession session) {
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.fromLTRB(15, 13, 8, 13),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.blue.withValues(alpha: .11),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.mic_rounded, color: AppColors.blue, size: 21),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_sessionDate(session.startedAt), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                Text(
                  '${_eventTime(session.startedAt)} – ${_eventTime(session.endedAt)}  ·  ${_formatDuration(session.duration)}',
                  style: TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          _buildPlaybackButton(session),
        ],
      ),
    );
  }

  Widget _buildRecordings() {
    return SafeArea(
      child: CustomScrollView(
        physics: BouncingScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildPageHeader('Sound log', 'A gentle record of the night.'),
                SizedBox(height: 24),
                _buildStorageBanner(),
                SizedBox(height: 24),
                _buildSavedRecordings(),
                SizedBox(height: 24),
                if (!_isLoadingData && _events.isEmpty)
                  _emptyCard(
                    icon: Icons.graphic_eq_rounded,
                    title: 'No sound events yet',
                    subtitle: 'When Luma hears a sound above your threshold, it will appear here.',
                    color: AppColors.lavenderBright,
                  )
                else if (!_isLoadingData) ...[
                  Row(
                    children: [
                      Expanded(child: Text('RECENT EVENTS', style: TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.1))),
                      Text('${_events.length} events', style: TextStyle(color: AppColors.lavenderBright, fontSize: 12, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  SizedBox(height: 12),
                  ..._events.take(8).map(_buildEventCard),
                  SizedBox(height: 10),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => _showSnack('Your recordings stay on this device only.'),
                      icon: Icon(Icons.lock_outline_rounded, size: 15),
                      label: Text('Your recordings are private'),
                      style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageBanner() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.mint.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.mint.withValues(alpha: .16)),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, color: AppColors.mint, size: 22),
          SizedBox(width: 11),
          Expanded(
            child: Text('Audio and sound markers stay on this device. You can delete everything from Settings.', style: TextStyle(color: AppColors.mint, fontSize: 12, height: 1.4)),
          ),
          IconButton(
            onPressed: () => _showSoundInfo(),
            icon: Icon(Icons.info_outline_rounded, color: AppColors.mint, size: 19),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildEventCard(SleepEvent event) {
    final time = _eventTime(event.time);
    final color = event.isSnore ? AppColors.amber : AppColors.blue;
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.fromLTRB(15, 15, 13, 15),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 43,
            decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(14)),
            child: Icon(event.isSnore ? Icons.air_rounded : Icons.multitrack_audio_rounded, color: color, size: 21),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(event.kind, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
                    SizedBox(width: 7),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(5)),
                      child: Text('${event.decibels.round()} dB', style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
                SizedBox(height: 5),
                Text('$time  ·  ${event.detail}', style: TextStyle(color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          SizedBox(width: 8),
        ],
      ),
    );
  }

  String _eventTime(DateTime date) {
    final hour = date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final suffix = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour % 12 == 0 ? 12 : hour % 12;
    return '$displayHour:$minute $suffix';
  }

  Widget _buildSettings() {
    return SafeArea(
      child: CustomScrollView(
        physics: BouncingScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildPageHeader('Settings', 'Make Luma feel like yours.'),
                SizedBox(height: 26),
                _settingsGroupLabel('NIGHT MONITOR'),
                SizedBox(height: 9),
                _settingsCard([
                  _settingRow(
                    icon: Icons.graphic_eq_rounded,
                    color: AppColors.lavenderBright,
                    title: 'Sound detection',
                    subtitle: 'Snoring and ambient sound',
                    trailing: Switch.adaptive(
                      value: _soundMonitorEnabled,
                      onChanged: _setSoundMonitorEnabled,
                      activeColor: AppColors.mint,
                    ),
                  ),
                  _divider(),
                  _settingRow(
                    icon: Icons.picture_in_picture_alt_rounded,
                    color: AppColors.blue,
                    title: 'Floating sleep control',
                    subtitle: _overlayVisible ? 'Visible over other apps' : 'Android overlay while tracking',
                    trailing: Switch.adaptive(
                      value: _overlayEnabled,
                      onChanged: (value) {
                        setState(() => _overlayEnabled = value);
                        if (value && _isTracking) _showSleepOverlayIfEnabled();
                        if (!value) _hideSleepOverlay();
                      },
                      activeColor: AppColors.mint,
                    ),
                  ),
                  _divider(),
                  _settingRow(
                    icon: Icons.speed_rounded,
                    color: AppColors.amber,
                    title: 'Detection sensitivity',
                    subtitle: ['Quiet', 'Balanced', 'Sensitive'][_sensitivity - 1],
                    trailing: Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    onTap: _chooseSensitivity,
                  ),
                  _divider(),
                  _settingRow(
                    icon: widget.lightMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                    color: AppColors.lavenderBright,
                    title: 'Light theme',
                    subtitle: widget.lightMode ? 'Light text and surfaces' : 'Dark text and surfaces',
                    trailing: Switch.adaptive(
                      value: widget.lightMode,
                      onChanged: widget.onLightModeChanged,
                      activeColor: AppColors.mint,
                    ),
                  ),
                ]),
                SizedBox(height: 25),
                _settingsGroupLabel('BACKGROUND LIMITS'),
                SizedBox(height: 9),
                _settingsCard([
                  _settingRow(
                    icon: Icons.lock_outline_rounded,
                    color: AppColors.blue,
                    title: 'Screen off & locked',
                    subtitle: !_isTracking
                        ? 'Supported during an active session'
                        : _usingForegroundService
                            ? 'Foreground service is active'
                            : 'App-only fallback; keep Luma open',
                    trailing: Icon(
                      _isTracking && !_usingForegroundService
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline_rounded,
                      color: _isTracking && !_usingForegroundService ? AppColors.amber : AppColors.mint,
                    ),
                  ),
                  _divider(),
                  _settingRow(
                    icon: Icons.power_settings_new_rounded,
                    color: AppColors.coral,
                    title: 'Phone powered off',
                    subtitle: 'Cannot record while the device is powered off',
                    trailing: SizedBox.shrink(),
                  ),
                ]),
                SizedBox(height: 25),
                _settingsGroupLabel('YOUR DATA'),
                SizedBox(height: 9),
                _settingsCard([
                  _settingRow(
                    icon: Icons.lock_outline_rounded,
                    color: AppColors.mint,
                    title: 'Privacy & storage',
                    subtitle: 'Everything stays on your device',
                    trailing: Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    onTap: _showSoundInfo,
                  ),
                  _divider(),
                  _settingRow(
                    icon: Icons.delete_outline_rounded,
                    color: AppColors.coral,
                    title: 'Clear all sleep data',
                    subtitle: 'Delete recordings, sessions, and events',
                    trailing: Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    onTap: _confirmClearAllData,
                  ),
                ]),
                SizedBox(height: 25),
                _settingsGroupLabel('ABOUT LUMA'),
                SizedBox(height: 9),
                _settingsCard([
                  _settingRow(
                    icon: Icons.favorite_border_rounded,
                    color: AppColors.coral,
                    title: 'How Luma works',
                    subtitle: 'Sound detection, explained',
                    trailing: Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    onTap: _showSoundInfo,
                  ),
                  _divider(),
                  _settingRow(
                    icon: Icons.info_outline_rounded,
                    color: AppColors.muted,
                    title: 'Luma Sleep',
                    subtitle: 'Version 1.0.0',
                    trailing: SizedBox.shrink(),
                  ),
                ]),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsGroupLabel(String text) {
    return Text(text, style: TextStyle(color: AppColors.muted, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.3));
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      decoration: _cardDecoration(),
      child: Column(children: children),
    );
  }

  Widget _settingRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required Widget trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 37,
              height: 37,
              decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(11)),
              child: Icon(icon, color: color, size: 18),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  SizedBox(height: 4),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: AppColors.muted)),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _buildPageHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: AppColors.lavender.withValues(alpha: .14), borderRadius: BorderRadius.circular(13)),
              child: Icon(Icons.nightlight_round, color: AppColors.lavenderBright, size: 20),
            ),
            SizedBox(width: 11),
            Text('luma', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -.7)),
            Spacer(),
            _roundIconButton(Icons.notifications_none_rounded, () => _showSnack('You’re all caught up.')),
          ],
        ),
        SizedBox(height: 31),
        Text(title, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -.9)),
        SizedBox(height: 6),
        Text(subtitle, style: TextStyle(color: AppColors.muted, fontSize: 14)),
      ],
    );
  }

  Widget _sectionTitle(String title) {
    return Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800));
  }

  Widget _sectionHeading(String title, String action, VoidCallback onTap) {
    return Row(
      children: [
        Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        Spacer(),
        GestureDetector(
          onTap: onTap,
          child: Text(action, style: TextStyle(color: AppColors.lavenderBright, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _eyebrow(String text) {
    return Text(text, style: TextStyle(color: AppColors.lavenderBright, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.4));
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: AppColors.border),
    );
  }

  Widget _statusDot(Color color) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: color.withValues(alpha: .75), blurRadius: 7)]),
    );
  }

  Widget _roundIconButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(width: 46, height: 46, child: Icon(icon, color: AppColors.ink, size: 20)),
      ),
    );
  }

  Widget _scoreRing(String score, Color color, {required double progress}) {
    return SizedBox(
      width: 49,
      height: 49,
      child: CustomPaint(
        painter: _ScorePainter(progress: progress, color: color, strokeWidth: 4),
        child: Center(child: Text(score, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13))),
      ),
    );
  }

  Widget _divider() => Container(height: 1, color: AppColors.border, margin: EdgeInsets.only(left: 64));

  void _showSoundInfo() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(22, 0, 22, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(width: 42, height: 42, decoration: BoxDecoration(color: AppColors.mint.withValues(alpha: .12), borderRadius: BorderRadius.circular(14)), child: Icon(Icons.shield_outlined, color: AppColors.mint)),
                  SizedBox(width: 12),
                  Text('Quietly private', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ],
              ),
              SizedBox(height: 16),
              Text('Luma checks the volume of nearby sound while you sleep. When a pattern rises above your chosen threshold, it saves a short event marker so you can review it in the morning.', style: TextStyle(color: AppColors.muted, height: 1.5, fontSize: 13)),
              SizedBox(height: 12),
              Text('No audio is uploaded, transcribed, or shared. This simple detector can suggest a possible snore, but it is not a medical diagnosis.', style: TextStyle(color: AppColors.muted, height: 1.5, fontSize: 13)),
              SizedBox(height: 19),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(context), child: Text('Got it')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _chooseSensitivity() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Detection sensitivity', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                SizedBox(height: 7),
                Text('Choose how quiet a sound can be before Luma saves it.', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                SizedBox(height: 12),
                ...['Quiet', 'Balanced', 'Sensitive'].asMap().entries.map((entry) {
                  final value = entry.key + 1;
                  return RadioListTile<int>(
                    value: value,
                    groupValue: _sensitivity,
                    onChanged: (newValue) {
                      if (newValue == null) return;
                      _setSensitivity(newValue);
                      setModalState(() {});
                    },
                    title: Text(entry.value),
                    subtitle: Text(['Only louder sounds', 'A good balance', 'Catches softer sounds'][entry.key]),
                    activeColor: AppColors.lavender,
                    contentPadding: EdgeInsets.zero,
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmClearAllData() {
    if (_isTracking) {
      _showSnack('End the current sleep session before clearing data.');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Clear all sleep data?'),
        content: Text('This permanently deletes saved recordings, sleep sessions, sound events, and reports from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _storage.clearAllData();
                try {
                  await FlutterForegroundTask.removeData(key: 'sensitivity');
                  await FlutterForegroundTask.removeData(key: 'monitorEnabled');
                } catch (_) {}
                if (!mounted) return;
                setState(() {
                  _events.clear();
                  _sessions.clear();
                });
                _showSnack('All sleep data has been deleted.');
              } catch (_) {
                if (mounted) _showSnack('Could not clear all data. Please try again.');
              }
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral, foregroundColor: AppColors.background),
            child: Text('Delete everything'),
          ),
        ],
      ),
    );
  }
}

class _SleepOverlayApp extends StatelessWidget {
  _SleepOverlayApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.dark(
          primary: AppColors.lavender,
          secondary: AppColors.mint,
          surface: AppColors.surface,
        ),
      ),
      home: _SleepOverlayPanel(),
    );
  }
}

class _SleepOverlayPanel extends StatefulWidget {
  _SleepOverlayPanel();

  @override
  State<_SleepOverlayPanel> createState() => _SleepOverlayPanelState();
}

class _SleepOverlayPanelState extends State<_SleepOverlayPanel> {
  StreamSubscription<dynamic>? _messages;
  String _elapsed = 'Listening';

  @override
  void initState() {
    super.initState();
    _messages = FlutterOverlayWindow.overlayListener.listen((message) {
      if (!mounted || message is! String || !message.startsWith('elapsed:')) return;
      setState(() => _elapsed = message.substring('elapsed:'.length));
    });
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Container(
            margin: EdgeInsets.only(top: 8, right: 8),
            padding: EdgeInsets.fromLTRB(14, 11, 9, 11),
            decoration: BoxDecoration(
              color: Color(0xFF171D31),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.lavender.withValues(alpha: .45)),
              boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 5))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: AppColors.mint,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: AppColors.mint.withValues(alpha: .7), blurRadius: 8)],
                  ),
                ),
                SizedBox(width: 9),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('SLEEP TRACKING', style: TextStyle(color: AppColors.lavenderBright, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: .8)),
                    SizedBox(height: 3),
                    Text('Luma is listening', style: TextStyle(color: AppColors.ink, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
                SizedBox(width: 12),
                Text(_elapsed, style: TextStyle(color: AppColors.mint, fontSize: 11, fontWeight: FontWeight.w800)),
                SizedBox(width: 8),
                Material(
                  color: AppColors.coral.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(13),
                  child: InkWell(
                    onTap: () {
                      FlutterOverlayWindow.shareData('stop_tracking');
                    },
                    borderRadius: BorderRadius.circular(13),
                    child: Padding(
                      padding: EdgeInsets.all(9),
                      child: Icon(Icons.stop_rounded, color: AppColors.coral, size: 17),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineMetric extends StatelessWidget {
  _InlineMetric({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.muted, size: 15),
        SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            SizedBox(height: 3),
            Text(label, style: TextStyle(color: AppColors.muted, fontSize: 9)),
          ],
        ),
      ],
    );
  }
}

class _ScorePainter extends CustomPainter {
  _ScorePainter({required this.progress, required this.color, this.strokeWidth = 6});

  final double progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - strokeWidth / 2;
    final background = Paint()
      ..color = AppColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final foreground = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, background);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, math.pi * 2 * progress, false, foreground);
  }

  @override
  bool shouldRepaint(covariant _ScorePainter oldDelegate) => oldDelegate.progress != progress || oldDelegate.color != color;
}
