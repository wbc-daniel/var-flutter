/// Flutter runtime player for vector_animate (.var.json / .var) animations.
library;

export 'src/engine/controller.dart'
    show VectorAnimateController, PlaybackMode, StateChangeEvent;
export 'src/engine/property_resolver.dart'
    show ResolvedElement, mapScalar, mapColor;
export 'src/render/scene_node.dart'
    show
        SceneNode,
        SvgPaint,
        SolidPaint,
        LinearGradientPaint,
        RadialGradientPaint;
export 'src/render/animation_painter.dart' show buildMaskPath, dashPath;
export 'src/model/model.dart'
    show
        VectorAnimation,
        Viewport,
        AnimatedElement,
        Keyframe,
        NodePos,
        ElementAnimation,
        StateConfig,
        TransitionInConfig,
        TransitionInType,
        StateTransition,
        ElementTransitionOverride,
        TransitionDefaults,
        EasingCurve,
        DataBinding,
        BoundProperty,
        StateInfo,
        DataBindingInfo,
        DataKeyInfo;
export 'src/widget/vector_animate_view.dart' show VectorAnimateView;
