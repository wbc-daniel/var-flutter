import 'dart:ui' show Color;

import '../model/model.dart';
import 'easing.dart';

/// The fully resolved transform for an element at a particular frame.
/// Consumed by the painter.
class ResolvedElement {
  final double x;
  final double y;
  final double rotation;
  final double scaleX;
  final double scaleY;
  final double opacity;
  final double pivotX;
  final double pivotY;

  /// Resolved z-order override. null = use the element's natural [elementOrder]
  /// position. Non-null values are compared across siblings when painting.
  final double? zIndex;

  /// Resolved motion-path progress (0–100). null = element is not on a path.
  /// Applied by the painter once motion-path support is added.
  final double? pathProgress;

  /// Data-binding fill override. When non-null, replaces the scene node's
  /// static [fill] paint with a solid colour.
  final Color? fillOverride;

  /// Data-binding stroke override. When non-null, replaces the scene node's
  /// static [stroke] paint with a solid colour.
  final Color? strokeOverride;

  /// Animated stroke-dashoffset. null = use the scene node's static
  /// [SceneNode.strokeDashOffset] instead.
  final double? strokeDashOffset;

  /// Keyframeable visibility override. null = unset (element paints normally).
  /// true = element is hidden (entire subtree skipped). false = explicitly shown.
  final bool? hidden;

  /// Resolved per-anchor positions for path-node morphing. null when no
  /// keyframe drives the path geometry — painter falls back to the static
  /// scene-node geometry. Iteration order matches the original path traversal.
  final Map<String, NodePos>? nodePositions;

  const ResolvedElement({
    required this.x,
    required this.y,
    required this.rotation,
    required this.scaleX,
    required this.scaleY,
    required this.opacity,
    required this.pivotX,
    required this.pivotY,
    this.zIndex,
    this.pathProgress,
    this.fillOverride,
    this.strokeOverride,
    this.strokeDashOffset,
    this.hidden,
    this.nodePositions,
  });

  /// Static identity pose — used when an element has no keyframes in a state.
  factory ResolvedElement.identityFor(AnimatedElement el) => ResolvedElement(
        x: 0,
        y: 0,
        rotation: 0,
        scaleX: 1,
        scaleY: 1,
        opacity: 1,
        pivotX: el.pivotX,
        pivotY: el.pivotY,
      );

  factory ResolvedElement.fromKeyframe(Keyframe kf, AnimatedElement el) =>
      ResolvedElement(
        x: kf.x,
        y: kf.y,
        rotation: kf.rotation,
        scaleX: kf.scaleX,
        scaleY: kf.scaleY,
        opacity: kf.opacity,
        zIndex: kf.zIndex,
        pathProgress: kf.pathProgress,
        strokeDashOffset: kf.strokeDashOffset,
        hidden: kf.hidden,
        nodePositions: kf.nodePositions,
        pivotX: el.pivotX,
        pivotY: el.pivotY,
      );

  ResolvedElement copyWith({
    double? x,
    double? y,
    double? rotation,
    double? scaleX,
    double? scaleY,
    double? opacity,
    Object? zIndex = _keep,
    Object? pathProgress = _keep,
    Object? fillOverride = _keep,
    Object? strokeOverride = _keep,
    Object? strokeDashOffset = _keep,
    Object? hidden = _keep,
    Object? nodePositions = _keep,
  }) {
    return ResolvedElement(
      x: x ?? this.x,
      y: y ?? this.y,
      rotation: rotation ?? this.rotation,
      scaleX: scaleX ?? this.scaleX,
      scaleY: scaleY ?? this.scaleY,
      opacity: opacity ?? this.opacity,
      pivotX: pivotX,
      pivotY: pivotY,
      zIndex: identical(zIndex, _keep) ? this.zIndex : zIndex as double?,
      pathProgress: identical(pathProgress, _keep)
          ? this.pathProgress
          : pathProgress as double?,
      fillOverride: identical(fillOverride, _keep)
          ? this.fillOverride
          : fillOverride as Color?,
      strokeOverride: identical(strokeOverride, _keep)
          ? this.strokeOverride
          : strokeOverride as Color?,
      strokeDashOffset: identical(strokeDashOffset, _keep)
          ? this.strokeDashOffset
          : strokeDashOffset as double?,
      hidden: identical(hidden, _keep) ? this.hidden : hidden as bool?,
      nodePositions: identical(nodePositions, _keep)
          ? this.nodePositions
          : nodePositions as Map<String, NodePos>?,
    );
  }
}

const Object _keep = Object();

/// Resolves [el]'s animated values at local time [localTimeMs] within [stateName].
///
/// When any keyframe carries a [Keyframe.props] declaration, per-channel
/// interpolation is used: each property finds its own nearest bracketing
/// keyframes that declare it. Legacy keyframes (props == null) declare all
/// channels, preserving backwards-compatible behaviour.
ResolvedElement resolveElement(
  AnimatedElement el,
  String stateName,
  double localTimeMs,
) {
  final anim = el.animations[stateName];
  if (anim == null || anim.keyframes.isEmpty) {
    return ResolvedElement.identityFor(el);
  }
  final kfs = anim.keyframes;
  if (kfs.length == 1) {
    return ResolvedElement.fromKeyframe(kfs.first, el);
  }

  // Fast path: no keyframe uses selective props — single binary search covers
  // all channels simultaneously.
  final hasSelectiveProps = kfs.any((k) => k.props != null);
  if (!hasSelectiveProps) {
    if (localTimeMs <= kfs.first.time) {
      return ResolvedElement.fromKeyframe(kfs.first, el);
    }
    if (localTimeMs >= kfs.last.time) {
      return ResolvedElement.fromKeyframe(kfs.last, el);
    }
    return _resolveAllChannels(kfs, localTimeMs, el);
  }

  // Slow path: at least one keyframe declares a subset of channels, so each
  // channel must find its own bracketing pair independently.
  return _resolvePerChannel(kfs, localTimeMs, el);
}

/// Binary-search interpolation used when all keyframes are legacy (props == null).
ResolvedElement _resolveAllChannels(
  List<Keyframe> kfs,
  double localTimeMs,
  AnimatedElement el,
) {
  var lo = 0;
  var hi = kfs.length - 1;
  while (lo < hi - 1) {
    final mid = (lo + hi) >> 1;
    if (kfs[mid].time <= localTimeMs) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = kfs[lo];
  final b = kfs[hi];
  final span = b.time - a.time;
  final t = span <= 0 ? 1.0 : (localTimeMs - a.time) / span;
  final eased = applyEasing(b.curve, t);

  // Step-hold for hidden: last non-null value at or before localTimeMs.
  bool? hidden;
  for (final kf in kfs) {
    if (kf.hidden == null) continue;
    if (kf.time <= localTimeMs) hidden = kf.hidden;
    else break;
  }

  return ResolvedElement(
    x: lerp(a.x, b.x, eased),
    y: lerp(a.y, b.y, eased),
    // Linear (not shortest-arc) lerp within a state — matches the editor and
    // lets users get full revolutions by typing rotation: 720. Cross-state
    // blending in [blendResolved] still uses shortest-arc.
    rotation: lerp(a.rotation, b.rotation, eased),
    scaleX: lerp(a.scaleX, b.scaleX, eased),
    scaleY: lerp(a.scaleY, b.scaleY, eased),
    opacity: lerp(a.opacity, b.opacity, eased),
    zIndex: _lerpNullable(a.zIndex, b.zIndex, eased),
    pathProgress: _lerpNullable(a.pathProgress, b.pathProgress, eased),
    strokeDashOffset:
        _lerpNullable(a.strokeDashOffset, b.strokeDashOffset, eased),
    hidden: hidden,
    nodePositions: _resolveNodePositions(kfs, localTimeMs),
    pivotX: el.pivotX,
    pivotY: el.pivotY,
  );
}

/// Per-channel interpolation used when selective [Keyframe.props] are present.
/// Each channel independently locates its bracketing keyframes.
ResolvedElement _resolvePerChannel(
  List<Keyframe> kfs,
  double localTimeMs,
  AnimatedElement el,
) {
  return ResolvedElement(
    x: _resolveChannel(kfs, localTimeMs, 'x', (k) => k.x, 0.0),
    y: _resolveChannel(kfs, localTimeMs, 'y', (k) => k.y, 0.0),
    // Linear lerp within a state (not shortest-arc) — see _resolveAllChannels.
    rotation: _resolveChannel(
      kfs, localTimeMs, 'rotation', (k) => k.rotation, 0.0,
    ),
    scaleX: _resolveChannel(kfs, localTimeMs, 'scaleX', (k) => k.scaleX, 1.0),
    scaleY: _resolveChannel(kfs, localTimeMs, 'scaleY', (k) => k.scaleY, 1.0),
    opacity: _resolveChannel(kfs, localTimeMs, 'opacity', (k) => k.opacity, 1.0),
    zIndex: _resolveNullableChannel(kfs, localTimeMs, 'zIndex', (k) => k.zIndex),
    pathProgress: _resolveNullableChannel(
        kfs, localTimeMs, 'pathProgress', (k) => k.pathProgress),
    strokeDashOffset: _resolveNullableChannel(
        kfs, localTimeMs, 'strokeDashOffset', (k) => k.strokeDashOffset),
    hidden: _resolveStepBoolChannel(kfs, localTimeMs, 'hidden', (k) => k.hidden),
    nodePositions: _resolveNodePositions(kfs, localTimeMs),
    pivotX: el.pivotX,
    pivotY: el.pivotY,
  );
}

/// Find the bracketing keyframes that drive [Keyframe.nodePositions] and
/// interpolate per-anchor. Mirrors the editor's `interpolateNodePositions`:
/// lerp x/y/cpIn/cpOut, hold isMove/close from the lo node. Iteration order
/// of the result follows lo's Map order; keys absent from lo are appended
/// from hi afterwards so contour traversal stays stable.
Map<String, NodePos>? _resolveNodePositions(List<Keyframe> kfs, double t) {
  Keyframe? lo;
  Keyframe? hi;
  for (final kf in kfs) {
    final np = kf.nodePositions;
    if (np == null || np.isEmpty) continue;
    if (kf.time <= t) {
      lo = kf;
    } else {
      hi = kf;
      break;
    }
  }
  if (lo == null && hi == null) return null;
  if (lo == null) return hi!.nodePositions;
  if (hi == null) return lo.nodePositions;
  final span = hi.time - lo.time;
  final frac = span <= 0 ? 1.0 : (t - lo.time) / span;
  final eased = applyEasing(hi.curve, frac);
  return _lerpNodePositions(lo.nodePositions!, hi.nodePositions!, eased);
}

Map<String, NodePos> _lerpNodePositions(
  Map<String, NodePos> a,
  Map<String, NodePos> b,
  double t,
) {
  final out = <String, NodePos>{};
  // Walk `a` first so the result preserves the original path traversal order
  // for shared anchors; nodes only present in `b` are appended afterwards.
  a.forEach((key, na) {
    final nb = b[key];
    out[key] = nb != null ? _blendNode(na, nb, t) : na;
  });
  b.forEach((key, nb) {
    out.putIfAbsent(key, () => nb);
  });
  return out;
}

NodePos _blendNode(NodePos a, NodePos b, double t) {
  return NodePos(
    x: lerp(a.x, b.x, t),
    y: lerp(a.y, b.y, t),
    cpIn:  _blendCp(a.cpIn,  b.cpIn,  t),
    cpOut: _blendCp(a.cpOut, b.cpOut, t),
    isMove: a.isMove,
    close:  a.close,
  );
}

({double x, double y})? _blendCp(
  ({double x, double y})? a,
  ({double x, double y})? b,
  double t,
) {
  if (a == null && b == null) return null;
  if (a == null) return b;
  if (b == null) return a;
  return (x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t));
}

/// Resolves a single required channel at [t] by finding the nearest
/// keyframes that declare [ch] on either side of [t].
double _resolveChannel(
  List<Keyframe> kfs,
  double t,
  String ch,
  double Function(Keyframe) get,
  double identity, {
  bool isAngle = false,
}) {
  // Walk backward for the most recent keyframe at-or-before t that declares ch.
  int lo = -1;
  for (var i = kfs.length - 1; i >= 0; i--) {
    if (kfs[i].time <= t && kfs[i].declaresChannel(ch)) {
      lo = i;
      break;
    }
  }

  // Walk forward for the first keyframe after t that declares ch.
  int hi = -1;
  for (var i = 0; i < kfs.length; i++) {
    if (kfs[i].time > t && kfs[i].declaresChannel(ch)) {
      hi = i;
      break;
    }
  }

  if (lo == -1 && hi == -1) return identity;
  if (lo == -1) return get(kfs[hi]);
  if (hi == -1) return get(kfs[lo]);

  final a = kfs[lo];
  final b = kfs[hi];
  final span = b.time - a.time;
  final frac = span <= 0 ? 1.0 : (t - a.time) / span;
  final eased = applyEasing(b.curve, frac);
  return isAngle
      ? lerpAngleDeg(get(a), get(b), eased)
      : lerp(get(a), get(b), eased);
}

/// Same as [_resolveChannel] but for nullable channels (zIndex, pathProgress).
/// Keyframes whose value is null are skipped — only keyframes with a non-null
/// value for [ch] are considered.
double? _resolveNullableChannel(
  List<Keyframe> kfs,
  double t,
  String ch,
  double? Function(Keyframe) get,
) {
  int lo = -1;
  for (var i = kfs.length - 1; i >= 0; i--) {
    if (kfs[i].time <= t && kfs[i].declaresChannel(ch) && get(kfs[i]) != null) {
      lo = i;
      break;
    }
  }

  int hi = -1;
  for (var i = 0; i < kfs.length; i++) {
    if (kfs[i].time > t && kfs[i].declaresChannel(ch) && get(kfs[i]) != null) {
      hi = i;
      break;
    }
  }

  if (lo == -1 && hi == -1) return null;
  if (lo == -1) return get(kfs[hi]);
  if (hi == -1) return get(kfs[lo]);

  final a = kfs[lo];
  final b = kfs[hi];
  final span = b.time - a.time;
  final frac = span <= 0 ? 1.0 : (t - a.time) / span;
  final eased = applyEasing(b.curve, frac);
  return lerp(get(a)!, get(b)!, eased);
}

/// Step-hold resolver for boolean channels (e.g. hidden). Returns the last
/// non-null value declared by a keyframe at or before [t], or null if none.
bool? _resolveStepBoolChannel(
  List<Keyframe> kfs,
  double t,
  String ch,
  bool? Function(Keyframe) get,
) {
  bool? val;
  for (final kf in kfs) {
    if (!kf.declaresChannel(ch)) continue;
    if (get(kf) == null) continue;
    if (kf.time <= t) val = get(kf);
    else break;
  }
  return val;
}

double? _lerpNullable(double? a, double? b, double t) {
  if (a == null && b == null) return null;
  if (a == null) return b;
  if (b == null) return a;
  return lerp(a, b, t);
}

/// Blends [from] → [to] by [t] in [0, 1], used during state transitions.
ResolvedElement blendResolved(ResolvedElement from, ResolvedElement to, double t) {
  return ResolvedElement(
    x: lerp(from.x, to.x, t),
    y: lerp(from.y, to.y, t),
    rotation: lerpAngleDeg(from.rotation, to.rotation, t),
    scaleX: lerp(from.scaleX, to.scaleX, t),
    scaleY: lerp(from.scaleY, to.scaleY, t),
    opacity: lerp(from.opacity, to.opacity, t),
    zIndex: _lerpNullable(from.zIndex, to.zIndex, t),
    pathProgress: _lerpNullable(from.pathProgress, to.pathProgress, t),
    strokeDashOffset:
        _lerpNullable(from.strokeDashOffset, to.strokeDashOffset, t),
    hidden: to.hidden ?? from.hidden,
    // Cross-state path-node morphing isn't supported — hold whichever side
    // has resolved nodes (prefer the destination once we're past t=0).
    nodePositions:
        t > 0 ? (to.nodePositions ?? from.nodePositions) : (from.nodePositions ?? to.nodePositions),
    pivotX: to.pivotX,
    pivotY: to.pivotY,
  );
}

// ────────────────────────────────────────────────────────────────────────
// Data binding mapping. Separate from the settle-state machinery in
// controller.dart so it's unit-testable without a ticker.
// ────────────────────────────────────────────────────────────────────────

/// Maps [raw] through a scalar binding's clamped linear mapping.
double mapScalar(DataBinding b, num raw) {
  final span = b.inMax - b.inMin;
  if (span == 0) return b.outMin;
  var t = (raw.toDouble() - b.inMin) / span;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return b.outMin + (b.outMax - b.outMin) * t;
}

/// Maps [raw] through a colour binding, lerping between [DataBinding.colorMinArgb]
/// and [colorMaxArgb]. Nulls fall back to black / white respectively.
Color mapColor(DataBinding b, num raw) {
  final span = b.inMax - b.inMin;
  final a = Color(b.colorMinArgb ?? 0xFF000000);
  final z = Color(b.colorMaxArgb ?? 0xFFFFFFFF);
  if (span == 0) return a;
  var t = (raw.toDouble() - b.inMin) / span;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return Color.lerp(a, z, t)!;
}
