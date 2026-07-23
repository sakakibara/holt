#!/usr/bin/env pwsh
# Install holt on Windows. Mirrors scripts/install.sh.
$ErrorActionPreference = 'Stop'

$Repo = 'sakakibara/holt'
$Bin  = 'holt.exe'

$Version    = if ($env:HOLT_VERSION) { $env:HOLT_VERSION } else { '' }
$InstallDir = if ($env:HOLT_INSTALL_DIR) { $env:HOLT_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'holt\bin' }

function Fail($msg) { Write-Error $msg; exit 1 }

if (-not $Version) {
  $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
  $Version = $rel.tag_name
  if (-not $Version) { Fail 'could not determine latest release version' }
}

switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { $Arch = 'x86_64' }
  'ARM64' { $Arch = 'aarch64' }
  default { Fail "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}

$Archive = "holt-windows-$Arch.zip"
$Base    = "https://github.com/$Repo/releases/download/$Version"
$Tmp     = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("holt-install-" + [guid]::NewGuid()))
try {
  Write-Host "Downloading holt $Version for windows/$Arch..."
  $zip = Join-Path $Tmp $Archive
  Invoke-WebRequest "$Base/$Archive" -OutFile $zip

  # Soft-skip only a missing or unfetchable checksums file; a real mismatch
  # below must stay fatal, so the compare lives outside this try. Current
  # releases publish SHA256SUMS; pre-0.6.1 published checksums.txt, so fall
  # back to that name (same GNU sha256sum format).
  try {
    $sums = try { (Invoke-WebRequest "$Base/SHA256SUMS").Content }
            catch { (Invoke-WebRequest "$Base/checksums.txt").Content }
    $expected = ($sums -split "`n" | Where-Object { $_ -match "\s$([regex]::Escape($Archive))$" } | ForEach-Object { ($_ -split '\s+')[0] })
  } catch { $expected = $null }
  if ($expected) {
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) { Fail "checksum mismatch for $Archive" }
    Write-Host 'Checksum verified.'
  }

  Expand-Archive -Path $zip -DestinationPath $Tmp -Force
  $extracted = Join-Path $Tmp $Bin
  if (-not (Test-Path $extracted)) { Fail "archive did not contain $Bin" }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $dest = Join-Path $InstallDir $Bin
  if (Test-Path $dest) {
    $old = "$dest.old"
    Remove-Item -Force $old -ErrorAction SilentlyContinue
    Move-Item -Force $dest $old   # renaming a locked running exe aside is permitted
  }
  Move-Item -Force $extracted $dest

  try { $installed = & $dest version 2>$null } catch { $installed = $null }
  if ($installed) { Write-Host "Installed $installed to $dest" }
  else { Write-Host "Installed holt to $dest" }

  # Add InstallDir to the USER PATH (idempotent), preserving REG_EXPAND_SZ so
  # existing %VAR% entries are not flattened to literal paths.
  $key = 'HKCU:\Environment'
  $raw = (Get-Item -Path $key).GetValue(
    'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if (($raw -split ';' | Where-Object { $_ }) -notcontains $InstallDir) {
    $newPath = if ($raw) { "$raw;$InstallDir" } else { $InstallDir }
    Set-ItemProperty -Path $key -Name Path -Value $newPath -Type ExpandString
    # Set-ItemProperty does not broadcast; tell running Explorer/shells to reload
    # the environment so a NEW shell sees the change without a logoff.
    if (-not ([System.Management.Automation.PSTypeName]'HoltNative.Win32').Type) {
      Add-Type -Namespace HoltNative -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    }
    $HWND_BROADCAST = [System.IntPtr]0xffff; $WM_SETTINGCHANGE = 0x1a; $SMTO_ABORTIFHUNG = 0x2
    [System.UIntPtr]$res = [System.UIntPtr]::Zero
    [void][HoltNative.Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [System.IntPtr]::Zero, 'Environment', $SMTO_ABORTIFHUNG, 5000, [ref]$res)
    Write-Host "Added $InstallDir to your user PATH. Restart your shell for it to take effect."
  }
  Write-Host "Then run 'holt setup' to get started."
} finally {
  Remove-Item -Recurse -Force $Tmp
}
