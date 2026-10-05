# Arena
# Arena
# Luma Sleep

A calm, privacy-first Flutter sleep tracker that records an overnight audio session locally, watches microphone amplitude for sound events, and presents a morning-friendly sleep report.

## What is included

- **Tonight dashboard** with start/stop sleep tracking, last-night summary, and a seven-day rhythm view.
- **Local sound monitoring** using the [`record`](https://pub.dev/packages/record) plugin. The app saves a local audio session and adds event markers when amplitude rises above the selected threshold.
- **Android background recording** using [`flutter_foreground_task`](https://pub.dev/packages/flutter_foreground_task). The recorder and amplitude detector run in a microphone foreground service so the session can continue with the display locked.
- **Floating sleep control** using [`flutter_overlay_window`](https://pub.dev/packages/flutter_overlay_window) on Android. While a session is active, a draggable pill can stay visible over other apps and stop the session.
- **Insights** for sleep score, stage breakdown, efficiency, consistency, and weekly trends.
- **Sound log** with possible snore / sound detected markers and decibel estimates.
- **Settings** for microphone monitoring, sensitivity, screen-awake preference, privacy information, and clearing the sound log.
- Audio is never uploaded. The detector labels a **possible snore** based on a simple volume heuristic and is not a medical diagnosis.

## Run it

This repository contains the Flutter application layer. It uses `flutter_foreground_task ^9.1.0`, so use Flutter 3.22+ / Dart 3.4+.

With Flutter installed:

```bash
flutter create .
flutter pub get
flutter run
```

`flutter create .` fills in the standard Android and iOS runner projects without replacing `lib/main.dart` or `pubspec.yaml`.

For Android, make sure the generated app has these permissions in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
```

Add both services inside `<application>`:

```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:exported="false"
    android:foregroundServiceType="microphone" />

<service
    android:name="flutter.overlay.window.flutter_overlay_window.OverlayService"
    android:exported="false"
    android:foregroundServiceType="specialUse">
    <property
        android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
        android:value="sleep_tracking_floating_control" />
</service>
```

The first time tracking starts on Android, Luma requests notification and battery-optimization permissions, then opens the system “display over other apps” permission screen for the optional floating control. The foreground service notification remains visible while recording, as required by Android. The floating control can be disabled in Settings.

For iOS, add a microphone usage string and background audio mode to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Luma listens for sleep sounds while you rest.</string>
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

## Screen-off and power-off behavior

- **Android screen locked or display off:** The microphone recorder runs inside the configured foreground service and can continue while the phone is awake, subject to Android battery policy and user permissions. The overlay itself is hidden by the lock screen.
- **iOS screen locked or display off:** The `audio` background mode allows an active recording session to continue, but iOS may interrupt or stop background work and does not provide Android-style always-on guarantees.
- **Phone fully powered off:** No mobile app can continue recording when the device is shut down. The phone must remain powered on; for reliable overnight monitoring, keep it charging and allow microphone, notification, overlay, and battery permissions.

The app uses Material 3 and does not require image assets or a network connection. The current detector labels a possible snore using an amplitude/volume heuristic; a production version could replace that classifier with an on-device audio model.
