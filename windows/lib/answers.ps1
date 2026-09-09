# The walkthrough's answers: the researched tables, the per-panel record and the
# one setter that edits it, and how that state is read from a config and written
# back as one file.
#
# The record is the state; walkthrough.ps1 is the flow over it and checks.ps1 is
# what proves it. Nothing outside this file edits a panel record by hand.

# --- the researched tables ----------------------------------------------------

# What a MANUFACTURER's panels answer to when the standard channel does not.
#
# Keyed by EDID VENDOR alone, never by model: a vendor:product key is one row
# per monitor whoever wrote the table happened to own, on a panel whose product
# id is per-input. The transport gates on the vendor too (EDID_VENDOR_GSM).
#
# A dialect is OFFERED, never probed (../AGENTS.md hard rule 1b). Values come
# from documentation and measurement; ../displays.toml is the human-readable
# source of truth and changes to both happen in one commit.
$DIALECTS = @{
    '1E6D' = @{                        # GSM -- LG Electronics
        What   = 'LG'
        Method = 'lg-alt'
        # DDC2AB: I2C source 0x50, VCP 0xF4. Measured on a 45GX950A.
        Inputs = [ordered]@{ 'DisplayPort' = '0xD0'; 'USB-C' = '0xD1'; 'HDMI 1' = '0x90'; 'HDMI 2' = '0x91' }
    }
}

# Standard MCCS input values, in the channel's own order (specs/configure.md 6.1).
$MCCS_INPUTS = [ordered]@{
    'DisplayPort 1' = '0x0F'
    'DisplayPort 2' = '0x10'
    'HDMI 1'        = '0x11'
    'HDMI 2'        = '0x12'
    'DVI 1'         = '0x03'
    'DVI 2'         = '0x04'
    'VGA 1'         = '0x01'
    'USB-C'         = '0x1B'
}

# Superseded spellings of keys the walkthrough writes. NOT unknown keys: each is
# the same fact under an older name, and carrying one across a Save would leave
# two answers to one question in the file. `configure` rewrites without them;
# the install path warns while they are still honoured.
$RENAMED_KEYS = @{
    'trigger.usb.device'      = 'trigger.device'
    'trigger.usb.debounce'    = 'trigger.debounce'
    'trigger.usb.settle'      = 'trigger.settle'
    'trigger.device.usb'      = 'trigger.device'
    'trigger.device.debounce' = 'trigger.debounce'
    'trigger.device.settle'   = 'trigger.settle'
    'install.tier'            = 'install.autostart'
    'install.start'           = 'install.autostart'
}

# --- one record per panel -----------------------------------------------------

# A panel's answers, as one object. Vendor, Product and Key are DERIVED from the
# EDID pair here so no caller formats them twice.
#
# Map is [ordered] and its order is the order the computers were listed, which
# is the order it is written and read back in (specs/config-format.md,
# "Ordering").
function New-PanelAnswer {
    param([string]$Label, [string]$Name, [string]$Method = 'standard', [string]$Transport = '',
          [int]$EdidVendor, [int]$EdidProduct, [string]$Mfg = '',
          [System.Collections.IDictionary]$Map = $null,
          # A CONFIGURED PANEL THAT IS NOT ATTACHED TODAY is still an answer --
          # specs/configure.md 6. It is shown as such, keeps every key on Save,
          # and cannot be checked; not being enumerated is not an answer, and
          # only unmanaging forgets it.
          [bool]$Attached = $true)

    return [PSCustomObject]@{
        Label      = $Label
        Name       = $Name
        Method     = $Method
        Transport  = $Transport
        Attached   = $Attached
        Vendor     = ('0x{0:X4}' -f $EdidVendor)
        Product    = ('0x{0:X4}' -f $EdidProduct)
        EdidVendor = $EdidVendor
        EdidProduct = $EdidProduct
        Mfg        = $Mfg
        Key        = ('{0:X4}:{1:X4}' -f $EdidVendor, $EdidProduct)
        Map        = $(if ($Map) { $Map } else { [ordered]@{} })
    }
}

# THE ONLY WRITER OF A PANEL RECORD. Every path that changes what a panel is
# configured as comes through here -- the Monitors submenu, a rename, a removal,
# a repair after a failed check, an escalation to another channel.
#
# One door, because specs/configure.md 10.8 binds a monitor-input pass to the
# method, transport and map that passed: an edit made anywhere else is an edit
# the pass would survive.
#
# CHANGING THE METHOD CLEARS THE MAP. The old values addressed the other
# channel, so they are not defaults -- they are numbers nobody would recognise
# (specs/configure.md 6.1 and 10.5).
#
# [CmdletBinding()] so a caller left on an old parameter name THROWS. A simple
# function swallows an undeclared named argument into $args without a word, and
# a lost edit here is a config that does not describe the desk.
function Set-PanelAnswer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Panel,
          [string]$Label,
          [string]$Method,
          [string]$Transport,
          # Replace the whole map at once.
          [System.Collections.IDictionary]$Map,
          # One computer's input. Pass -Value '' (or omit it) to clear.
          [string]$On,
          [AllowEmptyString()][string]$Value)

    if ($PSBoundParameters.ContainsKey('Label'))     { $Panel.Label = $Label }
    if ($PSBoundParameters.ContainsKey('Transport')) { $Panel.Transport = $Transport }
    if ($PSBoundParameters.ContainsKey('Method') -and $Method -ne $Panel.Method) {
        $Panel.Method = $Method
        $Panel.Map    = [ordered]@{}
    }
    if ($PSBoundParameters.ContainsKey('Map')) { $Panel.Map = $Map }
    if ($PSBoundParameters.ContainsKey('On')) {
        if ($Value) { $Panel.Map[$On] = $Value }
        elseif ($Panel.Map.Contains($On)) { $Panel.Map.Remove($On) }
    }
    return $Panel
}

# Carry a rename or a removal into every panel's map THE MOMENT IT HAPPENS. An
# empty -Now is a removal.
#
# Applied as it happens, never inferred afterwards: lining an old list of
# computers up against a new one to work out what changed goes wrong the moment
# one sitting holds both a rename and a removal, because the removal shifts
# every position after it and the computer that slides into the victim's slot
# inherits its inputs.
function Edit-PanelMaps {
    param($Panels = @(), [string]$Was, [string]$Now)

    if ($Was -eq $Now) { return }

    foreach ($a in @($Panels | Where-Object { $_ })) {
        if (-not $a.Map.Contains($Was)) { continue }
        # Rebuilt rather than edited in place: the map's ORDER is the order the
        # inputs were answered in, and a rename must not move a row.
        $map = [ordered]@{}
        foreach ($c in @($a.Map.Keys)) {
            if ($c -eq $Was) { if ($Now) { $map[$Now] = $a.Map[$c] } }
            else             { $map[$c]   = $a.Map[$c] }
        }
        Set-PanelAnswer -Panel $a -Map $map | Out-Null
    }
}

# The managed panels a desktop-only transport would strand before login. Names,
# because the person picking a tier knows their monitors by name and has never
# heard of dxva2. specs/configure.md 8, specs/status.md 4.
function Get-LoginOnlyPanels {
    param($Answers)
    return @(@($Answers) |
             Where-Object { $DESKTOP_TRANSPORTS -contains $_.Transport } |
             ForEach-Object { $(if ($_.Name) { $_.Name } else { $_.Label }) })
}

# --- input values -------------------------------------------------------------

# ONE SPELLING PER INPUT VALUE: canonical 0xNN, which is how the config and the
# channels' own tables are written.
#
# specs/configure.md 6.1 wants collision BY VALUE -- `17` and `0x11` are one
# socket -- and the way to get it is to convert at the two boundaries where a
# value enters (a typed prompt, and reading the file), so every later comparison
# is a plain string one.
#
# ConvertTo-Byte is the switcher's own converter, so a value accepted here is
# one the reader will accept back. Returns $null for anything that is not a
# byte -- "refuse", never zero (specs/config-format.md, "Value parsing").
function Format-Byte {
    param([string]$Text)
    $n = ConvertTo-Byte $Text
    if ($null -eq $n) { return $null }
    return ('0x{0:X2}' -f [int]$n)
}

# The inputs to offer for a panel: the channel's own values in the channel's own
# order, plus any assigned value the channel does not list.
#
# The monitor's own menu says "HDMI 1"; that is the only label worth showing and
# it stays where it was. A value someone typed by hand is appended, never
# inserted, and compared BY VALUE so a hand-edited `input.17` is the channel's
# own 0x11 rather than a second row for the same socket.
function Get-InputTable {
    param([string]$Method, $Map)

    $out = [ordered]@{}
    $base = $MCCS_INPUTS
    foreach ($d in $DIALECTS.Values) { if ($d.Method -eq $Method) { $base = $d.Inputs } }
    foreach ($n in $base.Keys) { $out[$n] = $base[$n] }

    if ($Map) {
        foreach ($m in $Map.Keys) {
            if (@($out.Values) -contains $Map[$m]) { continue }
            $out[$Map[$m]] = $Map[$m]
        }
    }
    return $out
}

# What the monitor's own menu calls a value, so recovery instructions can say
# "choose HDMI 1" rather than "choose 0x11". Nobody's OSD shows hex.
#
# The channel's own table only, never the map: "pc" is what THIS tool calls an
# input and the monitor's menu has never heard of it.
function Get-InputName {
    param($Answer, [string]$Value)
    $t = $MCCS_INPUTS
    foreach ($d in $DIALECTS.Values) { if ($d.Method -eq $Answer.Method) { $t = $d.Inputs } }
    foreach ($n in $t.Keys) { if ($t[$n] -ieq $Value) { return $n } }
    return ''
}

# --- reading the config back into records -------------------------------------

# What the config says about which computer is on which input of one panel.
#
# Ordered by the CONFIGURED ORDER OF COMPUTERS, not by input value: sorting on
# the hex puts the same two computers in opposite orders on two panels, purely
# by which socket each was plugged into (specs/config-format.md, "Ordering").
#
# `.input.(.+)` and then the converter, not a hex-only pattern: the reader
# accepts every form the format allows, so a spec-legal hand edit like
# `display.asus.input.17 = pc` has to be visible here or it is gone after the
# next Save while the switcher goes on acting on it.
function Get-DisplayMap {
    param([System.Collections.IDictionary]$Existing, [string]$Label, [string[]]$Computers = @())

    $found = @{}
    if ($Label) {
        foreach ($k in ($Existing.Keys | Sort-Object)) {
            if ($k -match ('^display\.' + [regex]::Escape($Label) + '\.input\.(.+)$')) {
                $v = Format-Byte $Matches[1]
                if (-not $v) { continue }     # not a byte: dropped, exactly as the switcher drops it
                $found["$($Existing[$k])".Trim().ToLower()] = $v
            }
        }
    }

    $out = [ordered]@{}
    foreach ($c in $Computers) { if ($found.Contains($c)) { $out[$c] = $found[$c]; $found.Remove($c) } }
    # Anything the config names that the walkthrough does not know about goes
    # last rather than being dropped -- it is somebody's hand edit.
    foreach ($c in ($found.Keys | Sort-Object)) { $out[$c] = $found[$c] }
    return $out
}

# What the config already says about one panel, matched on its EDID rather than
# on whatever label someone gave it.
#
# Compared BY VALUE, not as hex text: the config may spell an id in decimal, and
# a text comparison then matched nothing, so the panel showed as unmanaged and
# its answers were dropped on the next Save.
function Get-PriorDisplay {
    param([System.Collections.IDictionary]$Existing, [string]$Key, [string[]]$Computers = @())

    foreach ($k in $Existing.Keys) {
        if ($k -notmatch '^display\.([^.]+)\.vendor$') { continue }
        $l = $Matches[1]
        $ven = ConvertTo-Word $Existing["display.$l.vendor"]
        $pro = ConvertTo-Word $Existing["display.$l.product"]
        if ($null -eq $ven -or $null -eq $pro) { continue }
        if (('{0:X4}' -f $ven) -ne $Key.Split(':')[0]) { continue }
        if (('{0:X4}' -f $pro) -ne $Key.Split(':')[1]) { continue }
        return [PSCustomObject]@{
            Label  = $l
            Method = $(if ($Existing.Contains("display.$l.method")) { $Existing["display.$l.method"] } else { '' })
            # EMPTY, not 'nvapi', when the key is absent. The default is applied
            # where the value is USED; here empty means "nobody has answered", so
            # a fresh panel starts the cursor on the recommendation rather than
            # being shown a choice it never made marked (current).
            Transport = $(if ($Existing.Contains("display.$l.transport")) { "$($Existing["display.$l.transport"])".Trim().ToLower() } else { '' })
            Map    = (Get-DisplayMap -Existing $Existing -Label $l -Computers $Computers)
        }
    }
    return $null
}

# Rebuild the panel records straight from the config, asking nothing. What the
# Monitors menu opens with: the attached panels in the order they are attached,
# then every configured panel that is NOT attached today (specs/configure.md 6).
function Get-ConfiguredAnswers {
    param($Found, [System.Collections.IDictionary]$Existing, [string[]]$Computers = @())

    $out  = @()
    $seen = @{}
    foreach ($f in $Found) {
        $key   = '{0:X4}:{1:X4}' -f $f.EdidVendor, $f.EdidProduct
        $prior = Get-PriorDisplay -Existing $Existing -Key $key -Computers $Computers
        if (-not $prior) { continue }
        $seen[$prior.Label] = $true
        $out += New-PanelAnswer -Label $prior.Label `
            -Name $(if ($Existing.Contains("display.$($prior.Label).name")) { $Existing["display.$($prior.Label).name"] } else { $prior.Label }) `
            -Method $(if ($prior.Method) { $prior.Method } else { 'standard' }) `
            -Transport $(if ($prior.Transport) { $prior.Transport } else { 'nvapi' }) `
            -EdidVendor $f.EdidVendor -EdidProduct $f.EdidProduct -Mfg $f.Mfg -Map $prior.Map
    }

    # Every other panel the config names. Dropping these on Save is a silent
    # loss of real work: a monitor unplugged for the afternoon, or on a desk
    # somebody is rebuilding, is not somebody answering "stop managing it".
    foreach ($k in @($Existing.Keys)) {
        if ($k -notmatch '^display\.([^.]+)\.vendor$') { continue }
        $label = $Matches[1]
        if ($seen.Contains($label)) { continue }
        $ven = ConvertTo-Word $Existing["display.$label.vendor"]
        $pro = ConvertTo-Word $Existing["display.$label.product"]
        # An id that does not parse names no panel at all, attached or not.
        if ($null -eq $ven -or $null -eq $pro) { continue }
        $seen[$label] = $true
        $out += New-PanelAnswer -Label $label `
            -Name $(if ($Existing.Contains("display.$label.name")) { $Existing["display.$label.name"] } else { $label }) `
            -Method $(if ($Existing.Contains("display.$label.method")) { $Existing["display.$label.method"] } else { 'standard' }) `
            -Transport $(if ($Existing.Contains("display.$label.transport")) { "$($Existing["display.$label.transport"])".Trim().ToLower() } else { 'nvapi' }) `
            -EdidVendor $ven -EdidProduct $pro `
            -Map (Get-DisplayMap -Existing $Existing -Label $label -Computers $Computers) `
            -Attached $false
    }
    return $out
}

# The managed panels a check may move: attached, because a panel that is not
# there cannot be watched changing (specs/configure.md 10.1).
function Get-AttachedManaged {
    param($Panels)
    return @(@($Panels) | Where-Object { $_.Attached })
}

# WHAT A PASS COVERS -- specs/configure.md 10.8. A monitor-input pass is bound
# to the panels in SCOPE and to each one's method, transport and map, so any
# edit to those retires it and the row goes back to `untested`.
#
# A string, because the only question ever asked of it is "is this still the
# thing that passed?". Sorted by label so scope order cannot make two equal
# scopes look different.
function Get-PassSignature {
    param($Panels)

    $rows = @()
    foreach ($p in (@($Panels) | Sort-Object Label)) {
        $map = @()
        foreach ($m in $p.Map.Keys) { $map += ('{0}={1}' -f $m, $p.Map[$m]) }
        $rows += ('{0}|{1}|{2}|{3}' -f $p.Label, $p.Method, $p.Transport, ($map -join ','))
    }
    return ($rows -join ';')
}

# --- writing it back ----------------------------------------------------------

# Everything in the old file this walkthrough does not write itself, as
# `key = value` lines -- specs/config-format.md, "Hand edits survive".
#
# An unknown key is somebody's hand edit or a newer version's setting, and
# dropping it on Save is a silent loss. A key the walkthrough DOES write is
# dropped on purpose: that is the answer being applied. A display.<label>.* key
# survives only while that panel is still managed, because unmanaging is the one
# answer that means "forget", and it forgets the whole panel.
function Get-CarriedKeys {
    param([System.Collections.IDictionary]$Existing, $Displays)

    $managed = @(@($Displays) | ForEach-Object { $_.Label })
    $out = @()
    foreach ($k in @($Existing.Keys)) {
        if ($k -in @('install.autostart', 'computer.this',
                     'trigger.device', 'trigger.debounce', 'trigger.settle')) { continue }
        if ($RENAMED_KEYS.Contains($k)) { continue }
        if ($k -match '^display\.([^.]+)\.(.+)$') {
            if ($managed -notcontains $Matches[1]) { continue }
            if ($Matches[2] -in @('vendor', 'product', 'name', 'method', 'transport')) { continue }
            if ($Matches[2] -like 'input.*') { continue }
        }
        $out += ('{0} = {1}' -f $k, $Existing[$k])
    }
    return @($out | Sort-Object)
}

# THE TRIGGER ENTRIES AS THEY WILL BE WRITTEN: the identity, plus the remembered
# spot where the entry has a token to hang it on.
#
# The spot comes from the device if it is here, and FROM THE FILE IF IT IS NOT
# (specs/configure.md 7): a `where` is not dropped because the device is away
# today, or a re-run while the switch is on the other computer would quietly
# widen a qualified entry back to its bare id.
#
# One answer, so the config writer and the one-shot the trigger check runs
# cannot disagree about what is configured (specs/configure.md 11).
function Get-TriggerEntries {
    param([string[]]$Devices, $Candidates = @(), [System.Collections.IDictionary]$Existing = @{})

    $saved = @{}
    if ($Existing.Contains('trigger.device')) {
        foreach ($e in (ConvertFrom-TriggerDevices $Existing['trigger.device'])) {
            if ($e.Ok -and $e.Spot) { $saved[$e.Identity] = $e.Spot }
        }
    }

    return @(@($Devices) | ForEach-Object {
        $d = $_
        $e = (ConvertFrom-TriggerDevices $d)[0]
        # A malformed entry is written back EXACTLY as it was: rewriting it into
        # something that parses would edit somebody's file behind them and still
        # not start the watcher.
        if (-not $e.Ok) { return $d }
        # It already carries its spot -- it came from a candidate row that knew
        # which device it was, or from the file unchanged.
        if ($e.Spot) { return $d }
        # Only a tokened entry can gain one: detector.md 4.1 confines `where` to
        # breaking a tie, and there is nothing to break a tie between otherwise.
        if (-not $e.Token) { return $d }
        if ($saved.Contains($e.Identity)) { return ('{0}@{1}' -f $d, $saved[$e.Identity]) }
        return $d
    })
}

# Rewrite the config from the answers -- specs/config-format.md.
#
# $Candidates only supplies the remembered spot for a tokened device, so it is
# optional: a caller that writes no devices still writes a correct file.
function Write-ConfigFile {
    param([string]$Path, $Displays, [string[]]$Devices, [string]$Tier,
          [string]$This, [System.Collections.IDictionary]$Existing, $Candidates = @())

    $lines = @(
        '# trigger-kvm configuration'
        '#'
        '# Written by `trigger-kvm configure`. Safe to edit by hand.'
        '#'
        '# Everything here is read at the point it is used, so there is no separate'
        '# apply step: display edits take effect on the next switch, and trigger edits'
        '# when the watcher next starts --  trigger-kvm restart'
        '#'
        '# Displays are identified by the EDID the GPU reads off the output, never by'
        '# index -- \\.\DISPLAYn numbers are not stable and have swapped on this'
        '# computer. See what is attached with:  trigger-kvm list'
        ''
        '# --- install ----------------------------------------------------------'
        ("install.autostart = {0}" -f $(switch ($Tier) { 's4u' { 'boot' } 'manual' { 'no' } default { 'login' } }))
        ''
        '# --- computers --------------------------------------------------------'
        '# What this computer is called below. `trigger-kvm pull` means "point every'
        '# display at this one"; `trigger-kvm to mac` names any other.'
        ''
        ("computer.this = {0}" -f $This)
        ''
        '# --- displays ---------------------------------------------------------'
        '# method:    WHAT is sent.'
        '#         standard (I2C src 0x51, VCP 0x60) -- what nearly every panel takes'
        '#         lg-alt   (src 0x50, VCP 0xF4) -- LG panels whose 0x60 is stubbed'
        '# transport: HOW it gets there.'
        '#         nvapi -- aimed raw I2C at one GPU output. NVIDIA only, works with'
        '#                  no desktop, and the only one that can carry lg-alt.'
        '#         dxva2 -- Windows'' own DDC/CI stack. Any adapter, but it needs a'
        '#                  desktop, so a panel on it does not follow the switch'
        '#                  until somebody has logged in.'
        '#         Omit it and it means nvapi. Never a fallback: nothing tries one'
        '#         and falls through to the other.'
        '# input.<value> = <computer>: which computer is on which input of that panel.'
        '#         This is the whole map. pull and to are the same lookup against it,'
        '#         differing only in which name they look up, so the two can never'
        '#         disagree about where a computer is.'
        ''
    )
    foreach ($d in $Displays) {
        $lines += @(
            ("display.{0}.vendor    = {1}" -f $d.Label, $d.Vendor)
            ("display.{0}.product   = {1}" -f $d.Label, $d.Product)
            # THE ONE FREE-TEXT VALUE HERE, and it comes from the panel rather
            # than from anybody who could be asked to change it -- so it is the
            # one that has to be made storable (specs/config-format.md, "A
            # writer must not write what it cannot read back"). EDID descriptor
            # strings are LF-terminated by the standard.
            #
            # Every other value is safe by construction: labels and computer
            # names follow the name rule, ids are 0xNNNN, transport and method
            # are enumerated, inputs are hex, timings are decimals. That is why
            # nothing here has to refuse a value it cannot represent.
            ("display.{0}.name      = {1}" -f $d.Label, (ConvertTo-ConfigValue $d.Name))
            ("display.{0}.transport = {1}" -f $d.Label, $(if ($d.Transport) { $d.Transport } else { 'nvapi' }))
            ("display.{0}.method    = {1}" -f $d.Label, $d.Method)
        )
        foreach ($m in $d.Map.Keys) {
            $lines += ("display.{0}.input.{1} = {2}" -f $d.Label, ([string]$d.Map[$m]).ToLower(), $m)
        }
        $lines += ''
    }
    $lines += @(
        '# --- triggers ---------------------------------------------------------'
        '#'
        '# A trigger is anything that runs:  trigger-kvm pull'
        '# The one shipped here watches device presence. A hotkey or a Stream Deck'
        '# button needs no support from this tool -- it just runs that command.'
        '#'
        '# Triggers run `pull` and nothing else. Never wire one to another computer: a'
        '# name like `mac` describes inputs on hardware this computer cannot observe,'
        '# and a stale one would then be able to cause an AUTOMATIC switch to a dead'
        '# input. Getting there by hand, watching, is a different risk entirely.'
        '#'
        '# device: usb:VVVV:PPPP (bare VVVV:PPPP means usb) or bt:AAAAAAAAAAAA.'
        '#         Bluetooth fires on CONNECTED, and every PAIRED device is offered.'
        ''
        # The remembered spot is appended by Get-TriggerEntries rather than
        # carried in the key, because it is not part of a device's identity: an
        # entry whose device moved sockets is still the same entry.
        ("trigger.device   = {0}" -f ((Get-TriggerEntries -Devices $Devices -Candidates $Candidates -Existing $Existing) -join ', '))
        ("trigger.debounce = {0}" -f $(if ($Existing.Contains('trigger.debounce')) { $Existing['trigger.debounce'] } else { $DEFAULT_DEBOUNCE }))
        ("trigger.settle   = {0}" -f $(if ($Existing.Contains('trigger.settle'))   { $Existing['trigger.settle'] }   else { $DEFAULT_SETTLE }))
        ''
    )

    $carried = @(Get-CarriedKeys -Existing $Existing -Displays $Displays)
    if ($carried.Count -gt 0) {
        $lines += @(
            '# --- kept from the previous file (not something configure asks about) --'
            ''
        ) + $carried + @('')
    }

    # THE DIRECTORY MAY NOT EXIST YET. On a first run the walkthrough writes this
    # file before anything has created %LOCALAPPDATA%\trigger-kvm\, and
    # Set-Content does not create parents -- under $ErrorActionPreference =
    # 'Stop' that is a DirectoryNotFoundException at Save, after every question
    # has been answered and with nothing written. Measured 2026-09-08.
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $lines | Set-Content -LiteralPath $Path -Encoding ASCII
}
