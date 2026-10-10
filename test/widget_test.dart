import 'package:flutter_test/flutter_test.dart';

import 'package:luma_sleep/main.dart';

void main() {
  testWidgets('shows the tonight dashboard', (tester) async {
    await tester.pumpWidget(const LumaSleepApp());

    expect(find.text('Good evening'), findsOneWidget);
    expect(find.text('Start sleep tracking'), findsOneWidget);
    expect(find.text('Sound monitor'), findsOneWidget);
  });
}
