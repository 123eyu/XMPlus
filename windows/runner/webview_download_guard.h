#ifndef XMPLUS_WEBVIEW_DOWNLOAD_GUARD_H_
#define XMPLUS_WEBVIEW_DOWNLOAD_GUARD_H_

#include <WebView2.h>
#include <wrl.h>

// WebView2 forbids the CDP download-behavior commands. Cancel synchronously
// before any file/dialog is created; the handler belongs to this WebView only.
inline HRESULT XmplusDenyWebViewDownloads(ICoreWebView2* webview) {
  if (!webview) return E_POINTER;
  Microsoft::WRL::ComPtr<ICoreWebView2_4> downloads;
  auto hr = webview->QueryInterface(IID_PPV_ARGS(&downloads));
  if (FAILED(hr)) return hr;
  EventRegistrationToken token{};
  return downloads->add_DownloadStarting(
      Microsoft::WRL::Callback<ICoreWebView2DownloadStartingEventHandler>(
          [](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
            const auto cancelled = args->put_Cancel(TRUE);
            if (FAILED(cancelled)) return cancelled;
            return args->put_Handled(TRUE);
          }).Get(), &token);
}

#endif  // XMPLUS_WEBVIEW_DOWNLOAD_GUARD_H_
