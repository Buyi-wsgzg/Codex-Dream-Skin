if (-not (Get-Command Read-DreamSkinUtf8File -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'config-utf8.ps1')
}

$script:DreamSkinMaxImageBytes = 16 * 1024 * 1024
$script:DreamSkinMaxCssBytes = 512 * 1024

function Assert-DreamSkinNoReparseComponents {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetPathRoot($fullPath)
  $current = $fullPath
  while ($true) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Managed Dream Skin path contains a junction or symbolic link: $current"
      }
    }
    $currentNormalized = $current.TrimEnd('\')
    $rootNormalized = $root.TrimEnd('\')
    if ($currentNormalized.Equals($rootNormalized, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = [System.IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $current = $parent
  }
}

function Ensure-DreamSkinManagedDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
  if (-not ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      $fullPath.StartsWith($fullRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "Managed Dream Skin path escaped its state root: $fullPath"
  }
  Assert-DreamSkinNoReparseComponents -Path $fullPath
  if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
    throw "Managed Dream Skin path is a file, not a directory: $fullPath"
  }
  New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
  Assert-DreamSkinNoReparseComponents -Path $fullPath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
    throw "Managed Dream Skin directory could not be created: $fullPath"
  }
}

function Get-DreamSkinValidatedImageMetadata {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Get-Command Get-DreamSkinNodeRuntime -ErrorAction SilentlyContinue)) {
    throw 'Node.js runtime validation is unavailable for image metadata checks.'
  }
  $node = Get-DreamSkinNodeRuntime
  $metadataScript = Join-Path $PSScriptRoot 'image-metadata.mjs'
  $output = @(& $node.Path $metadataScript '--check' ([System.IO.Path]::GetFullPath($Path)) 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Image metadata is invalid or exceeds the 16384px / 50MP safety limit: $Path"
  }
  try { $metadata = ($output -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch {
    throw "Image metadata helper returned invalid output: $Path"
  }
  if ($null -eq $metadata -or $null -eq $metadata.width -or $null -eq $metadata.height) {
    throw "Image metadata is invalid or exceeds the 16384px / 50MP safety limit: $Path"
  }
}

function Assert-DreamSkinImageFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$SkipImageMetadata
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "Image does not exist: $fullPath"
  }
  $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
  if ($extension -notin @('.png', '.jpg', '.jpeg', '.webp')) {
    throw "Unsupported image format: $extension"
  }
  $length = (Get-Item -LiteralPath $fullPath -Force).Length
  if ($length -lt 1) { throw 'Theme image cannot be empty.' }
  if ($length -gt $script:DreamSkinMaxImageBytes) {
    throw 'Theme image exceeds the 16 MB limit.'
  }
  if (-not $SkipImageMetadata) {
    Get-DreamSkinValidatedImageMetadata -Path $fullPath
  }
}

function Assert-DreamSkinCssFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "Theme CSS does not exist: $fullPath"
  }
  if ([System.IO.Path]::GetExtension($fullPath) -cne '.css') {
    throw 'Theme stylesheet must use the .css extension.'
  }
  $length = (Get-Item -LiteralPath $fullPath -Force).Length
  if ($length -lt 1) { throw 'Theme stylesheet cannot be empty.' }
  if ($length -gt $script:DreamSkinMaxCssBytes) {
    throw 'Theme stylesheet exceeds the 512 KB limit.'
  }
  $null = Read-DreamSkinUtf8File -Path $fullPath
}

function Get-DreamSkinThemePaths {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  $fullRoot = [System.IO.Path]::GetFullPath($StateRoot)
  return [pscustomobject]@{
    Root = $fullRoot
    Active = Join-Path $fullRoot 'active-theme'
    Saved = Join-Path $fullRoot 'themes'
    Images = Join-Path $fullRoot 'images'
    PauseFile = Join-Path $fullRoot 'paused'
    State = Join-Path $fullRoot 'state.json'
  }
}

function Test-DreamSkinThemePathWithin {
  param([string]$Path, [string]$Root)
  if (-not $Path -or -not $Root) { return $false }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $inside = $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      $fullPath.StartsWith($fullRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { return $false }

    $current = $fullPath.TrimEnd('\')
    while ($true) {
      if (-not (Test-Path -LiteralPath $current)) { return $false }
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
      }
      if ($current.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
      $parent = [System.IO.Path]::GetDirectoryName($current)
      if (-not $parent -or $parent.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
      }
      $current = $parent.TrimEnd('\')
    }
  } catch {
    return $false
  }
}

function Read-DreamSkinTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [switch]$SkipImageMetadata
  )
  $directory = [System.IO.Path]::GetFullPath($ThemeDirectory)
  Assert-DreamSkinNoReparseComponents -Path $directory
  $themePath = Join-Path $directory 'theme.json'
  Assert-DreamSkinNoReparseComponents -Path $themePath
  if (-not (Test-Path -LiteralPath $themePath -PathType Leaf)) {
    throw "Theme metadata is missing: $themePath"
  }
  try {
    $theme = (Read-DreamSkinUtf8File -Path $themePath) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Theme metadata is invalid JSON: $themePath"
  }
  if ($null -eq $theme -or $theme -is [string] -or $theme -is [array] -or -not $theme.image) {
    throw "Theme metadata must be an object with a relative image path: $themePath"
  }
  if (-not $theme.id -or "$($theme.id)" -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
    throw "Theme id must be a safe 1-80 character identifier: $themePath"
  }
  $image = "$($theme.image)"
  if ([System.IO.Path]::IsPathRooted($image)) { throw 'Theme image path must be relative.' }
  $imagePath = [System.IO.Path]::GetFullPath((Join-Path $directory $image))
  if (-not (Test-DreamSkinThemePathWithin -Path $imagePath -Root $directory) -or
    -not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
    throw 'Theme image must remain inside its theme directory and exist.'
  }
  Assert-DreamSkinImageFile -Path $imagePath -SkipImageMetadata:$SkipImageMetadata
  $cssPath = $null
  if ($theme.css) {
    $css = "$($theme.css)"
    if ([System.IO.Path]::IsPathRooted($css)) { throw 'Theme CSS path must be relative.' }
    $cssPath = [System.IO.Path]::GetFullPath((Join-Path $directory $css))
    if (-not (Test-DreamSkinThemePathWithin -Path $cssPath -Root $directory) -or
      -not (Test-Path -LiteralPath $cssPath -PathType Leaf)) {
      throw 'Theme CSS must remain inside its theme directory and exist.'
    }
    Assert-DreamSkinCssFile -Path $cssPath
  }
  $desktopSettings = Get-DreamSkinDefaultDesktopSettings
  if ($theme.desktopSettings) {
    $desktopSettings = [ordered]@{
      appearanceLightCodeThemeId = "$($theme.desktopSettings.appearanceLightCodeThemeId)"
      appearanceLightChromeTheme = "$($theme.desktopSettings.appearanceLightChromeTheme)"
    }
  }
  Assert-DreamSkinDesktopSettings -Settings $desktopSettings
  return [pscustomobject]@{
    Directory = $directory
    ThemePath = $themePath
    ImagePath = $imagePath
    CssPath = $cssPath
    DesktopSettings = $desktopSettings
    Theme = $theme
  }
}

function Write-DreamSkinTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [Parameter(Mandatory = $true)][object]$Theme
  )
  Assert-DreamSkinNoReparseComponents -Path $ThemeDirectory
  New-Item -ItemType Directory -Force -Path $ThemeDirectory | Out-Null
  Assert-DreamSkinNoReparseComponents -Path $ThemeDirectory
  $json = $Theme | ConvertTo-Json -Depth 8
  $themePath = Join-Path $ThemeDirectory 'theme.json'
  Assert-DreamSkinNoReparseComponents -Path $themePath
  Write-DreamSkinUtf8FileAtomically -Path $themePath -Content ($json + "`r`n")
}

function Copy-DreamSkinThemePack {
  param(
    [Parameter(Mandatory = $true)][object]$LoadedTheme,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$ManagedRoot
  )
  Ensure-DreamSkinManagedDirectory -Path $Destination -Root $ManagedRoot
  $oldTheme = $null
  try { $oldTheme = Read-DreamSkinTheme -ThemeDirectory $Destination -SkipImageMetadata } catch {}
  $extension = [System.IO.Path]::GetExtension($LoadedTheme.ImagePath).ToLowerInvariant()
  $imageName = 'art' + $extension
  $imageTarget = Join-Path $Destination $imageName
  $imageTemporary = Join-Path $Destination ('.dream-tmp-' + [guid]::NewGuid().ToString('N') + $extension)
  $cssTarget = $null
  $cssTemporary = $null
  try {
    Assert-DreamSkinNoReparseComponents -Path $imageTarget
    Assert-DreamSkinNoReparseComponents -Path $imageTemporary
    Copy-Item -LiteralPath $LoadedTheme.ImagePath -Destination $imageTemporary -Force
    Assert-DreamSkinImageFile -Path $imageTemporary
    Move-Item -LiteralPath $imageTemporary -Destination $imageTarget -Force
    Assert-DreamSkinImageFile -Path $imageTarget

    $theme = $LoadedTheme.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $theme.image = $imageName
    if ($LoadedTheme.CssPath) {
      $cssName = 'theme.css'
      $cssTarget = Join-Path $Destination $cssName
      $cssTemporary = Join-Path $Destination ('.dream-tmp-' + [guid]::NewGuid().ToString('N') + '.css')
      Assert-DreamSkinNoReparseComponents -Path $cssTarget
      Assert-DreamSkinNoReparseComponents -Path $cssTemporary
      Copy-Item -LiteralPath $LoadedTheme.CssPath -Destination $cssTemporary -Force
      Assert-DreamSkinCssFile -Path $cssTemporary
      Move-Item -LiteralPath $cssTemporary -Destination $cssTarget -Force
      Assert-DreamSkinCssFile -Path $cssTarget
      $theme | Add-Member -NotePropertyName css -NotePropertyValue $cssName -Force
    } else {
      $theme.PSObject.Properties.Remove('css')
    }
    Write-DreamSkinTheme -ThemeDirectory $Destination -Theme $theme
  } finally {
    Remove-Item -LiteralPath $imageTemporary -Force -ErrorAction SilentlyContinue
    if ($cssTemporary) { Remove-Item -LiteralPath $cssTemporary -Force -ErrorAction SilentlyContinue }
  }
  foreach ($oldPath in @($oldTheme.ImagePath, $oldTheme.CssPath)) {
    if (-not $oldPath) { continue }
    $oldFull = [System.IO.Path]::GetFullPath($oldPath)
    $kept = ($imageTarget -and
        $oldFull.Equals([System.IO.Path]::GetFullPath($imageTarget), [System.StringComparison]::OrdinalIgnoreCase)) -or
      ($cssTarget -and
        $oldFull.Equals([System.IO.Path]::GetFullPath($cssTarget), [System.StringComparison]::OrdinalIgnoreCase))
    if (-not $kept -and (Test-DreamSkinThemePathWithin -Path $oldPath -Root $Destination)) {
      Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
    }
  }
  return Read-DreamSkinTheme -ThemeDirectory $Destination
}

function Initialize-DreamSkinThemeStore {
  param(
    [Parameter(Mandatory = $true)][string]$SkillRoot,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  foreach ($directory in @($paths.Root, $paths.Active, $paths.Saved, $paths.Images)) {
    Ensure-DreamSkinManagedDirectory -Path $directory -Root $paths.Root
  }
  $bundledRoot = Join-Path $SkillRoot 'themes'
  Assert-DreamSkinNoReparseComponents -Path $bundledRoot
  if (-not (Test-Path -LiteralPath $bundledRoot -PathType Container)) {
    throw "Bundled Windows themes are missing: $bundledRoot"
  }
  $bundledThemes = @()
  foreach ($directory in Get-ChildItem -LiteralPath $bundledRoot -Directory -ErrorAction Stop) {
    $bundledThemes += Read-DreamSkinTheme -ThemeDirectory $directory.FullName
  }
  if ($bundledThemes.Count -lt 1) { throw 'No valid bundled Windows themes were found.' }
  foreach ($bundled in $bundledThemes) {
    $destination = Join-Path $paths.Saved "$($bundled.Theme.id)"
    $null = Copy-DreamSkinThemePack -LoadedTheme $bundled -Destination $destination -ManagedRoot $paths.Root
  }
  $activeTheme = Join-Path $paths.Active 'theme.json'
  Assert-DreamSkinNoReparseComponents -Path $activeTheme
  if (-not (Test-Path -LiteralPath $activeTheme -PathType Leaf)) {
    $defaultTheme = $bundledThemes | Where-Object { $_.Theme.id -ceq 'arina' } | Select-Object -First 1
    if ($null -eq $defaultTheme) { $defaultTheme = $bundledThemes[0] }
    $themeCopy = $defaultTheme.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $null = Set-DreamSkinActiveTheme -ImagePath $defaultTheme.ImagePath -CssPath $defaultTheme.CssPath `
      -Theme $themeCopy -StateRoot $StateRoot
  }
  $null = Read-DreamSkinTheme -ThemeDirectory $paths.Active
  return $paths
}

function New-DreamSkinThemeImageName {
  param([Parameter(Mandatory = $true)][string]$Extension)
  return 'art-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' +
    [guid]::NewGuid().ToString('N').Substring(0, 8) + $Extension.ToLowerInvariant()
}

function New-DreamSkinThemeCssName {
  return 'style-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' +
    [guid]::NewGuid().ToString('N').Substring(0, 8) + '.css'
}

function Set-DreamSkinActiveTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [AllowNull()][string]$CssPath,
    [AllowNull()][object]$Theme,
    [string]$Name,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Active -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Images -Root $paths.Root
  $source = [System.IO.Path]::GetFullPath($ImagePath)
  Assert-DreamSkinImageFile -Path $source
  $cssSource = $null
  if ($CssPath) {
    $cssSource = [System.IO.Path]::GetFullPath($CssPath)
    Assert-DreamSkinCssFile -Path $cssSource
  }
  $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
  $oldImage = $null
  $oldCss = $null
  try {
    $oldTheme = Read-DreamSkinTheme -ThemeDirectory $paths.Active
    $oldImage = $oldTheme.ImagePath
    $oldCss = $oldTheme.CssPath
  } catch {}
  if ($null -eq $Theme) {
    $Theme = [pscustomobject]@{
      id = 'custom'
      name = '自定义主题'
      appearance = 'auto'
      layout = 'adaptive'
      art = [pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'auto' }
      palette = [pscustomobject]@{}
      desktopSettings = [pscustomobject](Get-DreamSkinDefaultDesktopSettings)
    }
  }
  $imageName = New-DreamSkinThemeImageName -Extension $extension
  $target = Join-Path $paths.Active $imageName
  $temporary = Join-Path $paths.Active ('.dream-tmp-' + [guid]::NewGuid().ToString('N') + $extension)
  $cssName = if ($cssSource) { New-DreamSkinThemeCssName } else { $null }
  $cssTarget = if ($cssName) { Join-Path $paths.Active $cssName } else { $null }
  $cssTemporary = if ($cssName) {
    Join-Path $paths.Active ('.dream-tmp-' + [guid]::NewGuid().ToString('N') + '.css')
  } else { $null }
  try {
    Assert-DreamSkinNoReparseComponents -Path $target
    Assert-DreamSkinNoReparseComponents -Path $temporary
    Copy-Item -LiteralPath $source -Destination $temporary -Force
    Assert-DreamSkinNoReparseComponents -Path $temporary
    Assert-DreamSkinImageFile -Path $temporary
    Move-Item -LiteralPath $temporary -Destination $target -Force
    Assert-DreamSkinNoReparseComponents -Path $target
    Assert-DreamSkinImageFile -Path $target
    if ($cssSource) {
      Assert-DreamSkinNoReparseComponents -Path $cssTarget
      Assert-DreamSkinNoReparseComponents -Path $cssTemporary
      Copy-Item -LiteralPath $cssSource -Destination $cssTemporary -Force
      Assert-DreamSkinCssFile -Path $cssTemporary
      Move-Item -LiteralPath $cssTemporary -Destination $cssTarget -Force
      Assert-DreamSkinCssFile -Path $cssTarget
      $Theme | Add-Member -NotePropertyName css -NotePropertyValue $cssName -Force
    } else {
      $Theme.PSObject.Properties.Remove('css')
    }
    $Theme | Add-Member -NotePropertyName image -NotePropertyValue $imageName -Force
    if ($Name) { $Theme | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force }
    if (-not $Theme.id) { $Theme | Add-Member -NotePropertyName id -NotePropertyValue 'custom' -Force }
    if (-not $Theme.appearance) { $Theme | Add-Member -NotePropertyName appearance -NotePropertyValue 'auto' -Force }
    if (-not $Theme.layout) { $Theme | Add-Member -NotePropertyName layout -NotePropertyValue 'adaptive' -Force }
    if (-not $Theme.art) {
      $Theme | Add-Member -NotePropertyName art -NotePropertyValue `
        ([pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'auto' }) -Force
    }
    if (-not $Theme.palette) {
      $Theme | Add-Member -NotePropertyName palette -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Write-DreamSkinTheme -ThemeDirectory $paths.Active -Theme $Theme
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    if ($cssTemporary) { Remove-Item -LiteralPath $cssTemporary -Force -ErrorAction SilentlyContinue }
  }
  $sameImage = $oldImage -and ([System.IO.Path]::GetFullPath($oldImage) -ieq [System.IO.Path]::GetFullPath($target))
  if ($oldImage -and -not $sameImage -and
    (Test-DreamSkinThemePathWithin -Path $oldImage -Root $paths.Active)) {
    Remove-Item -LiteralPath $oldImage -Force -ErrorAction SilentlyContinue
  }
  $sameCss = $oldCss -and $cssTarget -and
    ([System.IO.Path]::GetFullPath($oldCss) -ieq [System.IO.Path]::GetFullPath($cssTarget))
  if ($oldCss -and -not $sameCss -and
    (Test-DreamSkinThemePathWithin -Path $oldCss -Root $paths.Active)) {
    Remove-Item -LiteralPath $oldCss -Force -ErrorAction SilentlyContinue
  }
  $imageArchive = Join-Path $paths.Images $imageName
  Assert-DreamSkinNoReparseComponents -Path $imageArchive
  Copy-Item -LiteralPath $target -Destination $imageArchive -Force
  Assert-DreamSkinNoReparseComponents -Path $imageArchive
  Assert-DreamSkinImageFile -Path $imageArchive
  return Read-DreamSkinTheme -ThemeDirectory $paths.Active
}

function Save-DreamSkinCurrentTheme {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $trimmed = $Name.Trim()
  if (-not $trimmed -or $trimmed.Length -gt 80 -or $trimmed -match '[\u0000-\u001f]') {
    throw 'Theme name must be between 1 and 80 visible characters.'
  }
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Saved -Root $paths.Root
  $active = Read-DreamSkinTheme -ThemeDirectory $paths.Active
  $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $destination = Join-Path $paths.Saved $id
  Ensure-DreamSkinManagedDirectory -Path $destination -Root $paths.Root
  $extension = [System.IO.Path]::GetExtension($active.ImagePath).ToLowerInvariant()
  $imageName = 'art' + $extension
  $destinationImage = Join-Path $destination $imageName
  Assert-DreamSkinNoReparseComponents -Path $destinationImage
  Copy-Item -LiteralPath $active.ImagePath -Destination $destinationImage -Force
  Assert-DreamSkinNoReparseComponents -Path $destinationImage
  Assert-DreamSkinImageFile -Path $destinationImage
  $theme = $active.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $theme.id = $id
  $theme.name = $trimmed
  $theme.image = $imageName
  if ($active.CssPath) {
    $cssName = 'theme.css'
    $destinationCss = Join-Path $destination $cssName
    Assert-DreamSkinNoReparseComponents -Path $destinationCss
    Copy-Item -LiteralPath $active.CssPath -Destination $destinationCss -Force
    Assert-DreamSkinCssFile -Path $destinationCss
    $theme | Add-Member -NotePropertyName css -NotePropertyValue $cssName -Force
  } else {
    $theme.PSObject.Properties.Remove('css')
  }
  Write-DreamSkinTheme -ThemeDirectory $destination -Theme $theme
  return Read-DreamSkinTheme -ThemeDirectory $destination
}

function Get-DreamSkinSavedThemes {
  param(
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'),
    [switch]$SkipImageMetadata
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Saved -Root $paths.Root
  if (-not (Test-Path -LiteralPath $paths.Saved -PathType Container)) { return @() }
  $themes = @()
  foreach ($directory in Get-ChildItem -LiteralPath $paths.Saved -Directory -ErrorAction SilentlyContinue) {
    try {
      $loaded = Read-DreamSkinTheme -ThemeDirectory $directory.FullName -SkipImageMetadata:$SkipImageMetadata
      $themes += [pscustomobject]@{
        Id = "$($loaded.Theme.id)"
        Name = if ($loaded.Theme.name) { "$($loaded.Theme.name)" } else { $directory.Name }
        Path = $directory.FullName
      }
    } catch {}
  }
  return @($themes | Sort-Object Name)
}

function Use-DreamSkinSavedTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Saved -Root $paths.Root
  $directory = [System.IO.Path]::GetFullPath($ThemeDirectory)
  if (-not (Test-DreamSkinThemePathWithin -Path $directory -Root $paths.Saved)) {
    throw 'Saved theme must remain inside the Dream Skin themes folder.'
  }
  $saved = Read-DreamSkinTheme -ThemeDirectory $directory
  $theme = $saved.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  return Set-DreamSkinActiveTheme -ImagePath $saved.ImagePath -CssPath $saved.CssPath `
    -Theme $theme -StateRoot $StateRoot
}

function Use-DreamSkinSavedThemeWithConfig {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $saved = Read-DreamSkinTheme -ThemeDirectory $ThemeDirectory
  $originalBytes = [System.IO.File]::ReadAllBytes($ConfigPath)
  $configChanged = Set-DreamSkinDesktopTheme -ConfigPath $ConfigPath `
    -DesktopSettings $saved.DesktopSettings
  $appliedBytes = if ($configChanged) { [System.IO.File]::ReadAllBytes($ConfigPath) } else { $null }
  try {
    return Use-DreamSkinSavedTheme -ThemeDirectory $ThemeDirectory -StateRoot $StateRoot
  } catch {
    if ($configChanged) {
      try {
        Write-DreamSkinBytesAtomically -Path $ConfigPath -Bytes $originalBytes -ExpectedBytes $appliedBytes
      } catch {
        Write-Warning 'Theme activation failed and the native color rollback could not be completed safely.'
      }
    }
    throw
  }
}

function Set-DreamSkinPaused {
  param(
    [Parameter(Mandatory = $true)][bool]$Paused,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  if ($Paused) {
    Assert-DreamSkinNoReparseComponents -Path $paths.PauseFile
    Write-DreamSkinUtf8FileAtomically -Path $paths.PauseFile -Content "paused`r`n"
  } else {
    if (Test-Path -LiteralPath $paths.PauseFile) { Assert-DreamSkinNoReparseComponents -Path $paths.PauseFile }
    Remove-Item -LiteralPath $paths.PauseFile -Force -ErrorAction SilentlyContinue
  }
  return $Paused
}

function Test-DreamSkinPaused {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  return (Test-Path -LiteralPath (Get-DreamSkinThemePaths -StateRoot $StateRoot).PauseFile -PathType Leaf)
}
