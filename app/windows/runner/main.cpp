#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"
#include "desktop_integration.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  const bool start_hidden = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--autostart") != command_line_arguments.end();
  if (std::find(command_line_arguments.begin(), command_line_arguments.end(), "--install-shortcut") != command_line_arguments.end()) {
    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    std::string error;
    const bool installed = CreateStartMenuShortcut(&error);
    ::CoUninitialize();
    return installed ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  // Keep the production database and checkpoint owned by one process.
  HANDLE singleton = nullptr;
  if (GetEnvironmentVariableW(L"FOCUS_NATIVE_PROBE", nullptr, 0) == 0 &&
      GetEnvironmentVariableW(L"FOCUS_SMOKE_DIR", nullptr, 0) == 0) {
    singleton = CreateMutexW(nullptr, TRUE, L"Local\\FocusGarden.Personal.SingleInstance");
    if (singleton && GetLastError() == ERROR_ALREADY_EXISTS) {
      HWND existing = FindWindowW(nullptr, L"\u4e13\u6ce8\u82b1\u56ed \u00b7 Focus Garden");
      if (!existing) existing = FindWindowW(nullptr, L"focus_garden");
      if (existing && !start_hidden) { ShowWindow(existing, SW_RESTORE); SetForegroundWindow(existing); }
      CloseHandle(singleton);
      return EXIT_SUCCESS;
    }
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"focus_garden", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Dispose Flutter and COM-backed plugins before uninitializing COM. The tray
  // quit action posts WM_QUIT directly, so WM_DESTROY may not have run yet.
  window.Destroy();
  ::CoUninitialize();
  if (singleton) CloseHandle(singleton);
  return EXIT_SUCCESS;
}
