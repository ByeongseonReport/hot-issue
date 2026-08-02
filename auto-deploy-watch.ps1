# hot-issue auto-deploy watcher
# Watches hot-issue-state\index_draft.html (written by the Claude app scheduled task)
# and runs push.ps1 (copy -> git add/commit/push) whenever it changes.
# Event-driven: deploys whenever the draft lands, regardless of what/when generated it.
# Runs continuously via the HotIssueAutoDeploy scheduled task (at logon).
# Rationale: the GitHub PAT lives in Windows Credential Manager (DPAPI, this PC only),
# so the cloud task cannot push. The PC does the push instead; the token never leaves it.
# (Log messages kept ASCII on purpose: PS 5.1 mangles non-ASCII in BOM-less .ps1.)
#
# 2026-07-21: push.ps1 is now run in a background job with a hard timeout. Previously it
# was called synchronously (& $push); when git hung there (stale index.lock / dead network)
# the watcher never returned to its WaitForChanged loop, so every later draft was ignored
# silently. A hung deploy must never take the watcher down with it.

$ErrorActionPreference = 'Continue'
$watchDir = 'C:\Users\PC\Documents\claude cowork\프로젝트\hot-issue-state'
$file     = 'index_draft.html'
$push     = 'C:\Users\PC\Documents\claude cowork\프로젝트\hot-issue\push.ps1'
$log      = 'C:\Users\PC\Documents\claude cowork\프로젝트\hot-issue\auto-deploy.log'
$timeout  = 180

function Log([string]$m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File -FilePath $log -Append -Encoding utf8
}

function Deploy([string]$reason) {
    Log "deploy triggered ($reason)"
    try {
        $job = Start-Job -ScriptBlock {
            param($p)
            # No 2>&1: PS 5.1 wraps native stderr in NativeCommandError noise.
            # push.ps1 reports every failing step on stdout with its exit code.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
        } -ArgumentList $push

        if (Wait-Job $job -Timeout $timeout) {
            $out = (Receive-Job $job) | Out-String
            Log ("push.ps1 -> " + ($out.Trim() -replace '\s*\r?\n\s*', ' | '))
        } else {
            Stop-Job $job
            $stray = @(Get-Process -Name git -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
            Log ("TIMEOUT: push.ps1 exceeded ${timeout}s, job killed; watcher stays alive. stray git pids: " + ($stray -join ',' ))
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        Log ("ERROR: " + $_.Exception.Message)
    }
}

Log "=== watcher started ==="
# On startup: deploy once to catch a draft that landed while the watcher was down.
Deploy "startup catch-up"

$w = New-Object System.IO.FileSystemWatcher
$w.Path   = $watchDir
$w.Filter = $file
$w.NotifyFilter = [System.IO.NotifyFilters]'LastWrite,Size,FileName,CreationTime'
$w.IncludeSubdirectories = $false
$w.EnableRaisingEvents = $true

while ($true) {
    # Wait up to 30 min for a draft change (re-arm on timeout).
    $r = $w.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1800000)
    if (-not $r.TimedOut) {
        # Let the writer finish flushing before copying.
        Start-Sleep -Seconds 20
        Deploy ("file " + $r.ChangeType)
    } else {
        # Heartbeat + safety net: re-check the draft even if no event arrived
        # (network/mount writes do not always raise a native FileSystemWatcher event).
        Deploy "periodic re-check"
    }
}
