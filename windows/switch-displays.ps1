<#
.SYNOPSIS
Switch both monitors' inputs from this Windows PC.

.DESCRIPTION
    switch-displays.ps1 windows      pull both monitors here   (the normal case)
    switch-displays.ps1 mac          push both to the Mac
    switch-displays.ps1 windows -Only asus     move one monitor only

Values are documented in ..\displays.toml, which is the source of truth. They are
duplicated here as literals rather than parsed, because this script runs from a
Scheduled Task on every device arrival and should not depend on a TOML parser.
If you change displays.toml, change these to match.

The two monitors do not speak the same dialect:

  ASUS PG42UQ    standard DDC/CI, VCP 0x60, via dxva2.dll SetVCPFeature
  LG 45GX950A    standard input control is STUBBED; input lives on LG's
                 manufacturer sidechannel (I2C src 0x50, VCP 0xF4), reachable
                 only by injecting raw I2C through NVAPI. We shell out to
                 lg-input-switch.exe rather than binding NVAPI ourselves.

NEVER verify a switch by reading a VCP value back -- see ..\displays.toml for why.
Both monitors switched correctly during macOS testing while reads said they had
not. Writes are fire-and-forget; there are deliberately no reads in this script.

HAZARD: lg-input-switch injects the packet on EVERY connected output and ports
0-7, so the ASUS also receives the LG's VCP 0xF4 write. It is not addressable to
one monitor. See ..\AGENTS.md.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('windows', 'mac')]
    [string]$Target = 'windows',

    # Move one monitor only. The test plan and AGENTS.md rule 4 need this: moving
    # both at once can take the last display out from under the terminal.
    [ValidateSet('both', 'lg', 'asus')]
    [string]$Only = 'both',

    # DDC is lossy and these writes are idempotent, so a repeat is free.
    [int]$Tries = 2,

    # Append to this file as well as writing to the host. usb-watch.ps1 passes its
    # own log through, so a fired switch is recorded beside the arrival that caused
    # it. Unset for manual runs, where the host output is what you want.
    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- the contract, from ..\displays.toml -----------------------------------

# Matched against the monitor's PnP interface path. This is the EDID vendor+product
# id as Windows spells it. Deliberately not an index: \\.\DISPLAY1 is the ASUS on
# this machine, and an index silently becoming the other monitor would send LG
# service-channel writes to the ASUS.
$ASUS_MATCH = 'AUS42E0'          # ASUS PG42UQ, EDID 0x06b3:0x42e0

$ASUS_VCP_INPUT = 0x60
$ASUS_WIN       = 0x11           # 17 -- HDMI 1
$ASUS_MAC       = 0x0F           # 15 -- DisplayPort

# lg-input-switch verbs. Its INPUTS table maps dp->0xD0, usbc->0xD1, which is
# exactly displays.toml's windows/mac values for this panel.
$LG_WIN = 'dp'                   # 0xD0 -- DisplayPort
$LG_MAC = 'usbc'                 # 0xD1 -- USB-C

$LG_EXE_CANDIDATES = @(
    $env:DISPLAY_SWITCH_LG_EXE,
    (Join-Path $PSScriptRoot 'lg-input-switch.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\display-switch\lg-input-switch.exe')
) | Where-Object { $_ }

# --- logging ---------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    $line = '{0} display-switch: {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    if ($LogFile) {
        # The watcher appends to the same file, so a write can briefly collide.
        for ($i = 0; $i -lt 3; $i++) {
            try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 50 }
        }
    }
}

# --- ASUS: standard DDC/CI via the Monitor Configuration API ---------------

Add-Type -ErrorAction Stop @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class Ddc {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szDescription;
    }

    public delegate bool MonEnumProc(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFOEX mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string dev, uint devNum, ref DISPLAY_DEVICE dd, uint flags);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMon, ref uint n);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMon, uint n, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitors(uint n, PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetVCPFeature(IntPtr hMonitor, byte code, uint value);

    const uint EDD_GET_DEVICE_INTERFACE_NAME = 1;

    // The monitor's PnP interface path, e.g.
    //   \\?\DISPLAY#AUS42E0#5&aaaaaaaa&0&UID4352#{e6f07b5f-...}
    // This carries the EDID vendor+product id, which is what we match on. The
    // dxva2 description is not usable as a key: the LG reports the generic
    // "Generic PnP Monitor" string.
    public static string InterfacePath(string deviceName) {
        var dd = new DISPLAY_DEVICE();
        dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        if (!EnumDisplayDevices(deviceName, 0, ref dd, EDD_GET_DEVICE_INTERFACE_NAME)) return "";
        return dd.DeviceID ?? "";
    }

    public static List<IntPtr> Handles() {
        var list = new List<IntPtr>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
            delegate(IntPtr h, IntPtr hdc, ref RECT rc, IntPtr d) { list.Add(h); return true; },
            IntPtr.Zero);
        return list;
    }

    public static string DeviceOf(IntPtr hMon) {
        var mi = new MONITORINFOEX();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (!GetMonitorInfo(hMon, ref mi)) return "";
        return mi.szDevice ?? "";
    }

    // Write only. There is deliberately no GetVCPFeature wrapper here: reads on
    // this hardware produce false negatives and must never gate a switch.
    public static int SetVcp(IntPtr hMon, byte code, uint value) {
        uint n = 0;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref n) || n == 0) return -1;
        var arr = new PHYSICAL_MONITOR[n];
        if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return -2;
        try {
            int ok = 0;
            foreach (var pm in arr) {
                if (SetVCPFeature(pm.hPhysicalMonitor, code, value)) ok++;
            }
            return ok;
        } finally {
            DestroyPhysicalMonitors(n, arr);
        }
    }
}
'@

# Resolve a monitor's HMONITOR by the EDID id in its PnP interface path.
function Resolve-Monitor {
    param([string]$Match)
    foreach ($h in [Ddc]::Handles()) {
        $dev = [Ddc]::DeviceOf($h)
        if (-not $dev) { continue }
        $path = [Ddc]::InterfacePath($dev)
        if ($path -and $path -match [regex]::Escape($Match)) {
            return [PSCustomObject]@{ Handle = $h; Device = $dev; Path = $path }
        }
    }
    return $null
}

function Switch-Asus {
    param([int]$Value, [string]$Label)

    $mon = Resolve-Monitor -Match $ASUS_MATCH
    if (-not $mon) {
        Write-Log "WARN: ASUS ($ASUS_MATCH) not found in display enumeration; skipped"
        return $false
    }

    $ok = 0
    for ($i = 0; $i -lt $Tries; $i++) {
        $r = [Ddc]::SetVcp($mon.Handle, [byte]$ASUS_VCP_INPUT, [uint32]$Value)
        if ($r -gt 0) { $ok++ }
    }

    if ($ok -eq 0) {
        Write-Log ("ERROR: ASUS -> {0} (VCP 0x{1:X2} = 0x{2:X2}) -- no write succeeded on {3}" -f $Label, $ASUS_VCP_INPUT, $Value, $mon.Device)
        return $false
    }
    Write-Log ("ASUS -> {0} (VCP 0x{1:X2} = 0x{2:X2}) on {3}" -f $Label, $ASUS_VCP_INPUT, $Value, $mon.Device)
    return $true
}

# --- LG: wrap lg-input-switch ----------------------------------------------

function Get-LgExe {
    foreach ($p in $LG_EXE_CANDIDATES) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Switch-Lg {
    param([string]$Verb, [string]$Label)

    $exe = Get-LgExe
    if (-not $exe) {
        Write-Log "ERROR: lg-input-switch.exe not found. Run install.ps1, or set DISPLAY_SWITCH_LG_EXE."
        return $false
    }

    $ok = 0
    for ($i = 0; $i -lt $Tries; $i++) {
        & $exe $Verb 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ }
    }

    if ($ok -eq 0) {
        Write-Log "ERROR: LG -> $Label ($Verb) -- lg-input-switch reported failure"
        return $false
    }
    Write-Log "LG -> $Label ($Verb)"
    return $true
}

# --- main -------------------------------------------------------------------

if ($Target -eq 'windows') {
    $asusValue = $ASUS_WIN; $lgVerb = $LG_WIN; $label = 'this PC'
} else {
    $asusValue = $ASUS_MAC; $lgVerb = $LG_MAC; $label = 'the Mac'
}

$rc = 0
if ($Only -in @('both', 'asus')) { if (-not (Switch-Asus -Value $asusValue -Label $label)) { $rc = 1 } }
if ($Only -in @('both', 'lg'))   { if (-not (Switch-Lg   -Verb  $lgVerb    -Label $label)) { $rc = 1 } }

# A zero exit means the writes were sent, NOT that the monitors switched. There is
# no way to verify that from here: reads on this hardware lie. Confirm visually.
exit $rc
