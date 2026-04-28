class CaptureModelOption {
  const CaptureModelOption({
    required this.id,
    required this.name,
    required this.description,
    required this.actionPatternId,
  });

  final String id;
  final String name;
  final String description;
  final String actionPatternId;
}

class CaptureModelCatalog {
  CaptureModelCatalog._();

  static const String versionDate = '20260423';
  static const String fastModelId = 'swing_tf_fast_20260423';
  static const String balanceModelId = 'swing_tf_balance_20260423';
  static const String defaultModelId = balanceModelId;

  static const List<CaptureModelOption> _models = <CaptureModelOption>[
    CaptureModelOption(
      id: fastModelId,
      name: 'Swing TF Fast 20260423',
      description:
          'Quicker stance-first trigger for rapid live capture when you want the buffer armed earlier.',
      actionPatternId: 'feet_apart_stance_v1',
    ),
    CaptureModelOption(
      id: balanceModelId,
      name: 'Swing TF Balance 20260423',
      description:
          'Cross-body swing trigger tuned for a more complete baseball swing motion before capture fires.',
      actionPatternId: 'baseball_cross_body_v1',
    ),
  ];

  static List<CaptureModelOption> all() => _models;

  static CaptureModelOption resolve(String? id) {
    for (final model in _models) {
      if (model.id == id) {
        return model;
      }
    }
    return _models.firstWhere(
      (model) => model.id == defaultModelId,
      orElse: () => _models.first,
    );
  }

  static String actionPatternIdFor(String? id) => resolve(id).actionPatternId;

  static String migrateLegacySelection(String? legacyId) {
    return switch (legacyId) {
      fastModelId || 'feet_apart_stance_v1' => fastModelId,
      balanceModelId ||
      'baseball_cross_body_v1' ||
      'custom_json' ||
      _ => defaultModelId,
    };
  }
}
