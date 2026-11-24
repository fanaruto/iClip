# iClip for Windows 10/11 — 免 SmartScreen 安全拦截一键丝滑安装脚本（One iClip 唯一主线）
# 用法（PowerShell）：irm https://app.webfooo.com/iClip/install.ps1 | iex

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ZipName     = "iClip-Windows-x64.zip"
$PrimaryUrl  = "https://app.webfooo.com/iClip/downloads/$ZipName"
$FallbackUrl = "https://github.com/fanaruto/iClip/releases/latest/download/$ZipName"

$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\iClip"
$StageDir   = Join-Path $env:TEMP ("iclip-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

try {
    Write-Host ""
    Write-Host "==> 正在安装 iClip for Windows" -ForegroundColor Cyan
    Write-Host "    自动解除安全流标记，零 SmartScreen 蓝屏拦截..." -ForegroundColor DarkGray

    $ZipPath = Join-Path $StageDir $ZipName
    try {
        Invoke-WebRequest -Uri $PrimaryUrl -OutFile $ZipPath -UseBasicParsing -TimeoutSec 20
        Write-Host "  [OK] 已从国内高速源获取安装包" -ForegroundColor Green
    } catch {
        Write-Host "  [!] 正在切换至备用源获取安装包..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $FallbackUrl -OutFile $ZipPath -UseBasicParsing -TimeoutSec 45
        Write-Host "  [OK] 安装包下载完成" -ForegroundColor Green
    }

    $ZipInfo = Get-Item -LiteralPath $ZipPath -ErrorAction Stop
    if ($ZipInfo.Length -lt 65536) {
        throw "安装包体积异常（$($ZipInfo.Length) 字节），已中止安装"
    }

    Unblock-File -LiteralPath $ZipPath -ErrorAction SilentlyContinue
    $UnpackDir = Join-Path $StageDir "unpacked"
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $UnpackDir -Force

    $ExeSrc = Join-Path $UnpackDir "iClip.exe"
    if (-not (Test-Path -LiteralPath $ExeSrc)) {
        throw "安装包校验失败：未找到 iClip.exe"
    }

    Get-Process -Name "iClip" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 350

    if (Test-Path -LiteralPath $InstallDir) {
        $DirItem = Get-Item -LiteralPath $InstallDir -Force
        if ($DirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "安全拦截：安装目录 $InstallDir 存在异常重解析点/符号链接"
        }
    } else {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
    $TargetExe = Join-Path $InstallDir "iClip.exe"
    if (Test-Path -LiteralPath $TargetExe) {
        $ExeItem = Get-Item -LiteralPath $TargetExe -Force
        if ($ExeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "安全拦截：目标文件 $TargetExe 为符号链接"
        }
    }
    Copy-Item -LiteralPath $ExeSrc -Destination $TargetExe -Force
    Unblock-File -LiteralPath $TargetExe -ErrorAction SilentlyContinue

    $WshShell = New-Object -ComObject WScript.Shell
    $StartMenuLnk = Join-Path ([Environment]::GetFolderPath("Programs")) "iClip.lnk"
    $Shortcut = $WshShell.CreateShortcut($StartMenuLnk)
    $Shortcut.TargetPath = $TargetExe
    $Shortcut.WorkingDirectory = $InstallDir
    $Shortcut.IconLocation = "$TargetExe,0"
    $Shortcut.Description = "iClip 原生剪贴板"
    $Shortcut.Save()

    $DesktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "iClip.lnk"
    $DesktopShortcut = $WshShell.CreateShortcut($DesktopLnk)
    $DesktopShortcut.TargetPath = $TargetExe
    $DesktopShortcut.WorkingDirectory = $InstallDir
    $DesktopShortcut.IconLocation = "$TargetExe,0"
    $DesktopShortcut.Description = "iClip 原生剪贴板"
    $DesktopShortcut.Save()

    Start-Process -FilePath $TargetExe

    Write-Host ""
    Write-Host "✔ iClip 安装完成并已启动至系统托盘！" -ForegroundColor Green
    Write-Host "  • 安装路径：$TargetExe"
    Write-Host "  • 快捷方式：已创建「开始菜单」与「桌面」iClip 图标"
    Write-Host "  • 呼出面板：按下 Alt + V（或点击右下角系统托盘 iClip 图标）"
    Write-Host ""
} finally {
    Remove-Item -Path $StageDir -Recurse -Force -ErrorAction SilentlyContinue
}
