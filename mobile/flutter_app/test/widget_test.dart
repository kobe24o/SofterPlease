// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:softerplease/main.dart';

void main() {
  testWidgets('renders the local-only record conversation and family tabs',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const SofterPleaseApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(find.text('SofterPlease'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('家庭'), findsOneWidget);
    expect(find.textContaining('所有录音与声纹仅保存在本机'), findsOneWidget);
  });
}
