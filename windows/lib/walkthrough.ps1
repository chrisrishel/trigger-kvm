# The walkthrough -- specs/configure.md. THE MENU IS THE FLOW, and nothing is
# written until Save.
#
# The state it edits is one record per panel in lib/answers.ps1, edited through
# Set-PanelAnswer. There is no separate first-run questionnaire: an empty
# install is this same menu with `not set` in it and the cursor on the first
# thing that needs an answer.

# --- computers ----------------------------------------------------------------

# A sensible name for this computer before anyone has said one. The hostname is
# what people already call it, and it is never typed in anger -- `pull` is the verb.
function Get-DefaultComputerName {
    param([System.Collections.IDictionary]$Seed)
    if ($Seed.Contains('computer.this') -and $Seed['computer.this']) { return "$($Seed['computer.this'])".Trim().ToLower() }
    $n = "$env:COMPUTERNAME".ToLower() -replace '[^a-z0-9_-]', ''
    if ($n) { return $n }
    return 'pc'
}

# Every computer the config already names, in the order it first appears.
function Get-KnownComputers {
    param([System.Collections.IDictionary]$Cfg)
    $out = @()
    foreach ($k in ($Cfg.Keys | Sort-Object)) {
        if ($k -match '^display\.[^.]+\.input\.') {
            $n = "$($Cfg[$k])".Trim().ToLower()
            if ($n -and -not ($out -contains $n)) { $out += $n }
        }
    }
    return $out
}

# Which computers to take off the list -- specs/configure.md 5.3. Returns the
# survivors, and whether any panel's map changed.
#
# A ROW, NOT A KEYPRESS, for three reasons that point the same way: it is
# visible rather than a gesture you have to know; it works in the typed
# fallback, which 3.5 makes load-bearing; and a row has a detail column to state
# the cost in BEFORE it is chosen.
#
# computer.this is not offered: its name is what `pull` resolves, so a config
# without it is one the switcher declines to act on.
function Read-ComputerRemovals {
    param([string[]]$Others, $Panels)

    $rest  = @($Others)
    $edits = $false
    while ($true) {
        if ($rest.Count -eq 0) { return [PSCustomObject]@{ Remaining = @(); Edited = $edits } }

        $rows = @()
        $det  = @()
        foreach ($c in $rest) {
            $on = @($Panels | Where-Object { $_.Map.Contains($c) } | ForEach-Object { $_.Label })
            $rows += $c
            $det  += $(if ($on.Count) { 'on ' + (Join-Names $on) } else { 'not on any monitor' })
        }
        $rows += '';     $det += ''
        $done  = $rows.Count
        $rows += 'Done'; $det += ''

        Write-Host ''
        Write-Host '--- remove a computer ---'
        Write-Host '  Removing a computer also clears its input on every monitor it is on.'
        Write-Host ''
        $pick = Select-One -Items $rows -Detail $det -Default $done -Escapable
        if ($pick -lt 0 -or $pick -eq $done) {
            return [PSCustomObject]@{ Remaining = @($rest); Edited = $edits }
        }

        $victim = $rows[$pick]
        Write-Host ''
        Write-Host '  Its input on every monitor is cleared too. Nothing else changes.'
        # Defaults to NO. This is the destructive half of the menu, and the whole
        # reason removal stopped being a blank answer.
        if (Read-YesNo ("  Remove '{0}'?" -f $victim) $false) {
            # Cleared from the maps HERE, while the name is still known to be the
            # one that was chosen -- see Edit-PanelMaps.
            Edit-PanelMaps -Panels $Panels -Was $victim -Now ''
            $rest  = @($rest | Where-Object { $_ -ne $victim })
            $edits = $true
        }
    }
}

# The computers plugged into these monitors, this one included --
# specs/configure.md 5.
#
# Asked BEFORE the monitors, so a computer is described once and is then an
# option on every panel. $Panels is EDITED IN PLACE: a rename or a removal is
# carried into every map as it happens rather than reported for the caller to
# apply afterwards.
function Read-Computers {
    param([string]$This, [string[]]$Others, [switch]$Existing, $Panels = @())

    Write-Host ''
    Write-Host '--- computers ---'
    Write-Host 'These monitors are shared between this computer and some others.'
    Write-Host 'Each one gets a name, and the name is how you switch to it:'
    Write-Host '    trigger-kvm to mac'
    Write-Host ''

    $me    = $This
    $rest  = @($Others | Where-Object { $_ -and $_ -ne $This })
    # Whether anything happened that a monitor-input pass no longer describes
    # (specs/configure.md 5.2).
    $edits = $false

    # Nothing configured yet: a count, then that many names. "One per line, blank
    # line when there are no more" made people guess at both how to finish and
    # whether a blank meant cancel.
    if (-not $Existing) {
        $was = $me
        $me  = Read-Name -Prompt 'What should I call THIS computer?' -Default $This
        if ($was -and $me -ne $was) { Edit-PanelMaps -Panels $Panels -Was $was -Now $me; $edits = $true }

        $n = -1
        while ($n -lt 0) {
            $a = Read-Default '  How many OTHER computers are plugged into these monitors?' `
                              ([string]([Math]::Max($rest.Count, 1)))
            if ($a -match '^\d+$' -and [int]$a -le 16) { $n = [int]$a }
            else { Write-Host '  A number, please (16 at most).' }
        }

        $rest = @()
        for ($i = 1; $i -le $n; $i++) {
            $rest += Read-Name -Taken (@($me) + $rest) -Default '' `
                        -Prompt $(if ($n -eq 1) { 'What is the other one called?' }
                                  else { "Name for computer $i of ${n}:" })
        }
    }

    # Then, always, a list to correct. Renaming is the common edit -- a name is
    # typed once and lived with -- so it is what selecting a row does.
    while ($true) {
        $rows = @(@($me) + $rest)
        $det  = @(@('this computer') + @($rest | ForEach-Object { '' }))
        $rows += ''; $det += ''
        $add  = $rows.Count
        $rows += 'Add another computer'; $det += ''
        $rows += 'Remove a computer';    $det += ''
        $rows += 'Done';                 $det += ''

        Write-Host ''
        $pick = Select-One -Items $rows -Detail $det -Default ($add + 2) -Escapable `
                           -Help '  Pick a name to change it, or Done.'
        if ($pick -eq $add + 2 -or $pick -lt 0) { break }

        if ($pick -eq $add) {
            $rest += Read-Name -Prompt 'Name for the new computer' -Default '' `
                                       -Taken (@($me) + $rest)
            continue
        }

        if ($pick -eq $add + 1) {
            $r     = Read-ComputerRemovals -Others $rest -Panels $Panels
            $rest  = @($r.Remaining)
            $edits = $edits -or $r.Edited
            continue
        }

        if ($pick -eq 0) {
            $was = $me
            $me  = Read-Name -Prompt 'What should I call THIS computer?' `
                                     -Default $me -Taken $rest
            if ($me -ne $was) { Edit-PanelMaps -Panels $Panels -Was $was -Now $me; $edits = $true }
        } else {
            # PRE-FILLED, and a blank answer KEEPS the name, like every other
            # prompt here (specs/configure.md 5.0). Removal is its own row.
            $i   = $pick - 1
            $was = $rest[$i]
            $rest[$i] = Read-Name -Prompt ("Name for computer '{0}'" -f $was) `
                            -Default $was `
                            -Taken (@($me) + @($rest | Where-Object { $_ -ne $was }))
            if ($rest[$i] -ne $was) {
                Edit-PanelMaps -Panels $Panels -Was $was -Now $rest[$i]
                $edits = $true
            }
        }
    }

    return [PSCustomObject]@{ This = $me; All = @(@($me) + $rest); Edited = $edits }
}

# --- one panel ----------------------------------------------------------------

# Ask which input something is on, for one panel -- specs/configure.md 6.1.
# Returns a value, or $null when -AllowNone is given and that computer is not on
# this panel at all, or $BACK when esc is offered and taken.
#
# Every value it is handed -- the table's, the default's, $Taken's keys -- is
# already canonical, so the comparisons below are plain string ones. What keeps
# that true is the typed branch, which converts before doing anything else.
function Read-InputValue {
    param($Table, [string]$Prompt, [string]$Sub, [string]$Default = '',
          [hashtable]$Taken = @{}, [switch]$AllowNone,
          # Which channel these values are for. Only the typed branch cares: a
          # typed byte is the one thing that reaches a manufacturer channel from
          # outside the documented table.
          [string]$Method = 'standard',
          # Offer esc. Opt-in, because "back" only means something where the
          # caller arrived from somewhere: configuring a panel came from the
          # Monitors list, but a repair after a failed check is mid-flow.
          [switch]$Escapable)

    $names = @($Table.Keys)
    $rows  = @($names)
    # Two computers cannot share a socket, so an assigned input is not merely
    # discouraged -- it is not an answer. It stays in place, says who has it, and
    # the cursor skips it.
    $off   = @()
    $vals  = @()
    for ($i = 0; $i -lt $names.Count; $i++) {
        $v = $Table[$names[$i]]
        if ($Taken.Contains($v)) { $vals += ('{0}   assigned to {1}' -f $v, $Taken[$v]); $off += $i }
        else                     { $vals += $v }
    }
    $rows += 'Type a value...'; $vals += ''
    if ($AllowNone) { $rows += 'Not on this monitor'; $vals += '' }

    # The cursor starts on the configured value's row; an unlisted value starts
    # on "Type a value...", which is where it came from; a computer with no
    # answer yet on "Not on this monitor". Never on a row it cannot choose.
    $row = 0
    $now = -1
    if ($Default) {
        $row = $names.Count
        for ($i = 0; $i -lt $names.Count; $i++) { if ($Table[$names[$i]] -ieq $Default) { $row = $i } }
        $now = $row
    } elseif ($AllowNone) {
        $row = $rows.Count - 1
    }
    if ($off -contains $row) { $row = $names.Count }

    Write-Host ''
    Write-Host ('  ' + $Prompt)
    if ($Sub) { Write-Host ('  ' + $Sub) }

    while ($true) {
        $v = $null
        $pick = Select-One -Items $rows -Detail $vals -Default $row -Current $now -Disabled $off `
                           -Escapable:$Escapable
        # BEFORE the row tests: esc is -1, and -1 is less than $names.Count.
        if ($pick -lt 0) { return $BACK }
        if ($pick -lt $names.Count) {
            $v = $Table[$names[$pick]]
        } elseif ($AllowNone -and $pick -eq ($rows.Count - 1)) {
            return $null
        } else {
            if ($Method -ne 'standard') {
                # ../AGENTS.md hard rule 1 permits a typed value on a
                # manufacturer channel only because the person typing it is the
                # one who has to know where it came from. Say so before they do.
                Write-Host ''
                # DOUBLE-quoted, so the apostrophe appears once in the source:
                # this is normative wording and the conformance check looks for
                # it as the spec writes it.
                Write-Host "  This is the manufacturer's service channel. Type only a value you have"
                Write-Host '  from documentation; an unknown value here has made monitors unusable.'
            }
            $typed = Read-Default '  Value (e.g. 0x11)' $Default
            $v = Format-Byte $typed
            if (-not $v) { Write-Host '  Not a byte.'; continue }
        }
        # Two computers on one input makes `to` ambiguous, and it refuses rather
        # than guess -- so refuse here, where the person can still say which one
        # they meant. Marking it in the list is not enough: a typed value never
        # appears in the list at all.
        if ($Taken.Contains($v)) {
            Write-Host ('  {0} is already {1} on this monitor. Two computers cannot share one input.' -f $v, $Taken[$v])
            continue
        }
        return $v
    }
}

# How the bytes reach one panel -- specs/configure.md 6.3. Returns the transport.
#
# SHOWN ONLY WHERE A CHOICE EXISTS: where this panel enumerated through more
# than one of this platform's transports. ENUMERATING IS NOT PROBING -- the
# offer is built from which of this computer's APIs could see the panel, and
# reading an EDID sends nothing to a monitor.
#
# It comes BEFORE the method question, because the transport decides which
# dialects exist at all.
function Read-Transport {
    param([string[]]$Transports, [string]$Current, [int]$Vendor)

    $t = @($Transports | Where-Object { $_ })
    if ($t.Count -le 1) {
        # Nothing to ask. Store what it enumerated on, so the config records the
        # path that was actually confirmed rather than leaving it to a default.
        if ($t.Count -eq 1) { return $t[0] }
        return $(if ($Current) { $Current } else { 'nvapi' })
    }

    $d = $DIALECTS['{0:X4}' -f $Vendor]

    Write-Host ''
    Write-Host '--- how the switch reaches this monitor ---'
    Write-Host '  Both ways work on this computer. They differ in when they work and'
    Write-Host '  in what they can say.'
    Write-Host ''
    # THE CONSEQUENCE, NAMED WHERE THE CHOICE IS MADE, in terms of what the
    # person will experience: nobody picking a monitor setting wants to be told
    # about session 0.
    Write-Host '  Through Windows, this monitor will not follow the switch until'
    Write-Host '  somebody has logged in. A PC sitting at the login screen keeps'
    Write-Host '  showing whatever it was showing.'
    if ($d) {
        Write-Host ''
        Write-Host ("  It also cannot use {0}'s own method -- there is no way to send that" -f $d.What)
        Write-Host '  down it. Only the standard one.'
    }
    Write-Host ''

    # The graphics card is the default and where the cursor starts: it covers
    # more, and someone with no opinion should land on the answer with fewer
    # consequences.
    $now  = $(if ($Current -eq 'dxva2') { 1 } elseif ($Current -eq 'nvapi') { 0 } else { -1 })
    $pick = Select-One -Default ([Math]::Max(0, $now)) -Current $now -Escapable `
                -Items  @('Through the graphics card', 'Through Windows') `
                -Detail @('works before anyone logs in',
                          $(if ($d) { ('login onward only; cannot use {0}''s own method' -f $d.What) }
                            else    { 'login onward only' }))
    if ($pick -lt 0) { return $BACK }
    return $(if ($pick -eq 1) { 'dxva2' } else { 'nvapi' })
}

# Which channel to talk to one panel on -- specs/configure.md 6.2. Returns the
# method name.
#
# SHOWN ONLY when this panel's EDID VENDOR has a documented alternative, keyed
# by vendor alone. OFFERED, NEVER PROBED: nothing is sent to find out, the
# choice comes from the documented table or not at all, and the transport still
# refuses a manufacturer channel to a panel whose vendor does not match
# (../AGENTS.md hard rule 1b).
#
# Up front rather than only after a failure: someone who already knows their
# model needs the alternative should not have to run a check that moves a panel
# purely in order to fail. Offering here sends fewer packets, not more, and the
# check still offers it again in either direction.
function Read-Method {
    param([int]$Vendor, [string]$Current, [string]$Transport = 'nvapi')

    $d = $DIALECTS['{0:X4}' -f $Vendor]
    if (-not $d) { return $Current }

    # A transport that cannot address an I2C source byte cannot carry a
    # manufacturer channel, so there is no choice left to offer -- and offering
    # one here to refuse it at the transport is the question-whose-answer-is-
    # already-fixed that 6.3 orders these two to avoid. Read-Transport has
    # already said so on the row where dxva2 was picked.
    #
    # This is not a second copy of the switcher's refusal: that one refuses a
    # pair a hand-edited config can still ask for; this one never offers it.
    if ($Transport -in $SOURCELESS_TRANSPORTS) { return 'standard' }

    Write-Host ''
    Write-Host '--- how to talk to this monitor ---'
    Write-Host ('  Nearly every monitor takes the standard method, including most {0} ones.' -f $d.What)
    Write-Host ('  A few {0} models ignore it and need {0}''s own method instead.' -f $d.What)
    Write-Host ''
    # This is the moment a person commits to a service channel, and the rules
    # that keep it safe live in ../AGENTS.md, which a user never opens. These
    # three lines are the only warning they get: what the channel is, what is
    # sent to it, and what has happened on it.
    Write-Host ('  {0}''s own method talks to a service channel on the monitor. It is' -f $d.What)
    Write-Host '  sent only the values written down for it: unknown values on that'
    Write-Host '  channel have made monitors unusable.'
    Write-Host ''
    Write-Host '  If you are not sure, take the standard one. If it turns out not to'
    Write-Host '  work, the check further down will offer you this again.'
    Write-Host ''

    # Standard is the default and where the cursor starts on a fresh panel; an
    # existing choice keeps the cursor and is marked (current). Esc leaves the
    # panel's questions entirely -- resolving it to "keep $Current" made esc
    # byte-for-byte what enter does, so it appeared to ADVANCE the walkthrough.
    $now  = $(if ($Current -eq $d.Method) { 1 } else { 0 })
    $pick = Select-One -Default $now -Current $now -Escapable `
                -Items  @('Standard', ("{0}'s own method" -f $d.What)) `
                -Detail @('what nearly every monitor takes',
                          ('for {0} models that ignore the standard one' -f $d.What))
    if ($pick -lt 0) { return $BACK }
    return $(if ($pick -eq 1) { $d.Method } else { 'standard' })
}

# One panel's questions, as ONE SUBMENU -- specs/configure.md 6. Identity is
# already known; what is needed from the human is whether to manage it, what to
# call it, how the bytes get there, which channel, and which input each computer
# is on. Machines-major, not inputs-major.
#
# Esc at any menu in it returns $BACK and the panel keeps its old row exactly.
# $null is the different answer "do not manage this monitor", which does remove
# it -- conflating the two would let esc silently unmanage a panel.
function Get-DisplayAnswers {
    # $Existing is a PSCustomObject or $null -- deliberately untyped, because a
    # [hashtable] annotation is accepted at parse time and throws at RUN time,
    # i.e. mid-walkthrough.
    param($Found, $Existing, [string[]]$Computers, [string]$This,
          # The short names the OTHER managed panels already have: two panels
          # with one label would be written as one and read back as a merge.
          [string[]]$Labels = @())

    $key  = '{0:X4}:{1:X4}' -f $Found.EdidVendor, $Found.EdidProduct
    # The panel's own name, out of its EDID monitor-name descriptor. No table to
    # be absent from.
    $desc = if ($Found.Name) { $Found.Name } else { ('{0} panel {1}' -f $Found.Mfg, $key) }

    Write-Host ''
    Write-Host ('  {0}   EDID {1}   {2}' -f $desc, $key, $Found.Connector)

    $defaultLabel = if ($Existing) { $Existing.Label } else { Format-Name (($desc -split ' ')[0]) }
    if (-not $defaultLabel) { $defaultLabel = Format-Name $Found.Mfg }
    if (-not (Read-YesNo '  Manage this monitor?' $true)) {
        # "No" is DESTRUCTIVE when there is something to lose, so the loss is
        # named and confirmed -- the same rule as removing a computer. A panel
        # with nothing configured has nothing to lose and is not asked twice.
        $had = $(if ($Existing -and $Existing.Map) { @($Existing.Map.Keys).Count } else { 0 })
        if ($had -eq 0) { return $null }

        Write-Host ''
        Write-Host '  Which computer is on which of its inputs is forgotten. Nothing else'
        Write-Host '  changes, and nothing is written until you save.'
        if (Read-YesNo '  Stop managing this monitor?' $false) { return $null }
        return $BACK
    }

    # The same rule, prompt and duplicate check as a computer name
    # (specs/configure.md 6, which points at 5.1 rather than restating it).
    $label = Read-Name -Prompt 'Short name for it' -Default $defaultLabel `
                       -Taken $Labels -Noun 'monitor'

    # An existing method or transport is a SETTLED ANSWER -- somebody watched a
    # panel move over it -- so a re-run does not walk either back to a default.
    $was   = if ($Existing -and $Existing.Method) { $Existing.Method } else { 'standard' }
    $prior = if ($Existing -and $Existing.Map) { $Existing.Map } else { [ordered]@{} }
    $wasT  = if ($Existing -and $Existing.Transport) { $Existing.Transport } else { '' }

    # Transport before method, because the transport decides which dialects are
    # available; method before the inputs, because the values on offer depend on
    # it (specs/configure.md 6.2 and 6.3).
    $transport = Read-Transport -Transports $Found.Transports -Current $wasT -Vendor $Found.EdidVendor
    if ($transport -eq $BACK) { return $BACK }

    $method = Read-Method -Vendor $Found.EdidVendor -Current $was -Transport $transport
    if ($method -eq $BACK) { return $BACK }

    $panel = New-PanelAnswer -Label $label -Name $desc -Method $method -Transport $transport `
                             -EdidVendor $Found.EdidVendor -EdidProduct $Found.EdidProduct `
                             -Mfg $Found.Mfg
    # A changed method makes every prior value meaningless -- they addressed the
    # other channel -- so they stop being defaults.
    if ($method -ne $was) { $prior = [ordered]@{} }

    $taken = @{}
    foreach ($m in $Computers) {
        $table = Get-InputTable -Method $method -Map $panel.Map
        $prev  = if ($prior.Contains($m)) { $prior[$m] } else { '' }
        $sub   = if ($m -eq $This) { '(this computer -- the input you would pick to see this screen)' } else { '' }
        $v = Read-InputValue -Table $table -Default $prev -Taken $taken -AllowNone:($m -ne $This) `
                             -Prompt ("On the {0}, which input is '{1}' on?" -f $desc, $m) -Sub $sub `
                             -Method $method -Escapable
        # Esc anywhere in a panel's questions abandons the WHOLE panel. Half a
        # map is not an answer, and the person asked to leave.
        if ($v -eq $BACK) { return $BACK }
        if ($null -ne $v) { Set-PanelAnswer -Panel $panel -On $m -Value $v | Out-Null; $taken[$v] = $m }
    }

    return $panel
}

# --- the sections -------------------------------------------------------------

# The monitors, as a list you pick from -- specs/configure.md 6. The same shape
# as the computers list, and for the same reason: walking every panel in
# sequence to change one value meant answering for all of them.
function Read-Monitors {
    param($Found, $Answers, [string[]]$Computers, [string]$This, [System.Collections.IDictionary]$Existing = @{})

    $out = @($Answers)

    while ($true) {
        $items  = @()
        $detail = @()
        foreach ($f in $Found) {
            $key = '{0:X4}:{1:X4}' -f $f.EdidVendor, $f.EdidProduct
            $a   = @($out | Where-Object { $_.Key -eq $key }) | Select-Object -First 1
            $items  += $(if ($f.Name) { $f.Name } else { '{0} panel {1}' -f $f.Mfg, $key })
            # An id that answers for more than one ATTACHED panel cannot be
            # managed at all (specs/configure.md 6.4), so the row says that
            # rather than an answer -- including where a config written before
            # the second panel arrived still holds one. That answer is kept.
            $detail += $(if ($f.Panels -gt 1) { '{0} monitors share this id -- cannot manage' -f $f.Panels }
                         elseif ($a) { '{0}: {1}' -f $a.Label, (@($a.Map.Keys) -join '/') }
                         else { 'not managed' })
        }
        $items += ''; $detail += ''
        $done = $items.Count
        $items += 'Done'; $detail += ''

        # The first panel nobody has answered for, else the way out.
        $land = $done
        for ($i = 0; $i -lt $Found.Count; $i++) { if ($detail[$i] -eq 'not managed') { $land = $i; break } }

        Write-Host ''
        Write-Host '--- monitors ---'
        Write-Host 'Which of these should follow the switch, and which input is each'
        Write-Host 'computer on?'
        Write-Host ''
        # No -Disabled: no row in the Monitors list is ever unpickable.
        $pick = Select-One -Items $items -Detail $detail -Default $land -Escapable
        if ($pick -eq $done -or $pick -lt 0) { return @($out) }

        $f = $Found[$pick]
        # Refuse BEFORE any question is asked. Answers are looked up by the id,
        # so one record would serve both panels and the second answer would
        # overwrite the first: the person configures two monitors and has
        # configured one (specs/configure.md 6.4).
        if ($f.Panels -gt 1) {
            Write-Host ''
            Write-Host ('  {0} monitors report the same id and cannot be told apart (0x{1:X4}:0x{2:X4}).' -f `
                        $f.Panels, $f.EdidVendor, $f.EdidProduct)
            Write-Host  '  A switch cannot aim at one of them, so none of them can be managed.'
            Write-Host  '  Unplug one to manage the other. Anything already configured for'
            Write-Host  '  this id is left exactly as it is.'
            continue
        }
        $key   = '{0:X4}:{1:X4}' -f $f.EdidVendor, $f.EdidProduct
        $prior = @($out | Where-Object { $_.Key -eq $key }) | Select-Object -First 1
        if (-not $prior) { $prior = Get-PriorDisplay -Existing $Existing -Key $key -Computers $Computers }

        # Every OTHER managed panel's short name, so this one cannot take a name
        # already in use. This panel's own is excluded: keeping it is no clash.
        $others = @($out | Where-Object { $_.Key -ne $key } | ForEach-Object { $_.Label })
        $a = Get-DisplayAnswers -Found $f -Existing $prior -Computers $Computers -This $This `
                                -Labels $others
        # $BACK means CHANGE NOTHING, so the panel keeps whatever row it had.
        if ($a -is [string]) { continue }
        $out = @($out | Where-Object { $_.Key -ne $key })
        if ($a) { $out += $a }
    }
}

# Which devices travel with the switch -- specs/configure.md 7. Returns the
# chosen keys.
function Read-Triggers {
    param($Cands, [string[]]$Current)

    Write-Host ''
    Write-Host '--- triggers ---'
    Write-Host 'Which devices move to this computer when you flip the switch?'
    Write-Host 'USB rows are attached right now; Bluetooth rows are everything paired.'
    Write-Host ''

    $checked = @()
    for ($i = 0; $i -lt $Cands.Count; $i++) { if ($Current -contains $Cands[$i].Key) { $checked += $i } }

    $help = '  Keyboards and mice often share a vendor id with something that never' + "`n" +
            '  moves. The full vendor+product is matched, so pick the exact rows.'

    # THE NAME IS THE ROW; the id is what confirms it (specs/configure.md 7.1).
    # You recognise a device by what it is called, and `usb:046d:c547` names
    # nothing to a person -- but the help above says to match the FULL pair, and
    # you cannot act on that against a name alone, so the pair stays visible.
    $picked = Select-Many -Checked $checked -Help $help -Escapable `
        -Items  @($Cands | ForEach-Object { Get-CandidateLabel $_ }) `
        -Detail @($Cands | ForEach-Object {
                    ('{0,-20} {1}' -f $_.Key, $_.Bus) +
                    $(if ($_.State) { '   ' + $_.State } else { '' }) })

    if ($null -eq $picked) { return @($Current) }
    return @($picked | ForEach-Object { $Cands[$_].Key })
}

# Whether to put bin\ on the user PATH -- specs/configure.md 9. Returns $true or
# $false.
#
# A menu rather than a row that flips when you select it: a toggle cannot
# express "not answered yet", and a suggestion belongs on a highlighted row
# rather than in the value column of a menu nobody has opened (4.3).
function Read-PathChoice {
    param($Current)

    Write-Host ''
    Write-Host '--- PATH ---'
    # Single quotes: in a DOUBLE-quoted PowerShell string a backtick is the
    # escape character, so "`trigger-kvm`" renders as TAB + "rigger-kvm".
    Write-Host ('  Add {0} to your PATH, so `trigger-kvm` works from anywhere?' -f $BINDIR)
    Write-Host '  Only that directory is added, and it holds only the launcher.'
    Write-Host ''
    $now = $(if ($null -eq $Current) { -1 } elseif ($Current) { 0 } else { 1 })
    $pick = Select-One -Default ([Math]::Max(0, $now)) -Current $now -Escapable `
                       -Items @('Yes', 'No') `
                       -Detail @('trigger-kvm works from anywhere', 'call it by its full path')
    if ($pick -lt 0) { return $Current }
    return ($pick -eq 0)
}

# When the watcher should start -- specs/configure.md 8. Returns 's4u', 'user'
# or 'manual'.
#
# From boot is offered FIRST and is the highlighted row: a computer sitting at a
# login screen should still follow the switch. The cost is one UAC prompt now.
# An existing config still wins -- an existing choice is a choice.
function Read-Tier {
    param([string]$Current, [string[]]$LoginOnly = @())

    Write-Host ''
    Write-Host '--- should it start on its own? ---'
    Write-Host '  It can start as soon as the computer starts, or after you log in for'
    Write-Host '  the first time. Starting before you log in needs administrator'
    Write-Host '  permission to set up -- once, now. Nothing runs elevated afterwards.'
    Write-Host ''
    Write-Host '  Answering no still installs and starts it now; it just will not come'
    Write-Host '  back after a restart until you run:  trigger-kvm restart'
    Write-Host ''
    # DRAWN and disabled with the reason, never hidden. Two DIFFERENT facts can
    # disable it and must not be merged: the account case is answered by finding
    # an administrator, the transport case by putting that panel back on the
    # graphics card, and somebody told the wrong one goes hunting for a password
    # that would not have helped. Where both are true, both are said.
    $canElevate = Test-CanElevate
    # @() around it, not the parameter default: an EMPTY result passed
    # explicitly arrives as $null, which the default never replaces, and
    # Set-StrictMode makes $null.Count terminating.
    $stranded = @($LoginOnly | Where-Object { $_ })
    $off = @()
    if (-not $canElevate -or $stranded.Count -gt 0) { $off += 0 }

    $why = @()
    if ($stranded.Count -gt 0) {
        $why += ('{0} cannot switch before login' -f (Join-Names $stranded))
    }
    if (-not $canElevate) { $why += 'needs an administrator account' }
    if ($why.Count -eq 0) { $why += 'one administrator prompt now; nothing runs elevated afterwards' }

    $now = $(switch ($Current) { 's4u' { 0 } 'user' { 1 } 'manual' { 2 } default { -1 } })
    $default = [Math]::Max(0, $now)
    if ($off -contains $default) { $default = 1 }

    $pick = Select-One -Default $default -Current $now -Escapable -Disabled $off -Items @(
        'From boot',
        'From login',
        'No -- I will start it myself') -Detail @(
        ($why -join '; '),
        'covers everything from your logon onward',
        '')
    if ($pick -lt 0) { return $Current }
    return $(switch ($pick) { 1 { 'user' } 2 { 'manual' } default { 's4u' } })
}

# --- the menu -----------------------------------------------------------------

# The walkthrough. Current settings pre-fill every default, so a re-run is a
# review rather than a replay -- unless -Fresh, which starts from nothing.
#
# Two distinct roles for the old config, and -Fresh separates them: $seed
# supplies DEFAULTS, $existing is what must SURVIVE. Dropping both would
# silently discard anything hand-written, so -Fresh clears the first and never
# touches the second.
#
# Nothing is written until every answer is in (specs/configure.md 4.4).
function Invoke-Configure {
    param([switch]$Fresh)

    if (-not (Test-CanPrompt)) {
        Write-Log 'configure needs an interactive terminal.'
        Write-Host ''
        Write-Host ("Edit the config directly instead:  {0}" -f $CONFIG)
        Write-Host 'Then:  trigger-kvm restart'
        $global:LASTEXITCODE = 2
        return
    }

    $existing = Read-Config -Path $CONFIG
    $isFirst  = -not (Test-Path -LiteralPath $CONFIG)
    $seed     = if ($Fresh) { @{} } else { $existing }

    Write-Host ''
    Write-Host '=============================================================='
    Write-Host $(if ($isFirst) { ' trigger-kvm configure -- first run' } else { ' trigger-kvm configure' })
    Write-Host '=============================================================='
    if ($Fresh -and -not $isFirst) {
        Write-Host ' Starting fresh -- nothing is pre-filled from the current setup.'
    } elseif (-not $isFirst) {
        Write-Host ' Current settings are the defaults -- press enter to keep one.'
    }

    # ---- what is attached ---------------------------------------------------
    #
    # -Raw, not the human table: that one is Write-Host, which never reaches the
    # pipeline, so parsing it would silently find nothing.
    $found = @()
    foreach ($line in (Invoke-Sibling -Script (Get-Sibling 'trigger-kvm.ps1') `
                                      -Arguments @('list', '-Raw', '-Config', $CONFIG) 2>$null)) {
        $row = ConvertFrom-DisplayRow $line
        if ($row) { $found += $row }
    }
    if ($found.Count -eq 0) {
        Write-Log 'no displays found by any transport -- nothing to configure.'
        $global:LASTEXITCODE = 2
        return
    }

    Write-Host ''
    Write-Host ('--- monitors found ({0}) ---' -f $found.Count)
    foreach ($f in $found) {
        Write-Host ('  {0,-24} {1}' -f `
                    $(if ($f.Name) { $f.Name } else { '{0} panel' -f $f.Mfg }), $f.Connector)
    }

    # ---- state, from the config or empty ------------------------------------
    $ranDisplays = $null
    $ranTriggers = $null

    $this      = Get-DefaultComputerName -Seed $seed
    $computers = @(Get-KnownComputers -Cfg $seed)
    if ($computers.Count -gt 0) { $computers = @(@($this) + @($computers | Where-Object { $_ -ne $this })) }
    $answers   = @(Get-ConfiguredAnswers -Found $found -Existing $seed -Computers $computers)

    $devices = @()
    if ($seed.Contains('trigger.device')) {
        # A malformed entry keeps its RAW text, and that is the point: it is
        # what gets shown and what Write-ConfigFile puts back. Rewriting it into
        # something that parses would edit somebody's file behind them and still
        # not start the watcher.
        $devices = @(ConvertFrom-TriggerDevices $seed['trigger.device'] |
                     ForEach-Object { if ($_.Ok) { $_.Identity } else { $_.Raw } })
    }
    $cands = @(Get-TriggerCandidates)

    # Empty means UNANSWERED, and the row says so. Both of these have a
    # suggestion -- from boot, and yes -- but a suggestion belongs on the
    # highlighted row inside the menu (specs/configure.md 4.3), and this one
    # raises a UAC prompt.
    $newTier = $(if ($seed.Contains('install.autostart')) {
                     $(switch ($seed['install.autostart']) {
                         'boot' { 's4u' } 'no' { 'manual' } default { 'user' } })
                 } else { '' })

    # (Get-UserPath) -split ';' -- THE PARENTHESES ARE LOAD-BEARING. Without
    # them -split binds as a PARAMETER of the function, is swallowed into $args,
    # and the -contains never matches (windows/AGENTS.md).
    $onPath   = @((Get-UserPath) -split ';') -contains $BINDIR
    $wantPath = $null

    # THE SETTINGS ARE THE ROWS, and choosing one enters that section and comes
    # straight back here. Three groups separated by blank rows the cursor skips:
    # what you set, what you can check, and what ends the walkthrough.
    while ($true) {
        # One punctuation rule down the value column (specs/configure.md 3.1):
        #   ", " separates items   ": " separates a label from its value
        #   "/"  joins things sharing one label
        # Not only tidiness -- Split-Detail wraps at ", ".
        $items  = @('Computers', 'Monitors', 'Triggers', 'Autostart?')
        $detail = @(
            $(if ($computers.Count -eq 0) { 'not set' } else {
                ($computers | ForEach-Object { if ($_ -eq $this) { "$_ (this)" } else { $_ } }) -join ', ' })
            $(if ($answers.Count -eq 0) { 'not set' } else {
                ($answers | ForEach-Object { '{0}: {1}' -f $_.Label, (@($_.Map.Keys) -join '/') }) -join ', ' })
            # Named, like every other row. A device that is not attached right
            # now has no name to show and keeps its key -- the honest answer,
            # and the same one `status` gives. An entry the reader would refuse
            # is SAID to be refused, here as in `status`.
            $(if ($devices.Count -eq 0) { 'not set' } else {
                (@($devices | ForEach-Object {
                    $d = $_
                    $c = @($cands | Where-Object { $_.Key -eq $d }) | Select-Object -First 1
                    if     ($c) { $c.Name }
                    elseif (-not (ConvertFrom-TriggerDevices $d)[0].Ok) { "$d (malformed)" }
                    else   { $d }
                }) -join ', ') })
            $(switch ($newTier) { 's4u' { 'from boot' } 'manual' { 'no' }
                                  'user' { 'from login' } default { 'not set' } })
        )
        # Always drawn, even when there is nothing to decide: hiding it moved
        # every row below and left the cursor apparently skipping a step, with
        # no way to tell whether PATH had been handled or forgotten.
        $items  += 'Add to PATH?'
        $pathRow = $items.Count - 1
        $detail += $(if ($onPath) { 'already on PATH' }
                     elseif ($null -eq $wantPath) { 'not set' }
                     elseif ($wantPath) { 'yes' } else { 'no' })
        $off = @()
        if ($onPath) { $off += $pathRow }

        # Monitors first, then the trigger: once the input values are known
        # good, the flip back can PULL for real, so it stops being a report that
        # an event was seen and becomes the whole thing working.
        $items  += ''; $detail += ''
        # "the monitor inputs", not "the monitors": what is under test is the
        # claim that input V of panel P is computer C.
        $claims = 0
        foreach ($a in $answers) { $claims += @($a.Map.Keys | Where-Object { $_ -ne $this }).Count }
        $items  += $(if ($claims -eq 1) { 'Test the monitor input' } else { 'Test the monitor inputs' })
        $detail += $(if ($ranDisplays) { $ranDisplays.Text } else { 'untested' })
        $items  += $(if ($devices.Count -eq 1) { 'Test the trigger' } else { 'Test the triggers' })
        $detail += $(if ($ranTriggers) { $ranTriggers.Text } else { 'untested' })

        $items  += ''; $detail += ''
        $save = $items.Count
        $items += 'Save configuration and run'; $detail += ''
        $items += 'Cancel (discard changes)';   $detail += ''

        # Where the cursor lands is "the next thing that is not done": the
        # unanswered sections in order, then the checks, then Save. A FAILED
        # check sends the cursor to the setting that failed. BACKING OUT of a
        # check is neither (specs/configure.md 4.2) -- its row reads `not
        # checked` and the cursor moves on, because landing on Monitors would
        # say "you got the monitors wrong" to someone who only declined.
        $land =
            if     ($computers.Count -eq 0) { 0 }
            elseif ($answers.Count   -eq 0) { 1 }
            elseif ($devices.Count   -eq 0) { 2 }
            elseif (-not $newTier)          { 3 }
            elseif (-not $onPath -and $null -eq $wantPath) { $pathRow }
            elseif (-not $ranDisplays)      { $save - 3 }
            elseif (-not $ranDisplays.Ok -and -not $ranDisplays.Backed) { 1 }
            elseif (-not $ranTriggers)      { $save - 2 }
            elseif (-not $ranTriggers.Ok -and -not $ranTriggers.Backed) { 2 }
            else                            { $save }

        Write-Host ''
        Write-Host $(if ($answers.Count -and $devices.Count) { '--- review configuration ---' }
                     else { '--- configuration ---' })
        Write-Host ''
        # Esc moves to Cancel rather than doing nothing, and cannot press it.
        $pick = Select-One -Items $items -Detail $detail -Default $land -EscapeTo ($save + 1)

        if ($pick -eq $save + 1) {
            Write-Log 'cancelled; nothing was changed.'
            $global:LASTEXITCODE = 1
            return
        }
        if ($pick -eq $save) {
            # Saving half a setup would write a config the switcher then refuses
            # to act on, which is a worse way to find out.
            $missing = @()
            if ($computers.Count -eq 0) { $missing += 'Computers' }
            if ($answers.Count   -eq 0) { $missing += 'Monitors' }
            if ($devices.Count   -eq 0) { $missing += 'Triggers' }
            if (-not $newTier)          { $missing += 'Autostart?' }
            if (-not $onPath -and $null -eq $wantPath) { $missing += 'Add to PATH?' }
            if ($missing.Count -eq 0) { break }
            Write-Host ''
            Write-Host ('  Still needed: {0}.' -f (Join-Names $missing))
            continue
        }

        switch ($items[$pick]) {
            'Computers' {
                $m = Read-Computers -This $this -Others @($computers | Where-Object { $_ -ne $this }) `
                                    -Existing:([bool]$computers.Count) -Panels $answers
                $this = $m.This
                $computers = $m.All
                # The maps have already followed the edit -- Read-Computers
                # carried each rename and removal into them as it happened.
                # Adding a computer leaves them alone, and the Monitors row then
                # shows which panels do not know about it yet.
                #
                # specs/configure.md 5.2: a rename or a removal invalidates a
                # monitor-input pass, because the values that passed are no
                # longer the values configured.
                if ($m.Edited) { $ranDisplays = $null }
            }
            'Monitors' {
                $before  = ($answers | ForEach-Object { '{0}={1}' -f $_.Label, (@($_.Map.Values) -join ',') }) -join '|'
                $answers = @(Read-Monitors -Found $found -Answers $answers -Computers $computers `
                                           -This $this -Existing $seed)
                $after   = ($answers | ForEach-Object { '{0}={1}' -f $_.Label, (@($_.Map.Values) -join ',') }) -join '|'
                # A pass belongs to the values that passed. Looking at the list
                # and changing nothing is not an edit (specs/configure.md 6).
                if ($before -ne $after) { $ranDisplays = $null }

                # specs/configure.md 8: giving a panel a transport that cannot
                # switch before login makes an already-chosen boot tier
                # impossible, so it falls back to login and says so. In memory
                # only -- nothing is written until Save, so the recording and
                # the applying are the same act.
                $loginOnly = @(Get-LoginOnlyPanels -Answers $answers)
                if ($newTier -eq 's4u' -and $loginOnly.Count -gt 0) {
                    $newTier = 'user'
                    Write-Host ''
                    Write-Host ('  {0} cannot switch before anyone logs in, so starting from' -f (Join-Names $loginOnly))
                    Write-Host '  boot is no longer possible. Changed to starting from login.'
                }
            }
            'Triggers' {
                $devices = @(Read-Triggers -Cands $cands -Current $devices)
                $ranTriggers = $null
            }
            'Autostart?'      { $newTier = Read-Tier -Current $newTier -LoginOnly (Get-LoginOnlyPanels -Answers $answers) }
            'Add to PATH?'    { $wantPath = Read-PathChoice -Current $wantPath }
            { $_ -like 'Test the trigger*' } {
                # Only pull for real once the monitor values have been confirmed
                # by someone looking at them: before that, a pull would aim
                # unverified values at panels.
                $ranTriggers = Invoke-TriggerTest -Devices $devices -Answers $answers -This $this `
                                                  -Pull:([bool]($ranDisplays -and $ranDisplays.Ok))
            }
            { $_ -like 'Test the monitor input*' } {
                $ranDisplays = Invoke-DisplayTest -Answers $answers -This $this
            }
        }
    }

    Write-ConfigFile -Path $CONFIG -Displays $answers -Devices $devices -Tier $newTier -Candidates $cands `
                     -This $this -Existing $existing
    Write-Log "wrote $CONFIG"

    if ($wantPath) { Add-ToUserPath -Dir $BINDIR }

    Write-Host ''
    Write-Log 'configured. Applying...'
    $global:LASTEXITCODE = 0
}
