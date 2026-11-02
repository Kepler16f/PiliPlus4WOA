#include "../../windows/runner/touch_input_guard.h"

#include <iostream>

namespace {
int moves = 0;
int downs = 0;
int touches = 0;
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_MOUSEMOVE) ++moves;
  if (message == WM_LBUTTONDOWN) ++downs;
  if (message == WM_POINTERUPDATE) ++touches;
  return DefWindowProc(window, message, wp, lp);
}
}

int main() {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = L"PiliPlusTouchInputGuardTest";
  if (!RegisterClassW(&window_class)) return 1;
  HWND window = CreateWindowW(window_class.lpszClassName, L"", WS_POPUP,
                              0, 0, 100, 100, nullptr, nullptr,
                              window_class.hInstance, nullptr);
  if (!window || !SetWindowSubclass(window, piliplus::TouchInputGuard,
                                    piliplus::kTouchInputGuardId, 0)) return 2;
  bool passed = true;
  auto expect = [&](bool condition, const char* name) {
    if (!condition) { std::cerr << name << '\n'; passed = false; }
  };
  ReleaseCapture();
  for (WPARAM button : {MK_LBUTTON, MK_RBUTTON, MK_MBUTTON, MK_XBUTTON1, MK_XBUTTON2}) {
    SendMessage(window, WM_MOUSEMOVE, button, 0);
  }
  expect(moves == 0, "uncaptured button moves must not create a phantom pointer");
  SendMessage(window, WM_MOUSEMOVE, 0, 0);
  SendMessage(window, WM_MOUSEMOVE, MK_CONTROL | MK_SHIFT, 0);
  expect(moves == 2, "hover including keyboard modifiers must pass");
  SetCapture(window);
  SendMessage(window, WM_MOUSEMOVE, MK_LBUTTON, 0);
  expect(moves == 3, "captured real drag must pass");
  ReleaseCapture();
  SendMessage(window, WM_LBUTTONDOWN, MK_LBUTTON, 0);
  SendMessage(window, WM_POINTERUPDATE, 0, 0);
  expect(downs == 1 && touches == 1, "button and native touch messages must pass");
  DestroyWindow(window);
  UnregisterClassW(window_class.lpszClassName, window_class.hInstance);
  return passed ? 0 : 3;
}
