<#
.SYNOPSIS
Read-only NVAPI display enumeration probe. Sends nothing to any monitor.

.DESCRIPTION
Phase 1 of the pre-login work (see ..\.context\PLAN.md). Answers one question:

    can this machine enumerate and identify its monitors through NVAPI, in a
    context that has no desktop?

That matters because every display path the Windows switcher uses today is
desktop-bound -- EnumDisplayMonitors, EnumDisplayDevices, GetPhysicalMonitorsFromHMONITOR
-- and a process with no desktop (a service in session 0, a non-interactive
scheduled task) sees zero monitors. NVAPI talks to the driver rather than to a
window station, so it may not have that limitation. Nobody has tested it.

    .\nvapi-probe.ps1
    .\nvapi-probe.ps1 -LogFile C:\ProgramData\display-switch\nvapi-probe.log

SAFETY. This script performs NO writes of any kind:

  * NvAPI_I2CWrite is deliberately NOT resolved anywhere in this file. It cannot
    be called, including by accident.
  * Nothing is sent to I2C source address 0x50, the LG service channel.
  * No VCP value is read or written. NvAPI_GPU_GetEDID reads the monitor's EDID
    block from the GPU, which is not the service channel and not a VCP read.

It is therefore safe to run repeatedly, in any context, with no monitor at risk
and nothing to confirm visually.

The probe also runs a user32 EnumDisplayMonitors count as a CONTROL, in the same
process. Contrasting the two counts in one run is the whole point: "desktop path
sees 0, NVAPI path sees 2" is the result that makes pre-login switching possible.

Function ids and struct layouts are taken from fiddyschmitt/SimpleKVM (MIT), with
NvAPI_Initialize / NvAPI_EnumPhysicalGPUs independently corroborated by
meer-cha/lg-input-switch. See ..\.context\PLAN.md for provenance and the traps.
#>

[CmdletBinding()]
param(
    # Append to this file as well as writing to the host. Needed for the session-0
    # and non-interactive runs, which have no console anyone can see.
    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Probe {
    param([string]$Message)
    $line = '{0} nvapi-probe: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($LogFile) {
        for ($i = 0; $i -lt 3; $i++) {
            try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 50 }
        }
    }
}

if ($LogFile) {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

Add-Type -ErrorAction Stop @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class NvProbe {

    // ---- loader ------------------------------------------------------------
    // PowerShell 5.1 is .NET Framework, which has no NativeLibrary; use kernel32.

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true, BestFitMapping = false)]
    static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    // ---- user32 control ----------------------------------------------------
    // Same process, same moment: how many monitors does the DESKTOP path see?

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    public delegate bool MonEnumProc(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnumProc proc, IntPtr data);

    public static int CountDesktopMonitors() {
        int n = 0;
        try {
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
                delegate(IntPtr h, IntPtr hdc, ref RECT rc, IntPtr d) { n++; return true; },
                IntPtr.Zero);
        } catch {
            return -1;
        }
        return n;
    }

    // ---- NVAPI -------------------------------------------------------------
    // NvAPI_I2CWrite (0xE812EB07) is deliberately absent. This probe cannot write.

    const uint NVAPI_INITIALIZE                        = 0x0150E828;
    const uint NVAPI_ENUMPHYSICALGPUS                  = 0xE5AC921F;
    const uint NVAPI_GPU_GETCONNECTEDDISPLAYIDS        = 0x0078DBA2;
    const uint NVAPI_GPU_GETEDID                       = 0x37D32E69;
    const uint NVAPI_SYS_GETGPUANDOUTPUTIDFROMDISPLAYID = 0x112BA1A5;

    const int NVAPI_MAX_PHYSICAL_GPUS = 64;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate IntPtr QueryInterface_t(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Initialize_t();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int EnumPhysicalGPUs_t([Out] IntPtr[] handles, out int count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int GetConnectedDisplayIds_t(IntPtr gpu, [In, Out] NV_GPU_DISPLAYIDS[] ids, ref int count, int flags);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int GetEDID_t(IntPtr gpu, int outputId, ref NV_EDID edid);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int GetGpuAndOutputIdFromDisplayId_t(uint displayId, out IntPtr gpu, out uint outputId);

    // Struct version is sizeof(struct) | (version << 16). Get the layout wrong and
    // the encoded size is wrong and NvAPI rejects the call with an obscure error.
    [StructLayout(LayoutKind.Sequential)]
    public struct NV_GPU_DISPLAYIDS {
        public int version;
        public int connectorType;
        public int displayId;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_EDID {
        public int version;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public byte[] edidData;
        public int edidSize;
        public uint edidId;   // NV_EDID_V3 has these two extra fields; without them
        public uint offset;   // the size-encoded version is wrong and NvAPI refuses
    }

    static QueryInterface_t _qi;
    static Initialize_t _init;
    static EnumPhysicalGPUs_t _enumGpus;
    static GetConnectedDisplayIds_t _getDisplayIds;
    static GetEDID_t _getEdid;
    static GetGpuAndOutputIdFromDisplayId_t _getOutputId;

    static T Resolve<T>(uint id) where T : class {
        IntPtr p = _qi(id);
        if (p == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }

    public static string Init() {
        if (!Environment.Is64BitProcess)
            return "FAIL: not a 64-bit process; nvapi64.dll cannot be loaded";

        IntPtr lib = LoadLibrary("nvapi64.dll");
        if (lib == IntPtr.Zero)
            return "FAIL: nvapi64.dll not found (no NVIDIA driver?)";

        IntPtr qi = GetProcAddress(lib, "nvapi_QueryInterface");
        if (qi == IntPtr.Zero) qi = GetProcAddress(lib, "nvapi64_QueryInterface");
        if (qi == IntPtr.Zero)
            return "FAIL: nvapi_QueryInterface not exported by nvapi64.dll";

        _qi = (QueryInterface_t)Marshal.GetDelegateForFunctionPointer(qi, typeof(QueryInterface_t));

        _init          = Resolve<Initialize_t>(NVAPI_INITIALIZE);
        _enumGpus      = Resolve<EnumPhysicalGPUs_t>(NVAPI_ENUMPHYSICALGPUS);
        _getDisplayIds = Resolve<GetConnectedDisplayIds_t>(NVAPI_GPU_GETCONNECTEDDISPLAYIDS);
        _getEdid       = Resolve<GetEDID_t>(NVAPI_GPU_GETEDID);
        _getOutputId   = Resolve<GetGpuAndOutputIdFromDisplayId_t>(NVAPI_SYS_GETGPUANDOUTPUTIDFROMDISPLAYID);

        List<string> missing = new List<string>();
        if (_init          == null) missing.Add("NvAPI_Initialize");
        if (_enumGpus      == null) missing.Add("NvAPI_EnumPhysicalGPUs");
        if (_getDisplayIds == null) missing.Add("NvAPI_GPU_GetConnectedDisplayIds");
        if (_getEdid       == null) missing.Add("NvAPI_GPU_GetEDID");
        if (_getOutputId   == null) missing.Add("NvAPI_SYS_GetGpuAndOutputIdFromDisplayId");
        if (missing.Count > 0)
            return "FAIL: QueryInterface returned NULL for: " + string.Join(", ", missing);

        int rc = _init();
        if (rc != 0)
            return "FAIL: NvAPI_Initialize returned " + rc;

        return "OK";
    }

    // EDID manufacturer id is three 5-bit letters packed big-endian in bytes 8-9.
    static string DecodeMfg(ushort id) {
        char a = (char)(((id >> 10) & 0x1F) + 64);
        char b = (char)(((id >> 5)  & 0x1F) + 64);
        char c = (char)((id         & 0x1F) + 64);
        return new string(new char[] { a, b, c });
    }

    static string ConnectorName(int t) {
        switch (t) {
            case 0:  return "Uninitialized";
            case 1:  return "VGA";
            case 2:  return "Component";
            case 3:  return "SVideo";
            case 4:  return "HDMI";
            case 5:  return "DVI";
            case 6:  return "LVDS";
            case 7:  return "DisplayPort";
            case 8:  return "Composite";
            default: return "Unknown(" + t + ")";
        }
    }

    public static List<string> Enumerate() {
        List<string> outp = new List<string>();

        IntPtr[] gpus = new IntPtr[NVAPI_MAX_PHYSICAL_GPUS];
        int gpuCount = 0;
        int rc = _enumGpus(gpus, out gpuCount);
        if (rc != 0) { outp.Add("ERROR: NvAPI_EnumPhysicalGPUs returned " + rc); return outp; }
        outp.Add("gpus=" + gpuCount);
        if (gpuCount == 0) return outp;

        int versionDisplayIds = Marshal.SizeOf(typeof(NV_GPU_DISPLAYIDS)) | (3 << 16);
        int versionEdid       = Marshal.SizeOf(typeof(NV_EDID))           | (3 << 16);
        outp.Add(string.Format("struct versions: NV_GPU_DISPLAYIDS=0x{0:X8} ({1} bytes)  NV_EDID=0x{2:X8} ({3} bytes)",
            versionDisplayIds, Marshal.SizeOf(typeof(NV_GPU_DISPLAYIDS)),
            versionEdid,       Marshal.SizeOf(typeof(NV_EDID))));

        for (int g = 0; g < gpuCount; g++) {
            IntPtr gpu = gpus[g];

            // Two-call pattern: null array first to learn the count.
            int count = 0;
            rc = _getDisplayIds(gpu, null, ref count, 0);
            if (rc != 0) { outp.Add(string.Format("gpu[{0}]: GetConnectedDisplayIds(count) returned {1}", g, rc)); continue; }
            outp.Add(string.Format("gpu[{0}]: connected displays = {1}", g, count));
            if (count == 0) continue;

            NV_GPU_DISPLAYIDS[] ids = new NV_GPU_DISPLAYIDS[count];
            for (int i = 0; i < count; i++) ids[i].version = versionDisplayIds;

            rc = _getDisplayIds(gpu, ids, ref count, 0);
            if (rc != 0) { outp.Add(string.Format("gpu[{0}]: GetConnectedDisplayIds(fill) returned {1}", g, rc)); continue; }

            for (int d = 0; d < count; d++) {
                bool isConnected = (ids[d].flags & 0x40) != 0;   // bit 6; bit 2 is isActive
                bool isActive    = (ids[d].flags & 0x04) != 0;

                uint outputId = 0;
                IntPtr owner;
                int rc2 = _getOutputId((uint)ids[d].displayId, out owner, out outputId);

                // GetEDID and I2CWrite take the LEGACY single-bit output id, not the
                // displayId. Fall back to the displayId if the conversion failed.
                string edidVia = "outputId";
                int edidTarget = (int)outputId;
                string mfg = "-", mfgRaw = "-", prod = "-", serial = "-";
                int edidRc = -1;

                if (rc2 != 0 || outputId == 0) { edidVia = "displayId(fallback)"; edidTarget = ids[d].displayId; }

                NV_EDID edid = new NV_EDID();
                edid.version  = versionEdid;
                edid.edidData = new byte[256];
                edidRc = _getEdid(gpu, edidTarget, ref edid);

                if (edidRc != 0 && edidVia == "outputId") {
                    edidVia = "displayId(retry)";
                    edidTarget = ids[d].displayId;
                    edid = new NV_EDID();
                    edid.version  = versionEdid;
                    edid.edidData = new byte[256];
                    edidRc = _getEdid(gpu, edidTarget, ref edid);
                }

                if (edidRc == 0 && edid.edidSize >= 18 && edid.edidData[0] == 0x00 && edid.edidData[1] == 0xFF) {
                    ushort m = (ushort)((edid.edidData[8] << 8) | edid.edidData[9]);
                    ushort p = (ushort)(edid.edidData[10] | (edid.edidData[11] << 8));
                    uint   s = (uint)(edid.edidData[12] | (edid.edidData[13] << 8)
                                    | (edid.edidData[14] << 16) | (edid.edidData[15] << 24));
                    mfg    = DecodeMfg(m);
                    mfgRaw = string.Format("0x{0:X4}", m);
                    prod   = string.Format("0x{0:X4}", p);
                    serial = string.Format("0x{0:X8}", s);
                }

                outp.Add(string.Format(
                    "  display[{0}] displayId=0x{1:X8} outputId=0x{2:X8} connector={3} connected={4} active={5} edid={6}({7}) product={8} serial={9} via={10} edidRc={11}",
                    d, ids[d].displayId, outputId, ConnectorName(ids[d].connectorType),
                    isConnected, isActive, mfg, mfgRaw, prod, serial, edidVia, edidRc));
            }
        }

        return outp;
    }
}
'@

# --- context ----------------------------------------------------------------
# Record WHICH context this run happened in, so the 1a / 1b / 1c logs are tellable
# apart after the fact. This is the whole value of the session-0 and S4U runs.

$proc = Get-Process -Id $PID
$sessionId = $proc.SessionId
$who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Probe '================================================================'
Write-Probe ("context: user={0} sessionId={1} interactive={2} is64bit={3} host={4}" -f `
             $who, $sessionId, [Environment]::UserInteractive, [Environment]::Is64BitProcess, $PSVersionTable.PSVersion)

# The control. If this is 0 while NVAPI still enumerates displays, pre-login
# switching through NVAPI is possible and the desktop relay is not needed.
$desktopCount = [NvProbe]::CountDesktopMonitors()
Write-Probe ("control: user32 EnumDisplayMonitors sees {0} monitor(s)" -f $desktopCount)

# --- NVAPI ------------------------------------------------------------------

$status = [NvProbe]::Init()
Write-Probe ("nvapi init: {0}" -f $status)

if ($status -ne 'OK') {
    Write-Probe 'stopping: NVAPI unavailable in this context'
    Write-Probe '================================================================'
    exit 1
}

foreach ($line in [NvProbe]::Enumerate()) { Write-Probe $line }

Write-Probe '================================================================'
exit 0
