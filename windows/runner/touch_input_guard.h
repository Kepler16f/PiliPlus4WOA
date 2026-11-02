#ifndef PILIPLUS_TOUCH_INPUT_GUARD_H_
#define PILIPLUS_TOUCH_INPUT_GUARD_H_

#include <windows.h>
#include <commctrl.h>

namespace piliplus {
constexpr UINT_PTR kTouchInputGuardId = 1;

inline LRESULT CALLBACK TouchInputGuard(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam, UINT_PTR subclass_id,
                                DWORD_PTR) {
  // Flutter 3.47 can turn an uncaptured WM_MOUSEMOVE into a phantom mouse
  // down during touch input. Its matching touch-promoted mouse up is ignored.
  // Apply flutter/flutter#190029 at the engine's child HWND until the bundled
  // engine includes that fix. Hover and captured real mouse drags still pass.
  constexpr WPARAM kMouseButtons =
      MK_LBUTTON | MK_RBUTTON | MK_MBUTTON | MK_XBUTTON1 | MK_XBUTTON2;
  if (message == WM_MOUSEMOVE && (wparam & kMouseButtons) != 0 &&
      GetCapture() != window) {
    return 0;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, TouchInputGuard, subclass_id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}
}  // namespace piliplus


#endif
