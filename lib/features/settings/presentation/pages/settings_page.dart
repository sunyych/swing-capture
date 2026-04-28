import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';
import '../../../../core/models/capture_settings.dart';
import '../../../capture/domain/patterns/capture_model_catalog.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSettings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);

    return SafeArea(
      child: asyncSettings.when(
        data: (settings) => _SettingsView(
          settings: settings,
          onChanged: controller.updateSettings,
        ),
        error: (error, _) => Center(child: Text('Failed: $error')),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _SettingsView extends StatelessWidget {
  const _SettingsView({required this.settings, required this.onChanged});

  final CaptureSettings settings;
  final ValueChanged<CaptureSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            'Choose the live capture model, then tune timing and overlay behavior.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          _CaptureModelCard(settings: settings, onChanged: onChanged),
          const SizedBox(height: 16),
          _SliderCard(
            label: 'Pre-roll seconds',
            valueLabel: settings.preRollSeconds.toStringAsFixed(1),
            value: settings.preRollSeconds,
            min: 1,
            max: 4,
            onChanged: (value) =>
                onChanged(settings.copyWith(preRollSeconds: value)),
          ),
          _SliderCard(
            label: 'Post-roll seconds',
            valueLabel: settings.postRollSeconds.toStringAsFixed(1),
            value: settings.postRollSeconds,
            min: 1,
            max: 4,
            onChanged: (value) =>
                onChanged(settings.copyWith(postRollSeconds: value)),
          ),
          _SliderCard(
            label: 'Swing cooldown (ms)',
            valueLabel: settings.swingCooldownMs.toString(),
            value: settings.swingCooldownMs.toDouble(),
            min: 500,
            max: 4000,
            divisions: 14,
            onChanged: (value) =>
                onChanged(settings.copyWith(swingCooldownMs: value.round())),
          ),
          SwitchListTile.adaptive(
            value: settings.showDebugSkeleton,
            title: const Text('Show debug skeleton'),
            subtitle: const Text(
              'Displays detector landmarks and future bounding boxes.',
            ),
            onChanged: (value) =>
                onChanged(settings.copyWith(showDebugSkeleton: value)),
          ),
          SwitchListTile.adaptive(
            value: settings.autoRecordOnReady,
            title: const Text('Auto detection'),
            subtitle: const Text(
              'When on, SwingCapture uses the selected model to capture automatically. When off, capture stays manual and only saves when you trigger it on the Capture screen.',
            ),
            onChanged: (value) =>
                onChanged(settings.copyWith(autoRecordOnReady: value)),
          ),
          SwitchListTile.adaptive(
            value: settings.autoSaveToGallery,
            title: const Text('Auto-save to gallery'),
            subtitle: const Text(
              'When the native export pipeline is ready, clips go to the SwingCapture album.',
            ),
            onChanged: (value) =>
                onChanged(settings.copyWith(autoSaveToGallery: value)),
          ),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Model names include the release date in YYYYMMDD format. On Android, volume keys can still fire capture while you are on Capture.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureModelCard extends StatelessWidget {
  const _CaptureModelCard({required this.settings, required this.onChanged});

  final CaptureSettings settings;
  final ValueChanged<CaptureSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final models = CaptureModelCatalog.all();
    final selectedModel = CaptureModelCatalog.resolve(settings.captureModelId);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Capture TF model',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Pick the live trigger model version used during capture.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              settings.autoRecordOnReady
                  ? 'The selected model drives automatic swing capture.'
                  : 'Auto detection is off, so the selected model will wait until you turn it back on.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: selectedModel.id,
              decoration: const InputDecoration(
                labelText: 'TF model version',
                border: OutlineInputBorder(),
              ),
              items: models
                  .map(
                    (model) => DropdownMenuItem<String>(
                      value: model.id,
                      child: Text(model.name),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                onChanged(settings.copyWith(captureModelId: value));
              },
            ),
            const SizedBox(height: 12),
            Text(
              selectedModel.description,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderCard extends StatelessWidget {
  const _SliderCard({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label)),
                Text(valueLabel),
              ],
            ),
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}
