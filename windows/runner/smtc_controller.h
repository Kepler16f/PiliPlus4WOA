#ifndef PILIPLUS_SMTC_CONTROLLER_H_
#define PILIPLUS_SMTC_CONTROLLER_H_

#include <windows.h>
#include <windows.foundation.h>
#include <windows.media.h>
#include <windows.storage.h>
#include <windows.storage.streams.h>
#include <SystemMediaTransportControlsInterop.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/implements.h>
#include <wrl/wrappers/corewrappers.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
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

struct ThumbnailAsyncState {
  std::atomic<bool> disposed{false};
  std::atomic<uint64_t> latest_generation{0};
  HWND hwnd = nullptr;
  std::mutex mutex;
  uint64_t ready_generation = 0;
  Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStream>
      ready_stream;
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

  void StartThumbnailWrite(const std::vector<uint8_t>& bytes);
  void ApplyReadyThumbnail();

  void EnqueueEvent(SmtcActionType action, int64_t position_ms = 0);

  HWND hwnd_ = nullptr;
  bool ro_initialized_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls>
      smtc_;
  Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls2>
      smtc2_;
  Microsoft::WRL::ComPtr<
      ABI::Windows::Media::ISystemMediaTransportControlsDisplayUpdater>
      display_updater_;

  std::string current_media_id_;
  std::shared_ptr<ThumbnailAsyncState> thumb_state_;
  Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStream>
      thumbnail_stream_;
  Microsoft::WRL::ComPtr<
      ABI::Windows::Storage::Streams::IRandomAccessStreamReference>
      thumbnail_ref_;

  EventRegistrationToken button_token_{0};
  EventRegistrationToken seek_token_{0};

  std::mutex queue_mutex_;
  std::vector<SmtcQueuedEvent> event_queue_;
};

}  // namespace piliplus

#endif  // PILIPLUS_SMTC_CONTROLLER_H_
