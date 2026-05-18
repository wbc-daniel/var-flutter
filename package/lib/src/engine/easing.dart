import 'dart:math' as math;

import '../model/model.dart';

/// Applies [curve] to a normalised progress value [t] in [0, 1].
///
/// Curves match the JS authoring tool's `interpolation.js`. Input is clamped;
/// output may overshoot [0, 1] (bounce/elastic/back by design).
double applyEasing(EasingCurve curve, double t) {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  switch (curve) {
    case EasingCurve.linear:
      return t;
    case EasingCurve.easeIn:
      return t * t * t;
    case EasingCurve.easeOut:
      final u = 1 - t;
      return 1 - u * u * u;
    case EasingCurve.easeInOut:
      return t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
    case EasingCurve.easeInOutBack:
      const c1 = 1.70158;
      const c2 = c1 * 1.525;
      return t < 0.5
          ? (math.pow(2 * t, 2) * ((c2 + 1) * 2 * t - c2)) / 2
          : (math.pow(2 * t - 2, 2) * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2;
    case EasingCurve.step:
      return t < 1 ? 0 : 1;
    case EasingCurve.bounceOut:
      return _bounceOut(t);
    case EasingCurve.bounceIn:
      return 1 - _bounceOut(1 - t);
    case EasingCurve.elasticOut:
      const c4 = (2 * math.pi) / 3;
      return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * c4) + 1;
    case EasingCurve.elasticIn:
      const c4 = (2 * math.pi) / 3;
      return -math.pow(2, 10 * t - 10) * math.sin((t * 10 - 10.75) * c4);
  }
}

double _bounceOut(double t) {
  const n1 = 7.5625;
  const d1 = 2.75;
  if (t < 1 / d1) {
    return n1 * t * t;
  } else if (t < 2 / d1) {
    final u = t - 1.5 / d1;
    return n1 * u * u + 0.75;
  } else if (t < 2.5 / d1) {
    final u = t - 2.25 / d1;
    return n1 * u * u + 0.9375;
  } else {
    final u = t - 2.625 / d1;
    return n1 * u * u + 0.984375;
  }
}

/// Shortest-path linear interpolation of angles in degrees.
/// Prevents the long-way-around behaviour when crossing the 180/-180 boundary.
double lerpAngleDeg(double a, double b, double t) {
  var delta = ((b - a) % 360 + 540) % 360 - 180;
  return a + delta * t;
}

double lerp(double a, double b, double t) => a + (b - a) * t;
