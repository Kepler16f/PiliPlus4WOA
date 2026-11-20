# PiliPlus4WOA: patch cnativeapi's Windows WindowManager backend.
#
# Upstream libnativeapi/nativeapi-core fixes backported onto cnativeapi 0.5.10
# (0.6.x on pub.dev requires Dart 3.14 / Flutter 3.50, whereas this workspace
# builds on Flutter 3.47.9):
#   1. Remove system-wide EVENT_OBJECT_LOCATIONCHANGE occlusion WinEvent hook
#      (nativeapi-core PR #97 / e88e7bb9b) and install occlusion hooks lazily
#      only when explicit occlusion tracking is requested, stopping OS-wide cursor
#      and window move flooding on the UI thread during PiP playback.
#   2. Harden WindowManager::GetCurrent() and GetAll() across threads and hidden
#      startup windows (nativeapi-core PR #95 / 7b2e366f1).

$ErrorActionPreference = "Stop"

$RootOverride = if ($args.Count -ge 1) { [string]$args[0] } else { "" }

function Read-Text($path) {
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Write-Text($path, $text) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
}

function Get-Normalized($path) {
    $raw = Read-Text $path
    return @{ crlf = $raw.Contains("`r`n"); text = $raw.Replace("`r`n", "`n") }
}

function Save-Normalized($path, $state) {
    $out = $state.text
    if ($state.crlf) { $out = $out.Replace("`n", "`r`n") }
    Write-Text $path $out
}

$cnativeapiDir = $null
if (-not [string]::IsNullOrEmpty($RootOverride)) {
    $cnativeapiDir = $RootOverride
} else {
    $repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
    $pkgConfig = Join-Path $repoRoot ".dart_tool/package_config.json"
    if (-not (Test-Path $pkgConfig)) {
        throw ".dart_tool/package_config.json not found ($pkgConfig) -- run 'flutter pub get' first"
    }
    $json = Read-Text $pkgConfig | ConvertFrom-Json
    $entry = $json.packages | Where-Object { $_.name -eq "cnativeapi" } | Select-Object -First 1
    if ($null -eq $entry) {
        throw "cnativeapi not found in $pkgConfig"
    }
    $uri = [System.Uri]$entry.rootUri
    $cnativeapiDir = $uri.LocalPath
}

$wmWinPath = Join-Path $cnativeapiDir "cxx_impl/src/platform/windows/window_manager_windows.cpp"
if (-not (Test-Path -LiteralPath $wmWinPath)) {
    throw "cnativeapi window_manager_windows.cpp not found: $wmWinPath"
}

Write-Host "cnativeapi window_manager_windows.cpp: $wmWinPath"

$state = Get-Normalized $wmWinPath
if ($state.text.Contains("ScheduleOcclusionRefresh()") -and $state.text.Contains("FindCurrentWindowCandidates")) {
    Write-Host "patch_cnativeapi.ps1: already applied"
    exit 0
}

$edits = @(
    @{
        name = "OcclusionHooks"
        old  = @'
static void CALLBACK
OcclusionEventProc(HWINEVENTHOOK, DWORD, HWND hwnd, LONG id_object, LONG id_child, DWORD, DWORD) {
  if (id_object != OBJID_WINDOW || id_child != CHILDID_SELF || !hwnd ||
      GetAncestor(hwnd, GA_ROOT) != hwnd)
    return;
  WithObserver([&] {
    if (!g_occlusion_timer)
      g_occlusion_timer = SetTimer(nullptr, 0, kOcclusionDelayMs, OcclusionTimerProc);
  });
}

static void InstallOcclusionHooks() {
  if (g_occlusion_hooks[0])
    return;
  const DWORD ranges[5][2] = {
      {EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND},
      {EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND},
      {EVENT_OBJECT_SHOW, EVENT_OBJECT_REORDER},  // Show, hide, reorder.
      {EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE},
      {EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED},  // Virtual desktop switches.
  };
  for (int i = 0; i < 5; ++i)
    g_occlusion_hooks[i] = SetWinEventHook(ranges[i][0], ranges[i][1], nullptr, OcclusionEventProc,
                                           0, 0, WINEVENT_OUTOFCONTEXT);
}
'@
        new  = @'
static void ScheduleOcclusionRefresh() {
  WithObserver([] {
    if (g_occlusion_hooks[0] && !g_occlusion_timer) {
      g_occlusion_timer = SetTimer(nullptr, 0, kOcclusionDelayMs, OcclusionTimerProc);
    }
  });
}

static void CALLBACK
OcclusionEventProc(HWINEVENTHOOK, DWORD, HWND hwnd, LONG id_object, LONG id_child, DWORD, DWORD) {
  if (id_object != OBJID_WINDOW || id_child != CHILDID_SELF || !hwnd ||
      GetAncestor(hwnd, GA_ROOT) != hwnd)
    return;
  ScheduleOcclusionRefresh();
}

static void InstallOcclusionHooks() {
  if (g_occlusion_hooks[0])
    return;
  // Never hook EVENT_OBJECT_LOCATIONCHANGE system-wide: Windows fires it on
  // every cursor move (OBJID_CURSOR) and every desktop window move.
  const DWORD ranges[5][2] = {
      {EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND},
      {EVENT_SYSTEM_MOVESIZEEND, EVENT_SYSTEM_MOVESIZEEND},
      {EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND},
      {EVENT_OBJECT_SHOW, EVENT_OBJECT_REORDER},  // Show, hide, reorder.
      {EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED},  // Virtual desktop switches.
  };
  for (int i = 0; i < 5; ++i)
    g_occlusion_hooks[i] = SetWinEventHook(ranges[i][0], ranges[i][1], nullptr, OcclusionEventProc,
                                           0, 0, WINEVENT_OUTOFCONTEXT);
  WithObserver([] {
    std::vector<HWND> windows;
    windows.reserve(g_window_snapshots.size());
    for (const auto& entry : g_window_snapshots)
      windows.push_back(entry.first);
    for (HWND hwnd : windows) {
      if (!IsWindow(hwnd))
        continue;
      Window window(hwnd);
      detail::WindowPropertyDispatch::RefreshOcclusion(window);
    }
  });
}
'@
    },
    @{
        name = "SetOcclusionTrackingEnabledMethod"
        old  = @'
      if (thread && thread != GetCurrentThreadId() && detail::PostToThread(thread, remove)) {
        return;
      }
      remove_inline = std::move(remove);
    }
    remove_inline();
  }

 private:
'@
        new  = @'
      if (thread && thread != GetCurrentThreadId() && detail::PostToThread(thread, remove)) {
        return;
      }
      remove_inline = std::move(remove);
    }
    remove_inline();
  }

  void SetOcclusionTrackingEnabled(bool enabled) {
    DWORD thread = 0;
    uint64_t generation = 0;
    bool already_started = false;
    {
      std::lock_guard<std::mutex> lock(lifecycle_mutex_);
      if (occlusion_enabled_ == enabled) {
        return;
      }
      occlusion_enabled_ = enabled;
      already_started = started_;
      thread = observation_thread_;
      generation = generation_;
    }
    if (!already_started || thread == 0) {
      return;
    }
    auto lifetime = lifetime_;
    auto update = [this, lifetime, generation, enabled] {
      if (!lifetime->load()) {
        return;
      }
      {
        std::lock_guard<std::mutex> lock(lifecycle_mutex_);
        if (!started_ || generation_ != generation || occlusion_enabled_ != enabled) {
          return;
        }
      }
      if (enabled) {
        InstallOcclusionHooks();
      } else {
        RemoveOcclusionHooks();
      }
    };
    if (thread == GetCurrentThreadId()) {
      update();
    } else {
      detail::PostToThread(thread, std::move(update));
    }
  }

 private:
'@
    },
    @{
        name = "LazyInstallObservationOcclusion"
        old  = @'
    InstallOcclusionHooks();

    // Windows that exist already have a state to compare the first change with.
    // Only this thread can subclass them, which is why this runs here.
    EnumWindows(
        [](HWND hwnd, LPARAM) -> BOOL {
          if (IsOwnProcessWindow(hwnd) && IsReportableWindow(hwnd)) {
            g_window_snapshots[hwnd] = TakeSnapshot(hwnd);
            WatchWindowGeometry(hwnd);
            Window window(hwnd);
            detail::WindowPropertyDispatch::RefreshOcclusion(window);
            // Already on screen, so not created under our eyes: no
            // WindowCreatedEvent for it, only the WindowClosedEvent.
            if (IsWindowVisible(hwnd)) {
              WindowId window_id = GetWindowIdFromHwnd(hwnd);
              if (window_id != IdAllocator::kInvalidId) {
                g_shown_windows[hwnd] = window_id;
              }
            }
          }
          return TRUE;
        },
        0);
  }
'@
        new  = @'
    const bool enable_occlusion = occlusion_enabled_;

    // Windows that exist already have a state to compare the first change with.
    // Only this thread can subclass them, which is why this runs here.
    EnumWindows(
        [](HWND hwnd, LPARAM) -> BOOL {
          if (IsOwnProcessWindow(hwnd) && IsReportableWindow(hwnd)) {
            g_window_snapshots[hwnd] = TakeSnapshot(hwnd);
            WatchWindowGeometry(hwnd);
            // Already on screen, so not created under our eyes: no
            // WindowCreatedEvent for it, only the WindowClosedEvent.
            if (IsWindowVisible(hwnd)) {
              WindowId window_id = GetWindowIdFromHwnd(hwnd);
              if (window_id != IdAllocator::kInvalidId) {
                g_shown_windows[hwnd] = window_id;
              }
            }
          }
          return TRUE;
        },
        0);

    if (enable_occlusion) {
      InstallOcclusionHooks();
    }
  }
'@
    },
    @{
        name = "ScheduleOcclusionRefreshOnMoveResize"
        old  = @'
    if (current.rect.left != previous.rect.left || current.rect.top != previous.rect.top) {
      OnWindowEvent(hwnd, "moved");
    }
    if (current.rect.right - current.rect.left != previous.rect.right - previous.rect.left ||
        current.rect.bottom - current.rect.top != previous.rect.bottom - previous.rect.top) {
      OnWindowEvent(hwnd, "resized");
    }
'@
        new  = @'
    const bool moved =
        current.rect.left != previous.rect.left || current.rect.top != previous.rect.top;
    const bool resized =
        current.rect.right - current.rect.left != previous.rect.right - previous.rect.left ||
        current.rect.bottom - current.rect.top != previous.rect.bottom - previous.rect.top;
    if (moved) {
      OnWindowEvent(hwnd, "moved");
    }
    if (resized) {
      OnWindowEvent(hwnd, "resized");
    }
    if (moved || resized) {
      ScheduleOcclusionRefresh();
    }
'@
    },
    @{
        name = "OcclusionEnabledFieldAndCtor"
        old  = @'
  std::mutex lifecycle_mutex_;
  bool started_ = false;
  // Bumped by every start and stop, so a queued transition can tell that its own
'@
        new  = @'
  std::mutex lifecycle_mutex_;
  bool started_ = false;
  bool occlusion_enabled_ = false;
  // Bumped by every start and stop, so a queued transition can tell that its own
'@
    },
    @{
        name = "WindowManagerCtor"
        old  = @'
WindowManager::WindowManager() : pimpl_(std::make_unique<Impl>(this)) {
  StartEventListening();
}

WindowManager::~WindowManager() {
  ShutdownEmitter();
  StopEventListening();
}
'@
        new  = @'
WindowManager::WindowManager() : pimpl_(std::make_unique<Impl>(this)) {
  pimpl_->StartEventListening();
}

WindowManager::~WindowManager() {
  ShutdownEmitter();
  pimpl_->StopEventListening();
}
'@
    },
    @{
        name = "EnumOwnProcessOnly"
        old  = @'
  // Only include visible windows that are not minimized to taskbar
  // and have a title (filters out many background windows)
  if (IsWindowVisible(hwnd)) {
'@
        new  = @'
  // Only include this process's visible windows that have a title.
  if (IsOwnProcessWindow(hwnd) && IsWindowVisible(hwnd)) {
'@
    },
    @{
        name = "GetCurrentCrossThread"
        old  = @'
std::shared_ptr<Window> WindowManager::GetCurrent() {
  HWND hwnd = GetActiveWindow();
  if (hwnd) {
    WindowId window_id = GetWindowIdFromHwnd(hwnd);
    if (window_id != IdAllocator::kInvalidId) {
      return Get(window_id);
    }
  }
  return nullptr;
}
'@
        new  = @'
namespace {

struct CurrentWindowCandidates {
  HWND first_visible = nullptr;
  HWND first_hidden = nullptr;
};

BOOL CALLBACK FindCurrentWindowCandidates(HWND hwnd, LPARAM data) {
  if (!IsOwnProcessWindow(hwnd) || !IsWindow(hwnd) || GetAncestor(hwnd, GA_ROOT) != hwnd) {
    return TRUE;
  }
  if (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CHILD) {
    return TRUE;
  }
  const LONG_PTR ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if (ex_style & (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE)) {
    return TRUE;
  }
  if (!GetPropW(hwnd, kWindowIdProperty) && GetWindowTextLengthW(hwnd) <= 0) {
    return TRUE;
  }
  auto* candidates = reinterpret_cast<CurrentWindowCandidates*>(data);
  if (IsWindowVisible(hwnd)) {
    if (!candidates->first_visible) {
      candidates->first_visible = hwnd;
    }
  } else if (!candidates->first_hidden) {
    candidates->first_hidden = hwnd;
  }
  return TRUE;
}

}  // namespace

std::shared_ptr<Window> WindowManager::GetCurrent() {
  HWND hwnd = GetActiveWindow();
  if (!IsOwnProcessWindow(hwnd)) {
    HWND foreground = GetForegroundWindow();
    if (foreground) {
      foreground = GetAncestor(foreground, GA_ROOT);
    }
    hwnd = IsOwnProcessWindow(foreground) ? foreground : nullptr;
  }
  if (!hwnd && g_focused_hwnd && IsWindow(g_focused_hwnd) && IsOwnProcessWindow(g_focused_hwnd)) {
    hwnd = g_focused_hwnd;
  }
  if (!hwnd) {
    CurrentWindowCandidates candidates;
    EnumWindows(FindCurrentWindowCandidates, reinterpret_cast<LPARAM>(&candidates));
    hwnd = candidates.first_visible ? candidates.first_visible : candidates.first_hidden;
  }
  if (hwnd) {
    WindowId window_id = GetWindowIdFromHwnd(hwnd);
    if (window_id != IdAllocator::kInvalidId) {
      return Get(window_id);
    }
  }
  return nullptr;
}
'@
    },
    @{
        name = "StartStopEventListeningOcclusion"
        old  = @'
void WindowManager::StartEventListening() {
  pimpl_->StartEventListening();
}

void WindowManager::StopEventListening() {
  pimpl_->StopEventListening();
}
'@
        new  = @'
void WindowManager::StartEventListening() {
  pimpl_->StartEventListening();
  pimpl_->SetOcclusionTrackingEnabled(true);
}

void WindowManager::StopEventListening() {
  pimpl_->SetOcclusionTrackingEnabled(false);
}
'@
    }
)

# Verify every anchor before writing anything.
foreach ($edit in $edits) {
    $old = $edit.old.Replace("`r`n", "`n")
    $idx = $state.text.IndexOf($old, [System.StringComparison]::Ordinal)
    if ($idx -lt 0) {
        throw "patch_cnativeapi.ps1: anchor '$($edit.name)' not found in $wmWinPath"
    }
    $secondIdx = $state.text.IndexOf($old, $idx + $old.Length, [System.StringComparison]::Ordinal)
    if ($secondIdx -ge 0) {
        throw "patch_cnativeapi.ps1: anchor '$($edit.name)' matched multiple times in $wmWinPath"
    }
}

foreach ($edit in $edits) {
    $old = $edit.old.Replace("`r`n", "`n")
    $new = $edit.new.Replace("`r`n", "`n")
    $state.text = $state.text.Replace($old, $new)
    Write-Host "  applied: $($edit.name)"
}

Save-Normalized $wmWinPath $state
Write-Host "patch_cnativeapi.ps1: patched OK"
