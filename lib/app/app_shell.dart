import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/capture/presentation/pages/capture_page.dart';
import '../features/history/presentation/pages/history_page.dart';
import '../features/performance/data/startup_performance_repository.dart';
import '../features/performance/domain/startup_performance_benchmark.dart';
import '../features/settings/presentation/pages/settings_page.dart';
import '../l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context);
    final tabIndex = ref.watch(appTabProvider);
    final pages = <Widget>[
      const CapturePage(),
      const HistoryPage(),
      const SettingsPage(),
    ];

    return Scaffold(
      body: IndexedStack(index: tabIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        onDestinationSelected: (index) =>
            ref.read(appTabProvider.notifier).state = index,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.videocam_outlined),
            selectedIcon: const Icon(Icons.videocam),
            label: l10n.navCapture,
          ),
          NavigationDestination(
            icon: const Icon(Icons.video_library_outlined),
            selectedIcon: const Icon(Icons.video_library),
            label: l10n.navHistory,
          ),
          NavigationDestination(
            icon: const Icon(Icons.tune_outlined),
            selectedIcon: const Icon(Icons.tune),
            label: l10n.navSettings,
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
    final l10n = AppLocalizations.of(context);
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
            title: Text(l10n.dontShowTestContent),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          Text(
            l10n.performanceTests,
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
                  label: l10n.recordingProfile,
                  value: report?.recordingSummary ?? l10n.checking,
                  detail: report?.recordingDetail,
                ),
                const SizedBox(height: 12),
                _PerformanceMetricRow(
                  icon: Icons.accessibility_new,
                  label: l10n.poseDetection,
                  value: report == null
                      ? l10n.running
                      : l10n.fpsValue(
                          report.poseDetection.fps.toStringAsFixed(0),
                        ),
                  detail: report == null
                      ? null
                      : l10n.framesCandidates(
                          report.poseDetection.framesProcessed,
                          report.poseDetection.candidatesDetected,
                        ),
                ),
                const SizedBox(height: 12),
                _PerformanceMetricRow(
                  icon: Icons.timeline,
                  label: l10n.poseProcessing,
                  value: report == null
                      ? l10n.running
                      : l10n.fpsValue(
                          report.poseProcessing.fps.toStringAsFixed(0),
                        ),
                  detail: report == null
                      ? null
                      : l10n.framesElapsedMs(
                          report.poseProcessing.framesProcessed,
                          report.poseProcessing.elapsed.inMilliseconds,
                        ),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        FilledButton(onPressed: _close, child: Text(l10n.close)),
      ],
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
