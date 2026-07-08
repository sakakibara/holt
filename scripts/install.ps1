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

  # Soft-skip only a missing or unfetchable checksums.txt; a real mismatch
  # below must stay fatal, so the compare lives outside this try.
  try {
    $sums = (Invoke-WebRequest "$Base/checksums.txt").Content
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
  Move-Item -Force $extracted (Join-Path $InstallDir $Bin)

  try { $installed = & (Join-Path $InstallDir $Bin) version 2>$null } catch { $installed = $null }
  if ($installed) { Write-Host "Installed $installed to $InstallDir\$Bin" }
  else { Write-Host "Installed holt to $InstallDir\$Bin" }

  # Add InstallDir to the USER PATH (idempotent), never the system PATH.
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (($userPath -split ';') -notcontains $InstallDir) {
    $newPath = if ($userPath) { "$userPath;$InstallDir" } else { $InstallDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "Added $InstallDir to your user PATH. Restart your shell for it to take effect."
  }
  Write-Host "Then run 'holt setup' to get started."
} finally {
  Remove-Item -Recurse -Force $Tmp
}
