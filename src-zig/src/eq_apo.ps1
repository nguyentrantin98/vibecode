# Installs / removes VIBE CODE's equalizer APO (vibe-eq-apo.dll). Needs admin: audio.zig starts
# it with "runas". Writes {ok, devices, skipped, error} as JSON to -Out.
#
# install: copies the dll to %ProgramFiles%\VIBE CODE Audio, registers the COM class and the APO,
#   and puts it in the post-mix (GFX) slot of each playback device that has no effects of its own
#   (HDMI / monitor audio, many USB and Bluetooth devices), with a KSNODETYPE_ANY association.
#   Devices whose driver brings its own effect chain (Realtek's CompositeFX lists) are left alone:
#   Windows rebuilds those from the driver's keys, an entry added here is ignored.
#   Then lets everyone write %ProgramData%\VIBE CODE Audio\eq.txt and restarts Windows audio.
#   What it adds is noted in backup.json so remove undoes exactly that. If audiodg crashes while a
#   test tone plays right after, everything is removed again and the install fails.
# remove: takes it off every device, unregisters it and restarts Windows audio.
# -Only <guid,guid>: just those endpoints (testing).
param([string]$Action, [string]$Dll, [string]$Out, [string]$Only = '')

$ErrorActionPreference = 'Stop'
$clsid = '{A1C947FD-C3DA-4823-B683-41C0BA386B75}'
$fxBase = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}'
$assoc = "$fxBase,0"          # PKEY_FX_Association
$gfx = "$fxBase,2"            # PKEY_FX_PostMixEffectClsid
$efx = "$fxBase,15"           # PKEY_CompositeFX_EndpointEffectClsid
$sysFxOff = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5'   # PKEY_AudioEndpoint_Disable_SysFx
$anyNode = '{00000000-0000-0000-0000-000000000000}'      # KSNODETYPE_ANY
$render = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$bin = Join-Path $env:ProgramFiles 'VIBE CODE Audio'
$data = Join-Path $env:ProgramData 'VIBE CODE Audio'
$backupFile = Join-Path $data 'backup.json'

$r = [ordered]@{ ok = $false; devices = @(); skipped = @() }

function Get-DeviceName($key) {
    $p = Get-ItemProperty (Join-Path $key.PSPath 'Properties') -ErrorAction SilentlyContinue
    if (-not $p) { return $key.PSChildName }
    $name = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    $dev = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    if ($name -and $dev) { return "$name ($dev)" }
    if ($name) { return $name }
    return $key.PSChildName
}

# Administrators may only set values on an endpoint's FxProperties (TrustedInstaller owns it), so the
# key is opened with exactly that right: PowerShell's registry provider asks for full access and fails.
function Open-Fx($key) {
    $path = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$($key.PSChildName)\FxProperties"
    $rights = [Security.AccessControl.RegistryRights]::SetValue -bor [Security.AccessControl.RegistryRights]::ReadKey
    [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
}
function Set-Multi($fx, $name, $values) { $fx.SetValue($name, [string[]]$values, [Microsoft.Win32.RegistryValueKind]::MultiString) }

function Get-Endpoints {
    $keys = Get-ChildItem $render
    if ($Only) { $want = $Only.Split(',') | ForEach-Object { $_.Trim().ToLower() }; $keys = $keys | Where-Object { $want -contains $_.PSChildName.ToLower() } }
    $keys
}

function Restart-Audio {
    Restart-Service -Name AudioEndpointBuilder -Force
    Start-Service -Name Audiosrv
}

function Read-Backup {
    if (Test-Path $backupFile) { return @(Get-Content $backupFile -Raw | ConvertFrom-Json) }
    return @()
}

# Takes the APO off every endpoint (all of them, whatever -Only says) and unregisters it.
function Remove-Apo {
    $backup = @(Read-Backup)
    $removed = @()
    foreach ($k in Get-ChildItem $render) {
        $fx = Open-Fx $k
        if (-not $fx) { continue }
        $note = $backup | Where-Object { $_.key -eq $k.PSChildName } | Select-Object -First 1
        $hit = $false
        $list = @($fx.GetValue($efx))
        if ($list -contains $clsid) {
            $rest = @($list | Where-Object { $_ -and $_ -ne $clsid })
            if ($rest.Count -eq 0) { $fx.DeleteValue($efx, $false) } else { Set-Multi $fx $efx $rest }
            $hit = $true
        }
        if ($fx.GetValue($gfx) -eq $clsid) {
            $fx.DeleteValue($gfx, $false)
            if ($note -and $note.createdAssoc) { $fx.DeleteValue($assoc, $false) }
            $hit = $true
        }
        if ($note -and $note.sysFx -eq 1) { $fx.SetValue($sysFxOff, 1, [Microsoft.Win32.RegistryValueKind]::DWord) }
        $fx.Close()
        if ($hit) { $removed += (Get-DeviceName $k) }
    }
    Remove-Item -Recurse -Force "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "HKLM:\SOFTWARE\Classes\CLSID\$clsid" -ErrorAction SilentlyContinue
    Remove-Item -Force $backupFile, (Join-Path $data 'status.txt') -ErrorAction SilentlyContinue
    Restart-Audio
    # audiodg has let go of the dll now
    Get-ChildItem $bin -Filter 'vibe-eq-apo-*.dll' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    $removed
}

# A quiet 1.5 s tone on the default device, so audiodg builds its effect chain right away.
function Play-TestTone {
    $rate = 48000; $n = [int]($rate * 1.5)
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $ms
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $n * 2)); $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$rate); $w.Write([int]($rate * 2)); $w.Write([int16]2); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]($n * 2))
    for ($i = 0; $i -lt $n; $i++) { $w.Write([int16](300 * [Math]::Sin(2 * [Math]::PI * 440 * $i / $rate))) }
    $ms.Position = 0
    (New-Object Media.SoundPlayer $ms).PlaySync()
}

function Get-AudiodgCrashes($since) {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; StartTime = $since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'AUDIODG' })
}

try {
    if ($Action -eq 'install') {
        if (-not (Test-Path $Dll)) { throw "Missing $Dll" }
        New-Item -ItemType Directory -Force $bin, $data | Out-Null
        # a new name per build: audiodg may still hold the previous one open
        $hash = (Get-FileHash $Dll -Algorithm SHA256).Hash.Substring(0, 10).ToLower()
        $target = Join-Path $bin "vibe-eq-apo-$hash.dll"
        if (-not (Test-Path $target)) { Copy-Item $Dll $target -Force }
        Get-ChildItem $bin -Filter 'vibe-eq-apo-*.dll' | Where-Object { $_.FullName -ne $target } | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        # the app (as the user) writes eq.txt, audiodg (LOCAL SERVICE) reads it and writes status.txt
        & icacls $data /grant '*S-1-1-0:(OI)(CI)M' /T /Q | Out-Null
        $eq = Join-Path $data 'eq.txt'
        if (-not (Test-Path $eq)) { [IO.File]::WriteAllText($eq, "0 0 0 0 0 0 0 0 0 0 0`r`n") }

        $c = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
        New-Item -Force $c | Out-Null
        Set-ItemProperty $c '(default)' 'VIBE CODE EQ'
        New-Item -Force "$c\InprocServer32" | Out-Null
        Set-ItemProperty "$c\InprocServer32" '(default)' $target
        Set-ItemProperty "$c\InprocServer32" 'ThreadingModel' 'Both'

        $a = "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
        New-Item -Force $a | Out-Null
        Set-ItemProperty $a 'FriendlyName' 'VIBE CODE EQ'
        Set-ItemProperty $a 'Copyright' 'VIBE CODE'
        foreach ($kv in @(('MajorVersion', 1), ('MinorVersion', 0), ('Flags', 15), ('MinInputConnections', 1), ('MaxInputConnections', 1),
                ('MinOutputConnections', 1), ('MaxOutputConnections', 1), ('MaxInstances', -1), ('NumAPOInterfaces', 1))) {
            New-ItemProperty $a -Name $kv[0] -Value $kv[1] -PropertyType DWord -Force | Out-Null
        }
        Set-ItemProperty $a 'APOInterface0' '{FD7F2B29-24D0-4b5c-B177-592C39F9CA10}'

        $backup = @(Read-Backup)
        foreach ($k in Get-Endpoints) {
            $name = Get-DeviceName $k
            if (-not (Test-Path (Join-Path $k.PSPath 'FxProperties'))) { $r.skipped += "$name (no audio effects key)"; continue }
            $fx = Open-Fx $k
            if (-not $fx) { $r.skipped += "$name (no access)"; continue }
            $note = [ordered]@{ key = $k.PSChildName; createdAssoc = $false; sysFx = $null }
            $driverFx = @($fx.GetValueNames() | Where-Object { $_ -match '^\{d04e05a6-594b-4fb6-a80d-01af5eed7d1d\},(1|7|1[3-5])$' })
            if ($driverFx.Count -gt 0 -or ($fx.GetValue($gfx) -and $fx.GetValue($gfx) -ne $clsid)) {
                $fx.Close()
                $r.skipped += "$name (driver effects)"
                continue
            }
            if (-not $fx.GetValue($assoc)) {
                $fx.SetValue($assoc, $anyNode, [Microsoft.Win32.RegistryValueKind]::String)
                $note.createdAssoc = $true
            }
            $fx.SetValue($gfx, $clsid, [Microsoft.Win32.RegistryValueKind]::String)
            # "Audio enhancements" off would bypass every effect, this one included
            if ($fx.GetValue($sysFxOff) -eq 1) {
                $note.sysFx = 1
                $fx.SetValue($sysFxOff, 0, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
            $fx.Close()
            $backup = @($backup | Where-Object { $_.key -ne $note.key }) + [pscustomobject]$note
            $r.devices += $name
        }
        [IO.File]::WriteAllText($backupFile, (ConvertTo-Json @($backup) -Depth 3))

        $since = Get-Date
        Restart-Audio
        Start-Sleep -Seconds 1
        try { Play-TestTone } catch {}
        Start-Sleep -Seconds 3
        if ((Get-AudiodgCrashes $since).Count -gt 0) {
            [void](Remove-Apo)
            throw 'Windows audio crashed with the equalizer on, so it was removed again'
        }
    }
    elseif ($Action -eq 'remove') {
        $r.devices = @(Remove-Apo)
    }
    else { throw "Unknown action $Action" }
    $r.ok = $true
}
catch {
    $r.error = $_.Exception.Message
}
[IO.File]::WriteAllText($Out, ($r | ConvertTo-Json -Compress -Depth 3))
