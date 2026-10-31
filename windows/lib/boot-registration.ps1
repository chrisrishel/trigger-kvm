# Cross-user S4U registration authenticates the intended user once. S4U stores
# no password; execution also needs SeBatchLogonRight (Task Scheduler contract).
$BootRegistrationSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
using System.Text;

public static class TkBootRegistration {
    public const string Fingerprint = "__SOURCE_HASH__";
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct PromptInfo {
        public int size;
        public IntPtr parent;
        public string message, caption;
        public IntPtr banner;
    }
    [StructLayout(LayoutKind.Sequential)] struct Attributes {
        public uint length;
        public IntPtr root, name;
        public uint flags;
        public IntPtr descriptor, quality;
    }
    [StructLayout(LayoutKind.Sequential)] struct UnicodeString {
        public ushort length, maximum;
        public IntPtr buffer;
    }
    [DllImport("credui.dll", CharSet=CharSet.Unicode)] static extern uint CredUIPromptForCredentialsW(ref PromptInfo info, string target, IntPtr reserved, uint error, StringBuilder user, uint userSize, IntPtr password, uint passwordSize, ref bool save, uint flags);
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref Attributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountRights(IntPtr policy, byte[] sid, out IntPtr rights, out uint count);
    [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr policy, byte[] sid, ref UnicodeString right, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr policy, byte[] sid, [MarshalAs(UnmanagedType.U1)] bool all, ref UnicodeString right, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr memory);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);

    public static SecureString Prompt(string account) {
        if (!Environment.UserInteractive) throw new InvalidOperationException("Boot credentials require an interactive Windows session.");
        var info = new PromptInfo();
        info.size = Marshal.SizeOf(typeof(PromptInfo));
        info.caption = "trigger-kvm: start from boot";
        info.message = "Enter the password for the account shown below (not the administrator used for UAC). Windows needs it once to register this account's boot task. The password is not saved. Cancel leaves the existing task and program files unchanged.";
        var user = new StringBuilder(account, 514);
        const int length = 514;
        IntPtr buffer = Marshal.AllocHGlobal(length * 2);
        var secure = new SecureString();
        try {
            for (int i = 0; i < length; i++) Marshal.WriteInt16(buffer, i * 2, 0);
            bool save = false;
            // DO_NOT_PERSIST | ALWAYS_SHOW_UI | GENERIC_CREDENTIALS | KEEP_USERNAME.
            uint result = CredUIPromptForCredentialsW(ref info, "trigger-kvm boot registration", IntPtr.Zero, 0, user, 514, buffer, length, ref save, 0x140082);
            if (result == 1223) throw new OperationCanceledException("Boot credential entry was cancelled; no task was replaced.");
            if (result != 0) throw new Win32Exception((int)result);
            if (!String.Equals(user.ToString(), account, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Boot credentials must belong to the intended account.");
            for (int i = 0; i < length; i++) {
                char value = (char)Marshal.ReadInt16(buffer, i * 2);
                if (value == 0) break;
                secure.AppendChar(value);
            }
            if (secure.Length == 0) throw new InvalidOperationException("Boot registration needs an account password, not a PIN or an empty password. Choose From login if unavailable.");
            secure.MakeReadOnly();
            return secure;
        } catch { secure.Dispose(); throw; }
        finally {
            for (int i = 0; i < length; i++) Marshal.WriteInt16(buffer, i * 2, 0);
            Marshal.FreeHGlobal(buffer);
        }
    }

    // Only this one logon right can be changed, never arbitrary privileges.
    public static bool BatchRight(string account, bool add) {
        var sid = (SecurityIdentifier)new NTAccount(account).Translate(typeof(SecurityIdentifier));
        var bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        var attributes = new Attributes();
        attributes.length = (uint)Marshal.SizeOf(typeof(Attributes));
        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x810, out policy);
        if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
        try {
            bool present = false;
            IntPtr rights;
            uint count;
            status = LsaEnumerateAccountRights(policy, bytes, out rights, out count);
            if (status == 0) {
                try {
                    int size = Marshal.SizeOf(typeof(UnicodeString));
                    for (int i = 0; i < count; i++) {
                        var entry = (UnicodeString)Marshal.PtrToStructure(IntPtr.Add(rights, i * size), typeof(UnicodeString));
                        if (Marshal.PtrToStringUni(entry.buffer, entry.length / 2) == "SeBatchLogonRight") present = true;
                    }
                } finally { LsaFreeMemory(rights); }
            } else if (status != 0xC0000034) { // no direct rights assigned
                throw new Win32Exception((int)LsaNtStatusToWinError(status));
            }
            if (present == add) return false;
            const string name = "SeBatchLogonRight";
            var right = new UnicodeString();
            right.length = (ushort)(name.Length * 2);
            right.maximum = (ushort)(right.length + 2);
            right.buffer = Marshal.StringToHGlobalUni(name);
            try {
                status = add ? LsaAddAccountRights(policy, bytes, ref right, 1) : LsaRemoveAccountRights(policy, bytes, false, ref right, 1);
                if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
                return true;
            } finally { Marshal.FreeHGlobal(right.buffer); }
        } finally { LsaClose(policy); }
    }
}
'@

function Initialize-BootRegistration {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($BootRegistrationSource))) }
    finally { $hash.Dispose() }
    if ('TkBootRegistration' -as [type]) {
        if ([TkBootRegistration]::Fingerprint -ne $fingerprint) { throw 'Boot-registration bindings changed; use a fresh PowerShell process.' }
    } else {
        Add-Type -TypeDefinition ($BootRegistrationSource.Replace('__SOURCE_HASH__', $fingerprint))
    }
}

function Request-BootPassword {
    param([string]$User)
    Initialize-BootRegistration
    return [TkBootRegistration]::Prompt($User)
}

function Set-BootBatchRight {
    param([string]$User, [bool]$Add)
    Initialize-BootRegistration
    return [TkBootRegistration]::BatchRight($User, $Add)
}

# This is the fixed boot definition, not a general CIM-to-COM task converter.
# It mirrors the host's startup/self-heal/battery/restart settings.
function New-BootTaskDefinition {
    param($Service, [string]$User, [string]$Execute, [string]$Arguments)
    $definition = $Service.NewTask(0)
    $definition.RegistrationInfo.Description = 'trigger-kvm: pull the configured monitors to this computer when the shared peripherals arrive.'
    $definition.Principal.UserId = $User
    $definition.Principal.LogonType = 2 # S4U, never stored-password logon
    $definition.Principal.RunLevel = 0
    $definition.Settings.Compatibility = 3 # Windows 7+, same as ScheduledTasks
    $definition.Settings.Enabled = $true
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.MultipleInstances = 2 # IgnoreNew
    $definition.Settings.RestartCount = 3
    $definition.Settings.RestartInterval = 'PT1M'
    $definition.Triggers.Create(8) | Out-Null # startup
    $heal = $definition.Triggers.Create(1) # time
    $heal.StartBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
    $heal.Repetition.Interval = 'PT1M'
    $heal.Repetition.StopAtDurationEnd = $false
    $action = $definition.Actions.Create(0)
    $action.Path = $Execute
    $action.Arguments = $Arguments
    return $definition
}

function Get-BootTaskService {
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    return $service
}

function Register-CrossUserBootTask {
    param([string]$Name, [string]$User, [string]$Execute, [string]$Arguments,
          [Parameter(Mandatory=$true)][Security.SecureString]$Password)
    $service = Get-BootTaskService
    $definition = New-BootTaskDefinition -Service $service -User $User -Execute $Execute -Arguments $Arguments
    $added = $false
    $passwordPointer = [IntPtr]::Zero
    $plain = $null
    try {
        $added = Set-BootBatchRight -User $User -Add $true
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        # Password is used only for this authentication. S4U (2) stores none.
        $registered = $service.GetFolder('\').RegisterTaskDefinition($Name, $definition, 2, $User, $plain, 2)
        if ($registered.Definition.Principal.LogonType -ne 2) {
            $service.GetFolder('\').DeleteTask($Name, 0)
            throw 'Boot task did not retain S4U; the unexpected task was removed.'
        }
    } catch {
        if ($added) { Set-BootBatchRight -User $User -Add $false | Out-Null }
        throw
    } finally {
        $plain = $null
        if ($passwordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
    }
    # Keep the right while the registered task needs it. Uninstall must not
    # revoke a right another task may now use; see README prerequisites.
}
