import 'package:flutter_test/flutter_test.dart';

import 'package:amber_vitals/main.dart';

void main() {
  testWidgets('App boots and shows the home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const AmberVitalsApp());
    await tester.pumpAndSettle();

    expect(find.text('Amber Vitals'), findsOneWidget);
    expect(find.text('Conectar'), findsOneWidget);
  });
}
