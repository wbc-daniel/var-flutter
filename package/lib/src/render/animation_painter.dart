import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../engine/controller.dart';
import '../engine/property_resolver.dart';
import '../model/model.dart' as m;
import 'scene_node.dart';

class AnimationPainter extends CustomPainter {
  final VectorAnimateController controller;
  final BoxFit fit;

  AnimationPainter({
    required this.controller,
    required this.fit,
    // repaint: controller lets Flutter call markNeedsPaint() directly when the
    // controller notifies, bypassing the widget rebuild cycle entirely.
  }) : super(repaint: controller);

  m.VectorAnimation get _animation => controller.animation!;
  Map<String, ResolvedElement> get _resolved => controller.resolveAll();
  double get _fadeOpacity => controller.transitionInFadeOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    final vp = _animation.viewport;
    if (vp.backgroundArgb != null) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Color(vp.backgroundArgb!),
      );
    }

    if (vp.width <= 0 || vp.height <= 0) return;

    final resolved = _resolved;
    final fadeOpacity = _fadeOpacity;

    canvas.save();
    _applyFit(canvas, size, vp);
    canvas.clipRect(ui.Rect.fromLTWH(vp.x, vp.y, vp.width, vp.height));
    // Pass fadeOpacity as the inherited alpha rather than wrapping everything in
    // a saveLayer — avoids allocating a full-surface offscreen texture each frame.
    _paintNode(_animation.scene, canvas, resolved, fadeOpacity);
    canvas.restore();
  }

  /// Renders one frame at forced full opacity for warm-up.
  ///
  /// Uses `inheritedAlpha = 1.0` regardless of the animation's current
  /// fade-in state, so every path in the scene is drawn and Impeller can
  /// tessellate (and Skia can compile shaders for) all geometry before the
  /// first visible frame — even when the animation starts at opacity 0.
  void warmUpPaint(Canvas canvas, Size size) {
    final vp = _animation.viewport;
    if (vp.width <= 0 || vp.height <= 0) return;
    final resolved = _resolved;
    canvas.save();
    _applyFit(canvas, size, vp);
    canvas.clipRect(ui.Rect.fromLTWH(vp.x, vp.y, vp.width, vp.height));
    _paintNode(_animation.scene, canvas, resolved, 1.0);
    canvas.restore();
  }

  void _applyFit(Canvas canvas, Size size, m.Viewport vp) {
    final sx = size.width / vp.width;
    final sy = size.height / vp.height;
    double scaleX, scaleY, offsetX, offsetY;
    switch (fit) {
      case BoxFit.fill:
        scaleX = sx;
        scaleY = sy;
        offsetX = 0;
        offsetY = 0;
      case BoxFit.cover:
        final s = math.max(sx, sy);
        scaleX = scaleY = s;
        offsetX = (size.width - vp.width * s) / 2;
        offsetY = (size.height - vp.height * s) / 2;
      case BoxFit.fitWidth:
        scaleX = scaleY = sx;
        offsetX = 0;
        offsetY = (size.height - vp.height * sx) / 2;
      case BoxFit.fitHeight:
        scaleX = scaleY = sy;
        offsetX = (size.width - vp.width * sy) / 2;
        offsetY = 0;
      case BoxFit.scaleDown:
        final s = math.min(1.0, math.min(sx, sy));
        scaleX = scaleY = s;
        offsetX = (size.width - vp.width * s) / 2;
        offsetY = (size.height - vp.height * s) / 2;
      case BoxFit.none:
        scaleX = scaleY = 1.0;
        offsetX = (size.width - vp.width) / 2;
        offsetY = (size.height - vp.height) / 2;
      case BoxFit.contain:
        final s = math.min(sx, sy);
        scaleX = scaleY = s;
        offsetX = (size.width - vp.width * s) / 2;
        offsetY = (size.height - vp.height * s) / 2;
    }
    canvas.translate(offsetX, offsetY);
    canvas.scale(scaleX, scaleY);
    canvas.translate(-vp.x, -vp.y);
  }

  /// [inheritedAlpha] is the cumulative opacity from all ancestors. It is
  /// multiplied into this node's own opacity and the result is folded directly
  /// into every paint colour and gradient, with no saveLayer at any level.
  ///
  /// Tradeoff: overlapping children inside a partially-transparent group will
  /// composite individually rather than as a unit. In practice SVG animations
  /// from designer tools rarely exercise that case and the difference is
  /// imperceptible — this matches the web renderer's globalAlpha approach.
  void _paintNode(
    SceneNode node,
    Canvas canvas,
    Map<String, ResolvedElement> resolved,
    double inheritedAlpha,
  ) {
    // Keyframe-driven hidden: skip entire subtree before save/restore overhead.
    final anim = node.id != null ? resolved[node.id!] : null;
    if (anim?.hidden == true) return;

    canvas.save();

    // Clip mask: applied in the parent coordinate space, before this node's
    // own transforms.
    if (node.id != null) {
      final clipMaskId = _animation.elements[node.id!]?.clipMaskId;
      if (clipMaskId != null) {
        final maskNode = _animation.sceneIndex[clipMaskId];
        if (maskNode != null) {
          final maskPath = _buildMaskPath(maskNode, resolved[clipMaskId]);
          if (maskPath != null) canvas.clipPath(maskPath);
        }
      }
    }

    // Static clip-path: also in the parent coordinate space (SVG
    // clipPathUnits="userSpaceOnUse" default — coordinates are in the
    // referencing element's parent system, before its own transforms).
    if (node.clipPath != null) {
      canvas.clipPath(node.clipPath!);
    }

    if (anim != null) {
      canvas.translate(anim.pivotX + anim.x, anim.pivotY + anim.y);
      canvas.rotate(anim.rotation * math.pi / 180);
      canvas.scale(anim.scaleX, anim.scaleY);
      canvas.translate(-anim.pivotX, -anim.pivotY);
    }

    if (node.transform != null) {
      canvas.transform(node.transform!.storage);
    }

    final totalOpacity = (anim?.opacity ?? 1.0) * node.opacity * inheritedAlpha;
    if (totalOpacity <= 0) {
      canvas.restore();
      return;
    }

    if (node.geometry != null) {
      _drawGeometry(node, anim, canvas, totalOpacity);
    }

    _paintChildren(node.children, canvas, resolved, totalOpacity);

    canvas.restore();
  }

  Paint _buildPaint(
    SvgPaint paint,
    ui.Rect bounds,
    PaintingStyle style,
    SceneNode node,
    double alpha,
  ) {
    final p = Paint()
      ..style = style
      ..isAntiAlias = true;
    if (style == PaintingStyle.stroke) {
      p
        ..strokeWidth = node.strokeWidth
        ..strokeCap = node.strokeCap
        ..strokeJoin = node.strokeJoin;
    }
    switch (paint) {
      case SolidPaint(:final color):
        p.color = alpha < 1.0
            ? color.withAlpha((color.alpha * alpha).round())
            : color;
      case LinearGradientPaint():
        p.shader = _linearShader(paint, bounds);
        // colorFilter with BlendMode.modulate multiplies every pixel's alpha
        // (and premultiplied RGB) by alpha, applying opacity without saveLayer.
        if (alpha < 1.0) {
          p.colorFilter = ColorFilter.mode(
            Color.fromARGB((alpha * 255).round(), 255, 255, 255),
            BlendMode.modulate,
          );
        }
      case RadialGradientPaint():
        p.shader = _radialShader(paint, bounds);
        if (alpha < 1.0) {
          p.colorFilter = ColorFilter.mode(
            Color.fromARGB((alpha * 255).round(), 255, 255, 255),
            BlendMode.modulate,
          );
        }
    }
    return p;
  }

  void _drawGeometry(
    SceneNode node,
    ResolvedElement? anim,
    Canvas canvas,
    double alpha,
  ) {
    final bounds = node.geometryBounds!;
    final fillSrc = anim?.fillOverride != null
        ? SolidPaint(anim!.fillOverride!)
        : node.fill;
    final strokeSrc = anim?.strokeOverride != null
        ? SolidPaint(anim!.strokeOverride!)
        : node.stroke;
    // Geometry precedence:
    //   1. Animated nodePositions (per-frame path morphing) — overrides all.
    //   2. Pre-tessellated polyline baked at export time (option 4 in the
    //      designer's runtime-export modal) — bypasses Impeller's curve
    //      tessellation on first paint.
    //   3. Static SVG-derived path.
    final nodePositions = anim?.nodePositions;
    final el = node.id != null ? _animation.elements[node.id!] : null;
    final ui.Path geom;
    if (nodePositions != null && nodePositions.isNotEmpty) {
      geom = buildPathFromNodes(nodePositions);
    } else if (el?.polylinePath != null) {
      geom = el!.polylinePath!;
    } else {
      geom = node.geometry!;
    }
    if (fillSrc != null) {
      canvas.drawPath(
        geom,
        _buildPaint(fillSrc, bounds, PaintingStyle.fill, node, alpha),
      );
    }
    if (strokeSrc != null && node.strokeWidth > 0) {
      final strokePaint =
          _buildPaint(strokeSrc, bounds, PaintingStyle.stroke, node, alpha);
      if (node.strokeDashArray.isNotEmpty) {
        final offset = anim?.strokeDashOffset ?? node.strokeDashOffset;
        canvas.drawPath(
          dashPath(geom, node.strokeDashArray, offset),
          strokePaint,
        );
      } else {
        canvas.drawPath(geom, strokePaint);
      }
    }
  }

  ui.Shader _linearShader(LinearGradientPaint g, ui.Rect bounds) {
    final (start, end) = _mapLinearEndpoints(g, bounds);
    return ui.Gradient.linear(
      start,
      end,
      g.colors,
      g.stops,
      g.tileMode,
      g.gradientTransform?.storage,
    );
  }

  ui.Shader _radialShader(RadialGradientPaint g, ui.Rect bounds) {
    final (center, radius, focal) = _mapRadial(g, bounds);
    return ui.Gradient.radial(
      center,
      radius,
      g.colors,
      g.stops,
      g.tileMode,
      g.gradientTransform?.storage,
      focal,
      0.0,
    );
  }

  (ui.Offset, ui.Offset) _mapLinearEndpoints(
    LinearGradientPaint g,
    ui.Rect bounds,
  ) {
    if (!g.objectBoundingBox) return (g.start, g.end);
    ui.Offset map(ui.Offset o) => ui.Offset(
          bounds.left + o.dx * bounds.width,
          bounds.top + o.dy * bounds.height,
        );
    return (map(g.start), map(g.end));
  }

  (ui.Offset, double, ui.Offset?) _mapRadial(
    RadialGradientPaint g,
    ui.Rect bounds,
  ) {
    if (!g.objectBoundingBox) {
      return (g.center, g.radius, g.focal);
    }
    ui.Offset map(ui.Offset o) => ui.Offset(
          bounds.left + o.dx * bounds.width,
          bounds.top + o.dy * bounds.height,
        );
    final radius = math.max(bounds.width, bounds.height) * g.radius;
    return (map(g.center), radius, g.focal == null ? null : map(g.focal!));
  }

  Path? _buildMaskPath(SceneNode maskNode, ResolvedElement? anim) =>
      buildMaskPath(maskNode, anim);

  /// Paints [children] in z-order, forwarding [inheritedAlpha] to each child.
  void _paintChildren(
    List<SceneNode> children,
    Canvas canvas,
    Map<String, ResolvedElement> resolved,
    double inheritedAlpha,
  ) {
    if (children.isEmpty) return;

    bool needsSort = false;
    for (final child in children) {
      if (child.id != null && (resolved[child.id!]?.zIndex) != null) {
        needsSort = true;
        break;
      }
    }

    if (!needsSort) {
      for (final child in children) {
        _paintNode(child, canvas, resolved, inheritedAlpha);
      }
      return;
    }

    final indexed = <(double, SceneNode)>[
      for (var i = 0; i < children.length; i++)
        (
          children[i].id != null
              ? (resolved[children[i].id!]?.zIndex ?? i.toDouble())
              : i.toDouble(),
          children[i],
        ),
    ];
    indexed.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, child) in indexed) {
      _paintNode(child, canvas, resolved, inheritedAlpha);
    }
  }

  @override
  bool shouldRepaint(covariant AnimationPainter oldDelegate) =>
      controller != oldDelegate.controller || fit != oldDelegate.fit;
}

/// Builds the clip region for an element whose `clipMaskId` references
/// [maskNode]. Walks the entire mask subtree so masks rooted on a `<g>`
/// ("group" animated element with no own geometry) clip against the union
/// of their descendant shapes.
///
/// Returns null when the subtree contributes no geometry — the caller
/// treats that as "no clip" rather than "clip everything out".
///
/// Exposed at top level so tests can assert the resulting clip region
/// without needing a CustomPainter render harness.
Path? buildMaskPath(SceneNode maskNode, ResolvedElement? anim) {
  final result = Path();
  final root = Matrix4.identity();
  if (anim != null) {
    root
      ..multiply(Matrix4.translationValues(
        anim.pivotX + anim.x, anim.pivotY + anim.y, 0,
      ))
      ..multiply(Matrix4.rotationZ(anim.rotation * math.pi / 180))
      ..multiply(Matrix4.diagonal3Values(anim.scaleX, anim.scaleY, 1.0))
      ..multiply(Matrix4.translationValues(-anim.pivotX, -anim.pivotY, 0));
  }
  var added = 0;
  void walk(SceneNode node, Matrix4 parentTransform) {
    final combined = node.transform != null
        ? (Matrix4.identity()
          ..multiply(parentTransform)
          ..multiply(node.transform!))
        : parentTransform;
    if (node.geometry != null) {
      result.addPath(node.geometry!.transform(combined.storage), Offset.zero);
      added++;
    }
    for (final child in node.children) {
      walk(child, combined);
    }
  }
  walk(maskNode, root);
  return added > 0 ? result : null;
}

/// Builds a dashed copy of [src] using SVG dash semantics.
///
/// Walks each contour of [src] via `computeMetrics`, alternating "dash" and
/// "gap" lengths drawn from [dashArray]. The pattern repeats and is shifted
/// by [dashOffset] (positive offsets advance the dashes forward along the
/// path, matching the visual effect of `stroke-dashoffset` increasing).
///
/// **Closed vs. open contours.** For closed contours (rect, circle, polygon,
/// `<path>` ending in Z) the start position is rotated by `dashOffset` so the
/// pattern is laid out contiguously around the loop, with dashes that cross
/// the path-start seam emitted as two sub-paths that meet flush at the seam
/// point. Without this, animating offset on a closed shape resets the pattern
/// at the seam each cycle and the first dash visibly clips short. Open
/// contours keep the original semantics: offset shifts the pattern, the first
/// visible dash is whatever portion lies inside `[0, contourLen]`.
///
/// Each emitted dash is its own sub-path, so the host's `Paint.strokeCap`
/// applies at every dash boundary — round caps produce capsule-shaped dashes
/// (or perfect dots when the dash length is zero), matching SVG/Canvas.
ui.Path dashPath(
  ui.Path src,
  List<double> dashArray,
  double dashOffset,
) {
  double rawCycle = 0;
  for (final v in dashArray) {
    rawCycle += v;
  }
  if (rawCycle <= 0) return src;

  final out = ui.Path();
  for (final metric in src.computeMetrics()) {
    final contourLen = metric.length;
    if (contourLen <= 0) continue;

    if (metric.isClosed) {
      // For closed contours, fit cycle * N to the contour length so the
      // pattern tiles cleanly across the seam.
      final n = math.max(1, (contourLen / rawCycle).round());
      final scale = contourLen / (n * rawCycle);
      final scaledDash = [for (final v in dashArray) v * scale];
      final scaledCycle = rawCycle * scale;
      double off = (dashOffset * scale) % scaledCycle;
      if (off < 0) off += scaledCycle;
      _dashClosedContour(out, metric, contourLen, scaledDash, off);
    } else {
      double off = dashOffset % rawCycle;
      if (off < 0) off += rawCycle;
      _dashOpenContour(out, metric, contourLen, dashArray, off);
    }
  }
  return out;
}

void _dashOpenContour(
  ui.Path out,
  ui.PathMetric metric,
  double contourLen,
  List<double> dashArray,
  double off,
) {
  int idx = 0;
  double remaining = off;
  while (remaining >= dashArray[idx]) {
    remaining -= dashArray[idx];
    idx = (idx + 1) % dashArray.length;
  }
  bool drawing = idx.isEven;
  double segLen = dashArray[idx] - remaining;

  double cursor = 0;
  while (cursor < contourLen) {
    final end = cursor + segLen;
    final clipped = end > contourLen ? contourLen : end;
    if (drawing) {
      _emitDashRange(out, metric, cursor, clipped);
    }
    cursor = clipped;
    if (end <= contourLen) {
      idx = (idx + 1) % dashArray.length;
      drawing = !drawing;
      segLen = dashArray[idx];
    }
  }
}

void _dashClosedContour(
  ui.Path out,
  ui.PathMetric metric,
  double contourLen,
  List<double> dashArray,
  double off,
) {
  double cursor = (contourLen - off) % contourLen;
  if (cursor < 0) cursor += contourLen;

  double remaining = contourLen;
  int idx = 0;
  while (remaining > 1e-6) {
    double segLen = dashArray[idx];
    if (segLen > remaining) segLen = remaining;
    final endCursor = cursor + segLen;

    if (idx.isEven) {
      if (segLen <= 0) {
        _emitDot(out, metric, cursor % contourLen);
      } else if (endCursor <= contourLen) {
        _emitDashRange(out, metric, cursor, endCursor);
      } else {
        _emitDashRange(out, metric, cursor, contourLen);
        _emitDashRange(out, metric, 0, endCursor - contourLen);
      }
    }

    cursor = endCursor >= contourLen ? endCursor - contourLen : endCursor;
    remaining -= segLen;
    idx = (idx + 1) % dashArray.length;
  }
}

void _emitDashRange(
  ui.Path out,
  ui.PathMetric metric,
  double start,
  double end,
) {
  if (end > start) {
    out.addPath(metric.extractPath(start, end), Offset.zero);
  } else {
    _emitDot(out, metric, start);
  }
}

void _emitDot(ui.Path out, ui.PathMetric metric, double position) {
  final tan = metric.getTangentForOffset(position);
  if (tan != null) {
    out.moveTo(tan.position.dx, tan.position.dy);
    out.lineTo(tan.position.dx, tan.position.dy);
  }
}

/// Builds a [ui.Path] directly from animated path-node positions. Iteration
/// order of [nodes] defines the traversal — entries flagged `isMove` (or the
/// very first entry) start a new sub-path; otherwise we emit a line or cubic
/// bezier depending on whether either endpoint carries control points. A
/// `close` flag emits the closing-bezier-then-Z pair so the contour rejoins
/// its starting anchor without a visible seam.
ui.Path buildPathFromNodes(Map<String, m.NodePos> nodes) {
  final path = ui.Path();
  m.NodePos? prev;
  m.NodePos? contourStart;
  var first = true;
  for (final node in nodes.values) {
    if (first || node.isMove) {
      path.moveTo(node.x, node.y);
      contourStart = node;
      prev = node;
      first = false;
      continue;
    }
    if (prev != null) {
      final cpOut = prev.cpOut;
      final cpIn = node.cpIn;
      if (cpOut != null || cpIn != null) {
        path.cubicTo(
          cpOut?.x ?? prev.x, cpOut?.y ?? prev.y,
          cpIn?.x  ?? node.x, cpIn?.y  ?? node.y,
          node.x, node.y,
        );
      } else {
        path.lineTo(node.x, node.y);
      }
    }
    if (node.close && contourStart != null) {
      // Mirrors the editor's nodesToPathD: if either endpoint of the closing
      // segment carries a control point, emit it as a bezier so the closing
      // curve matches the original path's seam.
      final closeCpOut = node.cpOut;
      final closeCpIn = contourStart.cpIn;
      if (closeCpOut != null || closeCpIn != null) {
        path.cubicTo(
          closeCpOut?.x ?? node.x,         closeCpOut?.y ?? node.y,
          closeCpIn?.x  ?? contourStart.x, closeCpIn?.y  ?? contourStart.y,
          contourStart.x, contourStart.y,
        );
      }
      path.close();
      contourStart = null;
    }
    prev = node;
  }
  return path;
}
