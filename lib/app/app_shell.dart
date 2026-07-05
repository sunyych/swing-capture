import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/capture/presentation/pages/capture_page.dart';
import '../features/history/presentation/pages/history_page.dart';
import '../features/settings/presentation/pages/settings_page.dart';
import '../features/studio/presentation/pages/video_studio_page.dart';
import '../features/training/presentation/pages/training_page.dart';
import 'providers.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabIndex = ref.watch(appTabProvider);
    final pages = <Widget>[
      const CapturePage(),
      const HistoryPage(),
      const VideoStudioPage(),
      const TrainingPage(),
      const SettingsPage(),
    ];

    return Scaffold(
      body: IndexedStack(index: tabIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        onDestinationSelected: (index) =>
            ref.read(appTabProvider.notifier).state = index,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.videocam_outlined),
            selectedIcon: Icon(Icons.videocam),
            label: 'Capture',
          ),
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: 'Dataset',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_motion_outlined),
            selectedIcon: Icon(Icons.auto_awesome_motion),
            label: 'Studio',
          ),
          NavigationDestination(
            icon: Icon(Icons.model_training_outlined),
            selectedIcon: Icon(Icons.model_training),
            label: 'Training',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
