import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'services/notification_service.dart';
import 'screens/dashboard_screen.dart';

const colorMorado = Color(0xFF8A2387);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  runApp(const StockeArApp());
}

class StockeArApp extends StatelessWidget {
  const StockeArApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StockeAr · Vencimientos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey[50],
        textTheme: GoogleFonts.poppinsTextTheme(Theme.of(context).textTheme),
        colorScheme: ColorScheme.fromSeed(seedColor: colorMorado),
      ),
      home: const DashboardScreen(),
    );
  }
}
