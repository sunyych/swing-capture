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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hybrid learning and auto-record model',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use on-device inference for low-latency trigger and keep training lifecycle synced with backend model versions.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: settings.enableHybridLearning,
                    title: const Text('Enable hybrid learning'),
                    subtitle: const Text(
                      'On-device inference + backend training lifecycle.',
                    ),
                    onChanged: (value) => onChanged(
                      settings.copyWith(enableHybridLearning: value),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: settings.activeModelVersion,
                    decoration: const InputDecoration(
                      labelText: 'Active model version',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => onChanged(
                      settings.copyWith(activeModelVersion: value.trim()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _SliderCard(
            label: 'Auto-record trigger threshold',
            valueLabel: settings.autoRecordThreshold.toStringAsFixed(2),
            value: settings.autoRecordThreshold,
            min: 0.10,
            max: 0.99,
            divisions: 89,
            onChanged: (value) =>
                onChanged(settings.copyWith(autoRecordThreshold: value)),
          ),
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
          _RtmpSettingsCard(settings: settings, onChanged: onChanged),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Dual phone capture',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use one phone to detect the swing and a second phone to keep a synchronized high-speed buffer.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<DualCameraRole>(
                    key: ValueKey(settings.dualCameraRole),
                    initialValue: settings.dualCameraRole,
                    decoration: const InputDecoration(
                      labelText: 'This phone role',
                      border: OutlineInputBorder(),
                    ),
                    items: DualCameraRole.values
                        .map(
                          (role) => DropdownMenuItem<DualCameraRole>(
                            value: role,
                            child: Text(role.label),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      onChanged(settings.copyWith(dualCameraRole: value));
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Rolling buffer video frame rate',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Higher fps improves slow-motion clips but increases heat, battery use, and storage. Actual fps depends on the device; many phones fall back to 30–60 fps.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: settings.autoSelectBestFps,
                    title: const Text('Use fastest supported recording'),
                    subtitle: const Text(
                      'Checks this phone after camera permission and selects the highest safe frame-rate mode.',
                    ),
                    onChanged: (value) =>
                        onChanged(settings.copyWith(autoSelectBestFps: value)),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<VideoFpsMode>(
                    key: ValueKey(
                      minimumHighSpeedVideoFpsMode(settings.videoFpsMode),
                    ),
                    initialValue: minimumHighSpeedVideoFpsMode(
                      settings.videoFpsMode,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Target recording fps',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: VideoFpsMode.high60,
                        child: Text('60 fps'),
                      ),
                      DropdownMenuItem(
                        value: VideoFpsMode.high120,
                        child: Text('120 fps'),
                      ),
                      DropdownMenuItem(
                        value: VideoFpsMode.high240,
                        child: Text('240 fps'),
                      ),
                      DropdownMenuItem(
                        value: VideoFpsMode.maxSupported,
                        child: Text('Maximum supported'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      onChanged(settings.copyWith(videoFpsMode: value));
                    },
                  ),
                ],
              ),
            ),
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
              'When on, MotionCapture uses the selected model to capture automatically. When off, capture stays manual and only saves when you trigger it on the Capture screen.',
            ),
            onChanged: (value) =>
                onChanged(settings.copyWith(autoRecordOnReady: value)),
          ),
          SwitchListTile.adaptive(
            value: settings.autoSaveToGallery,
            title: const Text('Auto-save to gallery'),
            subtitle: const Text(
              'When the native export pipeline is ready, clips go to the MotionCapture album.',
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
              key: ValueKey(selectedModel.id),
              initialValue: selectedModel.id,
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

class _RtmpSettingsCard extends StatefulWidget {
  const _RtmpSettingsCard({required this.settings, required this.onChanged});

  final CaptureSettings settings;
  final ValueChanged<CaptureSettings> onChanged;

  @override
  State<_RtmpSettingsCard> createState() => _RtmpSettingsCardState();
}

class _RtmpSettingsCardState extends State<_RtmpSettingsCard> {
  late TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.settings.rtmpUrl);
  }

  @override
  void didUpdateWidget(covariant _RtmpSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.rtmpUrl != widget.settings.rtmpUrl &&
        widget.settings.rtmpUrl != _urlController.text) {
      _urlController.text = widget.settings.rtmpUrl;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'RTMP / RTMPS output',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Live stream and per-swing clip republish. Put your full URL here (credentials and stream key can be embedded), e.g. rtmps://user:pass@host/app/live_key. Swing windows are tagged with AMF onSwingStart / onSwingEnd metadata on the live stream.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: widget.settings.rtmpEnabled,
              title: const Text('Enable RTMP output'),
              subtitle: const Text(
                'When on, the capture session publishes a live stream and optional swing clips.',
              ),
              onChanged: (v) =>
                  widget.onChanged(widget.settings.copyWith(rtmpEnabled: v)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              enabled: widget.settings.rtmpEnabled,
              decoration: const InputDecoration(
                labelText: 'RTMP URL',
                hintText: 'rtmps://user:pass@host/app/streamKey',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) =>
                  widget.onChanged(widget.settings.copyWith(rtmpUrl: v)),
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
