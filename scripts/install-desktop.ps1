<#
.SYNOPSIS
把 dsh-browser 桥插件安装到 DSH Desktop 客户端（Windows）。

Install the dsh-browser bridge into the DSH Desktop client on Windows.

.DESCRIPTION
scripts/install.ps1 只把桥插件注册到 web profile，而 DSH Desktop 客户端加载的是
profiles\desktop，所以两者不能互相替代。本脚本复用 install.ps1 的同一套约定
（profile 内目录联接、~\.dsh\browser-extension 产物目录、install-info.json），
只把注册目标换成 desktop profile。

scripts/install.ps1 registers the bridge with the web profile only, while the DSH Desktop
client loads the desktop profile, so the two cannot replace each other. This script reuses
the conventions of install.ps1. These are a profile-local directory junction, the
~\.dsh\browser-extension output directory, and install-info.json. Only the target profile
changes.

.EXAMPLE
Set-Location F:\dsh\dsh-browser
pwsh -NoProfile -File .\scripts\install-desktop.ps1

.NOTES
只支持 Windows，且必须有本地 checkout：本脚本不做免 clone 的托管安装。
Windows only, and a local checkout is required; there is no clone-free install here.
#>
# This file is UTF-8 with a BOM on purpose, exactly like scripts/install.ps1: Windows
# PowerShell 5.1 decodes a BOM-less script with the machine's ANSI codepage and turns every
# Chinese line into mojibake. No param() block, for the same reason: it keeps the script
# runnable even when someone pipes it into Invoke-Expression anyway.
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is an order of magnitude slower in Windows PowerShell while it draws a progress bar.
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell picks the console codepage, which turns the Chinese half of every
# message into question marks on a non-Chinese install.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$DshHomeDir = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$LegacyPlugin = '@deepseek-ai/dsh-bridge-browser'
$BridgePlugin = '@yuxianglin/dsh-bridge-browser'
# DSH Desktop 的 profile 目录名固定为 desktop；环境变量留给个别改名的部署。
$ProfileName = if ($env:DSH_DESKTOP_PROFILE) { $env:DSH_DESKTOP_PROFILE } else { 'desktop' }

function Write-Step {
  param([int]$Number, [string]$Zh, [string]$En)
  Write-Host ''
  Write-Host ("[{0}/4] {1}" -f $Number, $Zh)
  Write-Host ("      {0}" -f $En)
}

function Write-Pair {
  param([string]$Zh, [string]$En)
  Write-Host $Zh
  Write-Host ("   {0}" -f $En)
}

function Stop-Install {
  param([string]$Zh, [string]$En)
  Write-Host ''
  [Console]::Error.WriteLine("错误：$Zh")
  [Console]::Error.WriteLine("Error: $En")
  exit 1
}

function Test-Workspace {
  param([string]$Candidate)

  if (-not $Candidate) { return $false }
  foreach ($relative in @(
      'package.json',
      'pnpm-lock.yaml',
      'extensions\dsh-browser\package.json',
      'packages\browser\bridge-browser\package.json',
      'scripts\install.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Candidate $relative) -PathType Leaf)) { return $false }
  }
  return $true
}

function Get-WorkspaceRoot {
  # $PSScriptRoot is empty when the script arrives through `irm ... | iex`; there is no
  # managed fallback here, so that case simply stops with instructions.
  if (-not $PSScriptRoot) { return $null }
  $candidate = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
  if (Test-Workspace $candidate) { return $candidate }
  return $null
}

function Test-Command {
  param([string]$Name)
  return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Assert-Command {
  param([string]$Name, [string]$Zh, [string]$En)
  if (-not (Test-Command $Name)) { Stop-Install $Zh $En }
}

function Test-ProfileDependency {
  param([string]$Manifest, [string]$PackageName)

  if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { return $false }
  try {
    $parsed = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    return $false
  }
  if ($null -eq $parsed -or $null -eq $parsed.dependencies) { return $false }
  return [bool]($parsed.dependencies.PSObject.Properties.Name -contains $PackageName)
}

function Get-SyncEntry {
  <#
    Walk $Root breadth-first without ever descending into an excluded directory, so a
    node_modules tree costs nothing instead of dominating the walk.
  #>
  param([string]$Root, [hashtable]$Excluded)

  $entries = New-Object System.Collections.Generic.List[object]
  $pending = New-Object System.Collections.Generic.Queue[string]
  $pending.Enqueue('')

  while ($pending.Count -gt 0) {
    $relativeDir = $pending.Dequeue()
    $absoluteDir = if ($relativeDir) { Join-Path $Root $relativeDir } else { $Root }
    foreach ($child in @(Get-ChildItem -LiteralPath $absoluteDir -Force)) {
      if ($Excluded.ContainsKey($child.Name)) { continue }
      $relative = if ($relativeDir) { Join-Path $relativeDir $child.Name } else { $child.Name }
      $entries.Add([pscustomobject]@{ Relative = $relative; Item = $child })
      if ($child.PSIsContainer) { $pending.Enqueue($relative) }
    }
  }
  return $entries
}

function Sync-Directory {
  <#
    The `rsync -a --delete-after` scripts/install.ps1 relies on: copy everything across
    first, then drop whatever the source no longer has, so renamed build chunks from an
    older extension build do not linger in the loaded directory.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string[]]$ExcludeName = @()
  )

  $sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
  if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  }
  $destinationRoot = (Resolve-Path -LiteralPath $Destination).ProviderPath.TrimEnd('\')

  $excluded = @{}
  foreach ($name in $ExcludeName) { $excluded[$name] = $true }

  $keep = @{}
  foreach ($entry in @(Get-SyncEntry -Root $sourceRoot -Excluded $excluded)) {
    $keep[$entry.Relative] = $true
    $target = Join-Path $destinationRoot $entry.Relative
    if ($entry.Item.PSIsContainer) {
      if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
      }
      continue
    }
    $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if ($existing -and -not $existing.PSIsContainer -and
        $existing.Length -eq $entry.Item.Length -and
        $existing.LastWriteTimeUtc -eq $entry.Item.LastWriteTimeUtc) {
      continue
    }
    $parent = Split-Path -Parent $target
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $entry.Item.FullName -Destination $target -Force
  }

  $stale = @(Get-SyncEntry -Root $destinationRoot -Excluded $excluded |
    Where-Object { -not $keep.ContainsKey($_.Relative) })
  # Deepest first: removing a child before its parent keeps Remove-Item off already-gone paths.
  foreach ($entry in @($stale | Sort-Object { $_.Relative.Length } -Descending)) {
    if (Test-Path -LiteralPath $entry.Item.FullName) {
      Remove-Item -LiteralPath $entry.Item.FullName -Recurse -Force
    }
  }
}

function Invoke-Quiet {
  <# Run a command and return its exit code plus output instead of failing here. #>
  param(
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$Command,
    [string[]]$Arguments = @()
  )

  Push-Location -LiteralPath $WorkingDirectory
  # PowerShell 7.3+ turns a native command's stderr into a terminating error while
  # $ErrorActionPreference is Stop; a non-zero exit code is the signal we actually want.
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $code = $null
  try {
    $output = & $Command @Arguments 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
    Pop-Location
  }
  return [pscustomobject]@{ Code = $code; Output = @($output) }
}

function Invoke-Step {
  <# Run a build/registration command silently, and surface its output only when it fails. #>
  param(
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$Command,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory = $true)][string]$FailZh,
    [Parameter(Mandatory = $true)][string]$FailEn
  )

  $result = Invoke-Quiet -WorkingDirectory $WorkingDirectory -Command $Command -Arguments $Arguments
  if ($result.Code -ne 0) {
    foreach ($line in $result.Output) { Write-Host $line }
    Stop-Install $FailZh $FailEn
  }
}

function Set-BundleRoster {
  <#
    Declaring the dependency is not enough: the loader only applies a package's
    dsh.bundle.patch when the package is listed in this profile's bundle roster.
    The roster is edited here rather than through `dsh plugin add`, because that command
    would resolve the bridge against the CLI's own DSH release instead of this checkout.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$PackageName,
    [Parameter(Mandatory = $true)][string]$LegacyName
  )

  $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $manifest -or $null -eq $manifest.dsh -or $null -eq $manifest.dsh.profile) {
    Stop-Install `
      "$ManifestPath 缺少 dsh.profile 段；这不是预期的 DSH Desktop profile，已停止。" `
      "$ManifestPath has no dsh.profile section; this is not the expected DSH Desktop profile, aborting."
  }

  $original = @($manifest.dsh.profile.bundles | Where-Object { $_ })
  # Drop the legacy package name too: one loader entry id appearing twice aborts startup
  # before any plugin is imported.
  $updated = @($original | Where-Object { $_ -ne $LegacyName })
  $added = $false
  if ($updated -notcontains $PackageName) {
    $updated += $PackageName
    $added = $true
  }
  if (-not $added -and $updated.Count -eq $original.Count) { return $false }

  $manifest.dsh.profile.bundles = $updated
  $json = ($manifest | ConvertTo-Json -Depth 20) + "`n"
  [System.IO.File]::WriteAllText(
    $ManifestPath,
    $json,
    (New-Object System.Text.UTF8Encoding $false))
  return $added
}

function Get-BrowserPath {
  <# Echoes the path to a local Chrome/Chromium executable, or $null when none is installed. #>
  $candidates = New-Object System.Collections.Generic.List[string]
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $base) { continue }
    $candidates.Add((Join-Path $base 'Google\Chrome\Application\chrome.exe'))
    $candidates.Add((Join-Path $base 'Google\Chrome SxS\Application\chrome.exe'))
    $candidates.Add((Join-Path $base 'Chromium\Application\chrome.exe'))
  }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }

  # Fallback: a browser installed outside those roots still registers an App Paths entry.
  foreach ($hive in @('HKLM:', 'HKCU:')) {
    foreach ($exe in @('chrome.exe', 'chromium.exe')) {
      $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
      try {
        $registered = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
      } catch {
        continue
      }
      if ($registered -and (Test-Path -LiteralPath $registered -PathType Leaf)) { return $registered }
    }
  }
  return $null
}

function Start-ExtensionsPage {
  param([string]$BrowserPath)

  if (-not $BrowserPath) { return $false }
  try {
    Start-Process -FilePath $BrowserPath -ArgumentList 'chrome://extensions' | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Set-ClipboardText {
  param([string]$Text)

  try {
    Set-Clipboard -Value $Text -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Get-PinnedDshVersion {
  param([string]$WorkspaceRoot)

  try {
    $manifest = Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    return [string]$manifest.dependencies.'@deepseek-ai/dsh'
  } catch {
    return ''
  }
}

function Get-DesktopVersion {
  param([string]$DshHome)

  $runtime = Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\runtime.json'
  if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { return '' }
  try {
    return [string]((Get-Content -LiteralPath $runtime -Raw -Encoding UTF8 | ConvertFrom-Json).desktopVersion)
  } catch {
    return ''
  }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
  Stop-Install `
    'install-desktop.ps1 仅用于 Windows；macOS 与 Linux 请使用 scripts/install.sh 安装到 web profile。' `
    'install-desktop.ps1 is for Windows only; use scripts/install.sh for the web profile on macOS and Linux.'
}

$Root = Get-WorkspaceRoot
if (-not $Root) {
  Stop-Install `
    '没有找到完整的本地 checkout，本脚本不做免 clone 的托管安装。请在克隆目录里按文件方式执行：pwsh -NoProfile -File .\scripts\install-desktop.ps1' `
    'No complete local checkout was found, and this script has no clone-free install. Run it as a file from the checkout: pwsh -NoProfile -File .\scripts\install-desktop.ps1'
}

$Ext = Join-Path $Root 'extensions\dsh-browser'
$Plugin = Join-Path $Root 'packages\browser\bridge-browser'
$DistDir = Join-Path $DshHomeDir 'browser-extension'
$ProfileDir = Join-Path $DshHomeDir ("profiles\" + $ProfileName)
$ProfileManifest = Join-Path $ProfileDir 'package.json'
$ProfileBackup = Join-Path $ProfileDir 'package.json.bak-dsh-browser'
# A profile-local junction keeps the link spec free of absolute Windows paths, so a checkout
# path containing spaces never reaches cmd.exe through pnpm.
$ProfileSourceLink = Join-Path $ProfileDir '.dsh-browser-source'

Assert-Command 'pnpm' '未找到 pnpm；请先启用 Corepack 或安装 pnpm。' 'pnpm was not found; enable Corepack or install pnpm first.'
Assert-Command 'node' '未找到 Node.js；请先安装受支持的 Node.js 版本。' 'Node.js was not found; install a supported Node.js version first.'

if (-not (Test-Path -LiteralPath $ProfileManifest -PathType Leaf)) {
  Stop-Install `
    "$ProfileDir 下没有 package.json。请先启动一次 DSH Desktop 客户端，让它生成 $ProfileName profile，然后重新运行本脚本。" `
    "No package.json under $ProfileDir. Start the DSH Desktop client once so it creates the $ProfileName profile, then rerun this script."
}

$PinnedVersion = Get-PinnedDshVersion $Root
$DesktopVersion = Get-DesktopVersion $DshHomeDir
# Runtime lines the bridge's peer ranges accept. The bridge source typechecks against both,
# so a client on one of these lines needs no extra warning.
$SupportedRuntimeLines = @('0.2.1-rc.5', '0.2.2-rc.1')
if ($DesktopVersion -and $DesktopVersion -ne $PinnedVersion -and $SupportedRuntimeLines -notcontains $DesktopVersion) {
  Write-Host ''
  Write-Pair `
    "注意：客户端运行时是 $DesktopVersion，而桥插件只验证过 $($SupportedRuntimeLines -join ' 与 ')。客户端升级后可能不兼容。" `
    "Note: the client runtime is $DesktopVersion while the bridge is only verified against $($SupportedRuntimeLines -join ' and '). It may break after a client upgrade."
  Write-Pair `
    '如果安装后侧栏连不上或工具报错，请改用 web 安装：.\scripts\install.ps1 并在仓库根目录 pnpm start。' `
    'If the side panel cannot connect or tools fail, fall back to the web install: .\scripts\install.ps1 plus pnpm start in the repository root.'
} elseif ($DesktopVersion -and $DesktopVersion -ne $PinnedVersion) {
  Write-Pair `
    "客户端运行时是 $DesktopVersion，桥插件的 peer 范围已覆盖该版本，无需额外配置。" `
    "The client runtime is $DesktopVersion, which the bridge's peer ranges already accept; no extra configuration is needed."
}

Write-Step 1 '构建浏览器桥' 'Build the browser bridge'
Invoke-Step -WorkingDirectory $Root -Command 'pnpm' -Arguments @('install', '--frozen-lockfile') `
  -FailZh '依赖安装失败。' -FailEn 'Dependency installation failed.'
Invoke-Step -WorkingDirectory $Root -Command 'pnpm' -Arguments @('--filter', $BridgePlugin, 'run', 'build') `
  -FailZh '桥插件构建失败。' -FailEn 'The bridge plugin build failed.'

Write-Step 2 "注册到本机 $ProfileName profile" "Register with the local $ProfileName profile"

# pnpm rewrites this manifest, so keep one deterministic backup next to it.
Copy-Item -LiteralPath $ProfileManifest -Destination $ProfileBackup -Force

if (Test-ProfileDependency -Manifest $ProfileManifest -PackageName $LegacyPlugin) {
  Invoke-Step -WorkingDirectory $ProfileDir -Command 'pnpm' -Arguments @('remove', '-w', $LegacyPlugin) `
    -FailZh '移除旧插件失败。' -FailEn 'Removing the legacy plugin failed.'
}

$DesiredTarget = (Resolve-Path -LiteralPath $Plugin).ProviderPath
if (Test-Path -LiteralPath $ProfileSourceLink) {
  $SourceItem = Get-Item -LiteralPath $ProfileSourceLink -Force
  if (-not ($SourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    Stop-Install `
      "$ProfileSourceLink 已存在且不是目录联接；请移动该路径后重试。" `
      "$ProfileSourceLink exists and is not a directory junction; move it and retry."
  }
  $ExistingTarget = [System.IO.Path]::GetFullPath([string]$SourceItem.Target)
  if ($ExistingTarget -ne $DesiredTarget) {
    Remove-Item -LiteralPath $ProfileSourceLink -Force
    New-Item -ItemType Junction -Path $ProfileSourceLink -Target $DesiredTarget | Out-Null
  }
} else {
  New-Item -ItemType Junction -Path $ProfileSourceLink -Target $DesiredTarget | Out-Null
}

# The desktop profile sets autoInstallPeers: false, so the bridge's exact-version peers are
# not installed for it. Strict peer validation can reject that on some pnpm builds; the
# registration still produces the same single link, so retry with the check relaxed.
$Add = Invoke-Quiet -WorkingDirectory $ProfileDir -Command 'pnpm' `
  -Arguments @('add', '-w', 'link:./.dsh-browser-source')
if ($Add.Code -ne 0) {
  Write-Pair `
    '默认 peer 策略下注册失败，放宽严格 peer 校验后重试……' `
    'Registration failed under the default peer policy; retrying with strict peer checks relaxed…'
  foreach ($line in $Add.Output) { Write-Host $line }
  Invoke-Step -WorkingDirectory $ProfileDir -Command 'pnpm' `
    -Arguments @('add', '-w', '--no-strict-peer-dependencies', 'link:./.dsh-browser-source') `
    -FailZh '注册桥插件失败。' -FailEn 'Registering the bridge plugin failed.'
}

# Direct pnpm registration bypasses dsh's bundle-roster update, so add the entry here.
if (Set-BundleRoster -ManifestPath $ProfileManifest -PackageName $BridgePlugin -LegacyName $LegacyPlugin) {
  Write-Pair `
    "已把 $BridgePlugin 加入 $ProfileName profile 的 bundle 列表。" `
    "Added $BridgePlugin to the $ProfileName profile's bundle roster."
} else {
  Write-Pair `
    "$BridgePlugin 已在 $ProfileName profile 的 bundle 列表中。" `
    "$BridgePlugin is already in the $ProfileName profile's bundle roster."
}

Write-Step 3 '构建 Chrome 扩展' 'Build the Chrome extension'
Invoke-Step -WorkingDirectory $Root -Command 'pnpm' -Arguments @('--filter', 'dsh-browser-extension', 'run', 'build') `
  -FailZh '扩展构建失败。' -FailEn 'The extension build failed.'

$ExtDist = Join-Path $Ext 'dist'
if (-not (Test-Path -LiteralPath (Join-Path $ExtDist 'manifest.json') -PathType Leaf)) {
  Stop-Install `
    "扩展产物不完整：$ExtDist 下没有 manifest.json。" `
    "The extension build is incomplete: no manifest.json under $ExtDist."
}

Write-Step 4 '准备扩展并打开 Chrome' 'Prepare the extension and open Chrome'
$IsUpdate = Test-Path -LiteralPath (Join-Path $DistDir 'manifest.json') -PathType Leaf
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
Sync-Directory -Source $ExtDist -Destination $DistDir

# install.ps1 writes the same provenance; mode is always checkout here because this script
# has no managed install.
$InstallInfo = [ordered]@{ schemaVersion = 1; mode = 'checkout'; sourceRoot = $Root }
$InstallInfoJson = ($InstallInfo | ConvertTo-Json -Depth 3) + "`n"
[System.IO.File]::WriteAllText(
  (Join-Path $DistDir 'install-info.json'),
  $InstallInfoJson,
  (New-Object System.Text.UTF8Encoding $false))

$ClipboardReady = Set-ClipboardText $DistDir
$ChromeOpened = Start-ExtensionsPage (Get-BrowserPath)

Write-Host ''
if (-not $ChromeOpened) {
  Write-Pair '无法自动打开 Chrome，请手动打开浏览器并在地址栏输入 chrome://extensions。' 'Could not open Chrome automatically; open the browser and type chrome://extensions in the address bar.'
}
if ($IsUpdate) {
  Write-Pair '检测到已有扩展目录，文件已安全更新。' 'Existing extension directory detected; its files were updated safely.'
  Write-Pair '打开 Google Chrome（注意不是 Edge/Firefox）：' 'Open Google Chrome (not Edge/Firefox):'
  Write-Host ''
  Write-Pair '    地址栏输入 chrome://extensions' '    Type chrome://extensions in the address bar'
  Write-Host ''
  Write-Pair '如果页面上已有「dsh 浏览器助手」卡片：' 'If the dsh Browser Assistant card is already listed:'
  Write-Pair '  点击卡片上的「重新加载」按钮，让扩展加载新文件。' '  Click Reload on that card so it picks up the updated files.'
} else {
  Write-Pair 'Chrome 扩展管理页已打开，请完成以下操作：' 'Chrome Extensions is open. Complete these steps:'
  Write-Host ''
  Write-Pair '1. 开启右上角的「开发者模式」' 'Enable Developer mode in the upper-right corner'
  Write-Pair '2. 点击「加载已解压的扩展程序」' 'Click Load unpacked'
  if ($ClipboardReady) {
    Write-Pair '3. 在路径栏粘贴以下路径（已复制到剪贴板）：' 'Paste this path into the folder picker (already copied):'
  } else {
    Write-Pair '3. 在路径栏复制并粘贴以下路径：' 'Copy and paste this path into the folder picker:'
  }
  Write-Host ("   {0}" -f $DistDir)
}

Write-Host ''
Write-Pair '加载完成后：' 'After loading the extension:'
Write-Pair '• 完全退出 DSH Desktop 客户端（包括托盘图标），再重新启动，让新 profile 生效' 'Fully quit DSH Desktop (including the tray icon) and start it again so the new profile loads'
Write-Pair '• 打开任意 http(s) 页面，点击工具栏的 DeepSeek 鲸鱼图标，等待侧栏显示「已连接」' 'Open any http(s) page, click the DeepSeek whale icon, and wait for Connected'
Write-Pair '• 客户端每次启动都会随机分配本地端口，侧栏找不到时用「设置 → 自动检测」列出实例' 'The client picks a random local port on each launch; use Settings then Detect to list instances when discovery fails'
Write-Host ''
Write-Pair '以后更新：' 'To update:'
Write-Pair "• 重新运行本脚本（cd `"$Root`"; pwsh -NoProfile -File .\scripts\install-desktop.ps1），再在 chrome://extensions 点「重新加载」" "• Rerun this script (cd `"$Root`"; pwsh -NoProfile -File .\scripts\install-desktop.ps1), then click Reload in chrome://extensions"
Write-Pair '• 侧栏「更新」按钮给出的命令指向 web 安装（scripts\install.ps1）；desktop 安装请始终用本脚本' 'The update command in the side panel targets the web install (scripts\install.ps1); always use this script for a desktop install'
Write-Pair "• 桥插件已登记在 $ProfileName profile 的 bundle 列表里，它的 cordis.patch.yml 会自行 insert；不要在 $ProfileName profile 的 cordis.patch.yml 里再 insert 一次，否则启动期会报 duplicate loader entry id" "The bridge is registered in the $ProfileName profile's bundle roster and its own cordis.patch.yml inserts it; never insert it again in the $ProfileName profile's cordis.patch.yml or startup fails with duplicate loader entry id"
Write-Pair '• profile 里的 .dsh-browser-source 目录联接指向本次 checkout，移动或删除该目录后需重新运行本脚本' 'The .dsh-browser-source junction points at this checkout; moving or deleting it means rerunning this script'
Write-Host ''
Write-Pair "如果用得顺手，欢迎在 GitHub 点个 Star 支持我们：https://github.com/Lum1104/dsh-browser" "If dsh-browser is useful to you, we'd appreciate a Star on GitHub: https://github.com/Lum1104/dsh-browser"
