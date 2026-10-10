class SleepEvent {
  const SleepEvent({
    required this.time,
    required this.kind,
    required this.detail,
    required this.decibels,
    required this.isSnore,
  });

  final DateTime time;
  final String kind;
  final String detail;
  final double decibels;
  final bool isSnore;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'time': time.millisecondsSinceEpoch,
        'kind': kind,
        'detail': detail,
        'decibels': decibels,
        'isSnore': isSnore,
      };

  factory SleepEvent.fromJson(Map<String, dynamic> json) {
    return SleepEvent(
      time: DateTime.fromMillisecondsSinceEpoch(json['time'] as int),
      kind: json['kind'] as String? ?? 'Sound detected',
      detail: json['detail'] as String? ?? 'Ambient sound',
      decibels: (json['decibels'] as num?)?.toDouble() ?? 0,
      isSnore: json['isSnore'] as bool? ?? false,
    );
  }
}

class SleepSession {
  const SleepSession({
    required this.startedAt,
    required this.endedAt,
    this.audioPath,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final String? audioPath;

  Duration get duration => endedAt.difference(startedAt);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'startedAt': startedAt.millisecondsSinceEpoch,
        'endedAt': endedAt.millisecondsSinceEpoch,
        'audioPath': audioPath,
      };

  factory SleepSession.fromJson(Map<String, dynamic> json) {
    return SleepSession(
      startedAt: DateTime.fromMillisecondsSinceEpoch(json['startedAt'] as int),
      endedAt: DateTime.fromMillisecondsSinceEpoch(json['endedAt'] as int),
      audioPath: json['audioPath'] as String?,
    );
  }
}
