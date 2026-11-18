#ifndef PILIPLUS_SMTC_CONTROLLER_H_
#define PILIPLUS_SMTC_CONTROLLER_H_

#include <windows.h>
#include <windows.foundation.h>
#include <windows.media.h>
#include <windows.storage.h>
#include <windows.storage.streams.h>
#include <SystemMediaTransportControlsInterop.h>
#include <shcore.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace piliplus {

constexpr UINT WM_APP_SMTC_EVENT = WM_APP + 101;

enum class SmtcActionType {
  kPlay,
  kPause,
  kStop,
  kNext,
  kPrevious,
  kFastForward,
  kRewind,
  kSeek,
};

struct SmtcQueuedEvent {
  SmtcActionType action;
  int64_t position_ms = 0;
};

class SmtcController {
 public:
  SmtcController();
  ~SmtcController();

  bool Initialize(HWND hwnd, flutter::BinaryMessenger* messenger);
  void Dispose();
  void ProcessQueuedEvents();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void UpdateMediaItem(const flutter::EncodableMap& args);
  void UpdateState(const flutter::EncodableMap& args);
  void Clear();

  void EnqueueEvent(SmtcActionType action, int64_t position_ms = 0);

  HWND hwnd_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls> smtc_;
  Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls2> smtc2_;
  Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControlsDisplayUpdater> display_updater_;

  EventRegistrationToken button_token_{0};
  EventRegistrationToken seek_token_{0};

  std::mutex queue_mutex_;
  std::vector<SmtcQueuedEvent> event_queue_;
};

}  // namespace piliplus

#endif  // PILIPLUS_SMTC_CONTROLLER_H_
