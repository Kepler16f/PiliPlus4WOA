# PiliPlus4WOA: patch media_kit_video's Windows native renderer.
#
# Why this file exists (instead of a .patch applied with `git apply`):
# the code we need to touch lives in a *git* dependency in the pub cache, whose
# directory name contains a commit hash (and the cache may hold several
# media-kit checkouts at once). A context diff would be fragile there, and
# gluing to a hard-coded hash path is worse. So:
#   * the target package is located through .dart_tool/package_config.json,
#     which is exactly what `flutter pub get` resolved -- no guessing;
#   * the edits are anchored string replacements, so they cannot apply at a
#     wrong offset;
#   * ALL anchors are verified before ANY file is written, so a mismatch can
#     never leave a half-patched tree -- it throws and fails the build instead.
#
# What it does:
#   1. Adds a pure-diagnostics counter block (no behaviour change) so we can
#      tell WHERE the picture stops updating while mpv keeps decoding. Output
#      goes to %TEMP%\piliplus_angle_trace.log; see the comment block inserted
#      into angle_surface_manager.h for how to read it.
#   2. Holds the surface mutex across ANGLESurfaceManager::SetSize(), which
#      releases and re-creates both D3D textures and the EGL surface. Without
#      it, a concurrent Read() (called from Flutter's raster thread) can observe
#      the just-nulled textures; that frame's CopyResource is skipped and the
#      shared texture keeps the previous frame -- a frozen picture while mpv
#      happily keeps rendering.
#
# All inserted C++ comments are ASCII on purpose: MSVC reads sources in the
# system codepage unless /utf-8 is set, so non-ASCII comments in a file whose
# build flags we do not control are a compile risk.

$ErrorActionPreference = "Stop"

# Local self-test: `powershell -File patch_media_kit_video.ps1 <path-to-media-kit-root>`
# (CI passes no argument and resolves through package_config.json instead).
$RootOverride = if ($args.Count -ge 1) { [string]$args[0] } else { "" }

function Read-Text($path) {
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Write-Text($path, $text) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
}

# 这个包的检出在 Windows 上是 CRLF，而本脚本里的锚点（here-string）是 LF。
# 匹配前统一成 LF，写回时再还原成原来的行尾，这样锚点字符串只有一种形态，
# 也不会因为把整份文件的行尾换掉而制造巨大 diff。
function Get-Normalized($path) {
    $raw = Read-Text $path
    return @{ crlf = $raw.Contains("`r`n"); text = $raw.Replace("`r`n", "`n") }
}

function Save-Normalized($path, $state) {
    $out = $state.text
    if ($state.crlf) { $out = $out.Replace("`n", "`r`n") }
    Write-Text $path $out
}

# ---- locate the resolved media_kit_video package --------------------------
$videoDir = $null
if (-not [string]::IsNullOrEmpty($RootOverride)) {
    $videoDir = Join-Path $RootOverride "windows"
    if (-not (Test-Path (Join-Path $videoDir "angle_surface_manager.cc"))) {
        throw "argument does not look like a media_kit_video package dir: $RootOverride"
    }
    Write-Host "media_kit_video (from argument): $videoDir"
} else {
    $repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
    $pkgConfig = Join-Path $repoRoot ".dart_tool/package_config.json"
    if (-not (Test-Path $pkgConfig)) {
        throw ".dart_tool/package_config.json not found ($pkgConfig) -- run 'flutter pub get' first"
    }
    $json = Read-Text $pkgConfig | ConvertFrom-Json
    $entry = $json.packages | Where-Object { $_.name -eq "media_kit_video" } | Select-Object -First 1
    if ($null -eq $entry) {
        throw "media_kit_video not found in $pkgConfig"
    }
    # rootUri looks like: file:///C:/Users/x/AppData/Local/Pub/Cache/git/media-kit-<hash>/media_kit_video
    $uri = [System.Uri]$entry.rootUri
    $videoDir = Join-Path $uri.LocalPath "windows"
    if (-not (Test-Path (Join-Path $videoDir "angle_surface_manager.cc"))) {
        throw "resolved media_kit_video dir has no windows sources: $videoDir"
    }
    Write-Host "media_kit_video (from package_config.json): $videoDir"
}

$headerPath = Join-Path $videoDir "angle_surface_manager.h"
$anglePath = Join-Path $videoDir "angle_surface_manager.cc"
$videoPath = Join-Path $videoDir "video_output.cc"
$videoHeaderPath = Join-Path $videoDir "video_output.h"
$utilsPath = Join-Path $videoDir "utils.cc"

foreach ($p in @($headerPath, $anglePath, $videoPath, $videoHeaderPath, $utilsPath)) {
    if (-not (Test-Path $p)) { throw "missing source file: $p" }
}

# ---- inserted code -------------------------------------------------------
$TraceHeader = @'
// ---------------------------------------------------------------------------
// PiliPlus4WOA diagnostics. Pure counters, no behaviour change.
//
// Written to %TEMP%\piliplus_angle_trace.log, one line every >= 2s while any
// counter changes. Purpose: locate where the picture stops being updated while
// mpv keeps decoding normally (no frame drops, estimated-vf-fps stays at 30).
//
//   render   VideoOutput::Render() calls  (mpv handed the client a frame)
//   noTex    ... of those, the ones that bailed out because texture_id_ == 0
//   cb       Flutter's texture callback invocations (engine asking for content)
//   cbRace   ... of those, the ones that arrived while textures_ had no entry
//            for texture_id_ (the registration window, see below). Before this
//            patch that was a std::out_of_range thrown into Flutter's C++ --
//            uncaught, it killed the process (0xC0000409 __fastfail).
//   read     copies from the internal D3D texture to the public shared one
//   mark     MarkTextureFrameAvailable() calls (texture marked dirty for Flutter)
//   draw     ANGLESurfaceManager::Draw() calls (GL rendering of a frame)
//   aread    ANGLESurfaceManager::Read() calls
//   null     ... of those, the ones that ran with a null context/texture,
//            i.e. they collided with SetSize()/Create() rebuilding them; the
//            CopyResource is skipped and the shared texture keeps the old frame
//   mcFail   eglMakeCurrent() failures
//   build    ANGLESurfaceManager::Create() calls (surface + texture rebuilds)
//
// Reading it when the picture freezes:
//   render grows, draw does not      -> texture_id_ is 0: the surface/texture
//                                       registration is stuck or failing
//   draw grows, cb does not          -> the engine stopped asking for content
//                                       (not marked dirty / layer not composited)
//   cb grows, aread does not         -> texture_id_ was 0 inside the callback
//   null / mcFail climbing           -> the rebuild path is racing or broken
//   everything grows, picture frozen -> the break is on the engine side of the
//                                       shared-handle copy, outside this plugin
//
// Added by lib/scripts/patch_media_kit_video.ps1; remove that step to undo.
// ---------------------------------------------------------------------------
#include <cstdio>
#include <cstdlib>
#include <string>

// MSVC treats C4996 as error (error C2220: the following warning is treated as
// an error: getenv/fopen unsafe). Suppress it for this diagnostics block.
#pragma warning(push)
#pragma warning(disable : 4996)

struct MKVideoTrace {
  long long video_render = 0;
  long long video_no_texture = 0;
  long long video_cb = 0;
  long long video_cb_race = 0;
  long long video_read = 0;
  long long video_mark = 0;
  long long angle_draw = 0;
  long long angle_read = 0;
  long long angle_null = 0;
  long long angle_mcfail = 0;
  long long angle_build = 0;

  long long l_video_render = -1;
  long long l_video_no_texture = -1;
  long long l_video_cb = -1;
  long long l_video_cb_race = -1;
  long long l_video_read = -1;
  long long l_video_mark = -1;
  long long l_angle_draw = -1;
  long long l_angle_read = -1;
  long long l_angle_null = -1;
  long long l_angle_mcfail = -1;
  long long l_angle_build = -1;

  DWORD last_tick = 0;
  bool started = false;
  std::string path;

  void tick() {
    const DWORD now = ::GetTickCount();
    if (!started) {
      started = true;
      last_tick = now;
      char buf[MAX_PATH] = {0};
      const DWORD n = ::GetTempPathA(MAX_PATH, buf);
      path = std::string(n > 0 && n < MAX_PATH ? buf : ".") +
             "\\piliplus_angle_trace.log";
      return;
    }
    if (now - last_tick < 2000) {
      return;
    }
    last_tick = now;
    if (video_render == l_video_render &&
        video_no_texture == l_video_no_texture && video_cb == l_video_cb &&
        video_read == l_video_read && video_cb_race == l_video_cb_race &&
        video_mark == l_video_mark &&
        angle_draw == l_angle_draw && angle_read == l_angle_read &&
        angle_null == l_angle_null && angle_mcfail == l_angle_mcfail &&
        angle_build == l_angle_build) {
      return;
    }
    l_video_render = video_render;
    l_video_no_texture = video_no_texture;
    l_video_cb = video_cb;
    l_video_read = video_read;
    l_video_cb_race = video_cb_race;
    l_video_mark = video_mark;
    l_angle_draw = angle_draw;
    l_angle_read = angle_read;
    l_angle_null = angle_null;
    l_angle_mcfail = angle_mcfail;
    l_angle_build = angle_build;
    FILE* f = nullptr;
    if (::fopen_s(&f, path.c_str(), "a") == 0 && f != nullptr) {
      std::fprintf(f,
                   "t=%lu render=%lld noTex=%lld cb=%lld cbRace=%lld read=%lld "
                   "mark=%lld draw=%lld aread=%lld null=%lld mcFail=%lld "
                   "build=%lld\n",
                   static_cast<unsigned long>(now), video_render,
                   video_no_texture, video_cb, video_cb_race, video_read,
                   video_mark,
                   angle_draw, angle_read, angle_null, angle_mcfail,
                   angle_build);
      std::fclose(f);
    }
  }
};

#pragma warning(pop)

extern MKVideoTrace g_mkTrace;

'@

$OldClassDecl = @'
class ANGLESurfaceManager {
'@

$OldInstanceCount = @'
int ANGLESurfaceManager::instance_count_ = 0;
'@

$NewInstanceCount = @'
int ANGLESurfaceManager::instance_count_ = 0;

MKVideoTrace g_mkTrace;
'@

$OldSetSize = @'
void ANGLESurfaceManager::SetSize(int32_t width, int32_t height) {
  if (width == width_ && height == height_) {
    return;
  }
  width_ = width;
  height_ = height;
  Create();
}
'@

$NewSetSize = @'
void ANGLESurfaceManager::SetSize(int32_t width, int32_t height) {
  if (width == width_ && height == height_) {
    return;
  }
  // PiliPlus4WOA: Create() releases and re-creates both D3D textures and the
  // EGL surface while Draw() (plugin thread pool) and Read() (Flutter raster
  // thread) may be using them. A concurrent Read() would then see the
  // just-nulled ComPtrs -- but this file's Read() used to guard on the device
  // context alone, so it would happily call CopyResource with a null texture
  // and the shared texture would keep the previous frame: a frozen picture
  // while mpv keeps rendering normally. Take the same mutex the others take.
  ::WaitForSingleObject(mutex_, INFINITE);
  width_ = width;
  height_ = height;
  Create();
  ::ReleaseMutex(mutex_);
}
'@

$OldMakeCurrent = @'
void ANGLESurfaceManager::MakeCurrent(bool value) {
  if (value) {
    eglMakeCurrent(display_, surface_, surface_, context_);
  } else {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
}
'@

$NewMakeCurrent = @'
void ANGLESurfaceManager::MakeCurrent(bool value) {
  if (value) {
    if (eglMakeCurrent(display_, surface_, surface_, context_) != EGL_TRUE) {
      g_mkTrace.angle_mcfail++;
    }
  } else {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
}
'@

$OldDraw = @'
void ANGLESurfaceManager::Draw(std::function<void()> callback) {
  ::WaitForSingleObject(mutex_, INFINITE);
  MakeCurrent(true);
  callback();
  SwapBuffers();
  MakeCurrent(false);
  ::ReleaseMutex(mutex_);
}
'@

$NewDraw = @'
void ANGLESurfaceManager::Draw(std::function<void()> callback) {
  g_mkTrace.angle_draw++;
  ::WaitForSingleObject(mutex_, INFINITE);
  MakeCurrent(true);
  callback();
  SwapBuffers();
  MakeCurrent(false);
  ::ReleaseMutex(mutex_);
  g_mkTrace.tick();
}
'@

$OldRead = @'
void ANGLESurfaceManager::Read() {
  ::WaitForSingleObject(mutex_, INFINITE);
  if (d3d_11_device_context_ != nullptr) {
    d3d_11_device_context_->CopyResource(d3d_11_texture_2D_.Get(),
                                         internal_d3d_11_texture_2D_.Get());
    d3d_11_device_context_->Flush();
  }
  ::ReleaseMutex(mutex_);
}
'@

$NewRead = @'
void ANGLESurfaceManager::Read() {
  ::WaitForSingleObject(mutex_, INFINITE);
  g_mkTrace.angle_read++;
  if (d3d_11_device_context_ == nullptr || d3d_11_texture_2D_ == nullptr ||
      internal_d3d_11_texture_2D_ == nullptr) {
    // PiliPlus4WOA: this is the race with SetSize()/Create(). Counted instead
    // of dereferenced, so the log names the failure instead of crashing.
    g_mkTrace.angle_null++;
  } else {
    d3d_11_device_context_->CopyResource(d3d_11_texture_2D_.Get(),
                                         internal_d3d_11_texture_2D_.Get());
    d3d_11_device_context_->Flush();
  }
  ::ReleaseMutex(mutex_);
  g_mkTrace.tick();
}
'@

$OldCreate = @'
void ANGLESurfaceManager::Create() {
  CleanUp(false);
'@

$NewCreate = @'
void ANGLESurfaceManager::Create() {
  g_mkTrace.angle_build++;
  CleanUp(false);
'@

$OldRenderHead = @'
void VideoOutput::Render() {
  if (texture_id_) {
'@

$NewRenderHead = @'
void VideoOutput::Render() {
  g_mkTrace.video_render++;
  if (!texture_id_) {
    // PiliPlus4WOA: counted; equivalent to the original code, which wrapped the
    // whole body in `if (texture_id_)`.
    g_mkTrace.video_no_texture++;
    g_mkTrace.tick();
    return;
  }
  if (texture_id_) {
'@

$OldMark = @'
    try {
      // Notify Flutter that a new frame is available.
      registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
    } catch (...) {
'@

$NewMark = @'
    try {
      // Notify Flutter that a new frame is available.
      g_mkTrace.video_mark++;
      registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
      g_mkTrace.tick();
    } catch (...) {
'@

$OldGpuCallbackBody = @'
              if (texture_id_) {
                surface_manager_->Read();
                return textures_.at(texture_id_).get();
              } else {
                return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
              }
'@

# The crash this fixes (dump analysis, 2026-09-29): two minidumps from the 2.1.5
# build died with 0xC0000409 __fastfail(FAST_FAIL_FATAL_APP_EXIT) thrown from
# this very lambda (media_kit_video_plugin.dll+0xf818), through msvcp140 ->
# VCRUNTIME140 -> std::terminate. The literal passed to the CRT helper was
# "invalid unordered_map<K, T> key" = std::out_of_range from unordered_map::at.
#
# Resize() publishes the callback to the engine on this line:
#     texture_id_ = registrar_->texture_registrar()->RegisterTexture(...)
# and only THEN inserts it:
#     textures_.emplace(std::make_pair(texture_id_, std::move(texture)))
# while the entry of the *previous* texture is erased asynchronously by the
# UnregisterTexture() completion. So the engine can invoke the callback while
# texture_id_ is already non-zero but textures_ has no entry for it -- at()
# threw, nothing catches it, and the process died. Any video that makes the
# app call setSize() (our portrait/rect-unusable path) triggers a Resize() and
# therefore re-opens the window -- hence "some videos" crash on open.
#
# Fix: look the entry up and answer "no descriptor" instead. A null descriptor
# is a normal answer for the engine (the else-branch below already returns one);
# a thrown exception is not.
$NewGpuCallbackBody = @'
              if (texture_id_) {
                g_mkTrace.video_cb++;
                g_mkTrace.video_read++;
                surface_manager_->Read();
                // PiliPlus4WOA: see the note above -- RegisterTexture() hands
                // this callback to the engine before textures_.emplace() runs,
                // so a lookup can legally miss. Report "no descriptor".
                const auto mk_it = textures_.find(texture_id_);
                if (mk_it == textures_.end()) {
                  g_mkTrace.video_cb_race++;
                  return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
                }
                return mk_it->second.get();
              } else {
                return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
              }
'@

$OldPixelBufferBody = @'
          if (texture_id_) {
            return pixel_buffer_textures_.at(texture_id_).get();
          } else {
            return (FlutterDesktopPixelBuffer*)nullptr;
          }
'@

# Same registration race as the GPU callback above (S/W rendering path).
$NewPixelBufferBody = @'
          if (texture_id_) {
            const auto mk_it = pixel_buffer_textures_.find(texture_id_);
            if (mk_it == pixel_buffer_textures_.end()) {
              g_mkTrace.video_cb_race++;
              return (FlutterDesktopPixelBuffer*)nullptr;
            }
            return mk_it->second.get();
          } else {
            return (FlutterDesktopPixelBuffer*)nullptr;
          }
'@

$OldSwCurrentSize = @'
  if (pixel_buffer_ != nullptr) {
    current_width = pixel_buffer_textures_.at(texture_id_)->width;
    current_height = pixel_buffer_textures_.at(texture_id_)->height;
  }
'@

$NewSwCurrentSize = @'
  if (pixel_buffer_ != nullptr) {
    // PiliPlus4WOA: a lookup can miss during the registration window (see the
    // GPU callback above); skip the resize request instead of throwing.
    const auto mk_it = pixel_buffer_textures_.find(texture_id_);
    if (mk_it == pixel_buffer_textures_.end()) {
      g_mkTrace.video_cb_race++;
      return;
    }
    current_width = mk_it->second->width;
    current_height = mk_it->second->height;
  }
'@

$OldSwRenderSize = @'
    if (pixel_buffer_ != nullptr) {
      int32_t size[]{
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->width),
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->height),
      };
'@

$NewSwRenderSize = @'
    if (pixel_buffer_ != nullptr) {
      // PiliPlus4WOA: skip the frame if the entry is not there yet (see above).
      const auto mk_it = pixel_buffer_textures_.find(texture_id_);
      if (mk_it == pixel_buffer_textures_.end()) {
        g_mkTrace.video_cb_race++;
        return;
      }
      int32_t size[]{
          static_cast<int32_t>(mk_it->second->width),
          static_cast<int32_t>(mk_it->second->height),
      };
'@

$OldHWidth = @'
    if (pixel_buffer_ != nullptr && texture_id_) {
      return pixel_buffer_textures_.at(texture_id_)->width;
    }
'@

# VideoOutput::width()/height() read the same map from a const getter that
# Render/CheckAndResize call. Guard them the same way so the S/W rendering
# path (reachable: the app disables hardware acceleration when the user picks
# software decoding) can never throw either.
$NewHWidth = @'
    if (pixel_buffer_ != nullptr && texture_id_) {
      // PiliPlus4WOA: a lookup can miss during the texture registration
      // window (see video_output.cc); fall through to the requested size
      // instead of throwing out_of_range into whoever is asking.
      const auto mk_it = pixel_buffer_textures_.find(texture_id_);
      if (mk_it != pixel_buffer_textures_.end()) {
        return mk_it->second->width;
      }
    }
'@

$OldHHeight = @'
    if (pixel_buffer_ != nullptr && texture_id_) {
      return pixel_buffer_textures_.at(texture_id_)->height;
    }
'@

$NewHHeight = @'
    if (pixel_buffer_ != nullptr && texture_id_) {
      // PiliPlus4WOA: see the note above.
      const auto mk_it = pixel_buffer_textures_.find(texture_id_);
      if (mk_it != pixel_buffer_textures_.end()) {
        return mk_it->second->height;
      }
    }
'@

$OldVideoOutputDtor = @'
            std::lock_guard<std::mutex> lock(textures_mutex_);
            texture_variants_.clear();
            // H/W
            textures_.clear();
            // S/W
            pixel_buffer_textures_.clear();
            // Free (call destructor) |ANGLESurfaceManager| through the thread
            // pool. This will ensure synchronized EGL or ANGLE usage & won't
            // conflict with |Render| or |CheckAndResize| of other
            // |VideoOutput|s.
            surface_manager_.reset(nullptr);
            promise.set_value();
          });
        });
  }

  promise.get_future().wait();
  texture_id_ = 0;

  thread_pool_ref_->Post([render_context = render_context_]() {
    mpv_render_context_free(render_context);
  });
}
'@

# VideoOutput::~VideoOutput() can hang forever, and that hang is fatal.
#
# Dump evidence (2026-09-30): 0xC0000409 __fastfail from libmpv-2.dll+0x3c8ee0, whose
# preceding instruction loads the literal
#   "Broken API use: mpv_render_context_free() not called."
# i.e. mpv aborted because the handle was destroyed while a render context was
# still alive. media_kit's Player.dispose() defers mpv_terminate_destroy() by
# only 5 seconds, so the render context has to be freed within that window.
#
# But the original code ends with an unconditional
#   promise.get_future().wait();
# while promise.set_value() is called ONLY from inside the UnregisterTexture()
# completion callback -- and that callback is registered only when texture_id_ is
# non-zero. Destroy a VideoOutput before its first frame ever registered a texture
# (quickly switching videos, or a media that never produces video-out-params) and
# nothing can ever set that promise: the destructor blocks forever on the detached
# thread, so it never releases the render context, and 5 s later mpv_fatal aborts
# the process. One leaked thread and no crash log line -- exactly the "sometimes
# the app just freezes and dies" report.
#
# Fix: give the no-texture case its own pool task that performs the same cleanup
# and DOES set the promise, and move mpv_render_context_free() into the awaited
# task (outside the textures mutex) so the context is guaranteed to be released
# before the destructor returns.
$OldVideoOutputDtor = @'
            std::lock_guard<std::mutex> lock(textures_mutex_);
            texture_variants_.clear();
            // H/W
            textures_.clear();
            // S/W
            pixel_buffer_textures_.clear();
            // Free (call destructor) |ANGLESurfaceManager| through the thread
            // pool. This will ensure synchronized EGL or ANGLE usage & won't
            // conflict with |Render| or |CheckAndResize| of other
            // |VideoOutput|s.
            surface_manager_.reset(nullptr);
            promise.set_value();
          });
        });
  }

  promise.get_future().wait();
  texture_id_ = 0;

  thread_pool_ref_->Post([render_context = render_context_]() {
    mpv_render_context_free(render_context);
  });
}
'@

$NewVideoOutputDtor = @'
            {
              std::lock_guard<std::mutex> lock(textures_mutex_);
              texture_variants_.clear();
              // H/W
              textures_.clear();
              // S/W
              pixel_buffer_textures_.clear();
              // Free (call destructor) |ANGLESurfaceManager| through the thread
              // pool. This will ensure synchronized EGL or ANGLE usage & won't
              // conflict with |Render| or |CheckAndResize| of other
              // |VideoOutput|s.
              surface_manager_.reset(nullptr);
            }
            // PiliPlus4WOA: release the render context inside this awaited task,
            // and *after* dropping textures_mutex_ so mpv cannot deadlock against
            // a queued Render task.
            mpv_render_context_free(render_context_);
            render_context_ = nullptr;
            promise.set_value();
          });
        });
  } else {
    // PiliPlus4WOA: no texture was ever registered, so no callback above will
    // ever run. Wait on a task we post ourselves instead of hanging forever.
    thread_pool_ref_->Post([&]() {
      std::cout << "VideoOutput::~VideoOutput (no texture): "
                << reinterpret_cast<int64_t>(handle_) << std::endl;
      {
        std::lock_guard<std::mutex> lock(textures_mutex_);
        texture_variants_.clear();
        textures_.clear();
        pixel_buffer_textures_.clear();
        surface_manager_.reset(nullptr);
      }
      mpv_render_context_free(render_context_);
      render_context_ = nullptr;
      promise.set_value();
    });
  }

  promise.get_future().wait();
  texture_id_ = 0;
}
'@

# Windows 26H2: rcNormalPosition is stale once the shell reports a work-area
# change, so exiting native fullscreen restored the window shifted up by one
# taskbar height (upstream PiliPlus #2901, fixed in bggRGjQaUbCoE/media-kit
# fd8421d21 by reading the window rect at the moment of entering instead).
$OldFullscreenRect = @'
    ::GetWindowPlacement(window, &placement);
    rect_before_fullscreen_ = RECT{
        placement.rcNormalPosition.left,
        placement.rcNormalPosition.top,
        placement.rcNormalPosition.right,
        placement.rcNormalPosition.bottom,
    };
'@

$NewFullscreenRect = @'
    ::GetWindowPlacement(window, &placement);
    ::GetWindowRect(window, &rect_before_fullscreen_);
'@

$edits = @(
    @{ file = $headerPath; old = $OldClassDecl;      new = ($TraceHeader + $OldClassDecl); label = "angle_surface_manager.h: trace counters" },
    @{ file = $anglePath;  old = $OldInstanceCount;  new = $NewInstanceCount;               label = "angle_surface_manager.cc: g_mkTrace definition" },
    @{ file = $anglePath;  old = $OldSetSize;        new = $NewSetSize;                     label = "angle_surface_manager.cc: SetSize under mutex" },
    @{ file = $anglePath;  old = $OldMakeCurrent;    new = $NewMakeCurrent;                 label = "angle_surface_manager.cc: MakeCurrent counter" },
    @{ file = $anglePath;  old = $OldDraw;           new = $NewDraw;                        label = "angle_surface_manager.cc: Draw counter" },
    @{ file = $anglePath;  old = $OldRead;           new = $NewRead;                        label = "angle_surface_manager.cc: Read counter + null guard" },
    @{ file = $anglePath;  old = $OldCreate;         new = $NewCreate;                      label = "angle_surface_manager.cc: Create counter" },
    @{ file = $videoPath;  old = $OldRenderHead;     new = $NewRenderHead;                  label = "video_output.cc: Render counters" },
    @{ file = $videoPath;  old = $OldMark;           new = $NewMark;                        label = "video_output.cc: MarkTextureFrameAvailable counter" },
    @{ file = $videoPath;  old = $OldGpuCallbackBody; new = $NewGpuCallbackBody;           label = "video_output.cc: GPU callback guard + counters" },
    @{ file = $videoPath;  old = $OldPixelBufferBody; new = $NewPixelBufferBody;           label = "video_output.cc: pixel buffer callback guard" },
    @{ file = $videoPath;  old = $OldSwCurrentSize;  new = $NewSwCurrentSize;               label = "video_output.cc: CheckAndResize S/W guard" },
    @{ file = $videoPath;  old = $OldSwRenderSize;   new = $NewSwRenderSize;                label = "video_output.cc: Render S/W guard" },
    @{ file = $videoHeaderPath; old = $OldHWidth;  new = $NewHWidth;                       label = "video_output.h: width() guard" },
    @{ file = $videoHeaderPath; old = $OldHHeight; new = $NewHHeight;                      label = "video_output.h: height() guard" },
    @{ file = $videoPath; old = $OldVideoOutputDtor; new = $NewVideoOutputDtor;              label = "video_output.cc: destructor must not hang (render context leak -> mpv abort)" },
    @{ file = $utilsPath; old = $OldFullscreenRect; new = $NewFullscreenRect;                label = "utils.cc: EnterNativeFullscreen must use GetWindowRect (26H2 taskbar-height shift)" }
)



# ---- pass 1: verify every anchor BEFORE writing anything -----------------
$states = @{}
foreach ($p in @($headerPath, $anglePath, $videoPath, $videoHeaderPath, $utilsPath)) {
    $states[$p] = Get-Normalized $p
}
# 锚点也要统一成 LF：本脚本在 Windows 上是 CRLF，here-string 里的换行因此是 CRLF，
# 而被改文件是 LF。两边都归一到 LF 才谈得上逐字符比较。
foreach ($e in $edits) {
    $e.oldN = $e.old.Replace("`r`n", "`n")
    $e.newN = $e.new.Replace("`r`n", "`n")
}
foreach ($e in $edits) {
    $text = $states[$e.file].text
    if ($text.Contains($e.newN)) { continue }   # already patched
    if (-not $text.Contains($e.oldN)) {
        throw "anchor not found in $($e.file) for '$($e.label)'. media_kit_video changed upstream, or package_config.json resolved a different checkout -- update lib/scripts/patch_media_kit_video.ps1"
    }
}
Write-Host "all anchors verified in $videoDir"

# ---- pass 2: apply ------------------------------------------------------
foreach ($e in $edits) {
    $state = $states[$e.file]
    if ($state.text.Contains($e.newN)) {
        Write-Host "  already patched: $($e.label)"
        continue
    }
    $state.text = $state.text.Replace($e.oldN, $e.newN)
    Save-Normalized $e.file $state
    Write-Host "  patched: $($e.label)"
}

Write-Host "media_kit_video patched OK: $videoDir"
