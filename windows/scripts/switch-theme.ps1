[CmdletBinding()]
param(
  [string]$Theme,
  [int]$Port = 9335
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$interactivePicker = -not $PSBoundParameters.ContainsKey('Theme')
$SkillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

function Set-DreamSkinPickerTitle {
  param([string]$Title)
  if (-not $interactivePicker) { return }
  try { $Host.UI.RawUI.WindowTitle = $Title } catch {}
}

trap {
  Set-DreamSkinPickerTitle -Title 'Codex Dream Skin - Switch Failed'
  Write-Host "Switch Theme failed: $($_.Exception.Message)" -ForegroundColor Red
  if ($interactivePicker) { $null = Read-Host 'Press Enter to close' }
  exit 1
}

$hotPort = $null
$selectedName = $null
$operationLock = Enter-DreamSkinOperationLock
try {
  Assert-DreamSkinPort -Port $Port
  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  $available = @(Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata)
  $bundledMissing = @('arina', 'fiona') | Where-Object {
    $id = $_
    @($available | Where-Object { $_.Id -ceq $id }).Count -eq 0
  }
  if ($available.Count -eq 0 -or $bundledMissing.Count -gt 0) {
    if ($interactivePicker) { Write-Host 'Preparing bundled themes...' }
    $paths = Initialize-DreamSkinThemeStore -SkillRoot $SkillRoot -StateRoot $StateRoot
    $available = @(Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata)
  }
  $themes = @()
  foreach ($bundledId in @('arina', 'fiona')) {
    $themes += @($available | Where-Object { $_.Id -ceq $bundledId })
  }
  $themes += @($available | Where-Object { $_.Id -cnotin @('arina', 'fiona') })
  if ($themes.Count -eq 0) { throw 'No saved Dream Skin themes are available.' }

  if (-not $Theme) {
    Set-DreamSkinPickerTitle -Title 'Codex Dream Skin - Choose Theme'
    Write-Host 'Available Codex Dream Skin themes:'
    for ($index = 0; $index -lt $themes.Count; $index++) {
      Write-Host "  [$($index + 1)] $($themes[$index].Name) ($($themes[$index].Id))"
    }
    $Theme = Read-Host 'Choose a theme number or id'
  }
  $selection = $null
  $number = 0
  if ([int]::TryParse($Theme, [ref]$number) -and $number -ge 1 -and $number -le $themes.Count) {
    $selection = $themes[$number - 1]
  } else {
    $selection = $themes | Where-Object { $_.Id -ieq $Theme.Trim() } | Select-Object -First 1
  }
  if ($null -eq $selection) { throw "Unknown Dream Skin theme: $Theme" }

  if ($interactivePicker) {
    Set-DreamSkinPickerTitle -Title 'Codex Dream Skin - Applying Theme'
    Write-Host "Applying $($selection.Name)..."
  }
  $paths = Initialize-DreamSkinThemeStore -SkillRoot $SkillRoot -StateRoot $StateRoot
  $ConfigPath = Join-Path $HOME '.codex\config.toml'
  $active = Use-DreamSkinSavedThemeWithConfig -ThemeDirectory $selection.Path `
    -ConfigPath $ConfigPath -StateRoot $StateRoot
  $selectedName = "$($active.Theme.name)"
  Set-DreamSkinPaused -Paused $false -StateRoot $StateRoot | Out-Null

  $state = $null
  try { $state = Read-DreamSkinState -Path $paths.State } catch {}
  $candidatePort = $Port
  if (-not $PortExplicit -and $null -ne $state -and $state.port) {
    $candidatePort = [int]$state.port
  }
  try {
    Assert-DreamSkinPort -Port $candidatePort
    $codex = Get-DreamSkinCodexInstall
    $identity = Get-DreamSkinVerifiedCdpIdentity -Port $candidatePort -Codex $codex
    if ($null -ne $identity) { $hotPort = $candidatePort }
  } catch {
    $hotPort = $null
  }
} finally {
  Exit-DreamSkinOperationLock -Mutex $operationLock
}

$startScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
if ($null -ne $hotPort) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript -Port $hotPort
  if ($LASTEXITCODE -ne 0) {
    throw "Theme '$selectedName' was selected, but the live injector refresh failed."
  }
  Write-Host "Dream Skin hot-switched to '$selectedName' without restarting Codex."
} else {
  Write-Host "Dream Skin theme '$selectedName' is selected for the next Dream Skin launch."
  Write-Warning 'The current Codex window has no verified Dream Skin CDP endpoint, so its live appearance was not changed.'
  if ($interactivePicker) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript -Port $candidatePort -PromptRestart
    if ($LASTEXITCODE -ne 0) {
      throw "Theme '$selectedName' was selected, but Dream Skin could not be started."
    }
  }
}

if ($interactivePicker) {
  Set-DreamSkinPickerTitle -Title 'Codex Dream Skin - Switch Complete'
  $null = Read-Host 'Press Enter to close'
}
