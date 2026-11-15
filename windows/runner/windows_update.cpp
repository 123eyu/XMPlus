#include "windows_update.h"

#include <shellapi.h>
#include <shlobj.h>

#include <filesystem>
#include <string>
#include <iterator>

namespace {
constexpr UINT_PTR kInstallerTimer = 0x584D5055;
constexpr WPARAM kUpdateReady = 0x584D5055;
constexpr wchar_t kUninstallKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    L"{684378F5-16A1-4C9A-BA9F-71D6709188B0}_is1";

std::filesystem::path ApplicationDirectory() {
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                        static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) return {};
  path.resize(length);
  return std::filesystem::path(path).parent_path();
}

bool CanWriteDirectory(const std::filesystem::path& directory) {
  const auto probe = directory / (L".xmplus-update-write-" +
      std::to_wstring(GetCurrentProcessId()) + L".tmp");
  HANDLE file = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  CloseHandle(file);
  return true;
}

bool MatchesInstallation(HKEY root, const std::filesystem::path& directory) {
  for (REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(root, kUninstallKey, 0,
                      KEY_QUERY_VALUE | view, &key) != ERROR_SUCCESS) continue;
    std::wstring location(32768, L'\0');
    DWORD bytes = static_cast<DWORD>(location.size() * sizeof(wchar_t));
    const LSTATUS status = RegGetValueW(key, nullptr, L"InstallLocation",
        RRF_RT_REG_SZ, nullptr, location.data(), &bytes);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) continue;
    std::error_code error;
    if (std::filesystem::equivalent(directory, location.c_str(), error) &&
        !error) return true;
  }
  return false;
}

bool IsInstallerName(const std::wstring& name) {
  constexpr wchar_t prefix[] = L"XMPlus-";
  constexpr wchar_t suffix[] = L"-windows-x64-setup.exe";
  constexpr size_t start = std::size(prefix) - 1;
  constexpr size_t tail = std::size(suffix) - 1;
  if (name.size() <= start + tail || name.compare(0, start, prefix) != 0 ||
      name.compare(name.size() - tail, tail, suffix) != 0) return false;
  const size_t end = name.size() - tail;
  size_t position = start;
  for (int part = 0; part < 3; ++part) {
    const size_t first = position;
    while (position < end && name[position] >= L'0' &&
           name[position] <= L'9') ++position;
    if (position == first) return false;
    if (part < 2 && (position == end || name[position++] != L'.')) return false;
  }
  return position == end;
}

bool IsPlainPath(const std::filesystem::path& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

bool IsAllowedInstaller(const std::filesystem::path& installer) {
  // Local drive paths only: no UNC/device paths, alternate streams or aliases.
  const auto text = installer.wstring();
  if (text.size() < 4 || text[1] != L':' || text[2] != L'\\' ||
      text.find(L':', 2) != std::wstring::npos ||
      !installer.is_absolute() || !IsInstallerName(installer.filename().wstring())) {
    return false;
  }
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
    return false;
  }
  // Matches path_provider_windows and Runner.rc CompanyName/ProductName.
  const auto company = std::filesystem::path(local) / L"XMPlus contributors";
  CoTaskMemFree(local);
  const auto application = company / L"XMPlus";
  const auto cache = application / L"updates";
  if (!IsPlainPath(company) || !IsPlainPath(application) ||
      !IsPlainPath(cache) || !IsPlainPath(installer)) return false;
  std::error_code error;
  if (!std::filesystem::is_regular_file(installer, error) || error) return false;
  const auto parent = std::filesystem::canonical(installer.parent_path(), error);
  if (error) return false;
  const auto expected = std::filesystem::canonical(cache, error);
  if (error || CompareStringOrdinal(parent.c_str(), -1, expected.c_str(), -1,
                                    TRUE) != CSTR_EQUAL) return false;
  return true;
}
}  // namespace

WindowsUpdate::WindowsUpdate(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window), channel_(messenger, "teikengstudio.xmplus/update",
                               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "isUpdateReady") {
      result->Success(flutter::EncodableValue(ready_));
      return;
    }
    if (call.method_name() != "installUpdate") {
      result->NotImplemented();
      return;
    }
    PollInstaller();
    if (installer_) {
      result->Error("installer_running", "An update is already running.");
      return;
    }
    const auto* arguments = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const auto item = arguments
        ? arguments->find(flutter::EncodableValue("path"))
        : flutter::EncodableMap::const_iterator{};
    const auto* path = arguments && item != arguments->end()
        ? std::get_if<std::string>(&item->second) : nullptr;
    if (!path || path->find('\0') != std::string::npos) {
      result->Error("invalid_installer", "Missing installer path.");
      return;
    }
    std::filesystem::path installer;
    try {
      installer = std::filesystem::u8path(*path);
    } catch (const std::filesystem::filesystem_error&) {
      result->Error("invalid_installer", "Invalid installer path.");
      return;
    }
    const auto directory = ApplicationDirectory();
    if (directory.empty() || !IsAllowedInstaller(installer)) {
      result->Error("invalid_installer", "Installer is outside the update cache.");
      return;
    }
    // 'open' preserves the original user token; Inno handles elevation and
    // runasoriginaluser relaunch. /DIR also updates portable copies in place.
    const bool installed_machine = MatchesInstallation(HKEY_LOCAL_MACHINE, directory);
    const bool installed = installed_machine || MatchesInstallation(HKEY_CURRENT_USER, directory);
    const bool machine = installed_machine || !CanWriteDirectory(directory);
    const std::wstring parameters =
        L"/SILENT /SP- /NORESTART /NOCLOSEAPPLICATIONS /NORESTARTAPPLICATIONS"
        L" /UPDATE=1 /UPDATEPID=" + std::to_wstring(GetCurrentProcessId()) +
        L" /UPDATEHWND=" + std::to_wstring(reinterpret_cast<UINT_PTR>(window_)) +
        L" /DIR=\"" + directory.wstring() + L"\"" +
        (machine ? L" /ALLUSERS" : L" /CURRENTUSER") +
        (installed ? L"" : L" /PORTABLE=1");
    SHELLEXECUTEINFOW launch{};
    launch.cbSize = sizeof(launch);
    launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    launch.hwnd = window_;
    launch.lpVerb = L"open";
    launch.lpFile = installer.c_str();
    launch.lpParameters = parameters.c_str();
    launch.lpDirectory = directory.c_str();
    launch.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&launch) || !launch.hProcess) {
      const DWORD error = GetLastError();
      result->Error(error == ERROR_CANCELLED ? "installer_cancelled" :
                    "installer_launch_failed", "Cannot start installer (" +
                    std::to_string(error) + ").");
      return;
    }
    ready_ = false;
    installer_ = launch.hProcess;
    pending_ = std::move(result);
    if (!SetTimer(window_, kInstallerTimer, 250, nullptr)) {
      pending_->Error("installer_monitor_failed", "Cannot monitor installer.");
      pending_.reset();
    }
  });
}

WindowsUpdate::~WindowsUpdate() {
  channel_.SetMethodCallHandler(nullptr);
  KillTimer(window_, kInstallerTimer);
  if (installer_) CloseHandle(installer_);
}

void WindowsUpdate::PollInstaller() {
  if (!installer_ || WaitForSingleObject(installer_, 0) == WAIT_TIMEOUT) return;
  DWORD exit_code = 0;
  GetExitCodeProcess(installer_, &exit_code);
  CloseHandle(installer_);
  installer_ = nullptr;
  ready_ = false;
  KillTimer(window_, kInstallerTimer);
  if (pending_) {
    pending_->Error("installer_exited", "Installer exited before hand-off (" +
                    std::to_string(exit_code) + ").");
    pending_.reset();
  }
}

bool WindowsUpdate::HandleWindowMessage(UINT message, WPARAM wparam) {
  if (message == WM_TIMER && wparam == kInstallerTimer) {
    PollInstaller();
    return true;
  }
  if (message == WM_CLOSE && wparam == kUpdateReady && installer_ &&
      WaitForSingleObject(installer_, 0) == WAIT_TIMEOUT) {
    // Setup sends this only after it is ready, and waits for normal Flutter
    // shutdown. Ordinary close requests retain the user's tray preference.
    ready_ = true;
    if (pending_) {
      pending_->Success();
      pending_.reset();
    }
  }
  return false;
}
