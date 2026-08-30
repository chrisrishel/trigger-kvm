<#
.SYNOPSIS
Switch both monitors' inputs from this Windows PC.

.DESCRIPTION
    switch-displays.ps1 windows      pull both monitors here   (the normal case)
    switch-displays.ps1 mac          push both to the Mac
    switch-displays.ps1 windows -Only asus     move one monitor only
    switch-displays.ps1 windows -WhatIf        resolve and build the packets, send nothing

Values are documented in ..\displays.toml, which is the source of truth. They are
duplicated here as literals rather than parsed, because this script runs from a
Scheduled Task on every device arrival and should not depend on a TOML parser.
If you change displays.toml, change these to match.

The two monitors do not speak the same dialect:

  ASUS PG42UQ    standard DDC/CI, VCP 0x60, via dxva2.dll SetVCPFeature
  LG 45GX950A    standard input control is STUBBED; input lives on LG's
                 manufacturer sidechannel (I2C src 0x50, VCP 0xF4), reachable
                 only by injecting raw I2C through NVAPI.

The LG path injects that I2C directly through NVAPI, AIMED at the single output
whose EDID identifies it as the LG. It is not a spray: no other panel on the GPU
receives the packet. See ..\ideas\nvapi-transport.md for the function ids, the
struct traps and the provenance.

NEVER verify a switch by reading a VCP value back -- see ..\displays.toml for why.
Both monitors switched correctly during macOS testing while reads said they had
not. Writes are fire-and-forget; there are deliberately no reads in this script.

SAFETY: the I2C source address 0x50 is LG's service channel. It appears in exactly
one function, NvDdc.WriteLgInput, which refuses to run unless the target's EDID
manufacturer is GSM (0x1E6D). There is no generic "write to source N" entry point,
so the sidechannel cannot be aimed at another vendor's panel by any caller.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
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

# The LG is identified from the EDID that NVAPI reads off the GPU output, never
# from the Windows display list. In session 0 that list reports a phantom monitor
# rather than nothing, so correlating against it silently mis-resolves -- see
# ..\AGENTS.md. NVAPI is the sole identity source here.
#
# The vendor id is the safety gate; the product id says which panel. Both are
# checked. NOTE: the product id is PER-INPUT on this panel (0x9e9d DP, 0x9e9f
# USB-C, 0x9ea0 through the old KVM). 0x9E9D is what this host sees on its own
# DisplayPort connection and is stable there -- but it is a local key, never a
# value to copy to another host. See ..\displays.toml.
$LG_EDID_VENDOR  = 0x1E6D        # GSM / LG Electronics
$LG_EDID_PRODUCT = 0x9E9D        # this host's DP input on the 45GX950A

$LG_WIN = 0xD0                   # DisplayPort
$LG_MAC = 0xD1                   # USB-C

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

# --- LG: aimed raw I2C through NVAPI ---------------------------------------
#
# Function ids and struct layouts from fiddyschmitt/SimpleKVM (MIT), with
# Initialize / EnumPhysicalGPUs / I2CWrite independently corroborated by
# meer-cha/lg-input-switch. Enumeration and EDID reads were verified against this
# hardware on 2026-08-30 in four contexts, including session 0 with no desktop and
# an at-startup task after a cold boot. The aimed write itself was confirmed
# visually, both directions, from an inactive link. See ..\ideas\nvapi-transport.md.

Add-Type -ErrorAction Stop @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// One connected output, identified purely by the EDID the GPU read from it.
public class NvDisplay {
    public IntPtr Gpu;
    public uint   OutputId;      // legacy single-bit output id -- what I2CWrite takes
    public int    DisplayId;
    public string Connector;
    public ushort EdidVendor;
    public ushort EdidProduct;
    public uint   EdidSerial;

    public override string ToString() {
        return string.Format("outputId=0x{0:X8} connector={1} edid=0x{2:X4}:0x{3:X4} serial=0x{4:X8}",
                             OutputId, Connector, EdidVendor, EdidProduct, EdidSerial);
    }
}

public static class NvDdc {

    // ---- loader ------------------------------------------------------------
    // PowerShell 5.1 is .NET Framework, which has no NativeLibrary; use kernel32.

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true, BestFitMapping = false)]
    static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    const uint NVAPI_INITIALIZE                         = 0x0150E828;
    const uint NVAPI_ENUMPHYSICALGPUS                   = 0xE5AC921F;
    const uint NVAPI_GPU_GETCONNECTEDDISPLAYIDS         = 0x0078DBA2;
    const uint NVAPI_GPU_GETEDID                        = 0x37D32E69;
    const uint NVAPI_SYS_GETGPUANDOUTPUTIDFROMDISPLAYID = 0x112BA1A5;
    const uint NVAPI_I2CWRITE                           = 0xE812EB07;

    const int NVAPI_MAX_PHYSICAL_GPUS = 64;

    // DDC/CI slave address 0x37, shifted left one bit for a write: 0x6E.
    const byte DDC_I2C_ADDRESS = 0x6E;

    // LG's manufacturer sidechannel. Standard DDC/CI is source 0x51 / VCP 0x60;
    // on this panel VCP 0x60 is stubbed and input lives here instead.
    const byte LG_I2C_SOURCE = 0x50;
    const byte LG_VCP_INPUT  = 0xF4;

    // The one vendor whose panels may be sent LG_I2C_SOURCE. 0x50 is a service /
    // factory channel; sweeping it has bricked LG monitors, and what it means on
    // another vendor's panel is unknown. See ..\AGENTS.md hard rule 1.
    const ushort EDID_VENDOR_GSM = 0x1E6D;

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
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int I2CWrite_t(IntPtr gpu, ref NV_I2C_INFO info);

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

    // NV_I2C_INFO_V3. The trailing bIsPortIdSet is the same class of trap as
    // NV_EDID's edidId/offset: omit it and the encoded size is wrong. On x64 this
    // must come out at 64 bytes, i.e. version 0x00030040 -- checked at runtime.
    [StructLayout(LayoutKind.Sequential)]
    public struct NV_I2C_INFO {
        public uint   version;
        public uint   displayMask;      // the legacy single-bit output id
        public byte   bIsDDCPort;
        public byte   i2cDevAddress;
        public IntPtr pbI2cRegAddress;
        public uint   regAddrSize;
        public IntPtr pbData;
        public uint   cbSize;
        public uint   i2cSpeed;         // deprecated, must be 0xFFFF
        public uint   i2cSpeedKhz;
        public byte   portId;
        public uint   bIsPortIdSet;
    }

    static QueryInterface_t _qi;
    static Initialize_t _init;
    static EnumPhysicalGPUs_t _enumGpus;
    static GetConnectedDisplayIds_t _getDisplayIds;
    static GetEDID_t _getEdid;
    static GetGpuAndOutputIdFromDisplayId_t _getOutputId;
    static I2CWrite_t _i2cWrite;
    static bool _ready;

    static T Resolve<T>(uint id) where T : class {
        IntPtr p = _qi(id);
        if (p == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }

    public static string Init() {
        if (_ready) return "OK";

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
        _i2cWrite      = Resolve<I2CWrite_t>(NVAPI_I2CWRITE);

        List<string> missing = new List<string>();
        if (_init          == null) missing.Add("NvAPI_Initialize");
        if (_enumGpus      == null) missing.Add("NvAPI_EnumPhysicalGPUs");
        if (_getDisplayIds == null) missing.Add("NvAPI_GPU_GetConnectedDisplayIds");
        if (_getEdid       == null) missing.Add("NvAPI_GPU_GetEDID");
        if (_getOutputId   == null) missing.Add("NvAPI_SYS_GetGpuAndOutputIdFromDisplayId");
        if (_i2cWrite      == null) missing.Add("NvAPI_I2CWrite");
        if (missing.Count > 0)
            return "FAIL: QueryInterface returned NULL for: " + string.Join(", ", missing);

        int size = Marshal.SizeOf(typeof(NV_I2C_INFO));
        if (size != 64)
            return string.Format("FAIL: NV_I2C_INFO marshals to {0} bytes, expected 64 " +
                                 "(version would encode as 0x{1:X8}, not 0x00030040). " +
                                 "The struct layout is wrong; NvAPI would reject the call.",
                                 size, size | (3 << 16));

        int rc = _init();
        if (rc != 0)
            return "FAIL: NvAPI_Initialize returned " + rc;

        _ready = true;
        return "OK";
    }

    // EDID manufacturer id is three 5-bit letters packed big-endian in bytes 8-9.
    public static string DecodeMfg(ushort id) {
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

    // Every connected output on every NVIDIA GPU, with its EDID decoded.
    //
    // Deliberately NOT correlated against the Windows display list: in session 0
    // user32 reports a phantom monitor rather than nothing, so any such match is
    // against a fiction. NVAPI is the sole identity source. See ..\AGENTS.md.
    public static List<NvDisplay> Enumerate() {
        var found = new List<NvDisplay>();

        IntPtr[] gpus = new IntPtr[NVAPI_MAX_PHYSICAL_GPUS];
        int gpuCount = 0;
        if (_enumGpus(gpus, out gpuCount) != 0 || gpuCount == 0) return found;

        int versionDisplayIds = Marshal.SizeOf(typeof(NV_GPU_DISPLAYIDS)) | (3 << 16);
        int versionEdid       = Marshal.SizeOf(typeof(NV_EDID))           | (3 << 16);

        for (int g = 0; g < gpuCount; g++) {
            IntPtr gpu = gpus[g];

            // Two-call pattern: null array first to learn the count.
            int count = 0;
            if (_getDisplayIds(gpu, null, ref count, 0) != 0 || count == 0) continue;

            var ids = new NV_GPU_DISPLAYIDS[count];
            for (int i = 0; i < count; i++) ids[i].version = versionDisplayIds;
            if (_getDisplayIds(gpu, ids, ref count, 0) != 0) continue;

            for (int d = 0; d < count; d++) {
                // bit 6 (0x40) is isConnected. Do NOT gate on isActive (bit 2):
                // it varied over time within a single session during phase 1.
                if ((ids[d].flags & 0x40) == 0) continue;

                IntPtr owner;
                uint outputId;
                if (_getOutputId((uint)ids[d].displayId, out owner, out outputId) != 0) continue;
                if (outputId == 0) continue;

                // GetEDID and I2CWrite take the LEGACY single-bit output id, not
                // the displayId that GetConnectedDisplayIds returns.
                var edid = new NV_EDID();
                edid.version  = versionEdid;
                edid.edidData = new byte[256];
                if (_getEdid(gpu, (int)outputId, ref edid) != 0) continue;
                if (edid.edidSize < 18) continue;
                if (edid.edidData[0] != 0x00 || edid.edidData[1] != 0xFF) continue;

                var nd = new NvDisplay();
                nd.Gpu         = gpu;
                nd.OutputId    = outputId;
                nd.DisplayId   = ids[d].displayId;
                nd.Connector   = ConnectorName(ids[d].connectorType);
                nd.EdidVendor  = (ushort)((edid.edidData[8] << 8) | edid.edidData[9]);
                nd.EdidProduct = (ushort)(edid.edidData[10] | (edid.edidData[11] << 8));
                nd.EdidSerial  = (uint)(edid.edidData[12] | (edid.edidData[13] << 8)
                                      | (edid.edidData[14] << 16) | (edid.edidData[15] << 24));
                found.Add(nd);
            }
        }
        return found;
    }

    // A DDC/CI SetVCP message: [source, 0x84, 0x03, vcp, valueMsb, valueLsb, checksum]
    // Checksum is 0x6E XOR every preceding byte.
    static byte[] BuildSetVcp(byte source, byte vcp, byte value) {
        byte[] p = new byte[7];
        p[0] = source; p[1] = 0x84; p[2] = 0x03; p[3] = vcp; p[4] = 0x00; p[5] = value;
        byte sum = DDC_I2C_ADDRESS;
        for (int i = 0; i < 6; i++) sum ^= p[i];
        p[6] = sum;
        return p;
    }

    public static string PacketForLgInput(byte value) {
        return BitConverter.ToString(BuildSetVcp(LG_I2C_SOURCE, LG_VCP_INPUT, value)).Replace("-", " ");
    }

    // Send an LG input-select packet to ONE output.
    //
    // This is the only function in the codebase that can emit I2C source 0x50, and
    // it refuses any target whose EDID manufacturer is not GSM. The source byte is
    // not a parameter and there is no generic write entry point, so the LG service
    // channel cannot be aimed at another vendor's panel by any caller. Enforcing it
    // here rather than at the call site is deliberate: constraint 10 then holds by
    // construction instead of by discipline.
    public static int WriteLgInput(NvDisplay target, byte value) {
        if (target == null)
            throw new ArgumentNullException("target");
        if (target.EdidVendor != EDID_VENDOR_GSM)
            throw new InvalidOperationException(string.Format(
                "REFUSING to send LG service-channel source 0x{0:X2} to a {1} (0x{2:X4}) panel at {3}. " +
                "Only GSM (0x{4:X4}) may receive it.",
                LG_I2C_SOURCE, DecodeMfg(target.EdidVendor), target.EdidVendor, target, EDID_VENDOR_GSM));

        byte[] packet = BuildSetVcp(LG_I2C_SOURCE, LG_VCP_INPUT, value);

        // Framing follows lg-input-switch: the whole packet goes in pbData with no
        // separate register address. SimpleKVM instead puts the source byte in
        // pbI2cRegAddress with regAddrSize = 1 and the rest in pbData. Both projects
        // report their own shape working; lg-input-switch is the one demonstrably
        // driving THIS panel today, so it wins the tie. If this ever stops working,
        // the alternative is documented in ..\ideas\nvapi-transport.md -- change it
        // here, do not add a switch.
        IntPtr pData = Marshal.AllocHGlobal(packet.Length);
        try {
            Marshal.Copy(packet, 0, pData, packet.Length);

            var info = new NV_I2C_INFO();
            info.version         = (uint)(Marshal.SizeOf(typeof(NV_I2C_INFO)) | (3 << 16));
            info.displayMask     = target.OutputId;
            info.bIsDDCPort      = 1;
            info.i2cDevAddress   = DDC_I2C_ADDRESS;
            info.pbI2cRegAddress = IntPtr.Zero;
            info.regAddrSize     = 0;
            info.pbData          = pData;
            info.cbSize          = (uint)packet.Length;
            info.i2cSpeed        = 0xFFFF;   // deprecated field, must be this
            info.i2cSpeedKhz     = 0;
            info.portId          = 0;
            info.bIsPortIdSet    = 0;

            return _i2cWrite(target.Gpu, ref info);
        } finally {
            Marshal.FreeHGlobal(pData);
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

    $what = 'ASUS -> {0} (VCP 0x{1:X2} = 0x{2:X2}) on {3}' -f $Label, $ASUS_VCP_INPUT, $Value, $mon.Device
    if (-not $PSCmdlet.ShouldProcess($mon.Device, $what)) {
        Write-Log "WHATIF: would send $what"
        return $true
    }

    $ok = 0
    for ($i = 0; $i -lt $Tries; $i++) {
        $r = [Ddc]::SetVcp($mon.Handle, [byte]$ASUS_VCP_INPUT, [uint32]$Value)
        if ($r -gt 0) { $ok++ }
    }

    if ($ok -eq 0) {
        Write-Log ("ERROR: {0} -- no write succeeded" -f $what)
        return $false
    }
    Write-Log $what
    return $true
}

# --- LG: aimed at the one output whose EDID says it is the LG ---------------

# Replaces the old Test-LgBlastRadius, which existed only to compensate for
# lg-input-switch spraying VCP 0xF4 at every connected output. An aimed write needs
# no blast-radius check: nothing else receives the packet. What remains is a
# stronger and simpler rule -- refuse unless the LG is positively identified.
#
# Note the behaviour change this buys: attaching a third monitor no longer blocks
# LG switching, because the third monitor is no longer in the blast radius.
function Switch-Lg {
    param([int]$Value, [string]$Label)

    $status = [NvDdc]::Init()
    if ($status -ne 'OK') {
        Write-Log "REFUSING LG switch: NVAPI unavailable -- $status"
        return $false
    }

    $all = @([NvDdc]::Enumerate())
    $lg  = @($all | Where-Object {
        $_.EdidVendor -eq $LG_EDID_VENDOR -and $_.EdidProduct -eq $LG_EDID_PRODUCT
    })

    if ($lg.Count -eq 0) {
        $seen = if ($all.Count) { ($all | ForEach-Object { $_.ToString() }) -join '; ' } else { 'nothing' }
        Write-Log ("REFUSING LG switch: no output identifies as the LG (EDID 0x{0:X4}:0x{1:X4}). NVAPI enumerated: {2}" -f `
                   $LG_EDID_VENDOR, $LG_EDID_PRODUCT, $seen)
        return $false
    }

    if ($lg.Count -gt 1) {
        Write-Log ("REFUSING LG switch: {0} outputs identify as the LG, so the target is ambiguous: {1}" -f `
                   $lg.Count, (($lg | ForEach-Object { $_.ToString() }) -join '; '))
        return $false
    }

    $target = $lg[0]
    $packet = [NvDdc]::PacketForLgInput([byte]$Value)
    $what   = 'LG -> {0} (src 0x50, VCP 0xF4 = 0x{1:X2}) on outputId 0x{2:X8} [{3}]' -f `
              $Label, $Value, $target.OutputId, $packet

    if (-not $PSCmdlet.ShouldProcess($target.ToString(), $what)) {
        Write-Log "WHATIF: would send $what"
        return $true
    }

    $ok = 0
    for ($i = 0; $i -lt $Tries; $i++) {
        try {
            if ([NvDdc]::WriteLgInput($target, [byte]$Value) -eq 0) { $ok++ }
        } catch {
            # The vendor gate throwing is a bug in the caller, not a transient
            # failure. Surface it rather than retrying into it.
            Write-Log ("ERROR: LG write refused: {0}" -f $_.Exception.Message)
            return $false
        }
    }

    if ($ok -eq 0) {
        Write-Log ("ERROR: {0} -- NvAPI_I2CWrite reported failure on every attempt" -f $what)
        return $false
    }
    Write-Log $what
    return $true
}

# --- main -------------------------------------------------------------------

if ($Target -eq 'windows') {
    $asusValue = $ASUS_WIN; $lgValue = $LG_WIN; $label = 'this PC'
} else {
    $asusValue = $ASUS_MAC; $lgValue = $LG_MAC; $label = 'the Mac'
}

$rc = 0
if ($Only -in @('both', 'asus')) { if (-not (Switch-Asus -Value $asusValue -Label $label)) { $rc = 1 } }
if ($Only -in @('both', 'lg'))   { if (-not (Switch-Lg   -Value $lgValue   -Label $label)) { $rc = 1 } }

# A zero exit means the writes were sent, NOT that the monitors switched. There is
# no way to verify that from here: reads on this hardware lie. Confirm visually.
exit $rc
