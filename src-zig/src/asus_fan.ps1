# Sets the ASUS firmware fan profile (the Whisper / Standard / Performance of MyASUS and Armoury
# Crate) through the ASUS ATK WMI interface, or with -Profile full / auto runs the CPU fan at full
# speed / gives it back to the firmware. Needs admin: thermal.zig starts it with "runas".
# Writes {ok, profile, cpuFanRpm, gpuFanRpm, error} as JSON to -Out.
param([string]$Profile, [string]$Out)

$ErrorActionPreference = 'Stop'
$r = [ordered]@{ ok = $false }
try {
    $o = Get-CimInstance -Namespace root/wmi -ClassName AsusAtkWmi_WMNB
    if (-not $o) { throw 'ASUS WMI interface not found (ASUS System Control Interface driver)' }
    function Get-Dev([uint32]$id) {
        [uint32](Invoke-CimMethod -InputObject $o -MethodName DSTS -Arguments @{ Device_ID = $id }).device_status
    }
    function Set-Dev([uint32]$id, [uint32]$v) {
        [uint32](Invoke-CimMethod -InputObject $o -MethodName DEVS -Arguments @{ Device_ID = $id; Control_status = $v }).result
    }
    function Test-Dev([uint32]$id) {
        $s = Get-Dev $id
        ($s -ne 0xFFFFFFFE) -and (($s -band 0x00010000) -ne 0)
    }

    # full speed: the CPU fan device takes 1 (full) / 0 (auto), as Linux's asus-wmi pwm1_enable does
    if ($Profile -eq 'full' -or $Profile -eq 'auto') {
        if (-not (Test-Dev 0x00110013)) { throw 'This laptop cannot run its fan at full speed' }
        $res = Set-Dev 0x00110013 ([uint32]($Profile -eq 'full'))
        if ($res -ne 1) { throw ('The fan did not accept the change ({0})' -f $res) }
        Start-Sleep -Seconds 3
    }

    # ROG / TUF: 0 standard, 1 performance (turbo), 2 silent.
    # Vivobook / Zenbook: their own device, with silent and performance swapped.
    if (Test-Dev 0x00120075) { $id = 0x00120075; $map = @{ standard = 0; performance = 1; silent = 2 } }
    elseif (Test-Dev 0x00110019) { $id = 0x00110019; $map = @{ standard = 0; silent = 1; performance = 2 } }
    else { $id = $null }
    if (-not $id -and -not ($Profile -eq 'full' -or $Profile -eq 'auto')) { throw 'This laptop has no ASUS fan profile' }

    if ($id) {
        if ($map.ContainsKey($Profile)) {
            [void](Set-Dev $id $map[$Profile])
        }
        $cur = (Get-Dev $id) -band 0xFF
        foreach ($k in $map.Keys) { if ($map[$k] -eq $cur) { $r.profile = $k } }
    }

    # fan speeds, in hundreds of RPM
    foreach ($f in @(@{ key = 'cpuFanRpm'; id = 0x00110013 }, @{ key = 'gpuFanRpm'; id = 0x00110014 })) {
        $s = Get-Dev $f.id
        if (($s -ne 0xFFFFFFFE) -and (($s -band 0x00010000) -ne 0)) { $r[$f.key] = ($s -band 0xFFFF) * 100 }
    }
    $r.ok = $true
}
catch {
    $r.error = $_.Exception.Message
}
[IO.File]::WriteAllText($Out, ($r | ConvertTo-Json -Compress))
