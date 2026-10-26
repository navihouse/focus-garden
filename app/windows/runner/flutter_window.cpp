#include "flutter_window.h"
#include "desktop_integration.h"
#include "task_sound.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
bool ReadHotkey(const flutter::EncodableMap& args, const char* name, UINT* modifiers, UINT* key) {
  const auto entry = args.find(flutter::EncodableValue(name));
  const auto* binding = entry == args.end() ? nullptr : std::get_if<flutter::EncodableMap>(&entry->second);
  if (!binding) return false;
  const auto m = binding->find(flutter::EncodableValue("modifiers"));
  const auto k = binding->find(flutter::EncodableValue("keyCode"));
  const auto* mv = m == binding->end() ? nullptr : std::get_if<int32_t>(&m->second);
  const auto* kv = k == binding->end() ? nullptr : std::get_if<int32_t>(&k->second);
  if (!mv || !kv || *mv < 1 || *mv > 7 || (*mv & (MOD_CONTROL | MOD_ALT)) == 0) return false;
  if (!(*kv == VK_SPACE || (*kv >= '0' && *kv <= '9') || (*kv >= 'A' && *kv <= 'Z') ||
        (*kv >= VK_F1 && *kv <= VK_F11))) return false;
  *modifiers = static_cast<UINT>(*mv); *key = static_cast<UINT>(*kv); return true;
}
}  // namespace

void FlutterWindow::ReleaseHotkeys() {
  if (music_hotkey_) UnregisterHotKey(GetHandle(), 4401);
  if (timer_hotkey_) UnregisterHotKey(GetHandle(), 4402);
  music_hotkey_ = timer_hotkey_ = false;
}

flutter::EncodableMap FlutterWindow::AcquireHotkeys() {
  if (!music_hotkey_) music_hotkey_ = RegisterHotKey(GetHandle(), 4401,
      music_modifiers_ | MOD_NOREPEAT, music_key_) != 0;
  if (!timer_hotkey_) timer_hotkey_ = RegisterHotKey(GetHandle(), 4402,
      timer_modifiers_ | MOD_NOREPEAT, timer_key_) != 0;
  return {{flutter::EncodableValue("music"), flutter::EncodableValue(music_hotkey_)},
          {flutter::EncodableValue("timer"), flutter::EncodableValue(timer_hotkey_)}};
}

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
    if (call.method_name() == "openLocalFile") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto it = args ? args->find(flutter::EncodableValue("path")) : flutter::EncodableMap::const_iterator{};
      const auto* path = args && it != args->end() ? std::get_if<std::string>(&it->second) : nullptr;
      if (!path || path->size() < 3 || path->size() > 16384 || path->find('\0') != std::string::npos ||
          !(((*path)[0] >= 'A' && (*path)[0] <= 'Z') || ((*path)[0] >= 'a' && (*path)[0] <= 'z')) ||
          (*path)[1] != ':' || ((*path)[2] != '\\' && (*path)[2] != '/')) {
        result->Error("INVALID_FILE_PATH", "Expected an absolute local file path"); return;
      }
      const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(), static_cast<int>(path->size()), nullptr, 0);
      if (size <= 0) { result->Error("INVALID_FILE_PATH", "Invalid file path encoding"); return; }
      std::wstring wide(size, L'\0');
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(), static_cast<int>(path->size()), wide.data(), size);
      const DWORD attrs = GetFileAttributesW(wide.c_str());
      if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        result->Error("FILE_UNAVAILABLE", "File does not exist or is inaccessible"); return;
      }
      SHELLEXECUTEINFOW info{}; info.cbSize = sizeof(info);
      info.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
      info.hwnd = GetHandle(); info.lpVerb = L"open"; info.lpFile = wide.c_str(); info.nShow = SW_SHOWNORMAL;
      if (ShellExecuteExW(&info)) result->Success();
      else result->Error("OPEN_FILE_FAILED", "No application could open this file");
    } else if (call.method_name() == "registerHotkeys") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      UINT music_modifiers, music_key, timer_modifiers, timer_key;
      if (!args || !ReadHotkey(*args, "music", &music_modifiers, &music_key) ||
          !ReadHotkey(*args, "timer", &timer_modifiers, &timer_key) ||
          (music_modifiers == timer_modifiers && music_key == timer_key)) {
        result->Error("INVALID_HOTKEY", "Expected two different Ctrl/Alt key combinations"); return;
      }
      const auto old_music_modifiers = music_modifiers_, old_music_key = music_key_;
      const auto old_timer_modifiers = timer_modifiers_, old_timer_key = timer_key_;
      ReleaseHotkeys();
      music_modifiers_ = music_modifiers; music_key_ = music_key;
      timer_modifiers_ = timer_modifiers; timer_key_ = timer_key;
      auto status = AcquireHotkeys();
      const bool accepted = music_hotkey_ && timer_hotkey_;
      status[flutter::EncodableValue("accepted")] = flutter::EncodableValue(accepted);
      const auto initial_it = args->find(flutter::EncodableValue("initial"));
      const auto* initial = initial_it == args->end() ? nullptr : std::get_if<bool>(&initial_it->second);
      if (!accepted && !(initial && *initial)) {
        ReleaseHotkeys();
        music_modifiers_ = old_music_modifiers; music_key_ = old_music_key;
        timer_modifiers_ = old_timer_modifiers; timer_key_ = old_timer_key;
        status[flutter::EncodableValue("restored")] = flutter::EncodableValue(AcquireHotkeys());
      }
      result->Success(flutter::EncodableValue(status));
    } else if (call.method_name() == "suspendHotkeys") {
      ReleaseHotkeys(); result->Success();
    } else if (call.method_name() == "resumeHotkeys") {
      result->Success(flutter::EncodableValue(AcquireHotkeys()));
    } else if (call.method_name() == "taskCompleted") {
      if (PlayTaskCompletionSound()) result->Success();
      else result->Error("TASK_SOUND", "Could not play completion sound");
    } else if (call.method_name() == "timerSound") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto it = args ? args->find(flutter::EncodableValue("kind")) : flutter::EncodableMap::const_iterator{};
      const auto* kind = args && it != args->end() ? std::get_if<std::string>(&it->second) : nullptr;
      if (!kind || (*kind != "focus" && *kind != "rest")) {
        result->Error("INVALID_ARGUMENT", "Expected focus or rest sound");
      } else if (PlayTimerSound(*kind == "rest")) result->Success();
      else result->Error("TIMER_SOUND", "Could not play timer sound");
    } else if (call.method_name() == "getDesktopIntegration") {
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
      wcsncpy_s(data.szInfo, text.c_str(), _TRUNCATE); data.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
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
  ReleaseHotkeys();
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
  if (message == WM_HOTKEY && focus_channel_ && (wparam == 4401 || wparam == 4402)) {
    focus_channel_->InvokeMethod("hotkey", std::make_unique<flutter::EncodableValue>(
        wparam == 4401 ? "music" : "timer"));
    return 0;
  }
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
