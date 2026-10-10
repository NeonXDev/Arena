# Luma Sleep for Android

A privacy-first Flutter sleep and sound tracker for Android. Luma records a local overnight audio session, detects loud sound events, and keeps a small local index of sessions and possible snores.

## Features

- Clean first-run dashboard with no seeded or fake sleep data.
- Local microphone recording with `record`.
- In-app playback of saved session recordings with `just_audio`.
- Volume-based possible-snore and sound-event markers.
- Android foreground microphone service so recording can continue with the screen locked.
- Draggable Android floating sleep control using `flutter_overlay_window`.
- Local persistence for sessions and sound events using `SharedPreferencesAsync`.
- Clear-all-data action that deletes the local index and Luma `.m4a` recordings.
- Insights with a duration-based estimated sleep-cycle bar graph.
- Light and dark appearance setting saved on the device.
- Honest empty states until the user has real data.

The detector is a volume heuristic, not a medical device or diagnosis. Audio is not uploaded.

## Current toolchain and dependencies

- Flutter `>=3.44.0`
- Dart `>=3.12.0`
- `record: ^7.1.1`
- `flutter_foreground_task: ^11.0.3`
- `flutter_overlay_window: ^0.5.0`
- `just_audio: ^0.10.6`
- `path_provider: ^2.1.6`
- `shared_preferences: ^2.5.6`

## Setup

This first version targets Android only. Generate the Android runner and apply the required Android configuration:

```bash
flutter create --platforms=android .
./tool/bootstrap_platforms.sh
flutter pub get
flutter run
```

The bootstrap script is idempotent. It adds:

- `RECORD_AUDIO`
- `POST_NOTIFICATIONS`
- `SYSTEM_ALERT_WINDOW`
- Android foreground-service permissions
- Microphone foreground service declaration
- Overlay service declaration
- Android minimum SDK 23

### Runtime permissions

On the first session, Android may request:

1. Microphone access
2. Notification access for the foreground-service notification
3. Battery-optimization exemption for reliable overnight recording
4. “Display over other apps” access when the optional floating control is enabled

If the overlay is not needed, leave **Floating sleep control** disabled in Settings. Tracking still works with the Android foreground service.

## Data storage

Audio is stored in the app-private support directory as files named `luma_sleep_<timestamp>.m4a`. Session metadata and sound-event markers are stored locally with `shared_preferences`. Nothing is sent to a server. **Settings → Your Data → Clear all sleep data** removes metadata and matching local recordings.

## Validation

The repository includes widget/model tests and a GitHub Actions workflow that runs:

- `flutter analyze`
- `flutter test`
- Android debug APK build

Microphone, screen-lock, battery, and overlay behavior must still be verified on a physical Android device.
