#include "desktop_integration.h"
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <vector>

namespace {
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunName[] = L"FocusGarden";
using Microsoft::WRL::ComPtr;

bool Fail(std::string* error, const char* operation, long code) {
  *error = std::string(operation) + " failed (" + std::to_string(code) + ")";
  return false;
}

std::wstring ExecutablePath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (!length || length >= buffer.size()) return L"";
  std::wstring path(buffer.data(), length);
  // Resolve SUBST aliases: logon must work without the development P: drive.
  const HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    const DWORD size = GetFinalPathNameByHandleW(file, buffer.data(),
        static_cast<DWORD>(buffer.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(file);
    if (size && size < buffer.size()) {
      path.assign(buffer.data(), size);
      if (path.rfind(L"\\\\?\\UNC\\", 0) == 0) path = L"\\\\" + path.substr(8);
      else if (path.rfind(L"\\\\?\\", 0) == 0) path = path.substr(4);
    }
  }
  return path;
}

bool ShortcutPath(std::wstring* path, bool create_folder, std::string* error) {
  PWSTR programs = nullptr;
  const HRESULT result = SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs);
  if (FAILED(result)) return Fail(error, "Read Start menu folder", result);
  const std::wstring folder = std::wstring(programs) + L"\\FocusGarden";
  CoTaskMemFree(programs);
  if (create_folder && !CreateDirectoryW(folder.c_str(), nullptr)) {
    const DWORD code = GetLastError();
    if (code != ERROR_ALREADY_EXISTS) return Fail(error, "Create Start menu folder", code);
  }
  *path = folder + L"\\FocusGarden - \u4e13\u6ce8\u82b1\u56ed.lnk";
  return true;
}

bool ShortcutTargets(const std::wstring& shortcut, const std::wstring& executable) {
  ComPtr<IShellLinkW> link;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(link.GetAddressOf())))) return false;
  ComPtr<IPersistFile> persisted;
  if (FAILED(link.As(&persisted)) || FAILED(persisted->Load(shortcut.c_str(), STGM_READ))) return false;
  std::vector<wchar_t> target(32768);
  if (FAILED(link->GetPath(target.data(), static_cast<int>(target.size()), nullptr, SLGP_RAWPATH))) return false;
  return _wcsicmp(target.data(), executable.c_str()) == 0;
}
}

bool ReadDesktopIntegration(DesktopIntegrationState* state, std::string* error) {
  const auto executable = ExecutablePath();
  if (executable.empty()) return Fail(error, "Resolve executable", GetLastError());
  const auto command = L"\"" + executable + L"\" --autostart";
  DWORD bytes = 0;
  LSTATUS code = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunName, RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
  if (code == ERROR_SUCCESS) {
    std::vector<wchar_t> value(bytes / sizeof(wchar_t) + 1, 0);
    code = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunName, RRF_RT_REG_SZ, nullptr, value.data(), &bytes);
    if (code != ERROR_SUCCESS) return Fail(error, "Read launch at login", code);
    state->startup_enabled = value[0] != 0;
    state->startup_current_path = _wcsicmp(value.data(), command.c_str()) == 0;
  } else if (code != ERROR_FILE_NOT_FOUND && code != ERROR_PATH_NOT_FOUND) {
    return Fail(error, "Read launch at login", code);
  }
  std::wstring shortcut;
  if (!ShortcutPath(&shortcut, false, error)) return false;
  state->shortcut_exists = GetFileAttributesW(shortcut.c_str()) != INVALID_FILE_ATTRIBUTES;
  state->shortcut_current_path = state->shortcut_exists && ShortcutTargets(shortcut, executable);
  return true;
}

bool SetLaunchAtLogin(bool enabled, std::string* error) {
  HKEY key = nullptr;
  LSTATUS code = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (code != ERROR_SUCCESS) return Fail(error, "Open launch at login", code);
  if (enabled) {
    const auto executable = ExecutablePath();
    const auto command = L"\"" + executable + L"\" --autostart";
    if (executable.empty() || command.size() > 260) {
      RegCloseKey(key); return Fail(error, "Launch path is empty or too long", ERROR_BAD_PATHNAME);
    }
    code = RegSetValueExW(key, kRunName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    code = RegDeleteValueW(key, kRunName);
    if (code == ERROR_FILE_NOT_FOUND) code = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return code == ERROR_SUCCESS || Fail(error, "Update launch at login", code);
}

bool CreateStartMenuShortcut(std::string* error) {
  const auto executable = ExecutablePath();
  if (executable.empty()) return Fail(error, "Resolve executable", GetLastError());
  std::wstring shortcut;
  if (!ShortcutPath(&shortcut, true, error)) return false;
  if (ShortcutTargets(shortcut, executable)) return true;
  ComPtr<IShellLinkW> link;
  HRESULT result = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(link.GetAddressOf()));
  if (FAILED(result)) return Fail(error, "Create shortcut", result);
  result = link->SetPath(executable.c_str());
  if (SUCCEEDED(result)) result = link->SetWorkingDirectory(executable.substr(0, executable.find_last_of(L"\\/")).c_str());
  if (SUCCEEDED(result)) result = link->SetDescription(L"FocusGarden - \u4e13\u6ce8\u82b1\u56ed");
  if (SUCCEEDED(result)) result = link->SetIconLocation(executable.c_str(), 0);
  ComPtr<IPersistFile> persisted;
  if (SUCCEEDED(result)) result = link.As(&persisted);
  if (SUCCEEDED(result)) result = persisted->Save(shortcut.c_str(), TRUE);
  if (FAILED(result)) return Fail(error, "Save shortcut", result);
  SHChangeNotify(SHCNE_CREATE, SHCNF_PATHW, shortcut.c_str(), nullptr);
  return true;
}
