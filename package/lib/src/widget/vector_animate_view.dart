import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../engine/controller.dart';
import '../render/animation_painter.dart';

/// Widget that plays a [VectorAnimation] managed by a [VectorAnimateController].
///
/// The controller owns loading and playback state. Create one with a named
/// constructor and pass it here:
///
/// ```dart
/// VectorAnimateView(
///   controller: VectorAnimateController.fromAsset('assets/card.var'),
/// )
/// ```
///
/// While the animation is loading (or warming up), [loadingBuilder] is shown
/// (defaults to [SizedBox.shrink]).
///
/// [warmUp] controls the two-phase warm-up pass shown before the animation
/// becomes live:
///
/// 1. An off-screen [ui.PictureRecorder] render at forced full opacity so
///    Impeller tessellates all geometry (and Skia compiles all shaders) before
///    the first on-screen frame.
///
/// 2. One "priming frame" where [CustomPaint] renders to the actual on-screen
///    surface (priming Impeller's pipeline-state cache for the correct render
///    target) while the animation's background colour acts as a cover — users
///    see the loading state for one extra frame, then the animation appears
///    without any stutter.
///
/// Precedence:
///   * Explicit `true` / `false` — always wins.
///   * `null` (default) — defers to the .var file's `runtimeHints.warmUp`
///     flag (default `true` when no hints are present). This lets the
///     designer's runtime-export modal disable warm-up for animations that
///     bake enough work upstream to make it unnecessary.
class VectorAnimateView extends StatefulWidget {
  const VectorAnimateView({
    super.key,
    required this.controller,
    this.fit = BoxFit.contain,
    this.loadingBuilder,
    this.warmUp,
  });

  final VectorAnimateController controller;
  final BoxFit fit;
  final WidgetBuilder? loadingBuilder;
  final bool? warmUp;

  @override
  State<VectorAnimateView> createState() => _VectorAnimateViewState();
}

class _VectorAnimateViewState extends State<VectorAnimateView>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  Duration _lastTick = Duration.zero;

  /// Phase 0: loading / picture.toImage warm-up (show loadingBuilder).
  /// Phase 1: priming frame — CustomPaint renders to on-screen surface behind
  ///           the background colour overlay.
  /// Phase 2: live — animation visible normally.
  int _phase = 0;

  /// Kept alive so Flutter never re-creates the painter between frames;
  /// combined with `repaint: controller` this means repaints are driven by
  /// markNeedsPaint() rather than widget rebuilds.
  AnimationPainter? _painter;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker.start();

    if (widget.controller.isLoaded) {
      _startWarmUp();
    } else {
      widget.controller.addListener(_onControllerNotify);
    }
  }

  void _onControllerNotify() {
    if (!widget.controller.isLoaded) return;
    widget.controller.removeListener(_onControllerNotify);
    _startWarmUp();
  }

  void _startWarmUp() {
    // Resolve precedence: explicit widget.warmUp wins; otherwise read the
    // .var file's runtimeHints.warmUp flag (defaults to true when missing).
    final hint = widget.controller.animation?.runtimeHints?.warmUp;
    final want = widget.warmUp ?? hint ?? true;
    if (!want) {
      if (mounted) setState(() => _phase = 2);
      return;
    }
    _runWarmUp();
  }

  Future<void> _runWarmUp() async {
    if (!mounted) return;

    // Pass 1: off-screen render at forced full opacity.
    // Primes Impeller path tessellation and Skia shader compilation.
    final vp = widget.controller.animation!.viewport;
    final w = vp.width.ceil().clamp(1, 4096);
    final h = vp.height.ceil().clamp(1, 4096);
    final recorder = ui.PictureRecorder();
    AnimationPainter(controller: widget.controller, fit: widget.fit)
        .warmUpPaint(ui.Canvas(recorder), Size(vp.width.toDouble(), vp.height.toDouble()));
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    image.dispose();

    if (!mounted) return;

    // Pass 2: show CustomPaint on-screen for one frame behind the background
    // colour overlay. This primes Impeller's pipeline-state cache for the
    // actual on-screen render target (which differs from the offscreen surface
    // used by toImage and would otherwise cause a pipeline-state miss on the
    // very first visible frame).
    setState(() => _phase = 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _phase = 2);
    });
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    final dtMs = dt.inMicroseconds / 1000.0;
    final clamped = dtMs > 100 ? 100.0 : dtMs;
    widget.controller.advance(clamped);
  }

  @override
  void didUpdateWidget(VectorAnimateView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged = oldWidget.controller != widget.controller;
    if (controllerChanged || oldWidget.fit != widget.fit) {
      _painter = null;
    }
    if (controllerChanged) {
      // Stop watching the old controller (may still be registered if it never loaded).
      oldWidget.controller.removeListener(_onControllerNotify);
      // Reset to loading phase so the guard in build() doesn't show a stale
      // animation while the new controller hasn't loaded yet.
      _phase = 0;
      if (widget.controller.isLoaded) {
        _startWarmUp();
      } else {
        widget.controller.addListener(_onControllerNotify);
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerNotify);
    _ticker.dispose();
    super.dispose();
  }

  AnimationPainter _getPainter() =>
      _painter ??= AnimationPainter(
        controller: widget.controller,
        fit: widget.fit,
      );

  @override
  Widget build(BuildContext context) {
    if (_phase == 0 || !widget.controller.isLoaded) {
      return widget.loadingBuilder?.call(context) ?? const SizedBox.shrink();
    }

    final vp = widget.controller.animation!.viewport;
    // Fill whatever box the host gave us so the painter's [BoxFit] has room
    // to actually do something — sizing CustomPaint to the native viewport
    // (which we used to do) made the fit factors all equal 1 and silently
    // disabled the [fit] setting. When the host's constraints are unbounded
    // on either axis we fall back to the viewport's natural size on that axis
    // so the widget still has an intrinsic size.
    final customPaint = LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.hasBoundedWidth ? constraints.maxWidth : vp.width;
        final h = constraints.hasBoundedHeight ? constraints.maxHeight : vp.height;
        return CustomPaint(
          size: Size(w, h),
          painter: _getPainter(),
        );
      },
    );

    // Phase 1: priming frame. CustomPaint renders to the on-screen surface to
    // prime Impeller's pipeline state; the background colour (if set) covers
    // it so the user sees a blank/loading frame rather than a stutter.
    if (_phase == 1) {
      final bgArgb = vp.backgroundArgb;
      if (bgArgb != null) {
        return Stack(
          children: [
            customPaint,
            Positioned.fill(child: ColoredBox(color: Color(bgArgb))),
          ],
        );
      }
    }

    return customPaint;
  }
}
