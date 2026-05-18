import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;
import 'package:xml/xml.dart';

import '../render/scene_node.dart';
import 'path_parser.dart';

/// Parses [svgRaw] (the contents of the `svgRaw` field in a .vaj.json file)
/// into a [SceneNode] tree. Unsupported elements/attributes produce entries
/// in [warnings] rather than throwing.
class SvgParseResult {
  final SceneNode root;
  final List<String> warnings;
  const SvgParseResult(this.root, this.warnings);
}

SvgParseResult parseSvg(String svgRaw) {
  final warnings = <String>[];
  final doc = XmlDocument.parse(svgRaw);
  final rootEl = doc.rootElement;
  if (rootEl.localName != 'svg') {
    warnings.add('expected root <svg>, got <${rootEl.localName}>');
  }

  // Build the id → element map before the main walk so url(#id) references
  // and <use href="#id"> resolve regardless of document order.
  final idIndex = <String, XmlElement>{};
  _buildIdIndex(rootEl, idIndex);

  // Collect class-selector rules from any <style> blocks so elements that
  // style their fill/stroke via `class="cls-X"` (Inkscape/Illustrator output)
  // resolve correctly. Without this, classed elements fall through to the
  // inherited black default and the artwork renders as solid black blobs.
  final classRules = _collectClassRules(rootEl);
  final ctx = _ParseContext(idIndex, warnings, classRules);

  final root = _parseElement(rootEl, _Inherited.initial(), ctx);
  return SvgParseResult(root, warnings);
}

void _buildIdIndex(XmlElement el, Map<String, XmlElement> out) {
  final id = el.getAttribute('id');
  if (id != null) out[id] = el;
  for (final child in el.childElements) {
    _buildIdIndex(child, out);
  }
}

class _ParseContext {
  final Map<String, XmlElement> idIndex;
  final List<String> warnings;
  /// className → declarations (lowercased property → raw value).
  final Map<String, Map<String, String>> classRules;
  _ParseContext(this.idIndex, this.warnings, this.classRules);
}

// ────────────────────────────────────────────────────────────────────────
// CSS <style> block collection.
// ────────────────────────────────────────────────────────────────────────

/// Walks the tree gathering text from every <style> element and parses the
/// simplest CSS subset Inkscape/Illustrator emit: comma-separated class
/// selectors with property:value declarations. Anything more exotic (id
/// selectors, descendants, media queries, @rules) is ignored.
Map<String, Map<String, String>> _collectClassRules(XmlElement root) {
  final map = <String, Map<String, String>>{};
  void visit(XmlElement el) {
    if (el.localName == 'style') {
      _parseStylesheet(el.innerText, map);
    }
    for (final child in el.childElements) {
      visit(child);
    }
  }
  visit(root);
  return map;
}

void _parseStylesheet(String css, Map<String, Map<String, String>> out) {
  final stripped = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final ruleRe = RegExp(r'([^{}]+)\{([^{}]*)\}');
  final selectorRe = RegExp(r'^\.[A-Za-z_][\w-]*$');
  for (final m in ruleRe.allMatches(stripped)) {
    final selectors = (m.group(1) ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final decls = _parseDeclarations(m.group(2) ?? '');
    if (decls.isEmpty) continue;
    for (final sel in selectors) {
      if (!selectorRe.hasMatch(sel)) continue;
      final cls = sel.substring(1);
      final bucket = out.putIfAbsent(cls, () => <String, String>{});
      decls.forEach((k, v) => bucket[k] = v);
    }
  }
}

Map<String, String> _parseDeclarations(String body) {
  final out = <String, String>{};
  for (final decl in body.split(';')) {
    final idx = decl.indexOf(':');
    if (idx <= 0) continue;
    final k = decl.substring(0, idx).trim().toLowerCase();
    final v = decl.substring(idx + 1).trim();
    if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
  }
  return out;
}

String? _lookupClassValue(
  String? classAttr,
  Map<String, Map<String, String>> classRules,
  String prop,
) {
  if (classAttr == null || classAttr.isEmpty) return null;
  String? value;
  for (final cls in classAttr.split(RegExp(r'\s+'))) {
    if (cls.isEmpty) continue;
    final v = classRules[cls]?[prop];
    if (v != null) value = v;
  }
  return value;
}

// ────────────────────────────────────────────────────────────────────────
// Inherited paint/stroke context. Walked down from root.
// ────────────────────────────────────────────────────────────────────────

class _Inherited {
  final SvgPaint? fill;
  final SvgPaint? stroke;
  final double strokeWidth;
  final StrokeCap strokeCap;
  final StrokeJoin strokeJoin;
  final List<double> strokeDashArray;
  final double strokeDashOffset;
  final double fillOpacity;
  final double strokeOpacity;

  const _Inherited({
    required this.fill,
    required this.stroke,
    required this.strokeWidth,
    required this.strokeCap,
    required this.strokeJoin,
    required this.strokeDashArray,
    required this.strokeDashOffset,
    required this.fillOpacity,
    required this.strokeOpacity,
  });

  /// SVG initial values: fill = black, stroke = none, stroke-width = 1.
  factory _Inherited.initial() => const _Inherited(
        fill: SolidPaint(Color(0xFF000000)),
        stroke: null,
        strokeWidth: 1.0,
        strokeCap: StrokeCap.butt,
        strokeJoin: StrokeJoin.miter,
        strokeDashArray: <double>[],
        strokeDashOffset: 0.0,
        fillOpacity: 1.0,
        strokeOpacity: 1.0,
      );

  _Inherited copyWith({
    Object? fill = _sentinel,
    Object? stroke = _sentinel,
    double? strokeWidth,
    StrokeCap? strokeCap,
    StrokeJoin? strokeJoin,
    List<double>? strokeDashArray,
    double? strokeDashOffset,
    double? fillOpacity,
    double? strokeOpacity,
  }) {
    return _Inherited(
      fill: identical(fill, _sentinel) ? this.fill : fill as SvgPaint?,
      stroke: identical(stroke, _sentinel) ? this.stroke : stroke as SvgPaint?,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      strokeCap: strokeCap ?? this.strokeCap,
      strokeJoin: strokeJoin ?? this.strokeJoin,
      strokeDashArray: strokeDashArray ?? this.strokeDashArray,
      strokeDashOffset: strokeDashOffset ?? this.strokeDashOffset,
      fillOpacity: fillOpacity ?? this.fillOpacity,
      strokeOpacity: strokeOpacity ?? this.strokeOpacity,
    );
  }
}

const Object _sentinel = Object();

/// Reads `style="k:v; k:v"`, element-level attributes, and `<style>` class
/// rules into an updated inheritance context. Class-rule fallback only kicks
/// in when neither presentation attr nor inline style declares the property
/// — keeps existing precedence intact while making editor-exported classed
/// SVGs (Inkscape/Illustrator) render with their declared paints.
_Inherited _applyAttrs(XmlElement el, _Inherited parent, _ParseContext ctx) {
  final style = _parseStyle(el.getAttribute('style'));
  final classAttr = el.getAttribute('class');
  String? lookup(String name) =>
      el.getAttribute(name) ??
      style[name] ??
      _lookupClassValue(classAttr, ctx.classRules, name);

  SvgPaint? fill = parent.fill;
  final fillRaw = lookup('fill');
  if (fillRaw != null) {
    fill = _parsePaintReference(fillRaw, ctx);
  }

  SvgPaint? stroke = parent.stroke;
  final strokeRaw = lookup('stroke');
  if (strokeRaw != null) {
    stroke = _parsePaintReference(strokeRaw, ctx);
  }

  final strokeWidth =
      _parseDouble(lookup('stroke-width')) ?? parent.strokeWidth;
  final fillOpacity =
      _parseDouble(lookup('fill-opacity')) ?? parent.fillOpacity;
  final strokeOpacity =
      _parseDouble(lookup('stroke-opacity')) ?? parent.strokeOpacity;

  StrokeCap strokeCap = parent.strokeCap;
  switch (lookup('stroke-linecap')) {
    case 'butt':
      strokeCap = StrokeCap.butt;
    case 'round':
      strokeCap = StrokeCap.round;
    case 'square':
      strokeCap = StrokeCap.square;
  }

  StrokeJoin strokeJoin = parent.strokeJoin;
  switch (lookup('stroke-linejoin')) {
    case 'miter':
      strokeJoin = StrokeJoin.miter;
    case 'round':
      strokeJoin = StrokeJoin.round;
    case 'bevel':
      strokeJoin = StrokeJoin.bevel;
  }

  final dashRaw = lookup('stroke-dasharray');
  final strokeDashArray = dashRaw != null
      ? _parseDashArray(dashRaw)
      : parent.strokeDashArray;
  final strokeDashOffset =
      _parseDouble(lookup('stroke-dashoffset')) ?? parent.strokeDashOffset;

  return parent.copyWith(
    fill: fill,
    stroke: stroke,
    strokeWidth: strokeWidth,
    strokeCap: strokeCap,
    strokeJoin: strokeJoin,
    strokeDashArray: strokeDashArray,
    strokeDashOffset: strokeDashOffset,
    fillOpacity: fillOpacity,
    strokeOpacity: strokeOpacity,
  );
}

/// Parses an SVG `stroke-dasharray` string into a list of non-negative numbers.
/// Returns [] for `none`, empty input, all-zero arrays, or any negative value
/// (the property is invalid in those cases per the SVG spec). An odd-length
/// list is repeated once so the dash/gap alternation closes cleanly, matching
/// browser behaviour.
List<double> _parseDashArray(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty || s == 'none') return const [];
  final nums = <double>[];
  for (final tok in raw.split(RegExp(r'[\s,]+'))) {
    if (tok.isEmpty) continue;
    final n = double.tryParse(tok);
    if (n == null || n < 0) return const [];
    nums.add(n);
  }
  if (nums.isEmpty) return const [];
  if (nums.every((n) => n == 0)) return const [];
  if (nums.length.isOdd) return [...nums, ...nums];
  return nums;
}

Map<String, String> _parseStyle(String? raw) {
  final out = <String, String>{};
  if (raw == null) return out;
  for (final decl in raw.split(';')) {
    final idx = decl.indexOf(':');
    if (idx <= 0) continue;
    final k = decl.substring(0, idx).trim();
    final v = decl.substring(idx + 1).trim();
    if (k.isNotEmpty) out[k] = v;
  }
  return out;
}

// ────────────────────────────────────────────────────────────────────────
// Element parsing.
// ────────────────────────────────────────────────────────────────────────

/// Elements that define resources but don't render. Their children are not
/// walked by the main pass; they are resolved lazily via the id index when
/// referenced (`url(#id)`, `<use href>`, `clip-path`).
const _nonRenderingTags = {
  'defs',
  'linearGradient',
  'radialGradient',
  'clipPath',
  'mask',
  'pattern',
  'symbol',
  'style',
  'title',
  'desc',
  'metadata',
};

SceneNode _parseElement(
  XmlElement el,
  _Inherited inheritedIn,
  _ParseContext ctx,
) {
  final tagName = el.localName;

  // <use> — inline the referenced element as this node's only child and
  // apply use/@x, use/@y, use/@transform above it.
  if (tagName == 'use') {
    return _parseUse(el, inheritedIn, ctx);
  }

  final inherited = _applyAttrs(el, inheritedIn, ctx);
  final id = el.getAttribute('id');
  final transform = _parseTransform(el.getAttribute('transform'), ctx.warnings);
  final opacity = _parseDouble(el.getAttribute('opacity')) ?? 1.0;
  final clipPath = _resolveClipPath(
    el.getAttribute('clip-path')
        ?? _parseStyle(el.getAttribute('style'))['clip-path']
        ?? _lookupClassValue(el.getAttribute('class'), ctx.classRules, 'clip-path'),
    ctx,
  );

  ui.Path? geometry;
  switch (tagName) {
    case 'svg':
    case 'g':
      break;
    case 'rect':
      geometry = _parseRect(el);
    case 'circle':
      geometry = _parseCircle(el);
    case 'ellipse':
      geometry = _parseEllipse(el);
    case 'line':
      geometry = _parseLine(el);
    case 'polygon':
      geometry = _parsePoly(el, close: true);
    case 'polyline':
      geometry = _parsePoly(el, close: false);
    case 'path':
      final d = el.getAttribute('d');
      if (d != null) {
        try {
          geometry = parseSvgPath(d);
        } catch (e) {
          ctx.warnings.add('failed to parse <path d="..."> ($e)');
        }
      }
    case 'text':
    case 'image':
      ctx.warnings.add('<$tagName> is not yet supported; skipping');
    default:
      if (!_nonRenderingTags.contains(tagName)) {
        ctx.warnings.add('unknown SVG element <$tagName>; skipping');
      }
  }

  final children = <SceneNode>[];
  for (final child in el.childElements) {
    if (_nonRenderingTags.contains(child.localName)) continue;
    children.add(_parseElement(child, inherited, ctx));
  }

  final hasGeometry = geometry != null;
  return SceneNode(
    id: id,
    tagName: tagName,
    geometry: geometry,
    fill: hasGeometry ? _withPaintOpacity(inherited.fill, inherited.fillOpacity) : null,
    stroke: hasGeometry
        ? _withPaintOpacity(inherited.stroke, inherited.strokeOpacity)
        : null,
    strokeWidth: inherited.strokeWidth,
    strokeCap: inherited.strokeCap,
    strokeJoin: inherited.strokeJoin,
    strokeDashArray: inherited.strokeDashArray,
    strokeDashOffset: inherited.strokeDashOffset,
    transform: transform,
    opacity: opacity,
    clipPath: clipPath,
    children: children,
  );
}

SceneNode _parseUse(
  XmlElement el,
  _Inherited inheritedIn,
  _ParseContext ctx,
) {
  final href = el.getAttribute('href') ??
      el.getAttribute('xlink:href') ??
      // package:xml strips namespace prefixes only when reading via
      // getAttribute(name, namespace:). Fallback for plain string match.
      _firstAttrMatching(el, 'href');

  final useX = _parseDouble(el.getAttribute('x')) ?? 0.0;
  final useY = _parseDouble(el.getAttribute('y')) ?? 0.0;
  final rawTransform = _parseTransform(el.getAttribute('transform'), ctx.warnings);

  // Compose: use's transform first, then its x/y translate (applied to
  // the inlined child's coordinate space).
  final transform = Matrix4.identity();
  if (rawTransform != null) transform.multiply(rawTransform);
  if (useX != 0 || useY != 0) {
    transform.multiply(Matrix4.translationValues(useX, useY, 0));
  }

  // Attributes on <use> cascade into the inlined subtree.
  final inherited = _applyAttrs(el, inheritedIn, ctx);
  final opacity = _parseDouble(el.getAttribute('opacity')) ?? 1.0;

  SceneNode? resolved;
  if (href != null && href.startsWith('#')) {
    final target = ctx.idIndex[href.substring(1)];
    if (target != null) {
      resolved = _parseElement(target, inherited, ctx);
    } else {
      ctx.warnings.add('<use> references unknown id "${href.substring(1)}"');
    }
  } else {
    ctx.warnings.add('<use> without "#..." href; skipping');
  }

  return SceneNode(
    id: el.getAttribute('id'),
    tagName: 'use',
    transform: _isIdentity(transform) ? null : transform,
    opacity: opacity,
    children: resolved != null ? [resolved] : const [],
  );
}

String? _firstAttrMatching(XmlElement el, String name) {
  for (final a in el.attributes) {
    if (a.name.local == name) return a.value;
  }
  return null;
}

bool _isIdentity(Matrix4 m) {
  for (var i = 0; i < 16; i++) {
    final expected = (i == 0 || i == 5 || i == 10 || i == 15) ? 1.0 : 0.0;
    if ((m.storage[i] - expected).abs() > 1e-9) return false;
  }
  return true;
}

// ────────────────────────────────────────────────────────────────────────
// Paint & gradient resolution.
// ────────────────────────────────────────────────────────────────────────

final _urlRefRe = RegExp(r'url\(\s*#([^)\s]+)\s*\)');

SvgPaint? _parsePaintReference(String raw, _ParseContext ctx) {
  final s = raw.trim();
  final urlMatch = _urlRefRe.firstMatch(s);
  if (urlMatch != null) {
    final id = urlMatch.group(1)!;
    final target = ctx.idIndex[id];
    if (target == null) {
      ctx.warnings.add('unresolved paint reference url(#$id)');
      return null;
    }
    switch (target.localName) {
      case 'linearGradient':
        return _parseLinearGradient(target, ctx);
      case 'radialGradient':
        return _parseRadialGradient(target, ctx);
      default:
        ctx.warnings.add(
          'url(#$id) points to <${target.localName}>, not a gradient',
        );
        return null;
    }
  }
  final color = _parseColor(s, ctx.warnings);
  return color != null ? SolidPaint(color) : null;
}

/// Resolves gradient attribute inheritance through an `href` chain.
/// Returns (effective attributes, effective stops).
(Map<String, String>, List<XmlElement>) _resolveGradientChain(
  XmlElement el,
  _ParseContext ctx, [
  Set<String>? visited,
]) {
  visited ??= <String>{};
  final id = el.getAttribute('id') ?? el.hashCode.toString();
  if (visited.contains(id)) {
    return (const {}, const []);
  }
  visited.add(id);

  final attrs = <String, String>{};
  for (final a in el.attributes) {
    attrs[a.name.local] = a.value;
  }
  final stops = el.childElements
      .where((c) => c.localName == 'stop')
      .toList(growable: false);

  final href = attrs['href'] ?? attrs['xlink:href'];
  if (href != null && href.startsWith('#')) {
    final target = ctx.idIndex[href.substring(1)];
    if (target != null) {
      final (parentAttrs, parentStops) = _resolveGradientChain(target, ctx, visited);
      // Parent attrs as defaults, ours take precedence.
      final merged = {...parentAttrs, ...attrs};
      final effectiveStops = stops.isEmpty ? parentStops : stops;
      return (merged, effectiveStops);
    }
  }
  return (attrs, stops);
}

LinearGradientPaint _parseLinearGradient(XmlElement el, _ParseContext ctx) {
  final (attrs, stopEls) = _resolveGradientChain(el, ctx);

  final x1 = _parseLengthOrPercent(attrs['x1']) ?? 0.0;
  final y1 = _parseLengthOrPercent(attrs['y1']) ?? 0.0;
  final x2 = _parseLengthOrPercent(attrs['x2']) ?? 1.0;
  final y2 = _parseLengthOrPercent(attrs['y2']) ?? 0.0;

  final objectBoundingBox = (attrs['gradientUnits'] ?? 'objectBoundingBox') ==
      'objectBoundingBox';
  final tileMode = _tileMode(attrs['spreadMethod']);
  final transform = _parseTransform(attrs['gradientTransform'], ctx.warnings);
  final (colors, stops) = _parseStops(stopEls, ctx);

  return LinearGradientPaint(
    start: Offset(x1, y1),
    end: Offset(x2, y2),
    colors: colors,
    stops: stops,
    tileMode: tileMode,
    objectBoundingBox: objectBoundingBox,
    gradientTransform: transform,
  );
}

RadialGradientPaint _parseRadialGradient(XmlElement el, _ParseContext ctx) {
  final (attrs, stopEls) = _resolveGradientChain(el, ctx);

  final cx = _parseLengthOrPercent(attrs['cx']) ?? 0.5;
  final cy = _parseLengthOrPercent(attrs['cy']) ?? 0.5;
  final r = _parseLengthOrPercent(attrs['r']) ?? 0.5;
  final fx = _parseLengthOrPercent(attrs['fx']);
  final fy = _parseLengthOrPercent(attrs['fy']);

  final objectBoundingBox = (attrs['gradientUnits'] ?? 'objectBoundingBox') ==
      'objectBoundingBox';
  final tileMode = _tileMode(attrs['spreadMethod']);
  final transform = _parseTransform(attrs['gradientTransform'], ctx.warnings);
  final (colors, stops) = _parseStops(stopEls, ctx);

  return RadialGradientPaint(
    center: Offset(cx, cy),
    radius: r,
    focal: (fx != null && fy != null) ? Offset(fx, fy) : null,
    colors: colors,
    stops: stops,
    tileMode: tileMode,
    objectBoundingBox: objectBoundingBox,
    gradientTransform: transform,
  );
}

(List<Color>, List<double>) _parseStops(
  List<XmlElement> stopEls,
  _ParseContext ctx,
) {
  final colors = <Color>[];
  final stops = <double>[];
  for (final s in stopEls) {
    final style = _parseStyle(s.getAttribute('style'));
    final classAttr = s.getAttribute('class');
    final offsetRaw = s.getAttribute('offset');
    final offset = _parseOffset(offsetRaw) ?? 0.0;
    final colorRaw = s.getAttribute('stop-color')
        ?? style['stop-color']
        ?? _lookupClassValue(classAttr, ctx.classRules, 'stop-color')
        ?? 'black';
    final opacityRaw = s.getAttribute('stop-opacity')
        ?? style['stop-opacity']
        ?? _lookupClassValue(classAttr, ctx.classRules, 'stop-opacity');
    final color = _parseColor(colorRaw, ctx.warnings) ?? const Color(0xFF000000);
    final opacity =
        opacityRaw != null ? _parseDouble(opacityRaw) ?? 1.0 : 1.0;
    colors.add(_withAlphaOpacity(color, opacity));
    stops.add(offset.clamp(0.0, 1.0));
  }
  if (colors.isEmpty) {
    return ([const Color(0x00000000), const Color(0x00000000)], [0.0, 1.0]);
  }
  if (colors.length == 1) {
    return (
      [colors.first, colors.first],
      [stops.first.clamp(0.0, 1.0), 1.0],
    );
  }
  // Ensure stops are monotonically non-decreasing (SVG allows equal, requires order).
  for (var i = 1; i < stops.length; i++) {
    if (stops[i] < stops[i - 1]) stops[i] = stops[i - 1];
  }
  return (colors, stops);
}

TileMode _tileMode(String? spread) {
  switch (spread) {
    case 'reflect':
      return TileMode.mirror;
    case 'repeat':
      return TileMode.repeated;
    default:
      return TileMode.clamp;
  }
}

/// Parses a length that may be a plain number or a percentage. Percentages
/// are returned as fractions (e.g. "50%" → 0.5), matching SVG's units=
/// objectBoundingBox convention.
double? _parseLengthOrPercent(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.endsWith('%')) {
    final v = double.tryParse(t.substring(0, t.length - 1));
    return v == null ? null : v / 100.0;
  }
  return _parseDouble(t);
}

double? _parseOffset(String? s) => _parseLengthOrPercent(s);

// ────────────────────────────────────────────────────────────────────────
// clip-path resolution.
// ────────────────────────────────────────────────────────────────────────

ui.Path? _resolveClipPath(String? raw, _ParseContext ctx) {
  if (raw == null) return null;
  final match = _urlRefRe.firstMatch(raw);
  if (match == null) return null;
  final id = match.group(1)!;
  final target = ctx.idIndex[id];
  if (target == null) {
    ctx.warnings.add('unresolved clip-path reference url(#$id)');
    return null;
  }
  if (target.localName != 'clipPath') {
    ctx.warnings.add('url(#$id) referenced from clip-path is not a <clipPath>');
    return null;
  }
  final path = ui.Path();
  for (final child in target.childElements) {
    final node = _parseElement(child, _Inherited.initial(), ctx);
    _accumulateClipGeometry(node, path, Matrix4.identity());
  }
  return path;
}

void _accumulateClipGeometry(SceneNode node, ui.Path out, Matrix4 parentTransform) {
  final combined = node.transform != null
      ? (Matrix4.identity()..multiply(parentTransform)..multiply(node.transform!))
      : parentTransform;
  if (node.geometry != null) {
    final g = _isIdentity(combined)
        ? node.geometry!
        : node.geometry!.transform(combined.storage);
    out.addPath(g, Offset.zero);
  }
  for (final child in node.children) {
    _accumulateClipGeometry(child, out, combined);
  }
}

// ────────────────────────────────────────────────────────────────────────
// Geometry parsers.
// ────────────────────────────────────────────────────────────────────────

ui.Path _parseRect(XmlElement el) {
  final x = _parseDouble(el.getAttribute('x')) ?? 0;
  final y = _parseDouble(el.getAttribute('y')) ?? 0;
  final w = _parseDouble(el.getAttribute('width')) ?? 0;
  final h = _parseDouble(el.getAttribute('height')) ?? 0;
  final rxRaw = _parseDouble(el.getAttribute('rx'));
  final ryRaw = _parseDouble(el.getAttribute('ry'));
  final rx = rxRaw ?? ryRaw ?? 0;
  final ry = ryRaw ?? rxRaw ?? 0;
  final path = ui.Path();
  if (rx > 0 || ry > 0) {
    path.addRRect(RRect.fromRectXY(Rect.fromLTWH(x, y, w, h), rx, ry));
  } else {
    path.addRect(Rect.fromLTWH(x, y, w, h));
  }
  return path;
}

ui.Path _parseCircle(XmlElement el) {
  final cx = _parseDouble(el.getAttribute('cx')) ?? 0;
  final cy = _parseDouble(el.getAttribute('cy')) ?? 0;
  final r = _parseDouble(el.getAttribute('r')) ?? 0;
  return ui.Path()
    ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
}

ui.Path _parseEllipse(XmlElement el) {
  final cx = _parseDouble(el.getAttribute('cx')) ?? 0;
  final cy = _parseDouble(el.getAttribute('cy')) ?? 0;
  final rx = _parseDouble(el.getAttribute('rx')) ?? 0;
  final ry = _parseDouble(el.getAttribute('ry')) ?? 0;
  return ui.Path()
    ..addOval(Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2));
}

ui.Path _parseLine(XmlElement el) {
  final x1 = _parseDouble(el.getAttribute('x1')) ?? 0;
  final y1 = _parseDouble(el.getAttribute('y1')) ?? 0;
  final x2 = _parseDouble(el.getAttribute('x2')) ?? 0;
  final y2 = _parseDouble(el.getAttribute('y2')) ?? 0;
  return ui.Path()
    ..moveTo(x1, y1)
    ..lineTo(x2, y2);
}

ui.Path _parsePoly(XmlElement el, {required bool close}) {
  final path = ui.Path();
  final pts = el.getAttribute('points');
  if (pts == null) return path;
  final nums = _numberList(pts);
  for (var i = 0; i + 1 < nums.length; i += 2) {
    if (i == 0) {
      path.moveTo(nums[i], nums[i + 1]);
    } else {
      path.lineTo(nums[i], nums[i + 1]);
    }
  }
  if (close) path.close();
  return path;
}

// ────────────────────────────────────────────────────────────────────────
// Transform parser.
// ────────────────────────────────────────────────────────────────────────

final _transformRe = RegExp(r'(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)');

Matrix4? _parseTransform(String? raw, List<String> warnings) {
  if (raw == null || raw.trim().isEmpty) return null;
  final result = Matrix4.identity();
  for (final m in _transformRe.allMatches(raw)) {
    final op = m.group(1)!;
    final args = _numberList(m.group(2)!);
    switch (op) {
      case 'matrix':
        if (args.length == 6) {
          result.multiply(Matrix4(
            args[0], args[1], 0, 0,
            args[2], args[3], 0, 0,
            0, 0, 1, 0,
            args[4], args[5], 0, 1,
          ));
        }
      case 'translate':
        final tx = args.isNotEmpty ? args[0] : 0.0;
        final ty = args.length > 1 ? args[1] : 0.0;
        result.multiply(Matrix4.translationValues(tx, ty, 0));
      case 'scale':
        final sx = args.isNotEmpty ? args[0] : 1.0;
        final sy = args.length > 1 ? args[1] : sx;
        result.multiply(Matrix4.diagonal3Values(sx, sy, 1));
      case 'rotate':
        final a = (args.isNotEmpty ? args[0] : 0.0) * math.pi / 180;
        if (args.length >= 3) {
          final cx = args[1], cy = args[2];
          result.multiply(Matrix4.translationValues(cx, cy, 0));
          result.multiply(Matrix4.rotationZ(a));
          result.multiply(Matrix4.translationValues(-cx, -cy, 0));
        } else {
          result.multiply(Matrix4.rotationZ(a));
        }
      case 'skewX':
        final a = (args.isNotEmpty ? args[0] : 0.0) * math.pi / 180;
        final sk = Matrix4.identity()..setEntry(0, 1, math.tan(a));
        result.multiply(sk);
      case 'skewY':
        final a = (args.isNotEmpty ? args[0] : 0.0) * math.pi / 180;
        final sk = Matrix4.identity()..setEntry(1, 0, math.tan(a));
        result.multiply(sk);
      default:
        warnings.add('unknown transform op $op');
    }
  }
  return result;
}

// ────────────────────────────────────────────────────────────────────────
// Primitives.
// ────────────────────────────────────────────────────────────────────────

final _numRe = RegExp(r'-?\d*\.?\d+(?:[eE][-+]?\d+)?');

List<double> _numberList(String s) =>
    _numRe.allMatches(s).map((m) => double.parse(m.group(0)!)).toList();

double? _parseDouble(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty) return null;
  final stripped = t.replaceAll(RegExp(r'(px|pt)$'), '');
  return double.tryParse(stripped);
}

Color _withAlphaOpacity(Color c, double o) {
  if (o >= 1.0) return c;
  return c.withAlpha(((c.a * 255.0) * o).round().clamp(0, 255));
}

/// Applies an inherited opacity multiplier to a paint source. For solid
/// fills this folds into the alpha; for gradients we apply the same
/// multiplier to every stop colour.
SvgPaint? _withPaintOpacity(SvgPaint? p, double opacity) {
  if (p == null || opacity >= 1.0) return p;
  switch (p) {
    case SolidPaint(:final color):
      return SolidPaint(_withAlphaOpacity(color, opacity));
    case LinearGradientPaint():
      return LinearGradientPaint(
        start: p.start,
        end: p.end,
        colors: p.colors.map((c) => _withAlphaOpacity(c, opacity)).toList(),
        stops: p.stops,
        tileMode: p.tileMode,
        objectBoundingBox: p.objectBoundingBox,
        gradientTransform: p.gradientTransform,
      );
    case RadialGradientPaint():
      return RadialGradientPaint(
        center: p.center,
        radius: p.radius,
        focal: p.focal,
        colors: p.colors.map((c) => _withAlphaOpacity(c, opacity)).toList(),
        stops: p.stops,
        tileMode: p.tileMode,
        objectBoundingBox: p.objectBoundingBox,
        gradientTransform: p.gradientTransform,
      );
  }
}

Color? _parseColor(String raw, List<String> warnings) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty || s == 'none' || s == 'transparent') return null;
  if (s.startsWith('#')) {
    final hex = s.substring(1);
    if (hex.length == 3) {
      final r = int.parse(hex[0] * 2, radix: 16);
      final g = int.parse(hex[1] * 2, radix: 16);
      final b = int.parse(hex[2] * 2, radix: 16);
      return Color.fromARGB(0xFF, r, g, b);
    }
    if (hex.length == 6) {
      return Color(0xFF000000 | int.parse(hex, radix: 16));
    }
    if (hex.length == 8) {
      final r = int.parse(hex.substring(0, 2), radix: 16);
      final g = int.parse(hex.substring(2, 4), radix: 16);
      final b = int.parse(hex.substring(4, 6), radix: 16);
      final a = int.parse(hex.substring(6, 8), radix: 16);
      return Color.fromARGB(a, r, g, b);
    }
  }
  if (s.startsWith('rgb')) {
    final nums = _numberList(s);
    if (nums.length >= 3) {
      final r = nums[0].round().clamp(0, 255);
      final g = nums[1].round().clamp(0, 255);
      final b = nums[2].round().clamp(0, 255);
      final a = nums.length >= 4 ? (nums[3] * 255).round().clamp(0, 255) : 255;
      return Color.fromARGB(a, r, g, b);
    }
  }
  final named = _namedColors[s];
  if (named != null) return named;
  warnings.add('unrecognised color "$raw"; treating as transparent');
  return null;
}

const _namedColors = <String, Color>{
  'black': Color(0xFF000000),
  'white': Color(0xFFFFFFFF),
  'red': Color(0xFFFF0000),
  'green': Color(0xFF008000),
  'blue': Color(0xFF0000FF),
  'yellow': Color(0xFFFFFF00),
  'cyan': Color(0xFF00FFFF),
  'magenta': Color(0xFFFF00FF),
  'gray': Color(0xFF808080),
  'grey': Color(0xFF808080),
  'silver': Color(0xFFC0C0C0),
  'maroon': Color(0xFF800000),
  'olive': Color(0xFF808000),
  'lime': Color(0xFF00FF00),
  'aqua': Color(0xFF00FFFF),
  'teal': Color(0xFF008080),
  'navy': Color(0xFF000080),
  'fuchsia': Color(0xFFFF00FF),
  'purple': Color(0xFF800080),
};
