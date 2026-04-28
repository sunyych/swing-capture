import 'dart:convert';

enum ActionPatternStageType {
  handsClusterNearShoulderSide,
  crossBodyTravel,
  feetApartStance,
}

class ActionPatternStageDefinition {
  const ActionPatternStageDefinition({
    required this.id,
    required this.type,
    required this.params,
    this.fromStage,
  });

  factory ActionPatternStageDefinition.fromMap(Map<String, Object?> map) {
    final typeName = map['type'] as String? ?? '';
    return ActionPatternStageDefinition(
      id: map['id'] as String? ?? 'stage',
      type: switch (typeName) {
        'hands_cluster_near_shoulder_side' =>
          ActionPatternStageType.handsClusterNearShoulderSide,
        'cross_body_travel' => ActionPatternStageType.crossBodyTravel,
        'feet_apart_stance' => ActionPatternStageType.feetApartStance,
        _ => throw FormatException('Unknown action stage type: $typeName'),
      },
      fromStage: map['fromStage'] as String?,
      params: Map<String, Object?>.from(
        map['params'] as Map? ?? const <String, Object?>{},
      ),
    );
  }

  final String id;
  final ActionPatternStageType type;
  final String? fromStage;
  final Map<String, Object?> params;

  double doubleParam(String key, double fallback) {
    return (params[key] as num?)?.toDouble() ?? fallback;
  }

  int intParam(String key, int fallback) {
    return (params[key] as num?)?.toInt() ?? fallback;
  }
}

class ActionPatternDefinition {
  const ActionPatternDefinition({
    required this.id,
    required this.name,
    required this.label,
    required this.preRollMs,
    required this.postRollMs,
    required this.cooldownMs,
    required this.stages,
    this.category,
    this.description,
  });

  factory ActionPatternDefinition.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException(
        'Action pattern JSON root must be an object.',
      );
    }
    return ActionPatternDefinition.fromMap(Map<String, Object?>.from(decoded));
  }

  factory ActionPatternDefinition.fromMap(Map<String, Object?> map) {
    final stagesRaw = map['stages'] as List? ?? const <Object?>[];
    return ActionPatternDefinition(
      id: map['id'] as String? ?? 'pattern',
      name: map['name'] as String? ?? 'Pattern',
      label: map['label'] as String? ?? 'pattern_event',
      category: map['category'] as String?,
      description: map['description'] as String?,
      preRollMs: (map['preRollMs'] as num?)?.toInt() ?? 2000,
      postRollMs: (map['postRollMs'] as num?)?.toInt() ?? 2000,
      cooldownMs: (map['cooldownMs'] as num?)?.toInt() ?? 1800,
      stages: stagesRaw
          .whereType<Map>()
          .map(
            (stage) => ActionPatternStageDefinition.fromMap(
              Map<String, Object?>.from(stage),
            ),
          )
          .toList(growable: false),
    );
  }

  final String id;
  final String name;
  final String label;
  final String? category;
  final String? description;
  final int preRollMs;
  final int postRollMs;
  final int cooldownMs;
  final List<ActionPatternStageDefinition> stages;

  ActionPatternDefinition copyWith({
    int? preRollMs,
    int? postRollMs,
    int? cooldownMs,
  }) {
    return ActionPatternDefinition(
      id: id,
      name: name,
      label: label,
      category: category,
      description: description,
      preRollMs: preRollMs ?? this.preRollMs,
      postRollMs: postRollMs ?? this.postRollMs,
      cooldownMs: cooldownMs ?? this.cooldownMs,
      stages: stages,
    );
  }
}

class ActionPatternSummary {
  const ActionPatternSummary({
    required this.id,
    required this.name,
    this.description,
  });

  final String id;
  final String name;
  final String? description;
}
