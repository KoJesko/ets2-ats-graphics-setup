<#
  ETS2 / ATS graphics setup: ReShade, Snowymoon lighting and DLSS 5.

  Works with HaulMP: every mod loads through the game folder's dxgi.dll proxy
  chain (ReShade -> dxgi2.dll Snowymoon). Nothing is injected into the game.

  Run in PowerShell:
    irm https://raw.githubusercontent.com/KoJesko/ets2-ats-graphics-setup/main/install.ps1 | iex
#>

function Main {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# ---- Sources ---------------------------------------------------------------
$ReShadeVersion   = '6.8.0'
$ReShadeSetupUrl  = "https://reshade.me/downloads/ReShade_Setup_$($ReShadeVersion)_Addon.exe"
$ReShadeSetupHash = 'AFE4C8F13048306307983B8B3D41D5BF00A86820440B0E57DEA10950E1176445'
$ShadersUrl       = 'https://github.com/crosire/reshade-shaders/archive/refs/heads/slim.zip'
$SnowyPageUrl     = 'https://snowymoon.io/?dl=v2'
$SnowyFallbackUrl = 'https://cdn.snowymoondl.net/lighting_v2/ets2ats_lighting_v2_5_10_snowymoon.io.zip'
$SnowyDlssUrl     = 'https://cdn.snowymoondl.net/dlss_3.7.zip'
$StreamlineTag    = 'v2.14.16'
$StreamlineUrl    = "https://github.com/NVIDIA-RTX/Streamline/releases/download/$StreamlineTag/streamline-sdk-$StreamlineTag.zip"
$StreamlineFiles  = @('sl.common.dll', 'sl.deepdvc.dll', 'sl.dlss.dll', 'sl.dlss_d.dll', 'sl.dlss_g.dll',
                      'sl.interposer.dll', 'sl.nis.dll', 'sl.pcl.dll', 'sl.reflex.dll',
                      'nvngx_dlss.dll', 'nvngx_dlssd.dll', 'nvngx_dlssg.dll')

# DLSS 5 pieces with no public download link: each user supplies their own.
$Dlss5Addons   = @('dlss5-bridge.addon64', 'renodx-dlss.addon64')
$Dlss5Required = @('nvngx_dlssnr.dll')
$Dlss5Optional = @('dlss5-bridge.cfg')

$Root  = if ($env:TRUCKGFX_ROOT) { $env:TRUCKGFX_ROOT } else { Join-Path $env:LOCALAPPDATA 'TruckGfxSetup' }
$Cache = Join-Path $Root 'cache'

$DefaultReShadeIni = @(
    '[GENERAL]'
    'EffectSearchPaths=.\reshade-shaders\Shaders\**'
    'TextureSearchPaths=.\reshade-shaders\Textures\**'
    'PresetPath=.\ReShadePreset.ini'
    ''
    '[INPUT]'
    'KeyOverlay=36,0,0,0'
)

# ---- Helpers ---------------------------------------------------------------
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Step($m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "!  $m" -ForegroundColor Yellow }

# Environment variables answer the prompts for unattended runs and tests.
function Ask($prompt, $envName) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { Say "$prompt $v"; return $v.Trim() }
    return "$(Read-Host $prompt)".Trim()
}

function Get-File($url, $name) {
    New-Item -ItemType Directory -Force $Cache | Out-Null
    $dest = Join-Path $Cache $name
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 0) { return $dest }
    Say "   downloading $url"
    $tmp = "$dest.part"
    # Start-Process keeps curl's progress bar (stderr) out of PowerShell's error stream.
    $p = Start-Process curl.exe -ArgumentList @('-fL', '--retry', '3', '--progress-bar', '-o', "`"$tmp`"", "`"$url`"") -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { Remove-Item $tmp -ErrorAction SilentlyContinue; throw "download failed (curl $($p.ExitCode)): $url" }
    Move-Item $tmp $dest -Force
    $dest
}

# Extracts the entries whose path matches $pattern into $destDir, without their folders.
function Expand-Entries($zipPath, $pattern, $destDir) {
    New-Item -ItemType Directory -Force $destDir | Out-Null
    $z = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($e in $z.Entries) {
            if ($e.Name -and $e.FullName -match $pattern) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $destDir $e.Name), $true)
            }
        }
    } finally { $z.Dispose() }
}

function Test-Contains($path, $text) {
    $s = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path))
    $s.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-Sha($path) { (Get-FileHash $path -Algorithm SHA256).Hash }

function Set-Ini($path, $section, $values) {
    $lines = [Collections.Generic.List[string]]@(Get-Content $path)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq "[$section]") { $start = $i; break } }
    if ($start -lt 0) {
        if ($lines.Count -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.Add("[$section]"); $start = $lines.Count - 1
    }
    foreach ($k in $values.Keys) {
        $end = $start + 1
        while ($end -lt $lines.Count -and -not $lines[$end].TrimStart().StartsWith('[')) { $end++ }
        $line = "$k=$($values[$k])"; $found = $false
        for ($i = $start + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($k))\s*=") { $lines[$i] = $line; $found = $true; break }
        }
        if (-not $found) {
            $at = $end
            while ($at -gt $start + 1 -and -not $lines[$at - 1].Trim()) { $at-- }
            $lines.Insert($at, $line)
        }
    }
    [IO.File]::WriteAllLines($path, $lines)
}

function Get-IniValue($path, $section, $key) {
    $in = $false
    foreach ($l in Get-Content $path) {
        if ($l.TrimStart().StartsWith('[')) { $in = ($l.Trim() -ieq "[$section]"); continue }
        if ($in -and $l -match "^\s*$([regex]::Escape($key))\s*=(.*)$") { return $matches[1].Trim() }
    }
    $null
}

function Remove-IniKey($path, $section, $key) {
    $in = $false
    $out = foreach ($l in Get-Content $path) {
        if ($l.TrimStart().StartsWith('[')) { $in = ($l.Trim() -ieq "[$section]") }
        elseif ($in -and $l -match "^\s*$([regex]::Escape($key))\s*=") { continue }
        $l
    }
    [IO.File]::WriteAllLines($path, [string[]]@($out))
}

# ---- Sources -> staged files in the cache ------------------------------------
function Get-ReShadeDll {
    $stage = Join-Path $Cache "reshade-$ReShadeVersion"
    $dll = Join-Path $stage 'ReShade64.dll'
    if (Test-Path $dll) { return $dll }
    $setup = Get-File $ReShadeSetupUrl "ReShade_Setup_$($ReShadeVersion)_Addon.exe"
    if ((Get-Sha $setup) -ne $ReShadeSetupHash) { Remove-Item $setup; throw 'ReShade installer checksum mismatch; try again' }
    # The installer carries its DLLs in an embedded zip archive.
    $b = [IO.File]::ReadAllBytes($setup)
    $i = 0
    while (($i = [Array]::IndexOf($b, [byte]0x50, $i)) -ge 0 -and $i -lt $b.Length - 4) {
        if ($b[$i + 1] -eq 0x4B -and $b[$i + 2] -eq 3 -and $b[$i + 3] -eq 4) {
            $z = $null
            try {
                $z = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($b, $i, $b.Length - $i), [IO.Compression.ZipArchiveMode]::Read)
                $e = $z.GetEntry('ReShade64.dll')
                if ($e) {
                    New-Item -ItemType Directory -Force $stage | Out-Null
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dll, $true)
                    return $dll
                }
            } catch { } finally { if ($z) { $z.Dispose() } }
        }
        $i++
    }
    throw 'ReShade64.dll not found in the ReShade installer'
}

function Get-SnowyZipUrl {
    try {
        $html = (Invoke-WebRequest $SnowyPageUrl -UseBasicParsing -TimeoutSec 30).Content
        $best = $null; $bestVer = $null
        foreach ($m in [regex]::Matches($html, 'https://[^"''\s<>]+/lighting_v2/ets2ats_lighting_v2_([0-9_]+)_snowymoon\.io\.zip')) {
            $v = [version]('2.' + $m.Groups[1].Value.Replace('_', '.'))
            if (-not $bestVer -or $v -gt $bestVer) { $bestVer = $v; $best = $m.Value }
        }
        if ($best) { return $best }
    } catch { Warn "could not read $SnowyPageUrl ($($_.Exception.Message)); using the pinned version" }
    $SnowyFallbackUrl
}

function Get-SnowyFiles {
    $url = Get-SnowyZipUrl
    $name = Split-Path $url -Leaf
    $stage = Join-Path $Cache ($name -replace '\.zip$', '')
    if (-not ((Test-Path "$stage\dxgi.dll") -and (Test-Path "$stage\dinput8.dll"))) {
        Expand-Entries (Get-File $url $name) '(^|/)(dxgi|dinput8)\.dll$' $stage
    }
    if (-not ((Test-Path "$stage\dxgi.dll") -and (Test-Path "$stage\dinput8.dll"))) { throw "unexpected files in $name" }
    Say "   Snowymoon: $name"
    @{ Dxgi = "$stage\dxgi.dll"; Dinput8 = "$stage\dinput8.dll" }
}

function Get-SnowyDlss {
    $stage = Join-Path $Cache 'snowymoon-dlss_3.7'
    if (-not (Test-Path "$stage\nvngx_dlss.dll")) { Expand-Entries (Get-File $SnowyDlssUrl 'dlss_3.7.zip') '(^|/)nvngx_dlss\.dll$' $stage }
    "$stage\nvngx_dlss.dll"
}

function Get-StreamlineFiles {
    $stage = Join-Path $Cache "streamline-$StreamlineTag"
    $missing = @($StreamlineFiles | Where-Object { -not (Test-Path (Join-Path $stage $_)) })
    if ($missing) {
        Say '   NVIDIA Streamline + DLSS (about 280 MB, downloaded once)'
        $names = ($StreamlineFiles | ForEach-Object { [regex]::Escape($_) }) -join '|'
        Expand-Entries (Get-File $StreamlineUrl "streamline-sdk-$StreamlineTag.zip") "^bin/x64/($names)$" $stage
    }
    $StreamlineFiles | ForEach-Object { Join-Path $stage $_ }
}

function Test-Dlss5Dir($d) {
    if (-not $d -or -not (Test-Path $d)) { return $false }
    $hasAddon = @($Dlss5Addons | Where-Object { Test-Path (Join-Path $d $_) }).Count -gt 0
    $hasDlls = @($Dlss5Required | Where-Object { -not (Test-Path (Join-Path $d $_)) }).Count -eq 0
    $hasAddon -and $hasDlls
}

# Finds the user's own DLSS 5 files and keeps a copy so later runs don't ask again.
function Get-Dlss5Local {
    $keep = Join-Path $Root 'dlss5'
    $dirs = @($env:TRUCKGFX_DLSS5_DIR, $keep, (Join-Path $env:USERPROFILE 'Downloads'))
    if ($PSScriptRoot) { $dirs = @(Join-Path $PSScriptRoot 'dlss5') + $dirs }
    $dir = $dirs | Where-Object { Test-Dlss5Dir $_ } | Select-Object -First 1
    if (-not $dir) {
        Say '   DLSS 5 needs files that have no public download. Put these in one folder:'
        Say "     $($Dlss5Required -join ', ') and $($Dlss5Addons -join ' and/or ')"
        Say "     optional: $($Dlss5Optional -join ', ')"
        $d = (Ask '   Folder with those files (Enter to skip DLSS 5):' 'TRUCKGFX_DLSS5_PROMPT').Trim('"')
        if (Test-Dlss5Dir $d) { $dir = $d }
    }
    if (-not $dir) { return $null }
    if ((Resolve-Path $dir).Path -ne (Join-Path $Root 'dlss5')) {
        New-Item -ItemType Directory -Force $keep | Out-Null
        foreach ($n in $Dlss5Addons + $Dlss5Required + $Dlss5Optional) {
            $s = Join-Path $dir $n
            if (Test-Path $s) { Copy-Item $s $keep -Force }
        }
    }
    Say "   DLSS 5 files: $dir"
    @($Dlss5Addons + $Dlss5Required + $Dlss5Optional | Where-Object { Test-Path (Join-Path $keep $_) } | ForEach-Object { Join-Path $keep $_ })
}

function Install-Shaders($bin) {
    $dst = Join-Path $bin 'reshade-shaders'
    if (Test-Path $dst) { return }
    $zip = Get-File $ShadersUrl 'reshade-shaders-slim.zip'
    $tmp = Join-Path $Cache 'shaders-tmp'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $zip $tmp -Force
    $src = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
    New-Item -ItemType Directory -Force $dst | Out-Null
    foreach ($d in 'Shaders', 'Textures') { if (Test-Path "$src\$d") { Copy-Item "$src\$d" $dst -Recurse -Force } }
    Remove-Item $tmp -Recurse -Force
    Say '   added the standard ReShade shaders'
}

# ---- Game folder -------------------------------------------------------------
# Which managed mod a file in bin\win_x64 belongs to, or $null to leave it alone.
function Get-Kind($f) {
    $n = $f.Name.ToLower()
    if ($n -match '^(dxgi|dxgi2|d3d9|d3d11|d3d12|opengl32|dinput8|reshade64|reshade32|snowymoon64)\.dll$') {
        if ($f.VersionInfo.ProductName -eq 'ReShade') { return 'ReShade' }
        if (Test-Contains $f.FullName 'snowymoon') { return 'Snowymoon' }
        return $null
    }
    if ($n -match '^(dlss5-bridge|renodx-dlss|renodx-dlss5)\.addon64$' -or $n -match '^sl\..+\.dll$' -or $n -match '^nvngx_dlss(d|g|nr)?\.dll$') { return 'DLSS' }
    $null
}

function Find-Games {
    if ($env:TRUCKGFX_BIN) { return @([pscustomobject]@{ Key = 'custom'; Name = 'Game'; Bin = $env:TRUCKGFX_BIN; Exe = 'none' }) }
    $libs = @()
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value -replace '\\\\', '\' }
        }
    }
    $libs += "${env:ProgramFiles(x86)}\Steam"
    $games = @()
    $defs = @(@{ Key = 'ets2'; Name = 'Euro Truck Simulator 2'; Exe = 'eurotrucks2.exe' },
              @{ Key = 'ats'; Name = 'American Truck Simulator'; Exe = 'amtrucks.exe' })
    foreach ($def in $defs) {
        foreach ($l in $libs) {
            $bin = Join-Path $l "steamapps\common\$($def.Name)\bin\win_x64"
            if (Test-Path (Join-Path $bin $def.Exe)) {
                $games += [pscustomobject]@{ Key = $def.Key; Name = $def.Name; Bin = $bin; Exe = $def.Exe }
                break
            }
        }
    }
    $games
}

function Wait-GameClosed($g) {
    $proc = [IO.Path]::GetFileNameWithoutExtension("$($g.Exe)")
    if (-not $proc) { return }
    while (Get-Process $proc -ErrorAction SilentlyContinue) {
        Warn "$($g.Name) is running. Close it (and HaulMP's game window), then press Enter."
        Read-Host | Out-Null
    }
}

# Old HaulMP workarounds injected a second ReShade (ReShade64.dll). Two ReShades
# make the dxgi.dll one shut down, DX11 fails and the game hangs on start.
function Remove-Injector {
    $startup = [Environment]::GetFolderPath('Startup')
    $sh = New-Object -ComObject WScript.Shell
    foreach ($l in Get-ChildItem $startup -Filter *.lnk -ErrorAction SilentlyContinue) {
        $t = $sh.CreateShortcut($l.FullName)
        if ("$($t.TargetPath) $($t.Arguments)" -match '(?i)inject-reshade') {
            $dst = Join-Path $Root 'backup\startup'
            New-Item -ItemType Directory -Force $dst | Out-Null
            Move-Item $l.FullName $dst -Force
            Warn "Removed startup item '$($l.Name)': it injects a second ReShade, which stops the game starting under HaulMP. Saved in $dst"
        }
    }
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'") {
        if ($p.CommandLine -match '(?i)inject-reshade') {
            Stop-Process -Id $p.ProcessId -Force
            Warn "Stopped a running ReShade injector (process $($p.ProcessId))."
        }
    }
}

function Install-Game($g, $want, $src) {
    $bin = $g.Bin
    Step "$($g.Name)"
    Say "   $bin"
    $backup = Join-Path $Root "backup\$($g.Key)\$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
    New-Item -ItemType Directory -Force $backup | Out-Null

    # Clear every managed DLL first, then put back exactly what was chosen.
    # Configs (ReShade.ini, snowymoon and bridge .cfg files) stay where they are.
    # A file with an identical copy in the cache can be restored any time, so it
    # is deleted; anything else is kept in the backup folder.
    $cached = @(Get-ChildItem $Cache, (Join-Path $Root 'dlss5') -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in Get-ChildItem $bin -File) {
        if (-not (Get-Kind $f)) { continue }
        $same = $cached | Where-Object { $_.Length -eq $f.Length } | Where-Object { (Get-Sha $_.FullName) -eq (Get-Sha $f.FullName) } | Select-Object -First 1
        if ($same) { Remove-Item $f.FullName -Force } else { Move-Item $f.FullName $backup -Force }
    }
    $needDxgi = $want.ReShade -or $want.Snowy
    foreach ($n in @(if ($needDxgi) { 'dxgi.dll' }; if ($want.Snowy) { 'dinput8.dll' })) {
        $p = Join-Path $bin $n
        if (Test-Path $p) { Warn "$n belongs to another mod; moved it to $backup"; Move-Item $p $backup -Force }
    }

    function Put($from, $name) { Copy-Item $from (Join-Path $bin $name) -Force }
    if ($want.ReShade) { Put $src.ReShade 'dxgi.dll' }
    if ($want.Snowy) {
        Put $src.Snowy.Dinput8 'dinput8.dll'
        if ($want.ReShade) { Put $src.Snowy.Dxgi 'dxgi2.dll' } else { Put $src.Snowy.Dxgi 'dxgi.dll' }
    }
    if ($want.SnowyDlss) { Put $src.SnowyDlss 'nvngx_dlss.dll' }
    if ($want.Dlss5) {
        # After Snowymoon's DLSS, so DLSS 5's nvngx_dlss.dll replaces it.
        foreach ($s in $src.Streamline) { Put $s (Split-Path $s -Leaf) }
        foreach ($s in $src.Dlss5Local) {
            $leaf = Split-Path $s -Leaf
            if ($leaf -like '*.cfg' -and (Test-Path (Join-Path $bin $leaf))) { continue }
            Put $s $leaf
        }
    }

    if ($want.ReShade) {
        $ini = Join-Path $bin 'ReShade.ini'
        if (Test-Path $ini) { Copy-Item $ini $backup } else { [IO.File]::WriteAllLines($ini, [string[]]$DefaultReShadeIni) }
        if ($want.Snowy) { Set-Ini $ini 'PROXY' @{ EnableProxyLibrary = '1'; InitProxyFunctions = '1'; ProxyLibrary = '.\dxgi2.dll' } }
        elseif (Get-IniValue $ini 'PROXY' 'ProxyLibrary') { Set-Ini $ini 'PROXY' @{ EnableProxyLibrary = '0' } }
        if ($want.Dlss5 -and (Test-Path (Join-Path $bin 'renodx-dlss.addon64'))) { Set-Ini $ini 'ADDON' @{ LoadFromDllMain = 'renodx-dlss.addon64' } }
        elseif ((Get-IniValue $ini 'ADDON' 'LoadFromDllMain') -eq 'renodx-dlss.addon64') { Remove-IniKey $ini 'ADDON' 'LoadFromDllMain' }
        Install-Shaders $bin
    }

    # Keep only backups of files that actually changed or went away.
    foreach ($b in Get-ChildItem $backup -File) {
        $cur = Join-Path $bin $b.Name
        if ((Test-Path $cur) -and (Get-Sha $cur) -eq (Get-Sha $b.FullName)) { Remove-Item $b.FullName }
    }
    if (-not (Get-ChildItem $backup)) { Remove-Item $backup } else { Say "   replaced files saved in $backup" }

    # Report the load chain the game (and HaulMP) will see.
    $files = Get-ChildItem $bin -File | Where-Object { Get-Kind $_ }
    $has = { param($n) [bool]($files | Where-Object Name -eq $n) }
    if (& $has 'dxgi.dll') {
        $first = Get-Kind (Get-Item (Join-Path $bin 'dxgi.dll'))
        $chain = "dxgi.dll ($first)"
        if ($first -eq 'ReShade' -and (& $has 'dxgi2.dll')) { $chain += ' -> dxgi2.dll (Snowymoon)' }
        Say "   load chain: $chain" 'Green'
    } else { Say '   no graphics mods installed (vanilla)' 'Green' }
    if (& $has 'dinput8.dll') { Say '   dinput8.dll (Snowymoon)' 'Green' }
    $dl = @($files | Where-Object { (Get-Kind $_) -eq 'DLSS' } | ForEach-Object Name)
    if ($dl) { Say "   DLSS files: $($dl -join ', ')" 'Green' }
    foreach ($bad in 'ReShade64.dll', 'ReShade32.dll', 'SnowyMoon64.dll') {
        if (Test-Path (Join-Path $bin $bad)) { Warn "$bad is still in the game folder; it will break HaulMP launches" }
    }
}

# ---- Menu --------------------------------------------------------------------
Say ''
Say 'ETS2 / ATS graphics setup: ReShade, Snowymoon, DLSS 5' 'White'
Say 'HaulMP-safe: mods load through the game folder dxgi.dll chain; nothing is injected.'

$games = @(Find-Games)
if (-not $games) {
    $p = (Ask 'ETS2/ATS not found. Paste the game''s bin\win_x64 folder:' 'TRUCKGFX_BIN_PROMPT').Trim('"')
    if (-not (Test-Path $p)) { Warn 'Folder not found.'; return }
    $exe = @('eurotrucks2.exe', 'amtrucks.exe' | Where-Object { Test-Path (Join-Path $p $_) })[0]
    $games = @([pscustomobject]@{ Key = 'custom'; Name = 'Game'; Bin = $p; Exe = "$exe" })
}
if ($games.Count -gt 1) {
    Say ''
    Say '  1. Euro Truck Simulator 2'
    Say '  2. American Truck Simulator'
    Say '  3. Both'
    switch (Ask 'Which game?' 'TRUCKGFX_GAME') {
        '1' { $games = @($games | Where-Object Key -eq 'ets2') }
        '2' { $games = @($games | Where-Object Key -eq 'ats') }
        '3' { }
        default { Warn 'No game chosen.'; return }
    }
}

Say ''
Say '  1. DLSS 5'
Say '  2. Snowymoon'
Say '  3. ReShade'
Say '  4. All'
Say '  5. All but DLSS 5'
Say '  6. Remove all (back to vanilla)'
$want = @{ ReShade = $false; Snowy = $false; Dlss5 = $false; SnowyDlss = $false }
switch (Ask 'Choose 1-6:' 'TRUCKGFX_CHOICE') {
    '1' { $want.ReShade = $true; $want.Dlss5 = $true; Say 'DLSS 5 runs as ReShade add-ons, so ReShade is installed too.' }
    '2' { $want.Snowy = $true }
    '3' { $want.ReShade = $true }
    '4' { $want.ReShade = $true; $want.Snowy = $true; $want.Dlss5 = $true }
    '5' { $want.ReShade = $true; $want.Snowy = $true }
    '6' { }
    default { Warn 'Nothing chosen.'; return }
}
if ($want.Snowy -and -not $want.Dlss5) {
    $want.SnowyDlss = (Ask 'Also install Snowymoon''s DLSS 3.7 (nvngx_dlss.dll)? (y/n)' 'TRUCKGFX_SNOWYDLSS') -match '^(y|yes)$'
}

Step 'Getting files'
$src = @{}
try {
    if ($want.Dlss5) {
        $src.Dlss5Local = Get-Dlss5Local
        if (-not $src.Dlss5Local) { Warn 'DLSS 5 skipped: its files were not found.'; $want.Dlss5 = $false }
        else { $src.Streamline = Get-StreamlineFiles }
    }
    if ($want.ReShade) { $src.ReShade = Get-ReShadeDll; Say "   ReShade $ReShadeVersion (add-on build)" }
    if ($want.Snowy) { $src.Snowy = Get-SnowyFiles }
    if ($want.SnowyDlss) { $src.SnowyDlss = Get-SnowyDlss; Say '   Snowymoon DLSS 3.7' }
} catch { Warn "Stopped before changing anything: $($_.Exception.Message)"; return }

Remove-Injector
foreach ($g in $games) {
    Wait-GameClosed $g
    try { Install-Game $g $want $src }
    catch {
        Warn "$($g.Name): $($_.Exception.Message)"
        if ($_.Exception -is [UnauthorizedAccessException]) { Warn 'Run PowerShell as administrator and try again.' }
    }
}

Step 'Done'
if ($want.Snowy) { Say 'Snowymoon asks for its activation key the first time the game starts.' }
if ($want.ReShade) { Say 'ReShade overlay: press Home in game.' }
Say 'Launch through HaulMP or Steam as usual. Run this again any time to switch options.'
}

Main
