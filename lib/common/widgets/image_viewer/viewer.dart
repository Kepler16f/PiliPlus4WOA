/*
 * This file is part of PiliPlus
 *
 * PiliPlus is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * PiliPlus is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with PiliPlus.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart'
    show touchSlopH;
import 'package:PiliPlus/common/widgets/gesture/image_horizontal_drag_gesture_recognizer.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart' show FrictionSimulation;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:material_ui/material_ui.dart';

///
/// created by dom on 2026/02/14
///

class Viewer extends StatefulWidget {
  const Viewer({
    super.key,
    required this.minScale,
    required this.maxScale,
    this.isLongPic = false,
    required this.containerSize,
    required this.childSize,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.doubleTapGestureRecognizer,
    required this.horizontalDragGestureRecognizer,
    required this.onChangePage,
    this.onTapBlank,
    required this.child,
  });

  final double minScale;
  final double maxScale;
  final bool isLongPic;
  final Size containerSize;
  final Size childSize;
  final Widget child;

  /// 单击「图片以外的空白处」时回调（判定见 [_onBlankPointerUp]）。
  ///
  /// 只能由 Viewer 判：图片画在哪只有它知道（`_imageRect`，与 `_isAtEdge`、
  /// `_clampPosition` 同一套不变式）；外层 PageView 每页铺满容器，图片与空白
  /// 命中的是同一个对象，拿不到任何边界信息。
  ///
  /// 判定用裸 `Listener` 的按下/抬起，而不是再挂一个 tap 识别器：识别器要同横滑
  /// 翻页、双指缩放、长按在竞技场里抢手势，输了就毫无反应 —— 那正是「很难退出」
  /// 的成因之一（另一半是关闭单击与双击缩放曾共用全局节流键 'VIEWER_TAP'）。
  /// 裸监听不进竞技场，判定必然执行。为 null 时行为完全不变。
  final VoidCallback? onTapBlank;

  final ValueChanged<ScaleStartDetails>? onDragStart;
  final ValueChanged<ScaleUpdateDetails>? onDragUpdate;
  final ValueChanged<ScaleEndDetails>? onDragEnd;
  final ValueChanged<int>? onChangePage;

  final DoubleTapGestureRecognizer doubleTapGestureRecognizer;
  final ImageHorizontalDragGestureRecognizer horizontalDragGestureRecognizer;

  @override
  State<StatefulWidget> createState() => _ViewerState();
}

class _ViewerState extends State<Viewer> with SingleTickerProviderStateMixin {
  static const double _scaleFactor = kDefaultMouseScrollToScaleFactor;

  _GestureType? _gestureType;

  final Matrix4 _matrix = Matrix4.identity();

  late double __scale;
  double get _scale => __scale;
  set _scale(double value) {
    __scale = value;
    _matrix[0] = _matrix[5] = _matrix[10] = value;
  }

  late Offset __position;
  Offset get _position => __position;
  set _position(Offset value) {
    __position = value;
    _matrix
      ..[12] = value.dx
      ..[13] = value.dy;
  }

  Offset? _scalePos;
  double? _scaleStart;
  Offset? _referenceFocalPoint;

  late Size _imageSize;

  late final DoubleTapGestureRecognizer _doubleTapGestureRecognizer;
  late final ImageHorizontalDragGestureRecognizer
  _horizontalDragGestureRecognizer;
  late final ScaleGestureRecognizer _scaleGestureRecognizer;

  Offset? _downPos;
  late final AnimationController _animationController;

  // ---- 「单击空白处退出」（见 [Viewer.onTapBlank]）----

  /// 当前被当作「候选单击」的指针；只认第一根按下且按主键的手指。
  /// 用裸 Listener 的按下/抬起自己判，不进竞技场（理由见 [Viewer.onTapBlank]）。
  int? _blankPointer;
  Offset? _blankDownPos;
  Duration? _blankDownStamp;

  /// 画面在本地坐标系（= 容器坐标系）里实际占据的矩形。
  ///
  /// 这套推导不是另起的：未缩放时画布是 `_imageSize`（`applyBoxFit(scaleDown,
  /// childSize, containerSize)` 的 destination）在容器内**居中**，`_matrix` 再绕
  /// 左上角缩放 `_scale`、平移 `_position`，所以
  /// 左上角 = `_position + (container - _imageSize) / 2 * _scale`、
  /// 尺寸 = `_imageSize * _scale`。反证：画面左边取 0（贴左、可翻页）时
  /// `_position.dx = _scale * (iw - cw) / 2`，与 [_isAtEdge] 里
  /// `dx + dxOffset` 的表达式逐字相同 —— 本 Widget 一直用的就是这一套。
  Rect get _imageRect {
    final container = widget.containerSize;
    final image = _imageSize;
    final scale = _scale;
    return Rect.fromLTWH(
      _position.dx + (container.width - image.width) * scale / 2,
      _position.dy + (container.height - image.height) * scale / 2,
      image.width * scale,
      image.height * scale,
    );
  }

  /// 画面是否留得下「空白」（没被铺满）。铺满时退回「点哪儿都退出」，
  /// 否则 Live Photo、比例刚好合屏的照片这类没有空白可点的图就再也点不关了。
  bool get _hasBlankArea {
    final container = widget.containerSize;
    final rect = _imageRect;
    return rect.width < container.width - 1 ||
        rect.height < container.height - 1;
  }

  void _onBlankPointerDown(PointerDownEvent event) {
    if (widget.onTapBlank == null) return;
    // 副键不算（桌面右键另有菜单，多键也不是「单击」）
    if (event.buttons != kPrimaryButton) return;
    final lastStamp = _blankDownStamp;
    if (_blankPointer != null &&
        lastStamp != null &&
        event.timeStamp - lastStamp <= kLongPressTimeout) {
      // 第二根手指很快按下 = 捏合/旋转，本轮不再是单击，判定作废
      _clearBlankCandidate();
      return;
    }
    // 走到这里：要么是第一根手指，要么上一根的记录已经陈旧 —— 即它的抬起被系统
    // 吞掉了（WOA 偶发，同 pl_player/view/view.dart 的幽灵指针守卫）。按新的一次
    // 按下重新起算，免得「丢一次抬起」就再也点不关（正是用户抱怨的病症）。
    _blankPointer = event.pointer;
    _blankDownPos = event.position;
    _blankDownStamp = event.timeStamp;
  }

  void _onBlankPointerUp(PointerUpEvent event) {
    if (event.pointer != _blankPointer) return;
    final down = _blankDownPos;
    final stamp = _blankDownStamp;
    final onTapBlank = widget.onTapBlank;
    _clearBlankCandidate();
    if (down == null || stamp == null || onTapBlank == null) return;
    // 按住太久属于长按（长按另有菜单），不是单击
    if (event.timeStamp - stamp > kLongPressTimeout) return;
    // 阈值按设备分档：手指点按天然会漂十几 px，写死小阈值会让「点空白」时灵时不灵
    final slop = event.kind == PointerDeviceKind.mouse
        ? kPrecisePointerPanSlop
        : kTouchSlop;
    if ((event.position - down).distanceSquared > slop * slop) return;
    final rect = _imageRect;
    // 贴边 2px 内当作「点在图上」：宁可少退一次，也别在用户看图时误退。
    // 画面还没量出来（未解码、或加载失败停在错误页）时矩形是退化的，contains
    // 自然为假 —— 当作空白放行，否则那种情况下反而一个退出手势都没有。
    if (rect.inflate(2).contains(event.localPosition) && _hasBlankArea) {
      return;
    }
    onTapBlank.call();
  }

  void _onBlankPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _blankPointer) _clearBlankCandidate();
  }

  void _clearBlankCandidate() {
    _blankPointer = null;
    _blankDownPos = null;
    _blankDownStamp = null;
  }

  late double _scaleFrom, _scaleTo;
  late Offset _positionFrom, _positionTo;

  void _listener() {
    final t = Curves.easeOut.transform(_animationController.value);
    _scale = t.lerp(_scaleFrom, _scaleTo);
    _position = Offset.lerp(_positionFrom, _positionTo, t)!;
    setState(() {});
  }

  void _reset() {
    _scale = widget.minScale;
    _position = .zero;
  }

  void _initSize() {
    _reset();
    _imageSize = applyBoxFit(
      .scaleDown,
      widget.childSize,
      widget.containerSize,
    ).destination;
    if (widget.isLongPic) {
      final containerWidth = widget.containerSize.width;
      final containerHeight = widget.containerSize.height;
      final imageHeight = _imageSize.height * _scale;
      _position = Offset(
        (1 - _scale) * containerWidth / 2,
        (imageHeight - _scale * containerHeight) / 2,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _initSize();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_listener);

    _doubleTapGestureRecognizer = widget.doubleTapGestureRecognizer;
    _horizontalDragGestureRecognizer = widget.horizontalDragGestureRecognizer;

    _scaleGestureRecognizer = ScaleGestureRecognizer(debugOwner: this)
      ..dragStartBehavior = .start
      ..onStart = _onScaleStart
      ..onUpdate = _onScaleUpdate
      ..onEnd = _onScaleEnd
      ..gestureSettings = DeviceGestureSettings(touchSlop: touchSlopH);
  }

  @override
  void didUpdateWidget(Viewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.containerSize != widget.containerSize ||
        oldWidget.childSize != widget.childSize) {
      _initSize();
    }
  }

  @override
  void dispose() {
    _stopFling();
    _animationController
      ..removeListener(_listener)
      ..dispose();
    _scaleGestureRecognizer.dispose();
    super.dispose();
  }

  Offset _toScene(Offset localFocalPoint) {
    return (localFocalPoint - _position) / _scale;
  }

  Offset _clampPosition(Offset offset, double scale) {
    final containerSize = widget.containerSize;
    final imageWidth = _imageSize.width * scale;
    final imageHeight = _imageSize.height * scale;

    final center = containerSize * (1 - scale) / 2;

    final dxOffset = (imageWidth - containerSize.width) / 2;
    final dyOffset = (imageHeight - containerSize.height) / 2;

    return Offset(
      imageWidth > containerSize.width
          ? clampDouble(
              offset.dx,
              center.width - dxOffset,
              center.width + dxOffset,
            )
          : center.width,
      imageHeight > containerSize.height
          ? clampDouble(
              offset.dy,
              center.height - dyOffset,
              center.height + dyOffset,
            )
          : center.height,
    );
  }

  Offset _matrixTranslate(Offset translation) {
    if (translation == .zero) {
      return _position;
    }
    return _clampPosition(_position + translation * _scale, _scale);
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _downPos = details.localPosition;
  }

  void _onDoubleTap() {
    if (!mounted) return;
    if (_animationController.isAnimating) return;
    EasyThrottle.throttle(
      'VIEWER_TAP',
      const Duration(milliseconds: 555),
      _handleDoubleTap,
    );
  }

  void _handleDoubleTap() {
    if (!mounted) return;
    if (_animationController.isAnimating) return;
    _scaleFrom = _scale;
    _positionFrom = _position;

    double endScale;
    if (_scale == widget.minScale) {
      endScale = widget.maxScale * 0.6;
      if (endScale <= widget.minScale) {
        endScale = widget.maxScale;
      }
    } else {
      endScale = widget.minScale;
    }
    final position = _clampPosition(
      Offset.lerp(_downPos!, _position, endScale / _scale)!,
      endScale,
    );

    _scaleTo = endScale;
    _positionTo = position;

    _animationController
      ..duration = const Duration(milliseconds: 300)
      ..forward(from: 0);
  }

  static bool _calc(Offset initialPosition, Offset lastPosition) {
    final offset = lastPosition - initialPosition;
    return offset.dy.abs() > offset.dx.abs();
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_animationController.isAnimating) {
      _animationController.stop();
    }

    if (details.pointerCount == 1) {
      if (widget.isLongPic) {
        final imageHeight = _scale * _imageSize.height;
        final containerHeight = widget.containerSize.height;
        if (_scalePos != null && _calc(_scalePos!, details.focalPoint)) {
          final bool drag;
          if (details.focalPoint.dy > _scalePos!.dy) {
            drag = _position.dy.equals(
              (imageHeight - _scale * containerHeight) / 2,
              1e-6,
            );
          } else {
            drag = _position.dy.equals(containerHeight - imageHeight, 1e-6);
          }
          if (drag) {
            _gestureType = .drag;
            widget.onDragStart?.call(details);
            return;
          }
        }
      } else if (_scale == widget.minScale) {
        _gestureType = .drag;
        widget.onDragStart?.call(details);
        return;
      }
    }

    _scaleStart = _scale;
    _referenceFocalPoint = _toScene(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_gestureType == .drag) {
      widget.onDragUpdate?.call(details);
      return;
    }

    if (details.scale != 1.0) {
      _gestureType = .scale;
      _scale = clampDouble(
        _scaleStart! * details.scale,
        widget.minScale,
        widget.maxScale,
      );

      final Offset focalPointSceneScaled = _toScene(details.localFocalPoint);
      _position = _matrixTranslate(
        focalPointSceneScaled - _referenceFocalPoint!,
      );
      setState(() {});
    } else {
      _gestureType = .pan;
      final Offset focalPointScene = _toScene(details.localFocalPoint);
      final Offset translationChange = focalPointScene - _referenceFocalPoint!;
      _position = _matrixTranslate(translationChange);
      _referenceFocalPoint = _toScene(details.localFocalPoint);
      setState(() {});
    }
  }

  /// ref https://github.com/ahnaineh/custom_interactive_viewer
  int? _flingFrameCallbackId;
  Simulation? _flingSimulation;
  Duration? _flingStartTime;
  double _lastFlingElapsedSeconds = 0.0;
  Offset _flingDirection = Offset.zero;

  /// Calculate appropriate friction based on velocity magnitude
  double _calculateDynamicFriction(double velocityMagnitude) {
    // Use higher friction for faster flicks
    // These values can be tuned for the feel you want
    if (velocityMagnitude > 5000) {
      return 0.03; // Higher friction for very fast flicks
    } else if (velocityMagnitude > 3000) {
      return 0.02; // Medium friction for moderate flicks
    } else {
      return 0.01; // Lower friction for gentle movements
    }
  }

  void _startFling(Velocity velocity) {
    _stopFling();

    final double velocityMagnitude = velocity.pixelsPerSecond.distance;
    final double frictionCoefficient = _calculateDynamicFriction(
      velocityMagnitude,
    );

    _flingSimulation = FrictionSimulation(
      frictionCoefficient,
      0.0,
      velocityMagnitude,
    );

    _flingDirection = velocityMagnitude > 0
        ? velocity.pixelsPerSecond / velocityMagnitude
        : Offset.zero;

    _flingStartTime = null;
    _lastFlingElapsedSeconds = 0.0;
    _scheduleFlingFrame();
  }

  void _scheduleFlingFrame() {
    _flingFrameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
      _handleFlingFrame,
    );
  }

  void _handleFlingFrame(Duration timeStamp) {
    if (_flingSimulation == null) return;

    _flingStartTime ??= timeStamp;
    final double elapsedSeconds =
        (timeStamp - _flingStartTime!).inMicroseconds / 1e6;

    final double distance = _flingSimulation!.x(elapsedSeconds);
    final double prevDistance = _flingSimulation!.x(_lastFlingElapsedSeconds);
    final double delta = distance - prevDistance;
    _lastFlingElapsedSeconds = elapsedSeconds;

    if ((prevDistance != 0.0 && delta.abs() < 0.1) ||
        _flingSimulation!.isDone(elapsedSeconds)) {
      _stopFling();
      return;
    }

    final Offset movement = _flingDirection * delta;
    _position = _clampPosition(_position + movement, _scale);
    setState(() {});

    if (_flingSimulation!.isDone(elapsedSeconds)) {
      _stopFling();
    } else {
      _scheduleFlingFrame();
    }
  }

  void _stopFling() {
    if (_flingFrameCallbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(
        _flingFrameCallbackId!,
      );
      _flingFrameCallbackId = null;
    }
    _flingStartTime = null;
    _lastFlingElapsedSeconds = 0.0;
    _flingSimulation = null;
  }

  /// ref [InteractiveViewer]
  void _onScaleEnd(ScaleEndDetails details) {
    switch (_gestureType) {
      case _GestureType.pan:
        final double velocityMagnitude =
            details.velocity.pixelsPerSecond.distance;
        if (velocityMagnitude >= 200.0) {
          _startFling(details.velocity);
        }

      case _GestureType.scale:
        // if (details.scaleVelocity.abs() < 0.1) {
        //   return;
        // }
        // final double scale = _scale;
        // final FrictionSimulation frictionSimulation = FrictionSimulation(
        //   _interactionEndFrictionCoefficient * _scaleFactor,
        //   scale,
        //   details.scaleVelocity / 10,
        // );
        // final double tFinal = _getFinalTime(
        //   details.scaleVelocity.abs(),
        //   _interactionEndFrictionCoefficient,
        //   effectivelyMotionless: 0.1,
        // );
        // _scaleAnimation = _scaleController.drive(
        //   Tween<double>(
        //     begin: scale,
        //     end: frictionSimulation.x(tFinal),
        //   ).chain(CurveTween(curve: Curves.decelerate)),
        // )..addListener(_handleScaleAnimation);
        // _animationController
        //   ..duration = Duration(milliseconds: (tFinal * 1000).round())
        //   ..forward(from: 0);
        break;
      case _GestureType.drag:
        widget.onDragEnd?.call(details);
      case null:
    }
    _scalePos = null;
    _gestureType = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: .opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _onBlankPointerUp,
      onPointerCancel: _onBlankPointerCancel,
      onPointerPanZoomStart: _onPointerPanZoomStart,
      onPointerSignal: _onPointerSignal,
      child: ClipRect(
        child: Transform(
          transform: _matrix,
          child: widget.child,
        ),
      ),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _stopFling();
    _scalePos = event.position;
    _onBlankPointerDown(event);
    _doubleTapGestureRecognizer
      ..onDoubleTapDown = _onDoubleTapDown
      ..onDoubleTap = _onDoubleTap;
    _horizontalDragGestureRecognizer.addPointer(
      event,
      isPointerAllowed: _isAtEdge(event.localPosition),
    );
    _scaleGestureRecognizer.addPointer(event);
  }

  void _onPointerPanZoomStart(PointerPanZoomStartEvent event) {
    // 触控板手势期间不判「单击空白」
    _clearBlankCandidate();
    _scaleGestureRecognizer.addPointerPanZoom(event);
  }

  bool _isAtEdge(Offset position) {
    if (_scale <= widget.minScale) {
      _horizontalDragGestureRecognizer.setAtBothEdges();
      return true;
    }
    final containerWidth = widget.containerSize.width;
    final imageWidth = _imageSize.width * _scale;
    if (imageWidth <= containerWidth) {
      _horizontalDragGestureRecognizer.setAtBothEdges();
      return true;
    }
    final dx = (1 - _scale) * containerWidth / 2;
    final dxOffset = (imageWidth - containerWidth) / 2;
    if (_position.dx.equals(dx + dxOffset, 1e-6)) {
      _horizontalDragGestureRecognizer.isAtLeftEdge = true;
      return true;
    }
    if (_position.dx.equals(dx - dxOffset, 1e-6)) {
      _horizontalDragGestureRecognizer.isAtRightEdge = true;
      return true;
    }
    return false;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (widget.onChangePage != null &&
          !HardwareKeyboard.instance.isControlPressed) {
        widget.onChangePage!.call(event.scrollDelta.dy < 0 ? -1 : 1);
        return;
      }
      _stopFling();
      final double scaleChange = math.exp(-event.scrollDelta.dy / _scaleFactor);
      final Offset local = event.localPosition;
      final Offset focalPointScene = _toScene(local);
      _scale = clampDouble(
        _scale * scaleChange,
        widget.minScale,
        widget.maxScale,
      );
      final Offset focalPointSceneScaled = _toScene(local);
      _position = _matrixTranslate(focalPointSceneScaled - focalPointScene);
      setState(() {});
    }
  }
}

enum _GestureType { pan, scale, drag }
