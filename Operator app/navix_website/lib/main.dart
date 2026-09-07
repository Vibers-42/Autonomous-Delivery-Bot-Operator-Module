import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/screens/main_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => RobotStateProvider())],
      child: const NavixApp(),
    ),
  );
}

class NavixApp extends StatelessWidget {
  const NavixApp({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);

    return MaterialApp(
      title: 'Navix AMR Operator Console',
      debugShowCheckedModeBanner: false,

      // Industrial High-Contrast Theme System
      theme: ThemeData(
        useMaterial3: true,
        brightness: provider.isDarkTheme ? Brightness.dark : Brightness.light,

        // Color Tokens
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00FFCC),
          brightness: provider.isDarkTheme ? Brightness.dark : Brightness.light,
          primary: const Color(0xFF00FFCC),
          secondary: const Color(0xFFCC00FF),
          surface: provider.isDarkTheme
              ? const Color(0xFF0F141C)
              : const Color(0xFFF5F7FA),
        ),

        // Font customization
        fontFamily: 'monospace',

        // Custom widget styles
        scaffoldBackgroundColor: provider.isDarkTheme
            ? const Color(0xFF080B0F)
            : const Color(0xFFE5E9F0),

        sliderTheme: SliderThemeData(
          activeTrackColor: const Color(0xFF00FFCC),
          inactiveTrackColor: const Color(0xFF1E2E43),
          thumbColor: const Color(0xFF00FFCC),
          overlayColor: const Color(0xFF00FFCC).withValues(alpha: 0.2),
          valueIndicatorColor: const Color(0xFF101622),
          valueIndicatorTextStyle: const TextStyle(color: Colors.white),
        ),

        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.selected)) {
              return const Color(0xFF00FFCC);
            }
            return const Color(0xFF6B7A90);
          }),
          trackColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.selected)) {
              return const Color(0xFF00FFCC).withValues(alpha: 0.3);
            }
            return const Color(0xFF131B26);
          }),
        ),

        appBarTheme: AppBarTheme(
          backgroundColor: provider.isDarkTheme
              ? const Color(0xFF0F141C)
              : Colors.white,
          elevation: 0,
          iconTheme: IconThemeData(
            color: provider.isDarkTheme ? Colors.white : Colors.black,
          ),
        ),
      ),

      home: const MainShell(),
    );
  }
}
