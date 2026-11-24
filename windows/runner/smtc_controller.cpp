#include "smtc_controller.h"

#include <roapi.h>

#include <fstream>
#include <utility>

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

bool GetBoolValue(const flutter::EncodableMap& map,
                  const char* key,
                  bool default_val = false) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() && std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  return default_val;
}

int64_t GetInt64Value(const flutter::EncodableMap& map,
                      const char* key,
                      int64_t default_val = 0) {
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

bool GetByteVector(const flutter::EncodableMap& map,
                   const char* key,
                   std::vector<uint8_t>* out_bytes) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() &&
      std::holds_alternative<std::vector<uint8_t>>(it->second)) {
    *out_bytes = std::get<std::vector<uint8_t>>(it->second);
    return !out_bytes->empty();
  }
  return false;
}

bool ReadFileToBytes(const std::wstring& path_w,
                     std::vector<uint8_t>* out_bytes) {
  if (path_w.empty()) {
    return false;
  }
  std::ifstream file(path_w, std::ios::binary | std::ios::ate);
  if (!file.is_open()) {
    return false;
  }
  std::streamsize size = file.tellg();
  if (size <= 0 || size > 10 * 1024 * 1024) {
    return false;
  }
  file.seekg(0, std::ios::beg);
  out_bytes->resize(static_cast<size_t>(size));
  return file.read(reinterpret_cast<char*>(out_bytes->data()), size).good();
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

  HRESULT ro_hr = ::RoInitialize(RO_INIT_SINGLETHREADED);
  if (SUCCEEDED(ro_hr)) {
    ro_initialized_ = true;
  }

  thumb_state_ = std::make_shared<ThumbnailAsyncState>();
  thumb_state_->hwnd = hwnd_;

  // Set up Flutter method channel
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "piliplus/windows_smtc",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) { HandleMethodCall(call, std::move(result)); });

  // Get SMTC interop for the top-level window
  Microsoft::WRL::ComPtr<ISystemMediaTransportControlsInterop> interop;
  HRESULT hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Media_SystemMediaTransportControls)
          .Get(),
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

  // Register ButtonPressed callback (agile via FtmBase so MTA WinRT callbacks never stall or fail COM STA marshaling)
  auto button_handler = Microsoft::WRL::Callback<
      Microsoft::WRL::Implements<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          ABI::Windows::Foundation::ITypedEventHandler<
              ABI::Windows::Media::SystemMediaTransportControls*,
              ABI::Windows::Media::
                  SystemMediaTransportControlsButtonPressedEventArgs*>,
          Microsoft::WRL::FtmBase>>(
      [this](ABI::Windows::Media::ISystemMediaTransportControls*,
             ABI::Windows::Media::
                 ISystemMediaTransportControlsButtonPressedEventArgs* args)
          -> HRESULT {
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
            case ABI::Windows::Media::
                SystemMediaTransportControlsButton_Previous:
              EnqueueEvent(SmtcActionType::kPrevious);
              break;
            case ABI::Windows::Media::
                SystemMediaTransportControlsButton_FastForward:
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
        Microsoft::WRL::Implements<
            Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
            ABI::Windows::Foundation::ITypedEventHandler<
                ABI::Windows::Media::SystemMediaTransportControls*,
                ABI::Windows::Media::PlaybackPositionChangeRequestedEventArgs*>,
            Microsoft::WRL::FtmBase>>(
        [this](ABI::Windows::Media::ISystemMediaTransportControls*,
               ABI::Windows::Media::IPlaybackPositionChangeRequestedEventArgs*
                   args) -> HRESULT {
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

    smtc2_->add_PlaybackPositionChangeRequested(seek_handler.Get(),
                                                &seek_token_);
  }

  return true;
}

void SmtcController::Dispose() {
  if (thumb_state_) {
    thumb_state_->disposed.store(true);
    thumb_state_->latest_generation.fetch_add(1);
    std::lock_guard<std::mutex> lock(thumb_state_->mutex);
    thumb_state_->ready_stream.Reset();
    thumb_state_->hwnd = nullptr;
  }

  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_ = nullptr;
  }

  thumbnail_ref_.Reset();
  thumbnail_stream_.Reset();
  current_media_id_.clear();

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
      display_updater_->Update();
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

  if (ro_initialized_) {
    ::RoUninitialize();
    ro_initialized_ = false;
  }
}

void SmtcController::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "setMediaItem") {
    if (call.arguments() &&
        std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
      UpdateMediaItem(std::get<flutter::EncodableMap>(*call.arguments()));
    }
    result->Success();
  } else if (method == "setState") {
    if (call.arguments() &&
        std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
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
  if (!display_updater_ || !thumb_state_) {
    return;
  }

  std::string media_id = GetStringValue(args, "mediaId");
  std::string title = GetStringValue(args, "title");
  std::string artist = GetStringValue(args, "artist");
  std::string album = GetStringValue(args, "album");

  std::vector<uint8_t> thumb_bytes;
  if (!GetByteVector(args, "thumbnailBytes", &thumb_bytes)) {
    std::string art_cache_file = GetStringValue(args, "artCacheFile");
    if (!art_cache_file.empty()) {
      ReadFileToBytes(Utf8ToWide(art_cache_file), &thumb_bytes);
    }
  }

  const bool media_changed =
      !media_id.empty() && media_id != current_media_id_;
  if (media_changed) {
    current_media_id_ = media_id;
    thumb_state_->latest_generation.fetch_add(1);
    {
      std::lock_guard<std::mutex> lock(thumb_state_->mutex);
      thumb_state_->ready_stream.Reset();
    }
    thumbnail_ref_.Reset();
    thumbnail_stream_.Reset();
    // Clear all stale metadata and thumbnail from the previous video before
    // populating the new item so Windows 11 Quick Settings never retains old
    // fields or cover artwork.
    display_updater_->ClearAll();
  }

  // Use Music display properties (like Chromium SMTC) so Windows 11 Quick
  // Settings reliably displays title, creator/artist, and cover artwork.
  display_updater_->put_Type(ABI::Windows::Media::MediaPlaybackType_Music);

  Microsoft::WRL::ComPtr<ABI::Windows::Media::IMusicDisplayProperties>
      music_props;
  if (SUCCEEDED(display_updater_->get_MusicProperties(&music_props)) &&
      music_props) {
    std::wstring title_w = Utf8ToWide(title);
    std::wstring artist_w = Utf8ToWide(artist);
    music_props->put_Title(HStringReference(title_w.c_str()).Get());
    music_props->put_Artist(HStringReference(artist_w.c_str()).Get());

    Microsoft::WRL::ComPtr<ABI::Windows::Media::IMusicDisplayProperties2>
        music_props2;
    if (SUCCEEDED(music_props.As(&music_props2)) && music_props2) {
      std::wstring album_w = Utf8ToWide(album);
      music_props2->put_AlbumTitle(HStringReference(album_w.c_str()).Get());
    }
  }

  if (smtc_) {
    smtc_->put_IsEnabled(TRUE);
  }
  display_updater_->Update();

  if (!thumb_bytes.empty()) {
    StartThumbnailWrite(thumb_bytes);
  }
}

void SmtcController::StartThumbnailWrite(const std::vector<uint8_t>& bytes) {
  if (!thumb_state_ || thumb_state_->disposed.load() || bytes.empty()) {
    return;
  }

  const uint64_t gen = thumb_state_->latest_generation.fetch_add(1) + 1;

  Microsoft::WRL::ComPtr<IInspectable> stream_insp;
  HRESULT hr = RoActivateInstance(
      HStringReference(
          RuntimeClass_Windows_Storage_Streams_InMemoryRandomAccessStream)
          .Get(),
      &stream_insp);
  if (FAILED(hr) || !stream_insp) {
    return;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStream>
      mem_stream;
  hr = stream_insp.As(&mem_stream);
  if (FAILED(hr) || !mem_stream) {
    return;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IOutputStream>
      output_stream;
  hr = mem_stream.As(&output_stream);
  if (FAILED(hr) || !output_stream) {
    return;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IDataWriterFactory>
      writer_factory;
  hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Storage_Streams_DataWriter).Get(),
      IID_PPV_ARGS(&writer_factory));
  if (FAILED(hr) || !writer_factory) {
    return;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IDataWriter> writer;
  hr = writer_factory->CreateDataWriter(output_stream.Get(), &writer);
  if (FAILED(hr) || !writer) {
    return;
  }

  hr = writer->WriteBytes(static_cast<UINT32>(bytes.size()),
                          const_cast<BYTE*>(bytes.data()));
  if (FAILED(hr)) {
    return;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::Foundation::IAsyncOperation<UINT32>>
      store_op;
  hr = writer->StoreAsync(&store_op);
  if (FAILED(hr) || !store_op) {
    return;
  }

  std::shared_ptr<ThumbnailAsyncState> shared = thumb_state_;
  auto handler = Microsoft::WRL::Callback<
      Microsoft::WRL::Implements<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          ABI::Windows::Foundation::IAsyncOperationCompletedHandler<UINT32>,
          Microsoft::WRL::FtmBase>>(
      [shared, gen, mem_stream, writer](
          ABI::Windows::Foundation::IAsyncOperation<UINT32>* async_info,
          ABI::Windows::Foundation::AsyncStatus status) -> HRESULT {
        if (!async_info || shared->disposed.load() ||
            gen != shared->latest_generation.load() ||
            status != ABI::Windows::Foundation::AsyncStatus::Completed) {
          Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IOutputStream>
              unused_out;
          writer->DetachStream(&unused_out);
          return S_OK;
        }

        UINT32 bytes_written = 0;
        HRESULT res_hr = async_info->GetResults(&bytes_written);
        Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IOutputStream>
            unused_out;
        writer->DetachStream(&unused_out);

        if (FAILED(res_hr) || bytes_written == 0) {
          return S_OK;
        }

        if (FAILED(mem_stream->Seek(0))) {
          return S_OK;
        }

        HWND target_hwnd = nullptr;
        {
          std::lock_guard<std::mutex> lock(shared->mutex);
          if (shared->disposed.load() ||
              gen != shared->latest_generation.load()) {
            return S_OK;
          }
          shared->ready_generation = gen;
          shared->ready_stream = mem_stream;
          target_hwnd = shared->hwnd;
        }
        if (target_hwnd) {
          PostMessage(target_hwnd, WM_APP_SMTC_EVENT, 0, 0);
        }
        return S_OK;
      });

  store_op->put_Completed(handler.Get());
}

void SmtcController::ApplyReadyThumbnail() {
  if (!thumb_state_ || thumb_state_->disposed.load() || !display_updater_) {
    return;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStream>
      stream;
  uint64_t ready_gen = 0;
  {
    std::lock_guard<std::mutex> lock(thumb_state_->mutex);
    if (!thumb_state_->ready_stream) {
      return;
    }
    ready_gen = thumb_state_->ready_generation;
    stream = std::move(thumb_state_->ready_stream);
  }

  if (ready_gen != thumb_state_->latest_generation.load() || !stream) {
    return;
  }

  Microsoft::WRL::ComPtr<
      ABI::Windows::Storage::Streams::IRandomAccessStreamReferenceStatics>
      statics;
  HRESULT hr = RoGetActivationFactory(
      HStringReference(
          RuntimeClass_Windows_Storage_Streams_RandomAccessStreamReference)
          .Get(),
      IID_PPV_ARGS(&statics));
  if (FAILED(hr) || !statics) {
    return;
  }

  Microsoft::WRL::ComPtr<
      ABI::Windows::Storage::Streams::IRandomAccessStreamReference>
      stream_ref;
  hr = statics->CreateFromStream(stream.Get(), &stream_ref);
  if (FAILED(hr) || !stream_ref) {
    return;
  }

  // Keep both stream and stream reference alive on SmtcController so
  // ShellExperienceHost can read the agile in-memory stream cross-process.
  thumbnail_stream_ = stream;
  thumbnail_ref_ = stream_ref;
  display_updater_->put_Thumbnail(thumbnail_ref_.Get());
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

  ABI::Windows::Media::MediaPlaybackStatus status =
      ABI::Windows::Media::MediaPlaybackStatus_Closed;
  if (processing_state == 2 /* buffering */) {
    status = ABI::Windows::Media::MediaPlaybackStatus_Changing;
  } else if (playing) {
    status = ABI::Windows::Media::MediaPlaybackStatus_Playing;
  } else if (processing_state == 4 /* completed */ ||
             processing_state == 0 /* idle */) {
    status = ABI::Windows::Media::MediaPlaybackStatus_Stopped;
  } else {
    status = ABI::Windows::Media::MediaPlaybackStatus_Paused;
  }
  smtc_->put_PlaybackStatus(status);

  // Update timeline properties (clear stale timeline when switching to live)
  if (smtc2_) {
    Microsoft::WRL::ComPtr<IInspectable> timeline_insp;
    HRESULT hr = RoActivateInstance(
        HStringReference(
            RuntimeClass_Windows_Media_SystemMediaTransportControlsTimelineProperties)
            .Get(),
        &timeline_insp);
    Microsoft::WRL::ComPtr<
        ABI::Windows::Media::ISystemMediaTransportControlsTimelineProperties>
        timeline_props;
    if (SUCCEEDED(hr) && timeline_insp &&
        SUCCEEDED(timeline_insp.As(&timeline_props)) && timeline_props) {
      if (duration_ms > 0 && can_seek) {
        const int64_t clamped_pos =
            position_ms < 0 ? 0
                            : (position_ms > duration_ms ? duration_ms
                                                         : position_ms);
        timeline_props->put_StartTime({0});
        timeline_props->put_MinSeekTime({0});
        timeline_props->put_EndTime({duration_ms * 10000});
        timeline_props->put_MaxSeekTime({duration_ms * 10000});
        timeline_props->put_Position({clamped_pos * 10000});
      } else {
        timeline_props->put_StartTime({0});
        timeline_props->put_MinSeekTime({0});
        timeline_props->put_EndTime({0});
        timeline_props->put_MaxSeekTime({0});
        timeline_props->put_Position({0});
      }
      smtc2_->UpdateTimelineProperties(timeline_props.Get());
    }
  }
}

void SmtcController::Clear() {
  if (thumb_state_) {
    thumb_state_->latest_generation.fetch_add(1);
    std::lock_guard<std::mutex> lock(thumb_state_->mutex);
    thumb_state_->ready_stream.Reset();
  }
  thumbnail_ref_.Reset();
  thumbnail_stream_.Reset();
  current_media_id_.clear();

  if (display_updater_) {
    display_updater_->ClearAll();
    display_updater_->Update();
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
  ApplyReadyThumbnail();

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
        channel_->InvokeMethod("onButtonPressed",
                               std::make_unique<flutter::EncodableValue>("play"));
        break;
      case SmtcActionType::kPause:
        channel_->InvokeMethod(
            "onButtonPressed",
            std::make_unique<flutter::EncodableValue>("pause"));
        break;
      case SmtcActionType::kStop:
        channel_->InvokeMethod("onButtonPressed",
                               std::make_unique<flutter::EncodableValue>("stop"));
        break;
      case SmtcActionType::kNext:
        channel_->InvokeMethod("onButtonPressed",
                               std::make_unique<flutter::EncodableValue>("next"));
        break;
      case SmtcActionType::kPrevious:
        channel_->InvokeMethod(
            "onButtonPressed",
            std::make_unique<flutter::EncodableValue>("previous"));
        break;
      case SmtcActionType::kFastForward:
        channel_->InvokeMethod(
            "onButtonPressed",
            std::make_unique<flutter::EncodableValue>("fastForward"));
        break;
      case SmtcActionType::kRewind:
        channel_->InvokeMethod(
            "onButtonPressed",
            std::make_unique<flutter::EncodableValue>("rewind"));
        break;
      case SmtcActionType::kSeek:
        channel_->InvokeMethod(
            "onSeekRequested",
            std::make_unique<flutter::EncodableValue>(ev.position_ms));
        break;
    }
  }
}

}  // namespace piliplus
