import 'dart:ui' as ui;

import '../render/scene_node.dart';

/// Built-in easing curve identifiers used by the .var.json format.
enum EasingCurve {
  linear,
  easeIn,
  easeOut,
  easeInOut,
  easeInOutBack,
  step,
  bounceIn,
  bounceOut,
  elasticIn,
  elasticOut;

  static EasingCurve parse(String? raw) {
    switch (raw) {
      case 'linear':           return linear;
      case 'ease-in':          return easeIn;
      case 'ease-out':         return easeOut;
      case 'ease-in-out':      return easeInOut;
      case 'ease-in-out-back': return easeInOutBack;
      case 'step':             return step;
      case 'bounce-in':        return bounceIn;
      case 'bounce-out':       return bounceOut;
      case 'elastic-in':       return elasticIn;
      case 'elastic-out':      return elasticOut;
      default:                 return linear;
    }
  }
}

class Viewport {
  final double x;
  final double y;
  final double width;
  final double height;

  /// null = transparent.
  final int? backgroundArgb;

  const Viewport({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.backgroundArgb,
  });
}

/// A single anchor on a path. [cpIn] and [cpOut] are the bezier control
/// handles incident on this node; [isMove] starts a new sub-path; [close]
/// ends the current sub-path before continuing.
class NodePos {
  final double x;
  final double y;
  final ({double x, double y})? cpIn;
  final ({double x, double y})? cpOut;
  final bool isMove;
  final bool close;

  const NodePos({
    required this.x,
    required this.y,
    this.cpIn,
    this.cpOut,
    this.isMove = false,
    this.close = false,
  });
}

class Keyframe {
  final String id;

  /// Milliseconds from state start.
  final double time;
  final double x;
  final double y;
  final double rotation;
  final double scaleX;
  final double scaleY;
  final double opacity;

  /// Z-order override. null = use the element's natural [elementOrder] position.
  final double? zIndex;

  /// Motion-path progress 0–100. null = not on a motion path.
  final double? pathProgress;

  /// Animated `stroke-dashoffset` for the underlying scene node's stroke.
  /// null = this keyframe doesn't drive the offset (resolver leaves it
  /// unowned). The dash *pattern* itself comes from the SVG's static
  /// `stroke-dasharray`.
  final double? strokeDashOffset;

  /// Keyframeable visibility. null = transparent (unset), true = element is
  /// hidden (entire subtree skipped during paint), false = explicitly shown.
  /// Step-hold: the last non-null value at or before the current time is used.
  final bool? hidden;

  /// Per-anchor positions for path-node morphing. null when this keyframe does
  /// not drive the path geometry. Iteration order matches the original path's
  /// `M`/`L`/`C` traversal — preserved via insertion-ordered Map so the
  /// painter can stream entries straight into a [Path].
  final Map<String, NodePos>? nodePositions;

  /// Entry curve: how values ease *into* this keyframe from the previous one.
  /// Unused on the first keyframe of a track.
  final EasingCurve curve;

  /// Selective channel declaration. null = legacy: this keyframe owns all
  /// transform channels. Non-null: only the named channels are owned by this
  /// keyframe; others skip it during per-channel interpolation.
  final Set<String>? props;

  const Keyframe({
    required this.id,
    required this.time,
    required this.x,
    required this.y,
    required this.rotation,
    required this.scaleX,
    required this.scaleY,
    required this.opacity,
    this.zIndex,
    this.pathProgress,
    this.strokeDashOffset,
    this.hidden,
    this.nodePositions,
    required this.curve,
    this.props,
  });

  bool declaresChannel(String ch) => props == null || props!.contains(ch);
}

class ElementAnimation {
  /// Sorted by [Keyframe.time] ascending.
  final List<Keyframe> keyframes;
  const ElementAnimation(this.keyframes);
}

class AnimatedElement {
  final String id;
  final String tagName;
  final double pivotX;
  final double pivotY;
  final bool visible;

  /// Keyed by state name.
  final Map<String, ElementAnimation> animations;

  /// Data-bound property overrides.
  final List<DataBinding> dataBindings;

  /// ID of another animated element whose current geometry clips this one.
  /// Applies in the parent coordinate space. null = no clip mask.
  final String? clipMaskId;

  /// Pre-tessellated polyline geometry baked at export time (option 4 in the
  /// designer's runtime-export modal). When non-null, the painter uses this
  /// path in place of the SVG-derived [SceneNode.geometry], bypassing
  /// Impeller's curve tessellation on first paint.
  final ui.Path? polylinePath;

  /// Total polyline length (sum of segment lengths). Used for closed-contour
  /// dash scaling. 0 when no polyline is baked.
  final double polylineLength;

  /// True when at least one polyline contour is closed.
  final bool polylineClosed;

  const AnimatedElement({
    required this.id,
    required this.tagName,
    required this.pivotX,
    required this.pivotY,
    required this.visible,
    required this.animations,
    this.dataBindings = const [],
    this.clipMaskId,
    this.polylinePath,
    this.polylineLength = 0,
    this.polylineClosed = false,
  });
}

// ── Data bindings ────────────────────────────────────────────────────────────

enum BoundProperty {
  x, y, rotation, scaleX, scaleY, opacity, fill, stroke, strokeDashOffset;

  static BoundProperty? parse(String raw) {
    switch (raw) {
      case 'x':                return x;
      case 'y':                return y;
      case 'rotation':         return rotation;
      case 'scaleX':           return scaleX;
      case 'scaleY':           return scaleY;
      case 'opacity':          return opacity;
      case 'fill':             return fill;
      case 'stroke':           return stroke;
      case 'strokeDashOffset': return strokeDashOffset;
      default:                 return null;
    }
  }

  bool get isColor  => this == fill || this == stroke;
  bool get isScalar => !isColor;
}

class DataBinding {
  final String id;
  final BoundProperty property;
  final String dataKey;
  final double settlingMs;
  final EasingCurve curve;
  final double inMin;
  final double inMax;
  final double outMin;
  final double outMax;
  final int? colorMinArgb;
  final int? colorMaxArgb;

  const DataBinding({
    required this.id,
    required this.property,
    required this.dataKey,
    required this.settlingMs,
    required this.curve,
    required this.inMin,
    required this.inMax,
    required this.outMin,
    required this.outMax,
    required this.colorMinArgb,
    required this.colorMaxArgb,
  });
}

// ── State machine ─────────────────────────────────────────────────────────────

enum TransitionInType { animate, fade }

class TransitionInConfig {
  final TransitionInType type;
  final double duration;
  const TransitionInConfig({required this.type, required this.duration});
}

class StateConfig {
  final double duration;
  final double windowIn;
  final double windowOut;
  final TransitionInConfig transitionIn;

  const StateConfig({
    required this.duration,
    required this.windowIn,
    required this.windowOut,
    this.transitionIn = const TransitionInConfig(
      type: TransitionInType.animate,
      duration: 300,
    ),
  });
}

class TransitionDefaults {
  final double duration;
  final EasingCurve curve;
  const TransitionDefaults({required this.duration, required this.curve});
}

class ElementTransitionOverride {
  final double delay;
  final double? duration;
  final EasingCurve? curve;
  const ElementTransitionOverride({
    required this.delay,
    this.duration,
    this.curve,
  });
}

class StateTransition {
  final String from;
  final String to;
  final double duration;
  final EasingCurve curve;
  final Map<String, ElementTransitionOverride> elements;

  const StateTransition({
    required this.from,
    required this.to,
    required this.duration,
    required this.curve,
    required this.elements,
  });
}

// ── Root animation ────────────────────────────────────────────────────────────

/// Hints recorded by the designer's runtime-export pipeline describing
/// what baking passes have already been applied. Runtimes use these to
/// skip work that's been done upstream (e.g. warm-up cycles when geometry
/// is already pre-tessellated).
class RuntimeHints {
  /// When false, the runtime should skip its warm-up paint cycle.
  final bool warmUp;
  /// True when every animated element was sampled at a fixed rate.
  final bool preSampledKeyframes;
  /// Hz used for pre-sampling, or null when [preSampledKeyframes] is false.
  final double? sampleRate;
  /// True when path geometry was flattened into polylines at export time.
  final bool preTessellated;
  /// Max chord deviation used when flattening, in SVG units.
  final double? tessellationFlatness;

  const RuntimeHints({
    this.warmUp = true,
    this.preSampledKeyframes = false,
    this.sampleRate,
    this.preTessellated = false,
    this.tessellationFlatness,
  });
}

class VectorAnimation {
  final String name;
  final int fps;
  final String svgRaw;
  final Viewport viewport;
  final List<String> states;
  final String defaultState;
  final Map<String, StateConfig> stateConfigs;
  final List<StateTransition> stateTransitions;
  final TransitionDefaults defaultTransition;
  final Map<String, AnimatedElement> elements;
  final List<String> elementOrder;
  final SceneNode scene;

  /// null when the export pre-dates the runtime-hints block.
  final RuntimeHints? runtimeHints;

  /// Flat lookup of scene nodes by SVG id, built at parse time.
  final Map<String, SceneNode> sceneIndex;
  final List<String> warnings;

  const VectorAnimation({
    required this.name,
    required this.fps,
    required this.svgRaw,
    required this.viewport,
    required this.states,
    required this.defaultState,
    required this.stateConfigs,
    required this.stateTransitions,
    required this.defaultTransition,
    required this.elements,
    required this.elementOrder,
    required this.scene,
    required this.sceneIndex,
    required this.warnings,
    this.runtimeHints,
  });

  StateTransition? findTransition(String from, String to) {
    for (final t in stateTransitions) {
      if (t.from == from && t.to == to) return t;
    }
    return null;
  }
}

// ── Exploration API ──────────────────────────────────────────────────────────

/// Static + live description of one state in the animation. Returned by
/// [VectorAnimateController.listStates] so hosts can build pickers, dropdowns,
/// or debug overlays without poking at internal model fields.
class StateInfo {
  final String name;
  final double duration;
  final double windowIn;
  final double windowOut;
  final TransitionInType transitionInType;
  final double transitionInDuration;

  /// True when this is [VectorAnimation.defaultState].
  final bool isDefault;

  /// True when this state is currently active on the controller.
  final bool isCurrent;

  /// Number of elements that declare a keyframe track for this state.
  final int elementCount;

  const StateInfo({
    required this.name,
    required this.duration,
    required this.windowIn,
    required this.windowOut,
    required this.transitionInType,
    required this.transitionInDuration,
    required this.isDefault,
    required this.isCurrent,
    required this.elementCount,
  });
}

/// One declared data binding, decorated with the id of the element that owns
/// it. Returned by [VectorAnimateController.listBindings].
class DataBindingInfo {
  final String id;
  final String elementId;
  final String dataKey;
  final BoundProperty property;
  final double inMin;
  final double inMax;
  final double outMin;
  final double outMax;
  final int? colorMinArgb;
  final int? colorMaxArgb;
  final double settlingMs;
  final EasingCurve curve;

  const DataBindingInfo({
    required this.id,
    required this.elementId,
    required this.dataKey,
    required this.property,
    required this.inMin,
    required this.inMax,
    required this.outMin,
    required this.outMax,
    required this.colorMinArgb,
    required this.colorMaxArgb,
    required this.settlingMs,
    required this.curve,
  });

  bool get isColor => property.isColor;
}

/// One data key declared by the animation, the bindings that consume it, and
/// the value (if any) currently held by the controller. Returned by
/// [VectorAnimateController.listDataKeys].
class DataKeyInfo {
  final String dataKey;
  final List<DataBindingInfo> bindings;

  /// Last value passed to [VectorAnimateController.setData]. null if unset.
  final num? currentValue;

  const DataKeyInfo({
    required this.dataKey,
    required this.bindings,
    required this.currentValue,
  });

  bool get isSet => currentValue != null;
}
