import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

/// A parsed SVG element in the static scene graph.
///
/// Animation is layered on top of this at paint time: the painter looks up
/// [id] in the runtime transform map to decide whether to apply a
/// pivot-relative transform before drawing [geometry].
class SceneNode {
  final String? id;
  final String tagName;

  /// null for container-only nodes (`<g>`, `<svg>`).
  final ui.Path? geometry;

  /// Already resolved through SVG inheritance. null = no fill.
  final SvgPaint? fill;

  /// Already resolved through SVG inheritance. null = no stroke.
  final SvgPaint? stroke;
  final double strokeWidth;
  final StrokeCap strokeCap;
  final StrokeJoin strokeJoin;

  /// SVG `stroke-dasharray` parsed into a list of non-negative lengths.
  /// Empty = solid stroke. Combined with `strokeCap == StrokeCap.round`,
  /// an array like `[0, 12]` produces a dotted line of round dots.
  final List<double> strokeDashArray;

  /// Static `stroke-dashoffset` from the SVG attribute. Used when no animated
  /// value is supplied. Defaults to 0.
  final double strokeDashOffset;

  /// Static SVG `transform` attribute on this node, if any.
  final Matrix4? transform;

  /// Static per-element opacity from the SVG source (not the animated value).
  final double opacity;

  /// `clip-path="url(#id)"` resolved to a concrete path, if any.
  final ui.Path? clipPath;

  final List<SceneNode> children;

  SceneNode({
    this.id,
    required this.tagName,
    this.geometry,
    this.fill,
    this.stroke,
    this.strokeWidth = 1.0,
    this.strokeCap = StrokeCap.butt,
    this.strokeJoin = StrokeJoin.miter,
    this.strokeDashArray = const [],
    this.strokeDashOffset = 0.0,
    this.transform,
    this.opacity = 1.0,
    this.clipPath,
    this.children = const [],
  });

  /// Bounding box of [geometry], cached on first access.
  /// Null when [geometry] is null (container-only nodes).
  ui.Rect? get geometryBounds => _geometryBounds ??= geometry?.getBounds();
  ui.Rect? _geometryBounds;
}

// ────────────────────────────────────────────────────────────────────────
// Paint sources: solid colour or gradient.
// ────────────────────────────────────────────────────────────────────────

sealed class SvgPaint {
  const SvgPaint();
}

class SolidPaint extends SvgPaint {
  final Color color;
  const SolidPaint(this.color);
}

/// SVG `<linearGradient>`. Coordinates are in the space indicated by
/// [objectBoundingBox]: if true, [start]/[end] are in 0..1 of the filled
/// element's bounding box; otherwise they are user-space SVG coordinates.
class LinearGradientPaint extends SvgPaint {
  final Offset start;
  final Offset end;
  final List<Color> colors;
  final List<double> stops;
  final TileMode tileMode;
  final bool objectBoundingBox;
  final Matrix4? gradientTransform;

  const LinearGradientPaint({
    required this.start,
    required this.end,
    required this.colors,
    required this.stops,
    required this.tileMode,
    required this.objectBoundingBox,
    required this.gradientTransform,
  });
}

/// SVG `<radialGradient>`.
class RadialGradientPaint extends SvgPaint {
  final Offset center;
  final double radius;

  /// Focal point. Defaults to [center] if null.
  final Offset? focal;
  final List<Color> colors;
  final List<double> stops;
  final TileMode tileMode;
  final bool objectBoundingBox;
  final Matrix4? gradientTransform;

  const RadialGradientPaint({
    required this.center,
    required this.radius,
    required this.focal,
    required this.colors,
    required this.stops,
    required this.tileMode,
    required this.objectBoundingBox,
    required this.gradientTransform,
  });
}
