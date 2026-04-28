import '../models/action_pattern_definition.dart';

class ActionPatternCatalog {
  ActionPatternCatalog._();

  static const String defaultPatternId = 'baseball_cross_body_v1';
  static const String customJsonPatternId = 'custom_json';

  static final Map<String, String> _builtinJsonById = {
    'feet_apart_stance_v1': '''
{
  "id": "feet_apart_stance_v1",
  "name": "Feet Apart Stance Trigger",
  "label": "feet_apart_stance",
  "category": "sports",
  "description": "Starts capture when both feet settle into a stable, wide stance instead of just stepping through while walking.",
  "preRollMs": 2000,
  "postRollMs": 2000,
  "cooldownMs": 1800,
  "stages": [
    {
      "id": "feet_apart_stance",
      "type": "feet_apart_stance",
      "params": {
        "minLandmarkConfidence": 0.45,
        "minFeetSeparationRatio": 1.8,
        "maxFootLateralSpeed": 0.24,
        "maxHipLateralSpeed": 0.12,
        "minConsecutiveFrames": 4
      }
    }
  ]
}
''',
    defaultPatternId: '''
{
  "id": "baseball_cross_body_v1",
  "name": "Baseball Cross-Body Swing",
  "label": "baseball_swing",
  "category": "sports",
  "description": "Both hands gather near one shoulder, then rapidly drive across the body to the other side.",
  "preRollMs": 2000,
  "postRollMs": 2000,
  "cooldownMs": 1800,
  "stages": [
    {
      "id": "load_side",
      "type": "hands_cluster_near_shoulder_side",
      "params": {
        "minLandmarkConfidence": 0.4,
        "nearShoulderSpanFactor": 0.55,
        "midlineSlackSpanFactor": 0.12,
        "minConsecutiveFrames": 2
      }
    },
    {
      "id": "cross_body",
      "type": "cross_body_travel",
      "fromStage": "load_side",
      "params": {
        "minLandmarkConfidence": 0.35,
        "wristCarryTtlMs": 240,
        "minTransitionMs": 40,
        "maxTransitionMs": 900,
        "minTravelSpanFactor": 0.74,
        "crossMidlineSlackSpanFactor": 0.10,
        "minAverageCrossSpeed": 0.52,
        "minBurstLateralSpeed": 0.82
      }
    }
  ]
}
''',
  };

  static List<ActionPatternSummary> summaries() {
    return _builtinJsonById.values
        .map(ActionPatternDefinition.fromJsonString)
        .map(
          (pattern) => ActionPatternSummary(
            id: pattern.id,
            name: pattern.name,
            description: pattern.description,
          ),
        )
        .toList(growable: false);
  }

  static List<ActionPatternSummary> allSummaries() {
    return <ActionPatternSummary>[
      ...summaries(),
      const ActionPatternSummary(
        id: customJsonPatternId,
        name: 'Custom JSON Pattern',
        description:
            'Paste a staged action pattern definition and match it at runtime.',
      ),
    ];
  }

  static String templateJson() {
    return _builtinJsonById[defaultPatternId] ?? _builtinJsonById.values.first;
  }

  static ActionPatternDefinition parseCustomJson(String source) {
    return ActionPatternDefinition.fromJsonString(source);
  }

  static ActionPatternDefinition resolve(
    String id, {
    String? customJson,
    int? preRollMs,
    int? postRollMs,
    int? cooldownMs,
  }) {
    ActionPatternDefinition definition;
    if (id == customJsonPatternId &&
        customJson != null &&
        customJson.trim().isNotEmpty) {
      try {
        definition = parseCustomJson(customJson);
      } on FormatException {
        definition = ActionPatternDefinition.fromJsonString(templateJson());
      }
    } else {
      final source = _builtinJsonById[id] ?? templateJson();
      definition = ActionPatternDefinition.fromJsonString(source);
    }
    return definition.copyWith(
      preRollMs: preRollMs,
      postRollMs: postRollMs,
      cooldownMs: cooldownMs,
    );
  }
}
