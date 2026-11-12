import 'package:flutter/material.dart';

/// Keeps the previous surface painted until the incoming content is opaque.
class ContentCrossFade extends StatefulWidget {
  const ContentCrossFade({required this.child, super.key});

  final Widget child;

  @override
  State<ContentCrossFade> createState() => _ContentCrossFadeState();
}

class _ContentCrossFadeState extends State<ContentCrossFade>
    with TickerProviderStateMixin {
  final _layers = <_ContentLayer>[];
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _addLayer(animate: false);
  }

  void _addLayer({required bool animate}) {
    for (final layer in _layers) {
      layer.controller.stop();
    }
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: animate ? 0 : 1,
    );
    final layer = _ContentLayer(widget.child, controller);
    _layers.add(layer);
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed &&
          mounted &&
          identical(_layers.last, layer)) {
        setState(_releasePrevious);
      }
    });
    if (animate) controller.forward();
  }

  void _releasePrevious() {
    while (_layers.length > 1) {
      _layers.removeAt(0).dispose();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _releasePrevious();
      _layers.single.controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant ContentCrossFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Widget.canUpdate(oldWidget.child, widget.child)) {
      _layers.last.child = widget.child;
    } else {
      _addLayer(animate: !_reduceMotion);
      if (_reduceMotion) _releasePrevious();
    }
  }

  @override
  void dispose() {
    for (final layer in _layers) {
      layer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        for (final layer in _layers)
          ExcludeFocus(
            key: ObjectKey(layer),
            excluding:
                !identical(layer, _layers.last) ||
                !layer.controller.isCompleted,
            child: ExcludeSemantics(
              excluding:
                  !identical(layer, _layers.last) ||
                  !layer.controller.isCompleted,
              child: IgnorePointer(
                ignoring:
                    !identical(layer, _layers.last) ||
                    !layer.controller.isCompleted,
                child: TickerMode(
                  enabled: identical(layer, _layers.last),
                  child: FadeTransition(
                    opacity: layer.opacity,
                    child: RepaintBoundary(
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: layer.child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _ContentLayer {
  _ContentLayer(this.child, this.controller)
    : opacity = CurvedAnimation(
        parent: controller,
        curve: Curves.easeInOutCubic,
      );

  Widget child;
  final AnimationController controller;
  final CurvedAnimation opacity;

  void dispose() {
    opacity.dispose();
    controller.dispose();
  }
}
