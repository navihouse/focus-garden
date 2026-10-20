#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_
#include <string>

struct DesktopIntegrationState {
  bool startup_enabled = false;
  bool startup_current_path = false;
  bool shortcut_exists = false;
  bool shortcut_current_path = false;
};

bool ReadDesktopIntegration(DesktopIntegrationState* state, std::string* error);
bool SetLaunchAtLogin(bool enabled, std::string* error);
bool CreateStartMenuShortcut(std::string* error);
#endif
