#!/usr/bin/env bash
set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is required. Install Flutter 3.44+ and run this script again." >&2
  exit 1
fi

# This first release targets Android only. It does not generate an iOS runner.
if [[ ! -d android ]]; then
  flutter create --platforms=android --project-name=luma_sleep .
fi

python3 - <<'PY'
from pathlib import Path
import re

manifest_path = Path('android/app/src/main/AndroidManifest.xml')
if not manifest_path.exists():
    raise SystemExit('android/app/src/main/AndroidManifest.xml was not generated')

text = manifest_path.read_text()
permissions = [
    'android.permission.RECORD_AUDIO',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.SYSTEM_ALERT_WINDOW',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MICROPHONE',
    'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
    'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
    'android.permission.WAKE_LOCK',
]
permission_xml = ''.join(
    f'    <uses-permission android:name="{permission}" />\n'
    for permission in permissions
    if f'android:name="{permission}"' not in text
)
if permission_xml:
    application_index = text.find('<application')
    if application_index == -1:
        raise SystemExit('Could not find <application> in AndroidManifest.xml')
    text = text[:application_index] + permission_xml + '\n' + text[application_index:]

services = '''
    <service
        android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
        android:exported="false"
        android:stopWithTask="false"
        android:foregroundServiceType="microphone" />

    <service
        android:name="flutter.overlay.window.flutter_overlay_window.OverlayService"
        android:exported="false"
        android:foregroundServiceType="specialUse">
        <property
            android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
            android:value="sleep_tracking_floating_control" />
    </service>
'''
foreground_service_name = 'com.pravera.flutter_foreground_task.service.ForegroundService'
if foreground_service_name in text:
    service_name_index = text.find(f'android:name="{foreground_service_name}"')
    service_start = text.rfind('<service', 0, service_name_index)
    service_end = text.find('>', service_name_index)
    service_block = text[service_start:service_end]
    if 'android:stopWithTask=' in service_block:
        service_block = re.sub(
            r'android:stopWithTask="[^"]+"',
            'android:stopWithTask="false"',
            service_block,
        )
    else:
        service_block = service_block.replace(
            'android:exported="false"',
            'android:exported="false"\n        android:stopWithTask="false"',
        )
    text = text[:service_start] + service_block + text[service_end:]

if foreground_service_name not in text:
    closing = text.rfind('</application>')
    if closing == -1:
        raise SystemExit('Could not find </application> in AndroidManifest.xml')
    text = text[:closing] + services + text[closing:]
manifest_path.write_text(text)

for gradle_path in [Path('android/app/build.gradle'), Path('android/app/build.gradle.kts')]:
    if not gradle_path.exists():
        continue
    text = gradle_path.read_text()
    text = text.replace('minSdk = flutter.minSdkVersion', 'minSdk = 23')
    text = text.replace('minSdkVersion flutter.minSdkVersion', 'minSdkVersion 23')
    gradle_path.write_text(text)
PY

echo "Android runner and permissions configured. Run: flutter pub get && flutter run"
