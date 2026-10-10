import 'package:flutter_test/flutter_test.dart';

import 'package:luma_sleep/sleep_models.dart';

void main() {
  test('sleep event round trips through JSON', () {
    final event = SleepEvent(
      time: DateTime(2026, 10, 6, 1, 20),
      kind: 'Possible snore',
      detail: 'Volume pattern detected',
      decibels: 43.5,
      isSnore: true,
    );

    final restored = SleepEvent.fromJson(event.toJson());

    expect(restored.time, event.time);
    expect(restored.kind, event.kind);
    expect(restored.decibels, event.decibels);
    expect(restored.isSnore, isTrue);
  });

  test('sleep session exposes tracked duration', () {
    final session = SleepSession(
      startedAt: DateTime(2026, 10, 6, 22),
      endedAt: DateTime(2026, 10, 7, 6, 30),
    );

    expect(session.duration, const Duration(hours: 8, minutes: 30));
  });
}
