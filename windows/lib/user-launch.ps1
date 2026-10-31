# S4U's Limited setting does not restrict an administrator's batch token.
# The host launcher creates a SAFER normal-user token, lowers its integrity,
# validates its effective rights, and only then starts the detector.
$UserLaunchSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

public sealed class TkUserTokenFacts {
    public bool Administrator;
    public bool PowerUser;
    public int Integrity;
    public int Session;
    public string UserSid;
    public string[] Privileges;
}

public static class TkUserLaunch {
    public const string Fingerprint = "__SOURCE_HASH__";
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, xSize, ySize, xChars, yChars, fill, flags;
        public short show, reserved2;
        public IntPtr reservedPtr, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
        public IntPtr process, thread;
        public uint processId, threadId;
    }
    [StructLayout(LayoutKind.Sequential)] struct MandatoryLabel {
        public IntPtr sid;
        public uint attributes;
    }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SaferCreateLevel(uint scope, uint level, uint flags, out IntPtr handle, IntPtr reserved);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SaferComputeTokenFromLevel(IntPtr level, IntPtr input, out IntPtr output, uint flags, IntPtr reserved);
    [DllImport("advapi32.dll")] static extern bool SaferCloseLevel(IntPtr level);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetTokenInformation(IntPtr token, int kind, ref MandatoryLabel label, int size);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr buffer, int size, out int returned);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeName(string system, IntPtr luid, StringBuilder name, ref int size);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessAsUser(IntPtr token, string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo info);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);

    static IntPtr ReadInfo(IntPtr token, int kind) {
        int size;
        GetTokenInformation(token, kind, IntPtr.Zero, 0, out size);
        if (size <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr buffer = Marshal.AllocHGlobal(size);
        if (!GetTokenInformation(token, kind, buffer, size, out size)) {
            int error = Marshal.GetLastWin32Error();
            Marshal.FreeHGlobal(buffer);
            throw new Win32Exception(error);
        }
        return buffer;
    }

    static TkUserTokenFacts Describe(IntPtr token) {
        var facts = new TkUserTokenFacts();
        using (var identity = new WindowsIdentity(token)) {
            var principal = new WindowsPrincipal(identity);
            facts.Administrator = principal.IsInRole(WindowsBuiltInRole.Administrator);
            facts.PowerUser = principal.IsInRole(WindowsBuiltInRole.PowerUser);
            facts.UserSid = identity.User.Value;
        }
        IntPtr info = ReadInfo(token, 25); // TokenIntegrityLevel
        try {
            IntPtr sid = Marshal.ReadIntPtr(info);
            byte count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
            facts.Integrity = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
        } finally { Marshal.FreeHGlobal(info); }
        info = ReadInfo(token, 12); // TokenSessionId
        try { facts.Session = Marshal.ReadInt32(info); }
        finally { Marshal.FreeHGlobal(info); }
        info = ReadInfo(token, 3); // TokenPrivileges, including disabled privileges
        try {
            int count = Marshal.ReadInt32(info);
            facts.Privileges = new string[count];
            for (int i = 0; i < count; i++) {
                int length = 256;
                var name = new StringBuilder(length);
                if (!LookupPrivilegeName(null, IntPtr.Add(info, 4 + i * 12), name, ref length))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                facts.Privileges[i] = name.ToString();
            }
        } finally { Marshal.FreeHGlobal(info); }
        return facts;
    }

    public static TkUserTokenFacts CurrentToken() {
        IntPtr token;
        // WindowsPrincipal duplicates a primary token to check membership.
        if (!OpenProcessToken(GetCurrentProcess(), 10, out token)) // QUERY | DUPLICATE
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return Describe(token); }
        finally { CloseHandle(token); }
    }

    public static void RequireOrdinaryToken(TkUserTokenFacts facts) {
        if (facts == null || facts.Administrator || facts.PowerUser || facts.Integrity != 8192 || facts.Privileges == null)
            throw new InvalidOperationException("The watcher token is not an ordinary medium-integrity token.");
        foreach (string privilege in facts.Privileges) {
            if (privilege != "SeChangeNotifyPrivilege")
                throw new InvalidOperationException("The watcher token retained an unexpected privilege.");
        }
    }

    static IntPtr CreateOrdinaryToken() {
        IntPtr level, token;
        // USER scope, NORMALUSER level, OPEN. Flags 0 preserve AppLocker/SRP.
        if (!SaferCreateLevel(2, 0x20000, 1, out level, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            if (!SaferComputeTokenFromLevel(level, IntPtr.Zero, out token, 0, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { SaferCloseLevel(level); }
        if (token == IntPtr.Zero) throw new InvalidOperationException("No restricted token was returned.");
        try {
            // SAFER removes rights but preserves the original integrity level.
            var sid = new SecurityIdentifier("S-1-16-8192");
            var bytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(bytes, 0);
            IntPtr memory = Marshal.AllocHGlobal(bytes.Length);
            try {
                Marshal.Copy(bytes, 0, memory, bytes.Length);
                var label = new MandatoryLabel();
                label.sid = memory;
                label.attributes = 0x20;
                if (!SetTokenInformation(token, 25, ref label, Marshal.SizeOf(typeof(MandatoryLabel)) + bytes.Length))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(memory); }
            TkUserTokenFacts original = CurrentToken();
            TkUserTokenFacts restricted = Describe(token);
            RequireOrdinaryToken(restricted);
            if (restricted.UserSid != original.UserSid || restricted.Session != original.Session)
                throw new InvalidOperationException("Token restriction changed the watcher owner or session.");
            return token;
        } catch { CloseHandle(token); throw; }
    }

    public static uint Run(string app, string arguments, string directory) {
        IntPtr token = CreateOrdinaryToken();
        try {
            var startup = new StartupInfo();
            startup.cb = Marshal.SizeOf(typeof(StartupInfo));
            ProcessInfo child;
            if (!CreateProcessAsUser(token, app, new StringBuilder("\"" + app + "\" " + arguments),
                IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, directory, ref startup, out child))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                // This replaces the boot task's WSH waiter; there is one detector.
                if (WaitForSingleObject(child.process, UInt32.MaxValue) != 0)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                uint code;
                if (!GetExitCodeProcess(child.process, out code))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return code;
            } finally { CloseHandle(child.thread); CloseHandle(child.process); }
        } finally { CloseHandle(token); }
    }
}
'@

function Initialize-UserLaunch {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($UserLaunchSource))) }
    finally { $hash.Dispose() }
    if ('TkUserLaunch' -as [type]) {
        if ([TkUserLaunch]::Fingerprint -ne $fingerprint) {
            throw 'User-launch bindings are already loaded from different source; use a fresh PowerShell process.'
        }
    } else {
        Add-Type -TypeDefinition ($UserLaunchSource.Replace('__SOURCE_HASH__', $fingerprint))
    }
}

# Compile during registration, not in the recurring S4U process. The direct
# Framework provider uses the runtime compiler; explicit runtime references and
# /noconfig avoid ambient compiler configuration. Default TempFileCollection
# retains Framework's protected high-integrity scratch directory when elevated.
function Get-BootAssemblyPayload {
    $provider = [Microsoft.CSharp.CSharpCodeProvider]::new()
    $temporary = [CodeDom.Compiler.TempFileCollection]::new()
    $output = $null
    try {
        $options = [CodeDom.Compiler.CompilerParameters]::new()
        $options.TempFiles = $temporary
        $output = $temporary.AddExtension('dll', $true)
        $options.OutputAssembly = $output
        $options.GenerateInMemory = $false
        $options.GenerateExecutable = $false
        $options.IncludeDebugInformation = $false
        $options.CompilerOptions = '/optimize+ /noconfig /nostdlib+'
        $runtime = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
        [void]$options.ReferencedAssemblies.Add([IO.Path]::Combine($runtime, 'mscorlib.dll'))
        [void]$options.ReferencedAssemblies.Add([IO.Path]::Combine($runtime, 'System.dll'))
        $result = $provider.CompileAssemblyFromSource($options, $UserLaunchSource)
        if ($result.Errors.HasErrors) { throw ('Cannot build the boot launcher: ' + $result.Errors[0].ErrorText) }
        $bytes = [IO.File]::ReadAllBytes($output)
        $buffer = [IO.MemoryStream]::new()
        try {
            $gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionMode]::Compress, $true)
            try { $gzip.Write($bytes, 0, $bytes.Length) }
            finally { $gzip.Dispose() }
            return [Convert]::ToBase64String($buffer.ToArray())
        } finally { $buffer.Dispose() }
    } finally {
        # Only the exact output registered with this collection; its remaining
        # scratch files and protected directory are disposed by the Framework.
        try { if ($output) { [IO.File]::Delete($output) } }
        finally {
            try { $temporary.Dispose() }
            finally { $provider.Dispose() }
        }
    }
}

# Embed the assembly in the administrator-protected task definition. Boot uses
# only in-memory Framework operations until restriction: no command/module
# resolution, compiler, temporary assembly or installed-code read, even on error.
function Get-BootTaskArguments {
    param([string]$Watcher, [string]$Switcher, [string]$LogFile, [string]$ConfigFile)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Exec "{1}" -Arg pull -LogFile "{2}" -Config "{3}"' -f `
        $Watcher, $Switcher, $LogFile, $ConfigFile
    $payload = Get-BootAssemblyPayload
    $bootstrap = @(
        '$PSModuleAutoLoadingPreference = ''None'''
        '$ErrorActionPreference = ''Stop'''
        'try {'
        ('$data = [IO.MemoryStream]::new([Convert]::FromBase64String(''{0}''))' -f $payload)
        '$gzip = [IO.Compression.GZipStream]::new($data, [IO.Compression.CompressionMode]::Decompress)'
        '$assembly = [IO.MemoryStream]::new()'
        'try { $gzip.CopyTo($assembly); [void][Reflection.Assembly]::Load($assembly.ToArray()) }'
        'finally { $assembly.Dispose(); $gzip.Dispose(); $data.Dispose() }'
        ('exit ([TkUserLaunch]::Run(''{0}'', ''{1}'', ''{2}''))' -f `
            (Join-Path $PSHOME 'powershell.exe').Replace("'", "''"), $arguments.Replace("'", "''"), (Split-Path -Parent $Watcher).Replace("'", "''"))
        '} catch {'
        '[Console]::Error.WriteLine($_.Exception.Message)'
        'exit 1'
        '}'
    ) -join "`n"
    $command = '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    if ($command.Length -gt 30000) { throw 'The boot command exceeds the supported Windows command-line length.' }
    return $command
}
