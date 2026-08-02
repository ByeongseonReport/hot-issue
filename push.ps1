Set-Location "C:\Users\PC\Documents\claude cowork\프로젝트\hot-issue"

$src  = "C:\Users\PC\Documents\claude cowork\프로젝트\hot-issue-state\index_draft.html"
$dst  = "C:\Users\PC\Documents\claude cowork\프로젝트\hot-issue\index.html"
$lock = "C:\Users\PC\Documents\claude cowork\프로젝트\hot-issue\.git\index.lock"

# 인증 프롬프트로 무한 대기하는 것을 방지 (실패하면 즉시 종료코드로 알림)
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"
# 네트워크가 죽으면 30초 내 포기 (git fetch/push가 영원히 매달리는 것 방지)
$gitOpts = @("-c","credential.interactive=false","-c","http.lowSpeedLimit=1000","-c","http.lowSpeedTime=30")

function Fail([string]$m) { Write-Output "실패: $m"; exit 1 }

if (-not (Test-Path $src)) { Write-Output "draft 파일 없음, 중단: $src"; exit 0 }

# 죽은 git이 남긴 stale index.lock 정리 (git 프로세스가 하나도 없을 때만)
if (Test-Path $lock) {
    $running = @(Get-Process -Name git -ErrorAction SilentlyContinue).Count
    if ($running -eq 0) {
        [System.IO.File]::Delete($lock)
        Write-Output "stale index.lock 정리함"
    } else {
        Fail "index.lock 존재 + git 프로세스 $running개 실행 중, 중단"
    }
}

# 원격 변경분을 먼저 반영해 non-fast-forward 거부를 예방
git @gitOpts fetch --quiet origin
if ($LASTEXITCODE -ne 0) { Fail "git fetch (exit $LASTEXITCODE)" }
git @gitOpts merge --ff-only --quiet origin/main
if ($LASTEXITCODE -ne 0) { Fail "git merge --ff-only (exit $LASTEXITCODE)" }

Copy-Item $src $dst -Force

# 공개 저장소이므로 index.html 하나만 스테이징 (다른 로컬 파일 유출 방지)
git add -- index.html
if ($LASTEXITCODE -ne 0) { Fail "git add (exit $LASTEXITCODE)" }

git diff --cached --quiet
if ($LASTEXITCODE -eq 0) { Write-Output "변경사항 없음, 커밋 스킵"; exit 0 }

$msg = "auto: " + (Get-Date -Format "yyyy-MM-dd HH:mm") + " 업데이트"
git commit -m $msg
if ($LASTEXITCODE -ne 0) { Fail "git commit (exit $LASTEXITCODE)" }

git @gitOpts push origin main
if ($LASTEXITCODE -ne 0) { Fail "git push (exit $LASTEXITCODE) - 커밋은 로컬에 남음" }

# 실제로 원격이 로컬을 따라왔는지 확인하고서야 성공이라고 말한다
$local  = (git rev-parse HEAD).Trim()
$remote = (git @gitOpts ls-remote origin main).Split()[0]
if ($local -ne $remote) { Fail "push 후에도 원격($remote) != 로컬($local)" }
Write-Output "푸시 검증 완료: $msg / $local"
