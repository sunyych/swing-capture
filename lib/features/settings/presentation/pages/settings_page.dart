import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';
import '../../../../core/models/capture_settings.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../capture/domain/patterns/capture_model_catalog.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final asyncSettings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);

    return SafeArea(
      child: asyncSettings.when(
        data: (settings) => _SettingsView(
          settings: settings,
          onChanged: controller.updateSettings,
        ),
        error: (error, _) =>
            Center(child: Text(l10n.failedWithError('$error'))),
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
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text(
            l10n.settingsTitle,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.settingsSubtitle,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          _CaptureModelCard(settings: settings, onChanged: onChanged),
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            value: settings.showDebugSkeleton,
            title: Text(l10n.showDebugSkeleton),
            subtitle: Text(l10n.showDebugSkeletonSubtitle),
            onChanged: (value) =>
                onChanged(settings.copyWith(showDebugSkeleton: value)),
          ),
          SwitchListTile.adaptive(
            value: settings.autoRecordOnReady,
            title: Text(l10n.autoDetection),
            subtitle: Text(l10n.autoDetectionSubtitle),
            onChanged: (value) =>
                onChanged(settings.copyWith(autoRecordOnReady: value)),
          ),
          SwitchListTile.adaptive(
            value: settings.autoSaveToGallery,
            title: Text(l10n.autoSaveToGallery),
            subtitle: Text(l10n.autoSaveToGallerySubtitle),
            onChanged: (value) =>
                onChanged(settings.copyWith(autoSaveToGallery: value)),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.settingsFooterNote),
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
    final l10n = AppLocalizations.of(context);
    final models = CaptureModelCatalog.all();
    final selectedModel = CaptureModelCatalog.resolve(settings.captureModelId);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.captureTfModel,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.captureTfModelSubtitle,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              settings.autoRecordOnReady
                  ? l10n.modelDrivesAutoCapture
                  : l10n.autoDetectionOffWaiting,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(selectedModel.id),
              initialValue: selectedModel.id,
              decoration: InputDecoration(
                labelText: l10n.tfModelVersion,
                border: const OutlineInputBorder(),
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
