import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../loader/var_loader.dart';
import '../model/model.dart';
import 'easing.dart';
import 'property_resolver.dart';

enum PlaybackMode { loop, oneShot, pingPong }

class StateChangeEvent {
  final String from;
  final String to;
  const StateChangeEvent({required this.from, required this.to});

  @override
  String toString() => 'StateChangeEvent($from → $to)';
}

/// Mutable playback state for a [VectorAnimation].
///
/// Create with a named constructor to load from an asset, bytes, or JSON.
/// The animation loads asynchronously; the widget shows a loading state until
/// [isLoaded] becomes true.
///
/// ```dart
/// VectorAnimateController.fromAsset('assets/card.var')
/// VectorAnimateController.fromAsset('assets/card.var.json')
/// VectorAnimateController.fromBytes(bytes)
/// VectorAnimateController.fromJson(jsonMap)
/// VectorAnimateController.fromJsonString(rawString)
/// VectorAnimateController(animation: alreadyParsed)
/// ```
class VectorAnimateController extends ChangeNotifier {
  /// Constructs a controller from an already-parsed [VectorAnimation].
  VectorAnimateController({
    required VectorAnimation animation,
    String? initialState,
    this.mode = PlaybackMode.loop,
    this.speed = 1.0,
    bool autoplay = true,
  }) : _pendingInitialState = initialState,
       _isPlaying = autoplay {
    _onAnimationLoaded(animation);
  }

  /// Private constructor used by the async named constructors.
  VectorAnimateController._pending({
    String? initialState,
    this.mode = PlaybackMode.loop,
    this.speed = 1.0,
    bool autoplay = true,
  }) : _pendingInitialState = initialState,
       _isPlaying = autoplay;

  factory VectorAnimateController.fromAsset(
    String key, {
    String? package,
    String? initialState,
    PlaybackMode mode = PlaybackMode.loop,
    double speed = 1.0,
    bool autoplay = true,
  }) {
    final c = VectorAnimateController._pending(
      initialState: initialState,
      mode: mode,
      speed: speed,
      autoplay: autoplay,
    );
    loadVarAsset(key, package: package).then(c._onAnimationLoaded);
    return c;
  }

  factory VectorAnimateController.fromBytes(
    List<int> bytes, {
    String? initialState,
    PlaybackMode mode = PlaybackMode.loop,
    double speed = 1.0,
    bool autoplay = true,
  }) {
    final c = VectorAnimateController._pending(
      initialState: initialState,
      mode: mode,
      speed: speed,
      autoplay: autoplay,
    );
    Future.value(parseVarBytes(bytes)).then(c._onAnimationLoaded);
    return c;
  }

  factory VectorAnimateController.fromJson(
    Map<String, dynamic> json, {
    String? initialState,
    PlaybackMode mode = PlaybackMode.loop,
    double speed = 1.0,
    bool autoplay = true,
  }) {
    final c = VectorAnimateController._pending(
      initialState: initialState,
      mode: mode,
      speed: speed,
      autoplay: autoplay,
    );
    Future.value(parseVarJson(json)).then(c._onAnimationLoaded);
    return c;
  }

  factory VectorAnimateController.fromJsonString(
    String raw, {
    String? initialState,
    PlaybackMode mode = PlaybackMode.loop,
    double speed = 1.0,
    bool autoplay = true,
  }) {
    final c = VectorAnimateController._pending(
      initialState: initialState,
      mode: mode,
      speed: speed,
      autoplay: autoplay,
    );
    Future.value(parseVarJsonString(raw)).then(c._onAnimationLoaded);
    return c;
  }

  // ── fields ────────────────────────────────────────────────────────────────

  final String? _pendingInitialState;
  VectorAnimation? _animation;

  PlaybackMode mode;
  double speed;

  String _currentState = '';
  double _stateTimeMs = 0;
  bool _isPlaying;
  int _direction = 1;

  double _wallClockMs = 0;

  // ── transition state ──
  bool _inTransition = false;
  double _transitionElapsedMs = 0;
  double _transitionMaxDurationMs = 0;
  Map<String, ResolvedElement> _snapshot = {};
  StateTransition? _activeTransition;

  // ── transitionIn-fade state ──
  bool _transitionInFade = false;
  double _transitionInFadeDurationMs = 0;

  // ── data binding state ──
  final Map<String, num> _dataValues = {};
  final Map<String, _BindingRtState> _bindingState = {};
  bool _bindingDirty = false;

  final _stateChangeCtl = StreamController<StateChangeEvent>.broadcast();
  final _stateTransitionEndCtl = StreamController<StateChangeEvent>.broadcast();

  Stream<StateChangeEvent> get onStateChange => _stateChangeCtl.stream;
  Stream<StateChangeEvent> get onStateTransitionEnd =>
      _stateTransitionEndCtl.stream;

  // ── public read-only surface ──
  VectorAnimation? get animation => _animation;
  bool get isLoaded => _animation != null;
  String get currentState => _currentState;
  List<String> get states => _animation?.states ?? const [];
  bool get isPlaying => _isPlaying;
  bool get isInTransition => _inTransition;

  double get transitionInFadeOpacity {
    if (!_transitionInFade || !_inTransition) return 1.0;
    if (_transitionInFadeDurationMs <= 0) return 1.0;
    return (_transitionElapsedMs / _transitionInFadeDurationMs).clamp(0.0, 1.0);
  }

  Duration get position =>
      Duration(microseconds: (_stateTimeMs * 1000).round());

  // ── internal init ─────────────────────────────────────────────────────────

  void _onAnimationLoaded(VectorAnimation animation) {
    _animation = animation;
    _currentState = _pendingInitialState ?? animation.defaultState;
    if (!animation.states.contains(_currentState) &&
        animation.states.isNotEmpty) {
      _currentState = animation.states.first;
    }
    _stateTimeMs = animation.stateConfigs[_currentState]?.windowIn ?? 0;
    notifyListeners();
  }

  // ── controls ──────────────────────────────────────────────────────────────

  void play() {
    if (_isPlaying) return;
    _isPlaying = true;
    notifyListeners();
  }

  void pause() {
    if (!_isPlaying) return;
    _isPlaying = false;
    notifyListeners();
  }

  void stop() {
    _isPlaying = false;
    _stateTimeMs = _animation?.stateConfigs[_currentState]?.windowIn ?? 0;
    _direction = 1;
    notifyListeners();
  }

  void seekTo(Duration position) {
    _stateTimeMs = position.inMicroseconds / 1000.0;
    final cfg = _animation?.stateConfigs[_currentState];
    if (cfg != null) {
      if (_stateTimeMs < cfg.windowIn) _stateTimeMs = cfg.windowIn;
      if (_stateTimeMs > cfg.windowOut) _stateTimeMs = cfg.windowOut;
    }
    notifyListeners();
  }

  void setState(String targetState) {
    final anim = _animation;
    if (anim == null) return;
    if (!anim.states.contains(targetState)) {
      throw ArgumentError(
        'unknown state "$targetState" (known: ${anim.states})',
      );
    }
    if (targetState == _currentState && !_inTransition) return;

    _snapshot = resolveAll();

    final from = _currentState;
    _currentState = targetState;
    _stateTimeMs = anim.stateConfigs[targetState]?.windowIn ?? 0;
    _direction = 1;

    final transitionIn = anim.stateConfigs[targetState]?.transitionIn;
    _transitionInFade = transitionIn?.type == TransitionInType.fade;
    _transitionInFadeDurationMs = transitionIn?.duration ?? 300;

    if (_transitionInFade) {
      _activeTransition = null;
      _transitionMaxDurationMs = _transitionInFadeDurationMs;
    } else {
      _activeTransition = anim.findTransition(from, targetState);
      final globalDur =
          _activeTransition?.duration ?? anim.defaultTransition.duration;
      var maxEnd = globalDur;
      if (_activeTransition != null) {
        for (final ov in _activeTransition!.elements.values) {
          final end = ov.delay + (ov.duration ?? globalDur);
          if (end > maxEnd) maxEnd = end;
        }
      }
      _transitionMaxDurationMs = maxEnd;
    }
    _transitionElapsedMs = 0;
    _inTransition = _transitionMaxDurationMs > 0;

    _stateChangeCtl.add(StateChangeEvent(from: from, to: targetState));
    notifyListeners();
  }

  // ── data binding API ──────────────────────────────────────────────────────

  void setData(String key, num value) {
    _setDataKey(key, value);
    _bindingDirty = true;
    notifyListeners();
  }

  void setDataMap(Map<String, num> values) {
    if (values.isEmpty) return;
    for (final e in values.entries) {
      _setDataKey(e.key, e.value);
    }
    _bindingDirty = true;
    notifyListeners();
  }

  void clearData(String key) {
    final removed = _dataValues.remove(key) != null;
    if (removed) {
      final anim = _animation;
      if (anim != null) {
        for (final el in anim.elements.values) {
          for (final b in el.dataBindings) {
            if (b.dataKey == key) _bindingState.remove(b.id);
          }
        }
      }
      _bindingDirty = true;
      notifyListeners();
    }
  }

  num? getData(String key) => _dataValues[key];
  Iterable<String> get dataKeys => _dataValues.keys;

  Set<String> get declaredDataKeys {
    final keys = <String>{};
    final anim = _animation;
    if (anim == null) return keys;
    for (final el in anim.elements.values) {
      for (final b in el.dataBindings) { keys.add(b.dataKey); }
    }
    return keys;
  }

  // ── Exploration API ───────────────────────────────────────────────────────

  List<StateInfo> listStates() {
    final anim = _animation;
    if (anim == null) return const [];
    final out = <StateInfo>[];
    for (final name in anim.states) {
      final cfg = anim.stateConfigs[name];
      var elementCount = 0;
      for (final el in anim.elements.values) {
        if (el.animations.containsKey(name)) elementCount++;
      }
      out.add(StateInfo(
        name: name,
        duration: cfg?.duration ?? 0,
        windowIn: cfg?.windowIn ?? 0,
        windowOut: cfg?.windowOut ?? 0,
        transitionInType: cfg?.transitionIn.type ?? TransitionInType.animate,
        transitionInDuration: cfg?.transitionIn.duration ?? 0,
        isDefault: name == anim.defaultState,
        isCurrent: name == _currentState,
        elementCount: elementCount,
      ));
    }
    return out;
  }

  StateInfo? getStateInfo(String name) {
    for (final s in listStates()) {
      if (s.name == name) return s;
    }
    return null;
  }

  List<DataBindingInfo> listBindings() {
    final anim = _animation;
    if (anim == null) return const [];
    final out = <DataBindingInfo>[];
    for (final elementId in anim.elementOrder) {
      final el = anim.elements[elementId];
      if (el == null) continue;
      for (final b in el.dataBindings) {
        out.add(_toBindingInfo(b, elementId));
      }
    }
    return out;
  }

  List<DataKeyInfo> listDataKeys() {
    final byKey = <String, List<DataBindingInfo>>{};
    final order = <String>[];
    for (final info in listBindings()) {
      final bucket = byKey.putIfAbsent(info.dataKey, () {
        order.add(info.dataKey);
        return <DataBindingInfo>[];
      });
      bucket.add(info);
    }
    return [
      for (final key in order)
        DataKeyInfo(
          dataKey: key,
          bindings: byKey[key]!,
          currentValue: _dataValues[key],
        ),
    ];
  }

  static DataBindingInfo _toBindingInfo(DataBinding b, String elementId) {
    return DataBindingInfo(
      id: b.id,
      elementId: elementId,
      dataKey: b.dataKey,
      property: b.property,
      inMin: b.inMin,
      inMax: b.inMax,
      outMin: b.outMin,
      outMax: b.outMax,
      colorMinArgb: b.colorMinArgb,
      colorMaxArgb: b.colorMaxArgb,
      settlingMs: b.settlingMs,
      curve: b.curve,
    );
  }

  // ── internals ─────────────────────────────────────────────────────────────

  void _setDataKey(String key, num value) {
    final prev = _dataValues[key];
    _dataValues[key] = value;
    final anim = _animation;
    if (anim == null) return;
    for (final el in anim.elements.values) {
      for (final b in el.dataBindings) {
        if (b.dataKey != key) continue;
        final state = _bindingState[b.id];
        if (state == null || state.lastRaw != value || prev == null) {
          _retargetBinding(b, value);
        }
      }
    }
  }

  void _retargetBinding(DataBinding b, num raw) {
    final prevState = _bindingState[b.id];
    final current = prevState != null
        ? _evalBindingCurrent(b, prevState, _wallClockMs)
        : _evalBinding(b, raw);
    _bindingState[b.id] = _BindingRtState(
      startValue: current,
      targetValue: _evalBinding(b, raw),
      startTsMs: _wallClockMs,
      settlingMs: b.settlingMs < 0 ? 0 : b.settlingMs,
      curve: b.curve,
      lastRaw: raw,
    );
  }

  Object _evalBinding(DataBinding b, num raw) {
    return b.property.isColor ? mapColor(b, raw) : mapScalar(b, raw);
  }

  Object _evalBindingCurrent(DataBinding b, _BindingRtState state, double now) {
    final elapsed = now - state.startTsMs;
    if (state.settlingMs <= 0 || elapsed >= state.settlingMs) {
      return state.targetValue;
    }
    var t = elapsed / state.settlingMs;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final eased = applyEasing(state.curve, t);
    if (b.property.isColor) {
      return Color.lerp(
        state.startValue as Color,
        state.targetValue as Color,
        eased,
      )!;
    }
    final from = (state.startValue as num).toDouble();
    final to = (state.targetValue as num).toDouble();
    return from + (to - from) * eased;
  }

  bool _anyBindingSettling() {
    for (final s in _bindingState.values) {
      if (s.settlingMs <= 0) continue;
      if (_wallClockMs - s.startTsMs < s.settlingMs) return true;
    }
    return false;
  }

  void advance(double dtMs) {
    if (dtMs <= 0) return;
    _wallClockMs += dtMs;

    final bindingActive = _anyBindingSettling();
    var repaint = _isPlaying || bindingActive || _bindingDirty;

    if (_isPlaying && _animation != null) {
      _advanceStateClock(dtMs);
      if (_inTransition) {
        _transitionElapsedMs += dtMs * speed;
        if (_transitionElapsedMs >= _transitionMaxDurationMs) {
          final from = _activeTransition?.from;
          final to = _currentState;
          _inTransition = false;
          _transitionInFade = false;
          _snapshot = {};
          if (from != null) {
            _stateTransitionEndCtl.add(StateChangeEvent(from: from, to: to));
          }
        }
      }
    }

    if (repaint) {
      _bindingDirty = false;
      notifyListeners();
    }
  }

  void _advanceStateClock(double dtMs) {
    final cfg = _animation?.stateConfigs[_currentState];
    if (cfg == null) return;
    final span = cfg.windowOut - cfg.windowIn;
    if (span <= 0) {
      _stateTimeMs = cfg.windowIn;
      return;
    }
    var t = _stateTimeMs + dtMs * speed * _direction;
    switch (mode) {
      case PlaybackMode.loop:
        var u = (t - cfg.windowIn) % span;
        if (u < 0) u += span;
        _stateTimeMs = cfg.windowIn + u;
      case PlaybackMode.oneShot:
        if (t <= cfg.windowIn) {
          _stateTimeMs = cfg.windowIn;
        } else if (t >= cfg.windowOut) {
          _stateTimeMs = cfg.windowOut;
          _isPlaying = false;
        } else {
          _stateTimeMs = t;
        }
      case PlaybackMode.pingPong:
        var remaining = dtMs * speed;
        while (remaining > 0) {
          final boundary = _direction > 0 ? cfg.windowOut : cfg.windowIn;
          final distance = (boundary - _stateTimeMs) * _direction;
          if (remaining < distance) {
            _stateTimeMs += remaining * _direction;
            remaining = 0;
          } else {
            _stateTimeMs = boundary;
            remaining -= distance;
            _direction = -_direction;
          }
        }
    }
  }

  Map<String, ResolvedElement> resolveAll() {
    final anim = _animation;
    if (anim == null) return const {};
    final out = <String, ResolvedElement>{};
    for (final id in anim.elementOrder) {
      final el = anim.elements[id];
      if (el == null) continue;
      out[id] = _resolveOne(el);
    }
    return out;
  }

  ResolvedElement _resolveOne(AnimatedElement el) {
    var base = resolveElement(el, _currentState, _stateTimeMs);
    if (_inTransition) base = _applyTransition(base, el);
    if (el.dataBindings.isNotEmpty) base = _applyBindings(base, el);
    return base;
  }

  ResolvedElement _applyTransition(ResolvedElement target, AnimatedElement el) {
    if (_transitionInFade) return target;

    final anim = _animation!;
    final globalDur =
        _activeTransition?.duration ?? anim.defaultTransition.duration;
    final globalCurve =
        _activeTransition?.curve ?? anim.defaultTransition.curve;
    final ov = _activeTransition?.elements[el.id];
    final delay = ov?.delay ?? 0;
    final duration = ov?.duration ?? globalDur;
    final curve = ov?.curve ?? globalCurve;

    final elapsed = _transitionElapsedMs - delay;
    if (elapsed <= 0) {
      return _snapshot[el.id] ?? ResolvedElement.identityFor(el);
    }
    if (duration <= 0) return target;
    final p = (elapsed / duration).clamp(0.0, 1.0);
    final eased = applyEasing(curve, p);
    if (eased >= 1.0) return target;
    final from = _snapshot[el.id] ?? ResolvedElement.identityFor(el);
    return blendResolved(from, target, eased);
  }

  ResolvedElement _applyBindings(ResolvedElement base, AnimatedElement el) {
    var x = base.x,
        y = base.y,
        rot = base.rotation,
        sx = base.scaleX,
        sy = base.scaleY,
        op = base.opacity;
    Color? fillOv = base.fillOverride;
    Color? strokeOv = base.strokeOverride;
    double? dashOffset = base.strokeDashOffset;

    for (final b in el.dataBindings) {
      if (!_dataValues.containsKey(b.dataKey)) continue;
      final state = _bindingState[b.id];
      final value = state != null
          ? _evalBindingCurrent(b, state, _wallClockMs)
          : _evalBinding(b, _dataValues[b.dataKey]!);

      switch (b.property) {
        case BoundProperty.x:
          x = (value as num).toDouble();
        case BoundProperty.y:
          y = (value as num).toDouble();
        case BoundProperty.rotation:
          rot = (value as num).toDouble();
        case BoundProperty.scaleX:
          sx = (value as num).toDouble();
        case BoundProperty.scaleY:
          sy = (value as num).toDouble();
        case BoundProperty.opacity:
          op = (value as num).toDouble();
        case BoundProperty.fill:
          fillOv = value as Color;
        case BoundProperty.stroke:
          strokeOv = value as Color;
        case BoundProperty.strokeDashOffset:
          dashOffset = (value as num).toDouble();
      }
    }

    return base.copyWith(
      x: x,
      y: y,
      rotation: rot,
      scaleX: sx,
      scaleY: sy,
      opacity: op,
      fillOverride: fillOv,
      strokeOverride: strokeOv,
      strokeDashOffset: dashOffset,
    );
  }

  @override
  void dispose() {
    _stateChangeCtl.close();
    _stateTransitionEndCtl.close();
    super.dispose();
  }
}

class _BindingRtState {
  final Object startValue;
  final Object targetValue;
  final double startTsMs;
  final double settlingMs;
  final EasingCurve curve;
  final num lastRaw;

  _BindingRtState({
    required this.startValue,
    required this.targetValue,
    required this.startTsMs,
    required this.settlingMs,
    required this.curve,
    required this.lastRaw,
  });
}
