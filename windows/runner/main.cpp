#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Disable Windows 11 background power throttling (EcoQoS) and timer
  // resolution throttling so unfocused PiP / background playback is not
  // starved on Windows on ARM64.
  PROCESS_POWER_THROTTLING_STATE power_throttling{};
  power_throttling.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  power_throttling.ControlMask =
      PROCESS_POWER_THROTTLING_EXECUTION_SPEED |
      PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
  power_throttling.StateMask = 0;
  ::SetProcessInformation(::GetCurrentProcess(), ProcessPowerThrottling,
                          &power_throttling, sizeof(power_throttling));

  flutter::DartProject project(L"data");

  // https://github.com/flutter/flutter/issues/188635
  // https://github.com/flutter/flutter/issues/191050
  // https://github.com/flutter/flutter/issues/191069
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"piliplus", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
