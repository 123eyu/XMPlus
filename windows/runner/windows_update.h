#ifndef RUNNER_WINDOWS_UPDATE_H_
#define RUNNER_WINDOWS_UPDATE_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

class WindowsUpdate {
 public:
  WindowsUpdate(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsUpdate();
  bool HandleWindowMessage(UINT message, WPARAM wparam);

 private:
  void PollInstaller();

  HWND window_;
  HANDLE installer_ = nullptr;
  bool ready_ = false;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> pending_;
};

#endif  // RUNNER_WINDOWS_UPDATE_H_
