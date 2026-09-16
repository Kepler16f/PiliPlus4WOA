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

foreach ($p in @($headerPath, $anglePath, $videoPath)) {
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
        video_read == l_video_read && video_mark == l_video_mark &&
        angle_draw == l_angle_draw && angle_read == l_angle_read &&
        angle_null == l_angle_null && angle_mcfail == l_angle_mcfail &&
        angle_build == l_angle_build) {
      return;
    }
    l_video_render = video_render;
    l_video_no_texture = video_no_texture;
    l_video_cb = video_cb;
    l_video_read = video_read;
    l_video_mark = video_mark;
    l_angle_draw = angle_draw;
    l_angle_read = angle_read;
    l_angle_null = angle_null;
    l_angle_mcfail = angle_mcfail;
    l_angle_build = angle_build;
    FILE* f = nullptr;
    if (::fopen_s(&f, path.c_str(), "a") == 0 && f != nullptr) {
      std::fprintf(f,
                   "t=%lu render=%lld noTex=%lld cb=%lld read=%lld mark=%lld "
                   "draw=%lld aread=%lld null=%lld mcFail=%lld build=%lld\n",
                   static_cast<unsigned long>(now), video_render,
                   video_no_texture, video_cb, video_read, video_mark,
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

$OldCallbackAnchor = @'
kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
'@

$NewCallbackAnchor = @'
kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
              g_mkTrace.video_cb++;
'@

$OldSurfaceRead = @'
surface_manager_->Read();
'@

$NewSurfaceRead = @'
g_mkTrace.video_read++;
                surface_manager_->Read();
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
    @{ file = $videoPath;  old = $OldCallbackAnchor; new = $NewCallbackAnchor;              label = "video_output.cc: texture callback counter" },
    @{ file = $videoPath;  old = $OldSurfaceRead;    new = $NewSurfaceRead;                 label = "video_output.cc: Read counter" }
)

# ---- pass 1: verify every anchor BEFORE writing anything -----------------
$states = @{}
foreach ($p in @($headerPath, $anglePath, $videoPath)) {
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
