# ============================================================
# Git 实时自动同步脚本 - 自动生成
# 路径: D:\linux\itcast_data_linux  ->  ssh://git@ssh.github.com:443/dsduyopg/itcast_data_linux.git (origin/main)
# ============================================================

$ErrorActionPreference = 'Continue'

$RepoPath      = 'D:\linux\itcast_data_linux'
$Branch        = 'main'
$Remote        = 'origin'
$LogFile       = Join-Path $RepoPath 'git_sync.log'
$DebounceMs    = 3000
$RetryTimes    = 3
$RetryWaitSec  = 5
$IgnoredPaths  = @()

if (-not (Test-Path $RepoPath)) {
    Write-Host "错误：目录不存在 $RepoPath"
    exit 1
}
Set-Location $RepoPath

function Write-Log {
    param([string]$Msg)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
    Write-Host $line
}

Write-Log '============================================'
Write-Log 'Git 实时同步脚本启动'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Log '错误：未找到 git 命令，请先安装 Git'
    exit 1
}
if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Log '错误：该目录不是 git 仓库'
    exit 1
}
$hasRemote = (git -C $RepoPath remote) -match "^$Remote$"
if (-not $hasRemote) {
    Write-Log "错误：未配置远程仓库 $Remote`n请先执行: git remote add $Remote <仓库地址>"
    exit 1
}

function Should-Ignore {
    param([string]$FullPath)
    if ($FullPath -like "$RepoPath\.git*") { return $true }
    if ($FullPath -like "$RepoPath\git_sync*") { return $true }
    foreach ($p in $IgnoredPaths) {
        $pWin = $p -replace '/', '\'
        $target = Join-Path $RepoPath $pWin
        if ($FullPath -eq $target -or $FullPath -like "$target\*") { return $true }
    }
    return $false
}

function Test-GitBusy {
    # 是否有其他 git 进程正在使用本仓库
    $procs = Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.CommandLine -and ($p.CommandLine -match [regex]::Escape($RepoPath))) { return $true }
    }
    return $false
}

function Clear-StaleLock {
    # 清理残留的 index.lock（无活跃 git 进程时才清理）
    $lock = Join-Path $RepoPath '.git\index.lock'
    if (Test-Path $lock) {
        if (Test-GitBusy) {
            Write-Log "index.lock 存在但 git 进程忙碌，等待其释放..."
            return $false
        }
        Write-Log "检测到残留 index.lock，正在清理..."
        Remove-Item $lock -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $lock)) { Write-Log "残留锁已清理" }
    }
    return $true
}

# ---- 邮件通知(可选功能) ----
# 未配置 SMTP 时整段自动跳过, 不启动任何额外进程, 行为与未集成时完全一致
# 失败通知默认 30 分钟节流, 避免持续失败时反复发信
$MailHelper   = 'D:\software\win系统Git自动同步工具包-v2.16-20260831\Git自动同步工具包-v2.16-20260831\05-邮件通知\send_mail.ps1'
$MailConfPath = Join-Path $env:ProgramData 'GitAutoSync\mail_config.txt'
$MailThrottle = Join-Path $RepoPath 'git_sync_mail_throttle.tmp'

function Send-MailNotify {
    param([string]$Title, [string]$Content, [switch]$Throttle)
    if (-not $MailHelper) { return }
    if (-not (Test-Path -LiteralPath $MailHelper)) { return }
    if (-not (Test-Path -LiteralPath $MailConfPath)) { return }
    if ($Throttle) {
        if (Test-Path -LiteralPath $MailThrottle) {
            $last = (Get-Item -LiteralPath $MailThrottle).LastWriteTime
            if (((Get-Date) - $last).TotalMinutes -lt 30) { return }
        }
        try { New-Item -ItemType File -Path $MailThrottle -Force | Out-Null } catch { }
    }
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $MailHelper -Subject $Title -Body $Content
    } catch { }
}

# 获取本次提交变更文件列表（处理 UTF-8 中文文件名）
function Get-ChangedFiles {
    param([string]$Path)
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        # 取最近 10 分钟内所有提交涉及的文件（去重），避免只显示 HEAD 单条提交
        $files = git -C $Path -c core.quotePath=false -c i18n.logOutputEncoding=UTF-8 log --since="10 minutes ago" --name-only --pretty=format: -- .
        if (-not $files) {
            $files = git -C $Path -c core.quotePath=false -c i18n.logOutputEncoding=UTF-8 diff-tree --no-commit-id --name-only -r HEAD
        }
        return ($files | Where-Object { $_.Trim() } | Sort-Object -Unique) -join "`n"
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
}

function Sync-Now {
    try {
        Clear-StaleLock
        $addOut = git -C $RepoPath add -A 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Log "git add 失败：$addOut"; return }
        # ---- 大文件保护：远端单文件上限 100MB，超标文件一律不入库 ----
        $MaxFileMB = 95
        $prevEnc2 = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            $stagedFiles = @(git -C $RepoPath -c core.quotePath=false diff --cached --name-only 2>$null)
        } finally { [Console]::OutputEncoding = $prevEnc2 }
        foreach ($rel in $stagedFiles) {
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $full = Join-Path $RepoPath ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $len = (Get-Item -LiteralPath $full).Length
            if ($len -gt ($MaxFileMB * 1MB)) {
                git -C $RepoPath reset -q -- ":(literal)$rel" 2>&1 | Out-Null
                Write-Log ("已跳过超大文件（{0:N1}MB > {1}MB）：{2}" -f ($len / 1MB), $MaxFileMB, $rel)
            }
        }
        $status = git -C $RepoPath status --porcelain
        if ([string]::IsNullOrWhiteSpace($status)) { Write-Log '无实际文件变动，跳过提交'; return }
        $msg = "auto-sync: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $commitOut = git -C $RepoPath commit -m $msg 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Log "git commit 失败：$commitOut"; return }
        Write-Log "已提交：$msg"
        for ($i = 1; $i -le $RetryTimes; $i++) {
            $pushOut = git -C $RepoPath push $Remote $Branch 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "推送成功 -> $Remote/$Branch"
                $syncFiles = Get-ChangedFiles -Path $RepoPath
                Send-MailNotify -Title "同步成功: $RepoPath" -Content "仓库: $RepoPath`n分支: $Remote/$Branch`n时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n结果: 推送成功`n`n变更文件:`n$syncFiles"
                return
            }
            Write-Log "推送失败(第 $i/$RetryTimes 次)：$pushOut"
            Start-Sleep -Seconds $RetryWaitSec
        }
        Write-Log '推送失败，超过重试次数，将在下次变化时重试'
        $failedFiles = (git -C $RepoPath -c core.quotePath=false diff-tree --no-commit-id --name-only -r HEAD) -join "`n"
        Send-MailNotify -Title "同步失败: $RepoPath" -Content "仓库: $RepoPath`n分支: $Remote/$Branch`n时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n结果: 推送失败(已重试 $RetryTimes 次)`n错误: $pushOut`n`n变更文件:`n$failedFiles" -Throttle
        Clear-StaleLock
    } catch {
        Write-Log "同步出错：$_"
        Clear-StaleLock
    }
}

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path                  = $RepoPath
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter          = [System.IO.NotifyFilters]::LastWrite -bor `
                                 [System.IO.NotifyFilters]::FileName -bor `
                                 [System.IO.NotifyFilters]::DirectoryName -bor `
                                 [System.IO.NotifyFilters]::Size
$watcher.EnableRaisingEvents   = $true

$null = Register-ObjectEvent $watcher Created -SourceIdentifier Sync.Created
$null = Register-ObjectEvent $watcher Changed -SourceIdentifier Sync.Changed
$null = Register-ObjectEvent $watcher Renamed -SourceIdentifier Sync.Renamed
$null = Register-ObjectEvent $watcher Deleted -SourceIdentifier Sync.Deleted

Write-Log '启动时执行一次完整同步...'
Sync-Now
Write-Log "开始实时监听目录：$RepoPath（按 Ctrl+C 停止）"

while ($true) {
    $e = Wait-Event -Timeout 1
    if ($null -eq $e) { continue }
    $evArgs = $e.SourceEventArgs
    if ($null -ne $evArgs -and (Should-Ignore $evArgs.FullPath)) {
        Remove-Event -EventIdentifier $e.EventIdentifier
        continue
    }
    Remove-Event -EventIdentifier $e.EventIdentifier
    Start-Sleep -Milliseconds $DebounceMs
    while ($null -ne ($tmp = Wait-Event -Timeout 0)) {
        Remove-Event -EventIdentifier $tmp.EventIdentifier
    }
    Write-Log '检测到文件变化，开始同步...'
    Sync-Now
}