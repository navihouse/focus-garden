#include "flutter_window.h"
#include "desktop_integration.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {
  // Detach platform handlers while their messenger and native view still exist.
  OnDestroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  focus_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "focus_garden/native",
      &flutter::StandardMethodCodec::GetInstance());
  focus_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "getDesktopIntegration") {
      DesktopIntegrationState state;
      std::string error;
      if (!ReadDesktopIntegration(&state, &error)) { result->Error("DESKTOP_INTEGRATION", error); return; }
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("startupEnabled"), flutter::EncodableValue(state.startup_enabled)},
          {flutter::EncodableValue("startupCurrentPath"), flutter::EncodableValue(state.startup_current_path)},
          {flutter::EncodableValue("shortcutExists"), flutter::EncodableValue(state.shortcut_exists)},
          {flutter::EncodableValue("shortcutCurrentPath"), flutter::EncodableValue(state.shortcut_current_path)}}));
    } else if (call.method_name() == "setLaunchAtLogin") {
      const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!map) { result->Error("INVALID_ARGUMENT", "Missing enabled flag"); return; }
      const auto it = map->find(flutter::EncodableValue("enabled"));
      const bool* enabled = it == map->end() ? nullptr : std::get_if<bool>(&it->second);
      if (!enabled) { result->Error("INVALID_ARGUMENT", "Missing enabled flag"); return; }
      std::string error;
      if (SetLaunchAtLogin(*enabled, &error)) result->Success();
      else result->Error("DESKTOP_INTEGRATION", error);
    } else if (call.method_name() == "createStartMenuShortcut") {
      std::string error;
      if (CreateStartMenuShortcut(&error)) result->Success();
      else result->Error("DESKTOP_INTEGRATION", error);
    } else if (call.method_name() == "takeSuspend") {
      result->Success(flutter::EncodableValue(suspend_pending_));
      suspend_pending_ = false;
    } else if (call.method_name() == "notify") {
      std::wstring text = L"Focus session finished";
      const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
      if (map) {
        auto it = map->find(flutter::EncodableValue("text"));
        if (it != map->end()) {
          const auto* value = std::get_if<std::string>(&it->second);
          if (value) {
            const int size = MultiByteToWideChar(CP_UTF8, 0, value->c_str(), -1, nullptr, 0);
            if (size > 0) { text.resize(size); MultiByteToWideChar(CP_UTF8, 0, value->c_str(), -1, text.data(), size); }
          }
        }
      }
      NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = GetHandle(); data.uID = 4397;
      data.uFlags = NIF_ICON | NIF_TIP | NIF_INFO;
      data.hIcon = LoadIcon(nullptr, IDI_INFORMATION);
      wcscpy_s(data.szTip, L"Focus Garden"); wcscpy_s(data.szInfoTitle, L"Focus Garden");
      wcsncpy_s(data.szInfo, text.c_str(), _TRUNCATE); data.dwInfoFlags = NIIF_INFO;
      Shell_NotifyIconW(NIM_ADD, &data); Shell_NotifyIconW(NIM_MODIFY, &data);
      SetTimer(GetHandle(), 4397, 12000, nullptr);
      result->Success();
    } else { result->NotImplemented(); }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (focus_channel_) {
    focus_channel_->SetMethodCallHandler(nullptr);
    focus_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND) {
    suspend_pending_ = true;
    if (focus_channel_) focus_channel_->InvokeMethod("suspend", nullptr);
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_TIMER:
      if (wparam == 4397) {
        NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = hwnd; data.uID = 4397;
        Shell_NotifyIconW(NIM_DELETE, &data); KillTimer(hwnd, 4397);
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
