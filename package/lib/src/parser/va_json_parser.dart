import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../model/model.dart';
import '../render/scene_node.dart';
import 'svg_parser.dart';

/// Parses a .var.json document. Accepts either a raw JSON string or a
/// pre-decoded [Map].
///
/// Unknown top-level keys and unknown keys inside nested objects are ignored
/// — the authoring tool leaks editor-only fields (e.g. `showGrid`, `color`,
/// `label`) into exports.
VectorAnimation parseVaJson(Object source) {
  final Map<String, dynamic> json;
  if (source is String) {
    json = jsonDecode(source) as Map<String, dynamic>;
  } else if (source is Map<String, dynamic>) {
    json = source;
  } else {
    throw ArgumentError('expected a JSON string or Map, got ${source.runtimeType}');
  }

  final warnings = <String>[];

  final svgRaw = json['svgRaw'] as String? ?? '';
  if (svgRaw.isEmpty) throw const FormatException('missing or empty svgRaw');
  final svgResult = parseSvg(svgRaw);
  warnings.addAll(svgResult.warnings);

  final viewport   = _parseViewport(json['viewport'], warnings);
  final states     = (json['states'] as List?)?.cast<String>() ?? const <String>[];
  final defaultState = json['defaultState'] as String? ??
      (states.isNotEmpty ? states.first : '');

  final stateConfigs = <String, StateConfig>{};
  final rawConfigs = json['stateConfigs'];
  if (rawConfigs is Map) {
    rawConfigs.forEach((k, v) {
      if (v is Map) stateConfigs[k as String] = _parseStateConfig(v);
    });
  }

  final defaultTransition = _parseDefaultTransition(json['defaultTransition']);

  final stateTransitions = <StateTransition>[];
  final rawTransitions = json['stateTransitions'];
  if (rawTransitions is List) {
    for (final t in rawTransitions) {
      if (t is! Map) continue;
      final overrides = <String, ElementTransitionOverride>{};
      final rawEls = t['elements'];
      if (rawEls is Map) {
        rawEls.forEach((k, v) {
          if (v is Map) {
            overrides[k as String] = ElementTransitionOverride(
              delay:    _d(v['delay'])    ?? 0,
              duration: _d(v['duration']),
              curve:    v['curve'] != null
                  ? EasingCurve.parse(v['curve'] as String)
                  : null,
            );
          }
        });
      }
      stateTransitions.add(StateTransition(
        from:     t['from']  as String,
        to:       t['to']    as String,
        duration: _d(t['duration']) ?? defaultTransition.duration,
        curve:    EasingCurve.parse(t['curve'] as String?),
        elements: overrides,
      ));
    }
  }

  final elements = <String, AnimatedElement>{};
  final rawElements = json['elements'];
  if (rawElements is Map) {
    rawElements.forEach((k, v) {
      if (v is! Map) return;
      elements[k as String] = _parseElement(k, v, warnings);
    });
  }
  final elementOrder =
      (json['elementOrder'] as List?)?.cast<String>() ?? elements.keys.toList();

  final scene      = svgResult.root;
  final sceneIndex = _buildSceneIndex(scene);

  return VectorAnimation(
    name:              json['name']        as String? ?? '',
    fps:               (json['fps'] as num?)?.toInt() ?? 60,
    svgRaw:            svgRaw,
    viewport:          viewport,
    states:            states,
    defaultState:      defaultState,
    stateConfigs:      stateConfigs,
    stateTransitions:  stateTransitions,
    defaultTransition: defaultTransition,
    elements:          elements,
    elementOrder:      elementOrder,
    scene:             scene,
    sceneIndex:        sceneIndex,
    warnings:          warnings,
    runtimeHints:      _parseRuntimeHints(json['runtimeHints']),
  );
}

RuntimeHints? _parseRuntimeHints(Object? raw) {
  if (raw is! Map) return null;
  return RuntimeHints(
    warmUp:               raw['warmUp']               as bool? ?? true,
    preSampledKeyframes:  raw['preSampledKeyframes']  as bool? ?? false,
    sampleRate:           _d(raw['sampleRate']),
    preTessellated:       raw['preTessellated']       as bool? ?? false,
    tessellationFlatness: _d(raw['tessellationFlatness']),
  );
}

// ── Scene index ─────────────────────────────────────────────────────────────

Map<String, SceneNode> _buildSceneIndex(SceneNode root) {
  final index = <String, SceneNode>{};
  void walk(SceneNode node) {
    if (node.id != null) index[node.id!] = node;
    for (final child in node.children) { walk(child); }
  }
  walk(root);
  return index;
}

// ── Viewport ─────────────────────────────────────────────────────────────────

Viewport _parseViewport(Object? raw, List<String> warnings) {
  if (raw is! Map) {
    return const Viewport(x: 0, y: 0, width: 0, height: 0, backgroundArgb: null);
  }
  return Viewport(
    x:              _d(raw['x'])      ?? 0,
    y:              _d(raw['y'])      ?? 0,
    width:          _d(raw['width'])  ?? 0,
    height:         _d(raw['height']) ?? 0,
    backgroundArgb: _parseCssColorArgb(raw['background'] as String?),
  );
}

// ── State config ─────────────────────────────────────────────────────────────

StateConfig _parseStateConfig(Map v) {
  final duration  = _d(v['duration'])  ?? 2000;
  final windowIn  = _d(v['windowIn'])  ?? 0;
  final windowOut = _d(v['windowOut']) ?? duration;
  return StateConfig(
    duration:     duration,
    windowIn:     windowIn,
    windowOut:    windowOut,
    transitionIn: _parseTransitionIn(v['transitionIn']),
  );
}

TransitionInConfig _parseTransitionIn(Object? raw) {
  if (raw is! Map) {
    return const TransitionInConfig(type: TransitionInType.animate, duration: 300);
  }
  final type = (raw['type'] as String?) == 'fade'
      ? TransitionInType.fade
      : TransitionInType.animate;
  return TransitionInConfig(type: type, duration: _d(raw['duration']) ?? 300);
}

TransitionDefaults _parseDefaultTransition(Object? raw) {
  if (raw is! Map) {
    return const TransitionDefaults(duration: 300, curve: EasingCurve.easeInOut);
  }
  return TransitionDefaults(
    duration: _d(raw['duration']) ?? 300,
    curve:    EasingCurve.parse(raw['curve'] as String?),
  );
}

// ── Animated element ─────────────────────────────────────────────────────────

AnimatedElement _parseElement(String id, Map raw, List<String> warnings) {
  final animations = <String, ElementAnimation>{};
  final rawAnims = raw['animations'];
  if (rawAnims is Map) {
    rawAnims.forEach((stateName, v) {
      if (v is! Map) return;
      final rawKfs = v['keyframes'];
      if (rawKfs is! List) return;
      final kfs = <Keyframe>[];
      for (var i = 0; i < rawKfs.length; i++) {
        final kf = rawKfs[i];
        if (kf is! Map) continue;
        Set<String>? props;
        final rawProps = kf['props'];
        if (rawProps is List) props = rawProps.whereType<String>().toSet();

        kfs.add(Keyframe(
          id:           kf['id'] as String? ?? '$id-$stateName-$i',
          time:         _d(kf['time'])     ?? 0,
          x:            _d(kf['x'])        ?? 0,
          y:            _d(kf['y'])        ?? 0,
          rotation:     _d(kf['rotation']) ?? 0,
          scaleX:       _d(kf['scaleX'])   ?? 1,
          scaleY:       _d(kf['scaleY'])   ?? 1,
          opacity:      _d(kf['opacity'])  ?? 1,
          zIndex:       _d(kf['zIndex']),
          pathProgress: _d(kf['pathProgress']),
          strokeDashOffset: _d(kf['strokeDashOffset']),
          hidden:       kf['hidden'] as bool?,
          nodePositions: _parseNodePositions(kf['nodePositions']),
          curve:        EasingCurve.parse(kf['curve'] as String?),
          props:        props,
        ));
      }
      kfs.sort((a, b) => a.time.compareTo(b.time));
      animations[stateName as String] = ElementAnimation(kfs);
    });
  }

  final bindings = <DataBinding>[];
  final rawBindings = raw['dataBindings'];
  if (rawBindings is List) {
    for (final b in rawBindings) {
      if (b is! Map) continue;
      final parsed = _parseBinding(id, b, warnings);
      if (parsed != null) bindings.add(parsed);
    }
  }

  final poly = _parsePolylines(raw['polylines']);

  return AnimatedElement(
    id:           id,
    tagName:      raw['tagName'] as String? ?? raw['type'] as String? ?? '',
    pivotX:       _d(raw['pivotX']) ?? 0,
    pivotY:       _d(raw['pivotY']) ?? 0,
    visible:      raw['visible'] as bool? ?? true,
    animations:   animations,
    dataBindings: bindings,
    clipMaskId:   raw['clipMaskId'] as String?,
    polylinePath: poly?.path,
    polylineLength: poly?.length ?? 0,
    polylineClosed: poly?.closed ?? false,
  );
}

class _PolylineResult {
  final ui.Path path;
  final double length;
  final bool closed;
  const _PolylineResult(this.path, this.length, this.closed);
}

_PolylineResult? _parsePolylines(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final path = ui.Path();
  double totalLength = 0;
  bool anyClosed = false;
  for (final c in raw) {
    if (c is! Map) continue;
    final points = c['points'];
    if (points is! List || points.length < 4) continue;
    final closed = c['closed'] == true;
    if (closed) anyClosed = true;
    double px = (_d(points[0]) ?? 0);
    double py = (_d(points[1]) ?? 0);
    path.moveTo(px, py);
    for (var i = 2; i < points.length - 1; i += 2) {
      final x = _d(points[i])     ?? 0;
      final y = _d(points[i + 1]) ?? 0;
      path.lineTo(x, y);
      totalLength += math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
      px = x; py = y;
    }
    if (closed) path.close();
  }
  return _PolylineResult(path, totalLength, anyClosed);
}

DataBinding? _parseBinding(String elementId, Map raw, List<String> warnings) {
  final propertyRaw = raw['property'] as String?;
  final dataKey     = raw['dataKey']  as String?;
  if (propertyRaw == null || dataKey == null) {
    warnings.add('data binding on "$elementId" missing property or dataKey; skipping');
    return null;
  }
  final property = BoundProperty.parse(propertyRaw);
  if (property == null) {
    warnings.add('data binding on "$elementId" targets unknown property "$propertyRaw"; skipping');
    return null;
  }
  return DataBinding(
    id:           raw['id'] as String? ?? 'db_${elementId}_$propertyRaw',
    property:     property,
    dataKey:      dataKey,
    settlingMs:   _d(raw['settlingMs']) ?? 300,
    curve:        EasingCurve.parse(raw['curve'] as String?),
    inMin:        _d(raw['inMin'])  ?? 0,
    inMax:        _d(raw['inMax'])  ?? 1,
    outMin:       _d(raw['outMin']) ?? 0,
    outMax:       _d(raw['outMax']) ?? 1,
    colorMinArgb: _parseCssColorArgb(raw['colorMin'] as String?),
    colorMaxArgb: _parseCssColorArgb(raw['colorMax'] as String?),
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

double? _d(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Parses a `nodePositions` keyframe channel from raw JSON.
///
/// Returns null when the keyframe doesn't drive the path geometry. Iteration
/// order of the resulting Map matches the JSON object's insertion order
/// (Dart's `Map` literal preserves insertion order), which mirrors the
/// editor's path traversal — required so the painter can stream entries
/// straight into a [Path].
Map<String, NodePos>? _parseNodePositions(Object? v) {
  if (v is! Map) return null;
  if (v.isEmpty) return null;
  final out = <String, NodePos>{};
  v.forEach((rawKey, rawVal) {
    if (rawKey is! String || rawVal is! Map) return;
    final x = _d(rawVal['x']);
    final y = _d(rawVal['y']);
    if (x == null || y == null) return;
    out[rawKey] = NodePos(
      x: x,
      y: y,
      cpIn:  _parseCp(rawVal['cpIn']),
      cpOut: _parseCp(rawVal['cpOut']),
      isMove: rawVal['isMove'] == true,
      close:  rawVal['close']  == true,
    );
  });
  return out.isEmpty ? null : out;
}

({double x, double y})? _parseCp(Object? v) {
  if (v is! Map) return null;
  final x = _d(v['x']);
  final y = _d(v['y']);
  if (x == null || y == null) return null;
  return (x: x, y: y);
}

/// Returns null for 'transparent', null, or unrecognised values.
int? _parseCssColorArgb(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (s.isEmpty || s == 'none' || s == 'transparent') return null;
  if (s.startsWith('#')) {
    final hex = s.substring(1);
    if (hex.length == 3) {
      final r = int.parse(hex[0] * 2, radix: 16);
      final g = int.parse(hex[1] * 2, radix: 16);
      final b = int.parse(hex[2] * 2, radix: 16);
      return 0xFF000000 | (r << 16) | (g << 8) | b;
    }
    if (hex.length == 6) return 0xFF000000 | int.parse(hex, radix: 16);
    if (hex.length == 8) {
      final r = int.parse(hex.substring(0, 2), radix: 16);
      final g = int.parse(hex.substring(2, 4), radix: 16);
      final b = int.parse(hex.substring(4, 6), radix: 16);
      final a = int.parse(hex.substring(6, 8), radix: 16);
      return (a << 24) | (r << 16) | (g << 8) | b;
    }
  }
  return null;
}
