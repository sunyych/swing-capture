import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/capture/presentation/pages/capture_page.dart';
import '../features/history/presentation/pages/history_page.dart';
import '../features/performance/data/startup_performance_repository.dart';
import '../features/performance/domain/startup_performance_benchmark.dart';
import '../features/settings/presentation/pages/settings_page.dart';
import '../features/studio/presentation/pages/video_studio_page.dart';
import '../features/training/presentation/pages/training_page.dart';
import 'providers.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _startupPerformanceModalChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowStartupPerformanceModal());
    });
  }

  Future<void> _maybeShowStartupPerformanceModal() async {
    if (!mounted || _startupPerformanceModalChecked) {
      return;
    }
    _startupPerformanceModalChecked = true;
    final repository = ref.read(startupPerformanceRepositoryProvider);
    final shouldShow = await repository.shouldShowStartupPerformanceModal();
    if (!mounted || !shouldShow) {
      return;
    }
    final benchmark = ref.read(startupPerformanceBenchmarkProvider);
    await showDialog<void>(
      context: context,
      builder: (context) => _StartupPerformanceDialog(
        repository: repository,
        benchmark: benchmark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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

class _StartupPerformanceDialog extends StatefulWidget {
  const _StartupPerformanceDialog({
    required this.repository,
    required this.benchmark,
  });

  final StartupPerformanceRepository repository;
  final StartupPerformanceBenchmark benchmark;

  @override
  State<_StartupPerformanceDialog> createState() =>
      _StartupPerformanceDialogState();
}

class _StartupPerformanceDialogState extends State<_StartupPerformanceDialog> {
  late final Future<StartupPerformanceReport> _report;
  bool _hideFutureModals = false;

  @override
  void initState() {
    super.initState();
    _report = widget.benchmark.run();
  }

  Future<void> _close() async {
    if (_hideFutureModals) {
      await widget.repository.setStartupPerformanceModalHidden(true);
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(
            value: _hideFutureModals,
            onChanged: (value) =>
                setState(() => _hideFutureModals = value ?? false),
            title: const Text('Don\'t show test content'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          Text(
            'Performance tests',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ],
      ),
      content: FutureBuilder<StartupPerformanceReport>(
        future: _report,
        builder: (context, snapshot) {
          final report = snapshot.data;
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PerformanceMetricRow(
                  icon: Icons.videocam_outlined,
                  label: 'Recording profile',
                  value: report?.recordingSummary ?? 'Checking...',
                  detail: report?.recordingDetail,
                ),
                const SizedBox(height: 12),
                _PerformanceMetricRow(
                  icon: Icons.accessibility_new,
                  label: 'Pose processing',
                  value: report == null
                      ? 'Running...'
                      : '${report.poseProcessing.fps.toStringAsFixed(0)} fps',
                  detail: report == null
                      ? null
                      : '${report.poseProcessing.framesProcessed} frames, '
                            '${report.poseProcessing.elapsed.inMilliseconds} ms',
                ),
              ],
            ),
          );
        },
      ),
      actions: [FilledButton(onPressed: _close, child: const Text('Close'))],
    );
  }
}

class _PerformanceMetricRow extends StatelessWidget {
  const _PerformanceMetricRow({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: textTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(value, style: textTheme.titleMedium),
              if (detail != null) ...[
                const SizedBox(height: 2),
                Text(
                  detail!,
                  style: textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
