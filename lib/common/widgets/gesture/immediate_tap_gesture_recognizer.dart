import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

class ImmediateTapGestureRecognizer extends OneSequenceGestureRecognizer {
  ImmediateTapGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter = _defaultButtonAcceptBehavior,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.onTap,
  });

  static bool _defaultButtonAcceptBehavior(int buttons) =>
      buttons == kPrimaryButton;

  GestureTapDownCallback? onTapDown;

  GestureTapUpCallback? onTapUp;

  GestureTapCancelCallback? onTapCancel;

  GestureTapCallback? onTap;

  PointerUpEvent? _up;
  int? _activePointer;
  bool _sentTapDown = false;
  bool _wonArena = false;
  Offset? _initialPosition;
  // 最后一笔「与 active pointer 相关」的事件时刻，用于识别器自我复活（见
  // isPointerAllowed）：触控驱动偶发不发 up/cancel 时，不留死闩。
  Duration? _lastActivity;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    // 闩死兜底（ARM64 修改版 2026-10-12）：上一根指针早已没有事件、只是
    // _activePointer 残留时，绝不能继续拒绝之后每一次按下 —— 「触控用着用着
    // 点击/长按全废、重启才好」就是这个形状。同一根手指还压着时两次 down 间隔
    // 远小于阈值，不会误伤。
    final active = _activePointer;
    final last = _lastActivity;
    if (active != null &&
        (last == null || event.timeStamp - last > _deadPointerGrace)) {
      _reset();
    }
    return _activePointer == null && super.isPointerAllowed(event);
  }

  static const Duration _deadPointerGrace = Duration(milliseconds: 1500);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _reset(event.pointer);
    _lastActivity = event.timeStamp;
    _handleTapDown(event);
    _initialPosition = event.position;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _activePointer) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }
    _lastActivity = event.timeStamp;

    if (event is PointerMoveEvent) {
      _handlePointerMove(event);
    } else if (event is PointerUpEvent) {
      _up = event;
      _handlePointerUp(event);
    } else if (event is PointerCancelEvent) {
      // 必须 _reset（原来只 resolve，_activePointer 残留 → isPointerAllowed
      // 从此永远 false → 「触控偶发点击/长按全废、重启才好」的主因之一）。
      _cancelGesture('pointer cancelled');
    } else if (event is PointerRemovedEvent) {
      // 驱动只发了 removed、没发 up/cancel（WOA 触控偶发）：按取消收尾，
      // 并立刻停止跟踪，didStopTrackingLastPointer 里做最后兜底复位。
      _cancelGesture('pointer removed');
      stopTrackingPointer(event.pointer);
    }

    stopTrackingIfPointerNoLongerDown(event);
  }

  void _handleTapDown(PointerDownEvent event) {
    if (_sentTapDown) return;
    _sentTapDown = true;

    if (onTapDown != null) {
      final details = TapDownDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        kind: event.kind,
      );
      invokeCallback<void>('onTapDown', () => onTapDown!(details));
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final initial = _initialPosition;
    if (initial == null) return;
    // 阈值按输入设备分档（ARM64 修改版 2026-10-12）：原来写死 2px
    // （distanceSquared>4），对鼠标合适，但手指「点按」天然漂移就超过它 ——
    // 触控下 tap 被自己提前否决，表现即「点一下进不了控制页」，且是否触发
    // 完全取决于这次手指抖没抖（偶发）。touch 用框架 kTouchSlop（18px），
    // 与竞技场里 tap/long-press 的判据同档；mouse 保持原有 2px 行为不变。
    final slop = event.kind == PointerDeviceKind.mouse
        ? kPrecisePointerPanSlop
        : kTouchSlop;
    if ((event.position - initial).distanceSquared > slop * slop) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      // 这次已经主动放弃，不可能再赢竞技场（与 didStopTrackingLastPointer 里
      // 那种「up 先于 arena sweep、accept 还要回来补发 _up」的情形不同），
      // 直接复位 —— 否则 _activePointer 残留会把之后每一次按下都挡在
      // isPointerAllowed 外面（闩死形状之一）。
      _reset();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_wonArena) {
      _handleTapUp(event);
    }
  }

  void _handleTapUp(PointerUpEvent event) {
    if (onTapUp != null) {
      final details = TapUpDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        kind: event.kind,
      );
      invokeCallback<void>('onTapUp', () => onTapUp!(details));
    }

    if (onTap != null) {
      invokeCallback<void>('onTap', onTap!);
    }

    _reset();
  }

  void _cancelGesture(String reason) {
    if (_sentTapDown && onTapCancel != null) {
      invokeCallback<void>('onTapCancel: $reason', onTapCancel!);
    }
    _reset();
  }

  void _reset([int? pointer]) {
    _activePointer = pointer;
    _up = null;
    _sentTapDown = false;
    _wonArena = false;
  }

  @override
  void acceptGesture(int pointer) {
    super.acceptGesture(pointer);

    if (pointer == _activePointer) {
      _wonArena = true;

      if (_up != null) {
        _handleTapUp(_up!);
      }
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);

    if (pointer == _activePointer) {
      _cancelGesture('gesture rejected by arena');
      stopTrackingPointer(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    // ⚠️ 这里**不能**整体 _reset（本文件 2026-10-12 的一次改动试过，是回归）：
    // binding 自身的 handleEvent（负责 gestureArena.sweep）排在命中链**最后**，
    // 所以手指抬起时的顺序是「识别器收到 up → stopTrackingPointer → 本回调」
    // 然后才「arena sweep → acceptGesture」。acceptGesture 依赖此时仍在的
    // _activePointer/_up 来补发「抬起后才赢得竞技场」的 tap（_up 的存在意义
    // 就是这个）。这里复位会把这类 tap 全丢掉。
    // 泄漏（永远等不到 accept 的 up）由别处收口：_handlePointerMove 的否决
    // 路径显式 _cancelGesture；驱动丢事件由 view 侧的幽灵指针守卫合成 cancel；
    // isPointerAllowed 还有一个基于时间窗的自愈兜底。
    _initialPosition = null;
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (_wonArena && disposition == GestureDisposition.rejected) {
      _cancelGesture('spontaneous');
    }
    super.resolve(disposition);
  }

  @override
  String get debugDescription => 'immediate tap';

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('activePointer', _activePointer))
      ..add(
        FlagProperty(
          'sentTapDown',
          value: _sentTapDown,
          ifTrue: 'has sentTapDown',
        ),
      )
      ..add(FlagProperty('wonArena', value: _wonArena, ifTrue: 'wonArena'))
      ..add(
        DiagnosticsProperty<PointerUpEvent>(
          'pointerUpEvent',
          _up,
          defaultValue: null,
        ),
      );
  }
}
