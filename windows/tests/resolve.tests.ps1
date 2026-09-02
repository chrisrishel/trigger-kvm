# What the switcher decides to send, for a given config.
#
# Runs the REAL trigger-kvm.ps1 with -WhatIf: it resolves every display, builds the
# packets and prints them without touching the I2C bus. That is the closest this can
# get to the wire without a monitor, and it covers the part where a mistake is
# expensive -- a wrong byte is aimed at real hardware.
#
# Needs an NVIDIA GPU with displays attached, because identity comes from NVAPI. It
# says so and skips rather than failing when there is not one.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$sw  = Join-Path (Split-Path -Parent $PSScriptRoot) 'trigger-kvm.ps1'
$cfg = Join-Path $env:TEMP 'trigger-kvm-resolve.cfg'

# A synthetic desk. The EDID ids are this project's two known panels, because those
# are the ones whose packets are documented in displays.toml and can be asserted
# byte for byte.
@(
 'computer.this = pc'
 'display.lg.vendor  = 0x1E6D'
 'display.lg.product = 0x9E9D'
 'display.lg.name    = LG'
 'display.lg.method  = lg-alt'
 'display.lg.input.0xd0 = pc'
 'display.lg.input.0xd1 = mac'
 'display.asus.vendor  = 0x06B3'
 'display.asus.product = 0x42E0'
 'display.asus.name    = ASUS'
 'display.asus.method  = standard'
 'display.asus.input.0x11 = pc'
 'display.asus.input.0x0f = mac'
 'trigger.device = usb:046d:0843'
) | Set-Content -LiteralPath $cfg -Encoding ASCII

function Invoke-Switcher {
    param([string[]]$Arguments)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sw @Arguments 2>&1
    return [PSCustomObject]@{ Text = ($out | ForEach-Object { "$_" }) -join "`n"; Code = $LASTEXITCODE }
}

$probe = Invoke-Switcher @('list', '-Config', $cfg)
if ($probe.Text -match 'NVAPI unavailable|no connected displays') {
    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
    Exit-Skipped 'no NVIDIA display to resolve against -- the byte-exact packets and every refusal below went unchecked'
}
$attached = ($probe.Text -match '1E6D' -and $probe.Text -match '06B3')
if (-not $attached) {
    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
    Exit-Skipped 'this desk does not have both reference panels attached -- the byte-exact packets and every refusal below went unchecked'
}

# ---- pull is `to computer.this` ----------------------------------------------

$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match $r.Text '51 84 03 60 00 11 C9' 'the ASUS packet, exactly as documented'
Assert-Match $r.Text '50 84 03 F4 00 D0 9D' 'the LG packet, on the manufacturer channel'

# ---- to <machine> is the same lookup, different name -------------------------

$r = Invoke-Switcher @('to', 'mac', '-WhatIf', '-Config', $cfg)
Assert-Match $r.Text '51 84 03 60 00 0F D7'
Assert-Match $r.Text '50 84 03 F4 00 D1 9C'

# ---- it fails closed ---------------------------------------------------------

$r = Invoke-Switcher @('to', 'nosuch', '-WhatIf', '-Config', $cfg)
Assert-Match $r.Text 'REFUSING' 'an unknown machine must refuse'
Assert-Match $r.Text 'it knows: mac, pc' 'and say what it does know'
Assert-Match $r.Text 'Nothing was sent'

# A machine two panels know about and a third does not moves NONE of them: a
# half-applied arrangement leaves the desk in a state nobody configured.
@('display.asus.input.0x0f = mac') | ForEach-Object {
    (Get-Content $cfg) -replace [regex]::Escape($_), '' | Set-Content -LiteralPath $cfg -Encoding ASCII
}
$r = Invoke-Switcher @('to', 'mac', '-WhatIf', '-Config', $cfg)
Assert-Match $r.Text 'REFUSING' 'a partial arrangement must move nothing'
Assert-NoMatch $r.Text 'WHATIF: would send' 'and must not resolve the half it could'

# ---- two inputs naming one machine is a refusal, not a coin toss -------------

@(
 'computer.this = pc'
 'display.lg.vendor  = 0x1E6D'
 'display.lg.product = 0x9E9D'
 'display.lg.method  = lg-alt'
 'display.lg.input.0xd0 = pc'
 'display.lg.input.0xd1 = mac'
 'display.lg.input.0x90 = mac'
) | Set-Content -LiteralPath $cfg -Encoding ASCII
$r = Invoke-Switcher @('to', 'mac', '-WhatIf', '-Config', $cfg)
Assert-Match $r.Text 'more than one input' 'ambiguity must be reported, not guessed at'

# ---- a value it could not resolve is never sent -------------------------------

# The rule this exists for, and the one the pre-machines code broke in the field: a
# config missing the value for THIS computer wrote 0x00 to both panels on every
# switch -- an input no monitor has, so nothing moved and nothing said why. Its null
# check was there and did not fire. Assert the property, not the check.

@(
 'computer.this = pc'
 'display.lg.vendor  = 0x1E6D'
 'display.lg.product = 0x9E9D'
 'display.lg.method  = lg-alt'
) | Set-Content -LiteralPath $cfg -Encoding ASCII        # a panel with no inputs at all
$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match   $r.Text 'REFUSING'
Assert-NoMatch $r.Text 'WHATIF: would send' 'a panel with no inputs must send nothing'
Assert-NoMatch $r.Text '= 0x00'             'and above all not zero'

@(
 'computer.this = pc'
 'display.lg.vendor  = 0x1E6D'
 'display.lg.product = 0x9E9D'
 'display.lg.method  = lg-alt'
 'display.lg.input.zzz = pc'                             # not a byte
) | Set-Content -LiteralPath $cfg -Encoding ASCII
$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match   $r.Text 'REFUSING'
Assert-NoMatch $r.Text '= 0x00' 'an unparseable value is not a zero'

@(
 'computer.this ='                                       # named nothing
 'display.lg.vendor  = 0x1E6D'
 'display.lg.product = 0x9E9D'
 'display.lg.method  = lg-alt'
 'display.lg.input.0xd0 = pc'
) | Set-Content -LiteralPath $cfg -Encoding ASCII
$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match   $r.Text 'REFUSING'
Assert-NoMatch $r.Text 'WHATIF: would send' 'and neither is a missing computer.this'

# ---- transport is a second axis, with one impossible cell --------------------
#
# specs/config-format.md, "transport and method are different questions".
# method says WHAT is sent, transport says HOW it gets there. dxva2 cannot
# express an I2C source byte at all, so it cannot carry lg-alt -- and that
# combination must be REFUSED rather than quietly downgraded to the standard
# command, or someone would confirm a panel moved and be wrong about what moved
# it (docs/decisions/003).

function Set-OneDisplay {
    param([string[]]$Lines)
    @('computer.this = pc') + $Lines | Set-Content -LiteralPath $cfg -Encoding ASCII
}

$asus = @(
 'display.asus.vendor  = 0x06B3'
 'display.asus.product = 0x42E0'
 'display.asus.name    = ASUS'
 'display.asus.input.0x11 = pc'
 'display.asus.input.0x0f = mac'
)

# dxva2 resolves the panel by the SAME EDID key nvapi uses, and says what it will
# call. No packet bytes: dxva2 builds the DDC frame itself, so printing one would
# be a fiction dressed as the NVAPI lines.
Set-OneDisplay ($asus + @('display.asus.method = standard', 'display.asus.transport = dxva2'))
$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match $r.Text 'dxva2 SetVCPFeature, VCP 0x60 = 0x11' 'dxva2 resolves and reports the call it would make'
Assert-NoMatch $r.Text 'src 0x51' 'and does not claim an I2C source it cannot send'

# The impossible cell.
Set-OneDisplay ($asus + @('display.asus.method = lg-alt', 'display.asus.transport = dxva2'))
$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match   $r.Text 'REFUSING'
Assert-Match   $r.Text 'cannot send one' 'the refusal says WHY the pair is impossible'
Assert-NoMatch $r.Text 'WHATIF: would send' 'and nothing is sent instead of it'

# An unrecognised transport is refused BY NAME, never defaulted to the usual one:
# defaulting would send the write down a path nobody confirmed by eye.
Set-OneDisplay ($asus + @('display.asus.method = standard', 'display.asus.transport = vulkan'))
$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match   $r.Text "unknown transport 'vulkan'" 'an unknown transport is named, not defaulted'
Assert-NoMatch $r.Text 'WHATIF: would send' 'and nothing is sent under it'

# Absent means nvapi, so a config written before the key existed is unchanged --
# same panel, same packet as the byte-exact assertion at the top of this file.
Set-OneDisplay ($asus + @('display.asus.method = standard'))
$r = Invoke-Switcher @('pull', '-WhatIf', '-Config', $cfg)
Assert-Match $r.Text '51 84 03 60 00 11 C9' 'no transport key still means nvapi, byte for byte'

Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
exit 0
