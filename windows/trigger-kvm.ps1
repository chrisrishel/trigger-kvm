<#
.SYNOPSIS
Switch both monitors' inputs from this Windows PC.

.DESCRIPTION
    trigger-kvm.ps1 windows      pull both monitors here   (the normal case)
    trigger-kvm.ps1 mac          push both to the Mac
    trigger-kvm.ps1 windows -Only asus     move one monitor only
    trigger-kvm.ps1 windows -WhatIf        resolve and build the packets, send nothing

Values are documented in ..\displays.toml, which is the source of truth. They are
duplicated here as literals rather than parsed, because this script runs from a
Scheduled Task on every device arrival and should not depend on a TOML parser.
If you change displays.toml, change these to match.

The two monitors do not speak the same dialect, but they now share one transport:

  ASUS PG42UQ    standard DDC/CI  -- I2C source 0x51, VCP 0x60
  LG 45GX950A    standard input control is STUBBED; input lives on LG's
                 manufacturer sidechannel -- I2C source 0x50, VCP 0xF4

Both are sent as raw I2C through NVAPI, each AIMED at the single GPU output whose
EDID identifies that panel. Neither is a spray: no other monitor sees either
packet. See ..\ideas\nvapi-transport.md for the function ids, struct traps and
provenance.

Identity comes from NVAPI alone -- enumerate the GPU's connected outputs, read each
EDID, match on manufacturer and product. The Windows display list is deliberately
never consulted: in session 0 it reports a phantom monitor rather than none, so
matching against it silently resolves to a fiction. That is also why there is no
dxva2 or user32 code left here, and why this script has no desktop dependency.

NEVER verify a switch by reading a VCP value back -- see ..\displays.toml for why.
Both monitors switched correctly during macOS testing while reads said they had
not. Writes are fire-and-forget; there are deliberately no reads in this script.

SAFETY: the I2C source address 0x50 is LG's service channel. It appears in exactly
one function, NvDdc.WriteLgInput, which refuses to run unless the target's EDID
manufacturer is GSM (0x1E6D). The source byte is not a parameter of any public
method, so the sidechannel cannot be aimed at another vendor's panel by any caller.
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

# Each panel is identified by the EDID vendor and product that NVAPI reads off the
# GPU output. Deliberately not an index and not a PnP path: \\.\DISPLAYn indices
# swapped on this machine on 2026-08-30, and an index silently becoming the other
# monitor would send LG service-channel writes to the ASUS.
$ASUS_EDID_VENDOR  = 0x06B3      # AUS / ASUSTek
$ASUS_EDID_PRODUCT = 0x42E0      # PG42UQ -- reads the same on every host and input

$ASUS_VCP_INPUT = 0x60
$ASUS_WIN       = 0x11           # 17 -- HDMI 1
$ASUS_MAC       = 0x0F           # 15 -- DisplayPort

# For the LG the vendor id is also the safety gate on the 0x50 sidechannel.
#
# NOTE: the LG's product id is PER-INPUT (0x9e9d DP, 0x9e9f USB-C, 0x9ea0 through
# the old KVM). 0x9E9D is what this host sees on its own DisplayPort connection and
# is stable there -- but it is a local key, never a value to copy to another host.
# The ASUS shows no such behaviour, which makes the trap easy to walk into. See
# ..\displays.toml.
$LG_EDID_VENDOR  = 0x1E6D        # GSM / LG Electronics
$LG_EDID_PRODUCT = 0x9E9D        # this host's DP input on the 45GX950A

$LG_WIN = 0xD0                   # DisplayPort
$LG_MAC = 0xD1                   # USB-C

# --- logging ---------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    $line = '{0} trigger-kvm: {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    if ($LogFile) {
        # The watcher appends to the same file, so a write can briefly collide.
        for ($i = 0; $i -lt 3; $i++) {
            try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 50 }
        }
    }
}

# --- LG: aimed raw I2C through NVAPI ---------------------------------------
#
# Function ids and struct layouts from fiddyschmitt/SimpleKVM (MIT), with
# Initialize / EnumPhysicalGPUs / I2CWrite independently corroborated by
# meer-cha/lg-input-switch. Enumeration and EDID reads were verified against this
# hardware on 2026-08-30 in four contexts, including session 0 with no desktop and
# an at-startup task after a cold boot. The aimed write itself was confirmed
# visually, both directions, from an inactive link. See ..\ideas\nvapi-transport.md.

$NvDdcSource = @'
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

    // The normal DDC/CI host source address. Everything except the LG's input uses
    // this; it is what dxva2's SetVCPFeature puts on the wire too.
    const byte STD_I2C_SOURCE = 0x51;

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

    // Used by -WhatIf to show the exact bytes without sending them.
    public static string PacketForLgInput(byte value) {
        return BitConverter.ToString(BuildSetVcp(LG_I2C_SOURCE, LG_VCP_INPUT, value)).Replace("-", " ");
    }

    public static string PacketForStandardVcp(byte vcp, byte value) {
        return BitConverter.ToString(BuildSetVcp(STD_I2C_SOURCE, vcp, value)).Replace("-", " ");
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

        return Send(target, BuildSetVcp(LG_I2C_SOURCE, LG_VCP_INPUT, value));
    }

    // Send a standard DDC/CI SetVCP to ONE output, on the normal host source 0x51.
    //
    // No vendor gate, and none is needed: 0x51 is the ordinary DDC/CI channel that
    // every monitor and every OS-level tool already uses. It is 0x50 that is a
    // service channel, and WriteLgInput above is the only way to reach it.
    public static int WriteStandardVcp(NvDisplay target, byte vcp, byte value) {
        if (target == null) throw new ArgumentNullException("target");
        return Send(target, BuildSetVcp(STD_I2C_SOURCE, vcp, value));
    }

    // Framing follows lg-input-switch: the whole packet goes in pbData with no
    // separate register address. SimpleKVM instead puts the source byte in
    // pbI2cRegAddress with regAddrSize = 1 and the rest in pbData. Both projects
    // report their own shape working; lg-input-switch is the one demonstrably
    // driving THIS panel, so it won the tie -- and the LG switch confirmed it on
    // hardware. If it ever stops working, the alternative is documented in
    // ..\ideas\nvapi-transport.md -- change it here, do not add a switch.
    static int Send(NvDisplay target, byte[] packet) {
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

# Load the transport, once per PowerShell process.
#
# .NET cannot replace a type once it is loaded into an AppDomain. That matters here
# because of how this script gets verified: you edit it and re-run it in the same
# shell. A bare Add-Type throws "type name 'NvDisplay' already exists" on the second
# run, and the tempting fix -- skip Add-Type when the type is already present -- is
# WORSE than the error. It would silently run the previously loaded transport, so a
# hand-verified switch would be confirming code that is not the code on disk. Given
# that hand-verification is the only verification this hardware permits (hard rule
# 3), a false pass is the most expensive failure available here.
#
# So: stamp the loaded types with a hash of the source they came from, and refuse
# loudly if this session already holds a different version. Re-running the SAME
# version in one session is fine and reuses what is loaded. The installed path never
# reaches any of this -- the task starts a fresh powershell.exe per switch.
$stampKey = 'trigger-kvm:NvDdcSourceStamp'
$stamp    = $NvDdcSource.GetHashCode()

if ('NvDdc' -as [type]) {
    if ([AppDomain]::CurrentDomain.GetData($stampKey) -ne $stamp) {
        throw ("This PowerShell session already loaded trigger-kvm's types from a " +
               "DIFFERENT version of this script, and .NET cannot replace a loaded type. " +
               "Open a new PowerShell window and re-run: continuing here would test the " +
               "old code while appearing to test the new.")
    }
} else {
    Add-Type -ErrorAction Stop -TypeDefinition $NvDdcSource
    [AppDomain]::CurrentDomain.SetData($stampKey, $stamp)
}

# --- resolving a panel ------------------------------------------------------

# Find the one connected output whose EDID matches, or $null with the reason logged.
#
# Fails closed on both sides of "exactly one". Zero is a refusal for the obvious
# reason. More than one is also a refusal: an ambiguous target cannot be aimed at,
# and picking the first would reintroduce exactly the order-dependence that this
# repo's conventions forbid.
#
# This replaces the old Test-LgBlastRadius, which existed only to compensate for
# lg-input-switch spraying VCP 0xF4 at every connected output. An aimed write has no
# blast radius, so the check is no longer "is anything unrecognised attached" -- it
# is the narrower and stronger "is the intended panel positively identified". A
# third monitor being attached is now simply irrelevant.
function Resolve-Panel {
    param([int]$Vendor, [int]$Product, [string]$Name)

    $status = [NvDdc]::Init()
    if ($status -ne 'OK') {
        Write-Log "REFUSING $Name switch: NVAPI unavailable -- $status"
        return $null
    }

    $all   = @([NvDdc]::Enumerate())
    $match = @($all | Where-Object {
        $_.EdidVendor -eq $Vendor -and $_.EdidProduct -eq $Product
    })

    if ($match.Count -eq 1) { return $match[0] }

    if ($match.Count -eq 0) {
        $seen = if ($all.Count) { ($all | ForEach-Object { $_.ToString() }) -join '; ' } else { 'nothing' }
        Write-Log ("REFUSING {0} switch: no output identifies as it (EDID 0x{1:X4}:0x{2:X4}). NVAPI enumerated: {3}" -f `
                   $Name, $Vendor, $Product, $seen)
    } else {
        Write-Log ("REFUSING {0} switch: {1} outputs identify as it, so the target is ambiguous: {2}" -f `
                   $Name, $match.Count, (($match | ForEach-Object { $_.ToString() }) -join '; '))
    }
    return $null
}

# Send one panel's input-select packet, twice. DDC is lossy and the writes are
# idempotent, so a repeat is free and covers a dropped byte.
function Invoke-Switch {
    param(
        [NvDisplay]$Target,
        [string]$What,
        [scriptblock]$Write
    )

    if (-not $PSCmdlet.ShouldProcess($Target.ToString(), $What)) {
        Write-Log "WHATIF: would send $What"
        return $true
    }

    $ok = 0
    for ($i = 0; $i -lt $Tries; $i++) {
        try {
            if ((& $Write) -eq 0) { $ok++ }
        } catch {
            # The vendor gate throwing is a bug in the caller, not a transient
            # failure. Surface it rather than retrying into it.
            Write-Log ("ERROR: write refused: {0}" -f $_.Exception.Message)
            return $false
        }
    }

    if ($ok -eq 0) {
        Write-Log ("ERROR: {0} -- NvAPI_I2CWrite reported failure on every attempt" -f $What)
        return $false
    }
    Write-Log $What
    return $true
}

function Switch-Asus {
    param([int]$Value, [string]$Label)

    $target = Resolve-Panel -Vendor $ASUS_EDID_VENDOR -Product $ASUS_EDID_PRODUCT -Name 'ASUS'
    if (-not $target) { return $false }

    $what = 'ASUS -> {0} (src 0x51, VCP 0x{1:X2} = 0x{2:X2}) on outputId 0x{3:X8} [{4}]' -f `
            $Label, $ASUS_VCP_INPUT, $Value, $target.OutputId,
            [NvDdc]::PacketForStandardVcp([byte]$ASUS_VCP_INPUT, [byte]$Value)

    return Invoke-Switch -Target $target -What $what -Write {
        [NvDdc]::WriteStandardVcp($target, [byte]$ASUS_VCP_INPUT, [byte]$Value)
    }
}

function Switch-Lg {
    param([int]$Value, [string]$Label)

    $target = Resolve-Panel -Vendor $LG_EDID_VENDOR -Product $LG_EDID_PRODUCT -Name 'LG'
    if (-not $target) { return $false }

    $what = 'LG -> {0} (src 0x50, VCP 0xF4 = 0x{1:X2}) on outputId 0x{2:X8} [{3}]' -f `
            $Label, $Value, $target.OutputId, [NvDdc]::PacketForLgInput([byte]$Value)

    return Invoke-Switch -Target $target -What $what -Write {
        [NvDdc]::WriteLgInput($target, [byte]$Value)
    }
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
