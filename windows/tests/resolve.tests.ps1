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
    Write-Host 'SKIPPED: no NVIDIA display to resolve against'
    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
    exit 0
}
$attached = ($probe.Text -match '1E6D' -and $probe.Text -match '06B3')
if (-not $attached) {
    Write-Host 'SKIPPED: this desk does not have both reference panels attached'
    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
    exit 0
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

Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
exit 0
