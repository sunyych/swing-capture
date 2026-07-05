import 'package:flutter/material.dart';

import 'app_shell.dart';

class MotionCaptureApp extends StatelessWidget {
  const MotionCaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MotionCapture',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF07131A),
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}
