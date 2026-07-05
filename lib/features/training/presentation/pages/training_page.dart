import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';

class TrainingPage extends ConsumerWidget {
  const TrainingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).valueOrNull;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Text('Training', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'Hybrid learning pipeline: tagged pose dataset -> backend training -> model version rollout -> on-device auto-record trigger.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Current model status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Active model: ${settings?.activeModelVersion ?? 'hybrid_v1'}',
                    ),
                    Text(
                      'Auto-record threshold: ${(settings?.autoRecordThreshold ?? 0.7).toStringAsFixed(2)}',
                    ),
                    Text(
                      'Hybrid learning: ${(settings?.enableHybridLearning ?? true) ? 'enabled' : 'disabled'}',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          ref.read(appTabProvider.notifier).state = 4,
                      icon: const Icon(Icons.tune_outlined),
                      label: const Text('Open model settings'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
