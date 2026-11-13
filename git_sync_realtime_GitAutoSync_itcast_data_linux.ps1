# ============================================================
# Git 实时自动同步脚本（v2，含状态查看）
# 路径: D:\linux\itcast_data_linux  ->  ssh://git@ssh.github.com:443/dsduyopg/itcast_data_linux.git (origin/main)
#
# 用法:
#   .\git_sync_realtime_GitAutoSync_itcast_data_linux.ps1
#       -> 实时监听并自动同步（默认，服务模式，原行为不变）
#   .\git_sync_realtime_GitAutoSync_itcast_data_linux.ps1 -Status
#       -> 打开状态查看菜单（备份状态 / 上传状态 / 上传文件 status，可选择仓库）
#   .\git_sync_realtime_GitAutoSync_itcast_data_linux.ps1 -Status -Repo itcast_data_linux
#       -> 直接查看指定仓库状态（不进入菜单）
# ============================================================

param(
    [switch]$Status,          # 状态查看模式
    [string]$Repo             # 指定要查看的仓库名（配合 -Status 使用）
)

$ErrorActionPreference = 'Continue'

# ---- 仓库配置：可在此添加/修改需要同步与查看的仓库 ----
# 字段说明: Name=显示名  Path=本地路径  Branch=分支  Remote=远程名
$Repos = @(
    @{ Name = 'itcast_data_linux'; Path = 'D:\linux\itcast_data_linux'; Branch = 'main'; Remote = 'origin' }
    # 追加更多仓库（取消注释，按需修改）：
    # @{ Name = 'repo2'; Path = 'D:\linux\repo2'; Branch = 'main'; Remote = 'origin' }
)

# 主仓库 = 配置列表第 1 个（实时监听/自动同步服务使用，行为不变）
$RepoPath      = $Repos[0].Path
$Branch        = $Repos[0].Branch
$Remote        = $Repos[0].Remote
$LogFile       = Join-Path $RepoPath 'git_sync.log'
$DebounceMs    = 3000
$RetryTimes    = 3
$RetryWaitSec  = 5
$IgnoredPaths  = @()

# ============================================================
# 状态查看功能（-Status）
# 备份状态 / 上传状态 / 上传文件 status
# ============================================================
function Show-RepoStatus {
    param([hashtable]$Repo)
    $path   = $Repo.Path
    $branch = $Repo.Branch
    $remote = $Repo.Remote

    Write-Host ""
    Write-Host ("=" * 72)
    Write-Host ("仓库: {0}" -f $Repo.Name) -ForegroundColor Cyan
    Write-Host ("路径: {0}" -f $path)
    Write-Host ("分支: {0}    远程: {1}" -f $branch, $remote)
    Write-Host ("=" * 72)

    if (-not (Test-Path $path)) { Write-Host "[错误] 目录不存在" -ForegroundColor Red; return }
    if (-not (Test-Path (Join-Path $path '.git'))) { Write-Host "[错误] 不是 git 仓库" -ForegroundColor Red; return }

    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

        # ---------- 1. 备份状态 ----------
        Write-Host ""
        Write-Host "【1. 备份状态】" -ForegroundColor Yellow
        $porcelain = @(git -C $path -c core.quotePath=false status --porcelain 2>$null)
        if ($porcelain.Count -eq 0) {
            Write-Host "  工作区: 干净，所有内容已入库" -ForegroundColor Green
        } else {
            $m = @($porcelain | Where-Object { $_ -match '^[MADRCU]' }).Count
            $u = @($porcelain | Where-Object { $_ -match '^.[MADRCU]' }).Count
            $t = @($porcelain | Where-Object { $_ -match '^\?\?' }).Count
            Write-Host ("  工作区: {0} 项改动 (已暂存 {1} / 未暂存 {2} / 未跟踪 {3})" -f $porcelain.Count, $m, $u, $t) -ForegroundColor Yellow
        }
        $last = git -C $path -c core.quotePath=false log -1 --format="%h|%ad|%s" --date=format:"%Y-%m-%d %H:%M:%S" 2>$null
        if ($last) {
            $p = $last -split '\|'
            Write-Host ("  最近提交: {0}  {1}" -f $p[0], $p[1])
            Write-Host ("  提交说明: {0}" -f $p[2])
        } else {
            Write-Host "  最近提交: (无)" -ForegroundColor Yellow
        }

        # ---------- 2. 上传状态 ----------
        Write-Host ""
        Write-Host "【2. 上传状态】" -ForegroundColor Yellow
        $url = git -C $path remote get-url $remote 2>$null
        if ($url) { Write-Host ("  远程地址: {0}" -f $url) }
        $remoteRef = "$remote/$branch"
        $hasRemoteRef = git -C $path rev-parse --verify "$remoteRef" 2>$null
        if ($hasRemoteRef) {
            $ahead  = (git -C $path rev-list --count "$remoteRef..$branch" 2>$null).Trim()
            $behind = (git -C $path rev-list --count "$branch..$remoteRef" 2>$null).Trim()
            if ([int]$ahead -gt 0) {
                Write-Host ("  未推送提交: {0} 个（本地领先远程）" -f $ahead) -ForegroundColor Red
            } else {
                Write-Host "  未推送提交: 0 个（本地与远程一致）" -ForegroundColor Green
            }
            if ([int]$behind -gt 0) {
                Write-Host ("  远程领先本地: {0} 个（可 git pull 更新）" -f $behind) -ForegroundColor Yellow
            }
        } else {
            Write-Host ("  未发现远程引用 {0}（首次推送前属正常）" -f $remoteRef) -ForegroundColor Yellow
        }
        $logFile = Join-Path $path 'git_sync.log'
        if (Test-Path $logFile) {
            $logLines = @(Get-Content $logFile -ErrorAction SilentlyContinue)
            $lastOk   = $logLines | Select-String '推送成功' | Select-Object -Last 1
            $lastFail = $logLines | Select-String '推送失败' | Select-Object -Last 1
            if ($lastOk)   { Write-Host ("  最近推送成功: {0}" -f $lastOk.Line) -ForegroundColor Green }
            if ($lastFail) { Write-Host ("  最近推送失败: {0}" -f $lastFail.Line) -ForegroundColor Red }
            $skip = @($logLines | Select-String '已跳过超大文件' | Select-Object -Last 5)
            if ($skip.Count -gt 0) {
                Write-Host "  被跳过的大文件（最近 5 条）:" -ForegroundColor Yellow
                foreach ($s in $skip) { Write-Host ("    {0}" -f $s.Line.Trim()) -ForegroundColor DarkYellow }
            }
        } else {
            Write-Host "  无同步日志文件 ($logFile)" -ForegroundColor DarkGray
        }

        # ---------- 3. 上传文件 status ----------
        Write-Host ""
        Write-Host "【3. 上传文件 status】" -ForegroundColor Yellow
        if ($porcelain.Count -eq 0) {
            Write-Host "  当前无未提交/未上传文件" -ForegroundColor Green
        } else {
            Write-Host "  当前工作区改动（git status --porcelain）:"
            foreach ($line in $porcelain) { Write-Host ("    {0}" -f $line) -ForegroundColor Yellow }
        }
        $lastCommitFiles = git -C $path -c core.quotePath=false show --name-status --format="" HEAD 2>$null
        if ($lastCommitFiles) {
            Write-Host "  最近一次提交的文件:" -ForegroundColor Cyan
            foreach ($f in $lastCommitFiles) { if ($f.Trim()) { Write-Host ("    {0}" -f $f.Trim()) } }
        }
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
}

function Show-RepoStatusByName {
    param([string]$Name)
    foreach ($r in $Repos) {
        if ($r.Name -ieq $Name) { Show-RepoStatus $r; return }
    }
    Write-Host "未找到仓库: $Name" -ForegroundColor Red
    Write-Host "可用仓库:"
    foreach ($r in $Repos) { Write-Host ("  {0}  ({1})" -f $r.Name, $r.Path) }
}

function Show-StatusMenu {
    while ($true) {
        Write-Host ""
        Write-Host "=========== Git 同步状态查看 ===========" -ForegroundColor Cyan
        for ($i = 0; $i -lt $Repos.Count; $i++) {
            $mark = if ($i -eq 0) { ' (主仓库)' } else { '' }
            Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $Repos[$i].Name, $mark)
        }
        Write-Host "  [A] 查看全部仓库"
        Write-Host "  [Q] 退出"
        $sel = Read-Host "请选择编号"
        if ($sel -match '^[Qq]$') { break }
        if ($sel -match '^[Aa]$') { foreach ($r in $Repos) { Show-RepoStatus $r }; continue }
        if ($sel -match '^\d+$') {
            $idx = [int]$sel - 1
            if ($idx -ge 0 -and $idx -lt $Repos.Count) { Show-RepoStatus $Repos[$idx] }
            else { Write-Host "编号超出范围" -ForegroundColor Red }
        } else {
            Write-Host "无效输入" -ForegroundColor Red
        }
    }
}

# ---- 状态查看模式（-Status）：查看备份/上传/文件状态，可选择仓库 ----
if ($Status) {
    if ($Repo) { Show-RepoStatusByName $Repo } else { Show-StatusMenu }
    exit
}

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