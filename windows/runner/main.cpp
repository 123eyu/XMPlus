// Adapted from PiliPlus, commit d9e9626f1a3f89cd9ca85e18f61aaba02634e12a.
// GPL-3.0; see ../LICENSE.PiliPlus and ../../NOTICE.
// Modified 2026-11-04 for XMLY Flutter.

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <sddl.h>

#include <memory>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kInstanceName[] =
    L"Local\\XMPlus.1A36E85E-8FF7-4C18-9874-94C85A0F41BD.";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"XMPlus";
constexpr DWORD kStartupWaitMs = 15000;
using UniqueHandle = std::unique_ptr<void, decltype(&::CloseHandle)>;

// Hold ownership until after the window/engine are destroyed. Windows abandons
// the mutex on a crash, so a surviving waiter can safely become the new owner.
class SingleInstance {
 public:
  enum class Result { primary, duplicate, error };

  ~SingleInstance() {
    if (owns_mutex_) {
      ::ReleaseMutex(mutex_.get());
    }
  }

  Result Acquire() {
    HANDLE token_handle = nullptr;
    if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token_handle)) {
      return Result::error;
    }
    UniqueHandle token(token_handle, ::CloseHandle);
    alignas(TOKEN_USER) BYTE user_buffer[sizeof(TOKEN_USER) +
                                        SECURITY_MAX_SID_SIZE];
    DWORD bytes = 0;
    if (!::GetTokenInformation(token.get(), TokenUser, user_buffer,
                               sizeof(user_buffer), &bytes)) {
      return Result::error;
    }
    wchar_t* sid_string = nullptr;
    if (!::ConvertSidToStringSidW(
            reinterpret_cast<TOKEN_USER*>(user_buffer)->User.Sid, &sid_string)) {
      return Result::error;
    }
    std::unique_ptr<wchar_t, decltype(&::LocalFree)> sid(sid_string, ::LocalFree);
    // Local\\ is the Windows session namespace; the SID separates users even
    // when several identities run applications inside that session.
    property_ = std::wstring(kInstanceName) + sid.get();
    mutex_.reset(::CreateMutexW(nullptr, FALSE, (property_ + L".Mutex").c_str()));
    ready_.reset(::CreateEventW(nullptr, TRUE, FALSE,
                               (property_ + L".Ready").c_str()));
    if (!mutex_ || !ready_) {
      return Result::error;
    }

    const ULONGLONG deadline = ::GetTickCount64() + kStartupWaitMs;
    const HANDLE handles[] = {mutex_.get(), ready_.get()};
    for (;;) {
      // Check ownership before readiness: a crashed owner's event may still
      // exist because another launch has an open handle to it.
      DWORD wait = ::WaitForSingleObject(mutex_.get(), 0);
      if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
        owns_mutex_ = true;
        return ::ResetEvent(ready_.get()) ? Result::primary : Result::error;
      }
      if (wait == WAIT_FAILED) {
        return Result::error;
      }
      if (RestoreWindow()) {
        return Result::duplicate;
      }
      const ULONGLONG now = ::GetTickCount64();
      if (now >= deadline) {
        return Result::duplicate;
      }
      wait = ::WaitForMultipleObjects(2, handles, FALSE,
                                      static_cast<DWORD>(deadline - now));
      if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED_0) {
        owns_mutex_ = true;
        return ::ResetEvent(ready_.get()) ? Result::primary : Result::error;
      }
      if (wait == WAIT_FAILED) {
        return Result::error;
      }
      if (wait == WAIT_TIMEOUT) {
        RestoreWindow();
        return Result::duplicate;
      }
      // A signalled event without a marked window means the owner is shutting
      // down, or a replacement has not reset its predecessor's event yet. This
      // bounded native wait avoids spinning while still noticing owner death.
      if (!RestoreWindow()) {
        wait = ::WaitForSingleObject(mutex_.get(), 25);
        if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
          owns_mutex_ = true;
          return ::ResetEvent(ready_.get()) ? Result::primary : Result::error;
        }
        if (wait == WAIT_FAILED) {
          return Result::error;
        }
      } else {
        return Result::duplicate;
      }
    }
  }

  bool Publish(HWND window) {
    // Never identify another Flutter runner by its shared class name alone.
    return ::SetPropW(window, property_.c_str(), reinterpret_cast<HANDLE>(1)) &&
           ::SetEvent(ready_.get());
  }

 private:
  bool RestoreWindow() const {
    HWND window = nullptr;
    while ((window = ::FindWindowExW(nullptr, window, kWindowClass,
                                     kWindowTitle)) != nullptr) {
      if (::GetPropW(window, property_.c_str()) == nullptr) {
        continue;
      }
      ::ShowWindowAsync(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(window);
      return true;
    }
    return false;
  }

  UniqueHandle mutex_{nullptr, ::CloseHandle};
  UniqueHandle ready_{nullptr, ::CloseHandle};
  std::wstring property_;
  bool owns_mutex_ = false;
};

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  SingleInstance single_instance;
  const auto launch = single_instance.Acquire();
  if (launch == SingleInstance::Result::duplicate) {
    return EXIT_SUCCESS;
  }
  if (launch == SingleInstance::Result::error) {
    ::MessageBoxW(nullptr, L"Unable to acquire the XMPlus single-instance lock.",
                  L"XMPlus", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

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
  Win32Window::Size size(1280, 800);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  if (!single_instance.Publish(window.GetHandle())) {
    return EXIT_FAILURE;
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
