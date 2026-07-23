import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/main.dart';

void main() {
  testWidgets('Navix app launch smoke test', (WidgetTester tester) async {
    // Build our app wrapped in the required Provider and trigger a frame.
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => RobotStateProvider(),
        child: const NavixApp(),
      ),
    );

    // Verify that the operator console title exists
    expect(find.textContaining('NAVIX // AMR'), findsOneWidget);
  });
}
