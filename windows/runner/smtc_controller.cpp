#include "smtc_controller.h"

#include <roapi.h>

namespace piliplus {

namespace {

using Microsoft::WRL::Wrappers::HStringReference;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (size <= 1) {
    return std::wstring();
  }
  std::wstring wide(size - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], size);
  return wide;
}

std::string GetStringValue(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() && std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return "";
}

bool GetBoolValue(const flutter::EncodableMap& map, const char* key, bool default_val = false) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() && std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  return default_val;
}

int64_t GetInt64Value(const flutter::EncodableMap& map, const char* key, int64_t default_val = 0) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end()) {
    if (std::holds_alternative<int32_t>(it->second)) {
      return std::get<int32_t>(it->second);
    }
    if (std::holds_alternative<int64_t>(it->second)) {
      return std::get<int64_t>(it->second);
    }
  }
  return default_val;
}

}  // namespace

SmtcController::SmtcController() = default;

SmtcController::~SmtcController() {
  Dispose();
}

bool SmtcController::Initialize(HWND hwnd, flutter::BinaryMessenger* messenger) {
  hwnd_ = hwnd;
  if (!hwnd_ || !messenger) {
    return false;
  }

  // Set up Flutter method channel
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "piliplus/windows_smtc", &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  // Get SMTC interop for the top-level window
  Microsoft::WRL::ComPtr<ISystemMediaTransportControlsInterop> interop;
  HRESULT hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Media_SystemMediaTransportControls).Get(),
      IID_PPV_ARGS(&interop));
  if (FAILED(hr) || !interop) {
    return false;
  }

  hr = interop->GetForWindow(hwnd_, IID_PPV_ARGS(&smtc_));
  if (FAILED(hr) || !smtc_) {
    return false;
  }

  // Query SMTC2 and DisplayUpdater
  smtc_.As(&smtc2_);
  smtc_->get_DisplayUpdater(&display_updater_);

  // Register ButtonPressed callback
  auto button_handler = Microsoft::WRL::Callback<
      ABI::Windows::Foundation::ITypedEventHandler<
          ABI::Windows::Media::SystemMediaTransportControls*,
          ABI::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs*>>(
      [this](ABI::Windows::Media::ISystemMediaTransportControls*,
             ABI::Windows::Media::ISystemMediaTransportControlsButtonPressedEventArgs* args) -> HRESULT {
        if (!args) {
          return S_OK;
        }
        ABI::Windows::Media::SystemMediaTransportControlsButton btn;
        if (SUCCEEDED(args->get_Button(&btn))) {
          switch (btn) {
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Play:
              EnqueueEvent(SmtcActionType::kPlay);
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Pause:
              EnqueueEvent(SmtcActionType::kPause);
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Stop:
              EnqueueEvent(SmtcActionType::kStop);
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Next:
              EnqueueEvent(SmtcActionType::kNext);
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Previous:
              EnqueueEvent(SmtcActionType::kPrevious);
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_FastForward:
              EnqueueEvent(SmtcActionType::kFastForward);
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Rewind:
              EnqueueEvent(SmtcActionType::kRewind);
              break;
            default:
              break;
          }
        }
        return S_OK;
      });

  smtc_->add_ButtonPressed(button_handler.Get(), &button_token_);

  // Register PlaybackPositionChangeRequested callback if SMTC2 is supported
  if (smtc2_) {
    auto seek_handler = Microsoft::WRL::Callback<
        ABI::Windows::Foundation::ITypedEventHandler<
            ABI::Windows::Media::SystemMediaTransportControls*,
            ABI::Windows::Media::PlaybackPositionChangeRequestedEventArgs*>>(
        [this](ABI::Windows::Media::ISystemMediaTransportControls*,
               ABI::Windows::Media::IPlaybackPositionChangeRequestedEventArgs* args) -> HRESULT {
          if (!args) {
            return S_OK;
          }
          ABI::Windows::Foundation::TimeSpan requested_pos{};
          if (SUCCEEDED(args->get_RequestedPlaybackPosition(&requested_pos))) {
            // Duration is in 100ns units -> convert to milliseconds
            int64_t position_ms = requested_pos.Duration / 10000;
            EnqueueEvent(SmtcActionType::kSeek, position_ms);
          }
          return S_OK;
        });

    smtc2_->add_PlaybackPositionChangeRequested(seek_handler.Get(), &seek_token_);
  }

  return true;
}

void SmtcController::Dispose() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_ = nullptr;
  }

  if (smtc_) {
    if (button_token_.value != 0) {
      smtc_->remove_ButtonPressed(button_token_);
      button_token_.value = 0;
    }
    if (smtc2_ && seek_token_.value != 0) {
      smtc2_->remove_PlaybackPositionChangeRequested(seek_token_);
      seek_token_.value = 0;
    }
    if (display_updater_) {
      display_updater_->ClearAll();
      display_updater_ = nullptr;
    }
    smtc_->put_IsEnabled(FALSE);
    smtc_ = nullptr;
    smtc2_ = nullptr;
  }

  hwnd_ = nullptr;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    event_queue_.clear();
  }
}

void SmtcController::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "setMediaItem") {
    if (call.arguments() && std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
      UpdateMediaItem(std::get<flutter::EncodableMap>(*call.arguments()));
    }
    result->Success();
  } else if (method == "setState") {
    if (call.arguments() && std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
      UpdateState(std::get<flutter::EncodableMap>(*call.arguments()));
    }
    result->Success();
  } else if (method == "clear") {
    Clear();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void SmtcController::UpdateMediaItem(const flutter::EncodableMap& args) {
  if (!display_updater_) {
    return;
  }

  std::string title = GetStringValue(args, "title");
  std::string artist = GetStringValue(args, "artist");
  std::string art_cache_file = GetStringValue(args, "artCacheFile");

  std::wstring title_w = Utf8ToWide(title);
  std::wstring artist_w = Utf8ToWide(artist);

  display_updater_->put_Type(ABI::Windows::Media::MediaPlaybackType_Video);

  Microsoft::WRL::ComPtr<ABI::Windows::Media::IVideoDisplayProperties> video_props;
  if (SUCCEEDED(display_updater_->get_VideoProperties(&video_props)) && video_props) {
    video_props->put_Title(HStringReference(title_w.c_str()).Get());
    video_props->put_Subtitle(HStringReference(artist_w.c_str()).Get());
  }

  // Load thumbnail if available
  bool thumbnail_set = false;
  if (!art_cache_file.empty()) {
    std::wstring path_w = Utf8ToWide(art_cache_file);
    Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStream> file_stream;
    HRESULT hr = CreateRandomAccessStreamOnFile(
        path_w.c_str(), STGM_READ | STGM_SHARE_DENY_WRITE, IID_PPV_ARGS(&file_stream));
    if (SUCCEEDED(hr) && file_stream) {
      Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStreamReferenceStatics> statics;
      hr = RoGetActivationFactory(
          HStringReference(RuntimeClass_Windows_Storage_Streams_RandomAccessStreamReference).Get(),
          IID_PPV_ARGS(&statics));
      if (SUCCEEDED(hr) && statics) {
        Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStreamReference> stream_ref;
        hr = statics->CreateFromStream(file_stream.Get(), &stream_ref);
        if (SUCCEEDED(hr) && stream_ref) {
          display_updater_->put_Thumbnail(stream_ref.Get());
          thumbnail_set = true;
        }
      }
    }
  }

  if (!thumbnail_set) {
    display_updater_->put_Thumbnail(nullptr);
  }

  display_updater_->Update();
}

void SmtcController::UpdateState(const flutter::EncodableMap& args) {
  if (!smtc_) {
    return;
  }

  bool playing = GetBoolValue(args, "playing");
  int64_t processing_state = GetInt64Value(args, "processingState");
  int64_t position_ms = GetInt64Value(args, "positionMs");
  int64_t duration_ms = GetInt64Value(args, "durationMs");

  bool can_play = GetBoolValue(args, "canPlay", true);
  bool can_pause = GetBoolValue(args, "canPause", true);
  bool can_stop = GetBoolValue(args, "canStop", true);
  bool can_seek = GetBoolValue(args, "canSeek", true);
  bool can_ff = GetBoolValue(args, "canFastForward", true);
  bool can_rewind = GetBoolValue(args, "canRewind", true);
  bool can_next = GetBoolValue(args, "canSkipToNext", false);
  bool can_prev = GetBoolValue(args, "canSkipToPrevious", false);

  smtc_->put_IsEnabled(TRUE);
  smtc_->put_IsPlayEnabled(can_play ? TRUE : FALSE);
  smtc_->put_IsPauseEnabled(can_pause ? TRUE : FALSE);
  smtc_->put_IsStopEnabled(can_stop ? TRUE : FALSE);
  smtc_->put_IsFastForwardEnabled(can_ff ? TRUE : FALSE);
  smtc_->put_IsRewindEnabled(can_rewind ? TRUE : FALSE);
  smtc_->put_IsNextEnabled(can_next ? TRUE : FALSE);
  smtc_->put_IsPreviousEnabled(can_prev ? TRUE : FALSE);

  ABI::Windows::Media::MediaPlaybackStatus status = ABI::Windows::Media::MediaPlaybackStatus_Closed;
  if (processing_state == 2 /* buffering */) {
    status = ABI::Windows::Media::MediaPlaybackStatus_Changing;
  } else if (playing) {
    status = ABI::Windows::Media::MediaPlaybackStatus_Playing;
  } else if (processing_state == 4 /* completed */ || processing_state == 0 /* idle */) {
    status = ABI::Windows::Media::MediaPlaybackStatus_Stopped;
  } else {
    status = ABI::Windows::Media::MediaPlaybackStatus_Paused;
  }
  smtc_->put_PlaybackStatus(status);

  // Update timeline if supported
  if (smtc2_ && duration_ms > 0 && can_seek) {
    Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControlsTimelineProperties> timeline_props;
    HRESULT hr = RoActivateInstance(
        HStringReference(RuntimeClass_Windows_Media_SystemMediaTransportControlsTimelineProperties).Get(),
        &timeline_props);
    if (SUCCEEDED(hr) && timeline_props) {
      ABI::Windows::Foundation::TimeSpan start_time{0};
      ABI::Windows::Foundation::TimeSpan min_seek{0};
      ABI::Windows::Foundation::TimeSpan end_time{duration_ms * 10000};
      ABI::Windows::Foundation::TimeSpan max_seek{duration_ms * 10000};
      ABI::Windows::Foundation::TimeSpan pos_time{position_ms * 10000};

      timeline_props->put_StartTime(start_time);
      timeline_props->put_MinSeekTime(min_seek);
      timeline_props->put_EndTime(end_time);
      timeline_props->put_MaxSeekTime(max_seek);
      timeline_props->put_Position(pos_time);

      smtc2_->UpdateTimelineProperties(timeline_props.Get());
    }
  }
}

void SmtcController::Clear() {
  if (display_updater_) {
    display_updater_->ClearAll();
  }
  if (smtc_) {
    smtc_->put_PlaybackStatus(ABI::Windows::Media::MediaPlaybackStatus_Closed);
    smtc_->put_IsEnabled(FALSE);
  }
}

void SmtcController::EnqueueEvent(SmtcActionType action, int64_t position_ms) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    event_queue_.push_back({action, position_ms});
  }
  if (hwnd_) {
    PostMessage(hwnd_, WM_APP_SMTC_EVENT, 0, 0);
  }
}

void SmtcController::ProcessQueuedEvents() {
  std::vector<SmtcQueuedEvent> events;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    events.swap(event_queue_);
  }

  if (!channel_) {
    return;
  }

  for (const auto& ev : events) {
    switch (ev.action) {
      case SmtcActionType::kPlay:
        channel_->InvokeMethod("onButtonPressed", std::make_unique<flutter::EncodableValue>("play"));
        break;
      case SmtcActionType::kPause:
        channel_->InvokeMethod("onButtonPressed", std::make_unique<flutter::EncodableValue>("pause"));
        break;
      case SmtcActionType::kStop:
        channel_->InvokeMethod("onButtonPressed", std::make_unique<flutter::EncodableValue>("stop"));
        break;
      case SmtcActionType::kNext:
        channel_->InvokeMethod("onButtonPressed", std::make_unique<flutter::EncodableValue>("next"));
        break;
      case SmtcActionType::kPrevious:
        channel_->InvokeMethod("onButtonPressed", std::make_unique<flutter::EncodableValue>("previous"));
        break;
      case SmtcActionType::kFastForward:
        channel_->InvokeMethod("onButtonPressed", std::make_unique<flutter::EncodableValue>("fastForward"));
        break;
      case SmtcActionType::kRewind:
        channel_->InvokeMethod("onButtonPressed", std::make_unique<flutter::EncodableValue>("rewind"));
        break;
      case SmtcActionType::kSeek:
        channel_->InvokeMethod("onSeekRequested", std::make_unique<flutter::EncodableValue>(ev.position_ms));
        break;
    }
  }
}

}  // namespace piliplus
