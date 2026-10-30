# The two checks -- specs/configure.md 10 and 11. This is the only part of the
# program that deliberately moves a monitor while somebody is watching.
#
# What is under test is the claim that INPUT V OF PANEL P IS COMPUTER C. A panel
# that answers every command while its inputs are mapped to the wrong computers
# fails this and is not broken.
#
# A switch is confirmed by a person looking at it, never by a return code and
# never by reading a value back (../AGENTS.md hard rules 2 and 3). A repair
# re-asks the walkthrough's own input question rather than a copy of it, so a
# value fixed here and a value answered there cannot diverge.

# THE ONE PLACE THE INSTALLER EMITS A PACKET. Everything that moves a panel
# reaches the bus through here, so there is a single line to read when asking
# "what can send?" and a single thing for the suite to stand in for.
function Send-Input {
    param([string]$Label, [string]$Value, [string]$Config)
    Invoke-Sibling -Script (Get-Sibling 'trigger-kvm.ps1') `
                   -Arguments @('set', '-Only', $Label, '-Value', $Value, '-Config', $Config) | Out-Null
}

# --- the swing ----------------------------------------------------------------

# Say what is about to move and what stays, warn, and block until the person is
# ready. Returns $false if they declined -- which reads as `not checked`, never
# as a failure (specs/configure.md 10.1).
#
# HARD RULE 4 LIVES HERE: one panel always stays on this computer, and what
# stays is measured against every managed attached panel rather than this
# round's, because a panel nobody asked to check is still somewhere to put a
# window. Where nothing can be held back, the only-monitor warning
# (specs/configure.md 10.7) is what replaces it -- the telling has to happen
# while there is still a screen to read it on.
function Show-MovePreamble {
    param($Panels, $Stays, [string]$Target, [string]$This, [int]$Hold)

    $names = @($Panels | ForEach-Object { $_.Name })
    Write-Host ''
    Write-Host ('  Sending {0} to {1} for {2}s, then back automatically.' -f (Join-Names $names), $Target, $Hold)
    Write-Host ('  If {0} is asleep or off you will see No Signal, which still proves the' -f $Target)
    Write-Host '  switch worked.'

    if ($Stays) {
        $sn = @($Stays | ForEach-Object { $_.Name })
        Write-Host ''
        Write-Host ('  {0} {1} here, so you can read this.' -f (Join-Names $sn),
                    $(if ($sn.Count -eq 1) { 'stays' } else { 'stay' }))
        # Told every round rather than asked once. This cannot see where the
        # window is, and asking made someone answer a question about the tool's
        # scheduling; saying what is about to move lets them act on it.
        Write-Host ('  If this window is on {0}, drag it to {1} first: if the switch back' -f `
                    (Join-Names $names), $sn[0])
        Write-Host '  fails, the window goes dark with it and there is no way to answer.'
        # Last, and blocking: it is the thing to act on, so nothing may print
        # after it and be read too late.
        $null = Read-Default '  Enter when ready' ''
        return $true
    }

    $solo  = @($Panels) | Select-Object -First 1
    $back  = $solo.Map[$This]
    $bname = Get-InputName -Answer $solo -Value $back
    Write-Host ''
    Write-Host '  READ THIS FIRST -- this is your only monitor.'
    Write-Host '  You will not be able to read anything while it is away.'
    Write-Host ''
    Write-Host '  IF IT DOES NOT COME BACK there is nothing this tool can do for you --'
    Write-Host '  it cannot draw on a screen that is showing another computer. The way'
    Write-Host '  back is the monitor itself: press its input (or source) button and'
    Write-Host ('  choose {0}. No software can take that button away from you.' -f `
                $(if ($bname) { '{0}, value {1}' -f $bname, $back } else { "value $back" }))
    Write-Host ''
    if (Read-YesNo '  Ready?' $true) { return $true }
    Write-Host '  Skipped. Nothing was sent.'
    return $false
}

# Send a group of panels away, hold, and bring them all back.
#
# THE RETURN IS WHAT MAKES THIS SAFE to run against the display someone is
# reading: the question always arrives on a panel that has already come back, so
# nothing here needs to know which monitor the window is on, and a wrong guess
# costs a few seconds of black rather than a stranded session.
function Move-PanelsAndBack {
    param($Panels, [hashtable]$Away, [string]$This, [string]$Config, [int]$Hold)

    foreach ($a in $Panels) { Send-Input -Label $a.Label -Value $Away[$a.Label] -Config $Config }
    Start-Sleep -Seconds $Hold
    foreach ($a in $Panels) { Send-Input -Label $a.Label -Value $a.Map[$This] -Config $Config }
    Start-Sleep -Seconds 2
}

# Where one panel goes for a check: the target computer's input, or -- with no
# other computer configured -- the first value on its channel that is not this
# computer's, because then the only claim left to test is that the transport
# reaches it. Returns $null when the panel has nowhere to go.
function Get-SwingCandidate {
    param($Answer, [string]$Target, [string]$This)

    if ($Target) {
        if (-not $Answer.Map.Contains($Target)) { return $null }
        return [PSCustomObject]@{ Value = $Answer.Map[$Target]; Name = $Target; IsComputer = $true }
    }
    $here  = $Answer.Map[$This]
    $table = Get-InputTable -Method $Answer.Method -Map $Answer.Map
    foreach ($n in $table.Keys) {
        if ($table[$n] -ine $here) {
            return [PSCustomObject]@{ Value = $table[$n]; Name = $n; IsComputer = $false }
        }
    }
    return $null
}

# --- checking the monitor inputs ----------------------------------------------

# Prove the display answers BEFORE anything is written, against a throwaway
# config: the switcher takes its map from a file rather than from a command
# line, so testing early means writing a temp one, not weakening "nothing is
# written until Save".
#
# BATCHED ACROSS PANELS, NEVER ACROSS COMPUTERS (specs/configure.md 10.2).
# Monitors sit side by side, so several can be confirmed in one glance; a
# sequence of switches over half a minute has to be held in memory, and memory
# is the weak link. The win is the QUESTION: "did they all show mac?" makes the
# common case one keystroke, and the four-way diagnosis appears only for the
# panels somebody says went wrong.
function Invoke-DisplayTest {
    param($Answers, [string]$This)

    # A CONFIGURED PANEL THAT IS NOT ATTACHED IS NOT OFFERED and cannot be
    # checked (specs/configure.md 6 and 10.1): nobody can watch a monitor that
    # is not there change. It keeps its keys and stays out of the scope.
    $All = @(Get-AttachedManaged -Panels $Answers)
    if ($All.Count -eq 0) {
        Write-Host ''
        Write-Host '  No managed monitor is attached right now, so there is nothing to check.'
        return [PSCustomObject]@{ Ok = $false; Backed = $true; Text = 'not checked'; Sig = ''; Scope = @() }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('trigger-kvm-test-{0}.cfg' -f $PID)
    $bad = @()
    $confirmed = @{}
    try {
        # The WHOLE answer set goes to the throwaway config, absent panels
        # included: the switcher is asked to move one label at a time, and a
        # config missing the others would not be the config being tested.
        Write-ConfigFile -Path $tmp -Displays $Answers -Devices @() -Tier 'user' -This $This -Existing @{}

        $Answers = $All
        # Which monitor to check -- their intent, not the tool's convenience.
        # Backing out here is `not checked`, never a pass (specs/configure.md 10.1).
        if ($Answers.Count -gt 1) {
            Write-Host ''
            Write-Host '  Which monitor do you want to check?'
            $rows = @(@('All of them') + @($Answers | ForEach-Object { $_.Name }))
            $pick = Select-One -Items $rows -Default 0 -Escapable
            if ($pick -lt 0) { return [PSCustomObject]@{ Ok = $false; Backed = $true; Text = 'not checked'; Sig = ''; Scope = @() } }
            if ($pick -gt 0) { $Answers = @($Answers[$pick - 1]) }
        }

        # Scope first, then the claims for EACH panel. A panel with only this
        # computer still owes a transport check when its neighbour has others.
        $others = @()
        foreach ($a in $Answers) {
            $targets = @($a.Map.Keys | Where-Object { $_ -ne $This })
            foreach ($m in $targets) { if ($others -notcontains $m) { $others += $m } }
            if ($targets.Count -eq 0) {
                $result = Test-OneComputer -Answer $a -All $All -This $This -Target '' -Config $tmp
                if ($null -eq $result) { $bad += '(skipped)' }
                elseif (-not $result) { $bad += $a.Name }
                else { $confirmed[$a.Label] = @{ Sig = (Get-PassSignature @($a)); Targets = @('') } }
            }
        }

        foreach ($m in $others) {
            $panels = @($Answers | Where-Object { $_.Map.Contains($m) -and $_.Map.Contains($This) })
            if ($panels.Count -eq 0) { continue }

            # Hard rule 4: one panel always stays here, so the question arrives
            # on a screen you can still read. When every panel being checked
            # claims this computer, that is two rounds -- the second covers the
            # one held back.
            $rounds = @()
            if ($panels.Count -eq @($Answers).Count -and $panels.Count -gt 1) {
                $rounds += ,@($panels[0..($panels.Count - 2)])
                $rounds += ,@($panels[-1])
            } else {
                $rounds += ,@($panels)
            }

            foreach ($r in $rounds) {
                $moving = @($r | ForEach-Object { $_.Label })
                $stays  = @(Get-AttachedManaged -Panels $All | Where-Object { -not ($moving -contains $_.Label) })
                $failures = @(Invoke-TestRound -Panels $r -Stays $stays -Target $m -All $All `
                                                 -This $This -Config $tmp)
                foreach ($f in $failures) {
                    if (-not ($bad -contains $f)) { $bad += $f }
                }
                if ($failures.Count -eq 0) {
                    foreach ($a in $r) {
                        $sig = Get-PassSignature @($a)
                        # A repair can change a method or another mapping too.
                        # Earlier claims on that panel no longer describe it.
                        if (-not $confirmed.Contains($a.Label) -or $confirmed[$a.Label].Sig -ne $sig) {
                            $confirmed[$a.Label] = @{ Sig = $sig; Targets = @() }
                        }
                        $confirmed[$a.Label].Targets += $m
                    }
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    # Declining is not a failure and must not read as a pass either.
    $scope = @($Answers | ForEach-Object { $_.Label })
    foreach ($a in $Answers) {
        $required = @($a.Map.Keys | Where-Object { $_ -ne $This })
        if (-not $required.Count) { $required = @('') }
        if (-not $confirmed.Contains($a.Label) -or $confirmed[$a.Label].Sig -ne (Get-PassSignature @($a))) {
            if (-not $bad.Count) { $bad += '(skipped)' }
            continue
        }
        foreach ($target in $required) {
            if ($confirmed[$a.Label].Targets -notcontains $target) { $bad += '(skipped)' }
        }
    }
    if ($bad -contains '(skipped)') {
        return [PSCustomObject]@{ Ok = $false; Backed = $true; Text = 'not checked'; Sig = ''; Scope = @() }
    }
    if ($bad.Count -gt 0) {
        return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = ('trouble with ' + ($bad -join ', ')); Sig = ''; Scope = $scope }
    }
    # A PASS IS BOUND TO WHAT IT CHECKED -- specs/configure.md 10.8. The scope
    # and the signature travel with it, so any later edit to a panel's method,
    # transport or map retires it, and a one-panel pass cannot stand for the
    # others.
    return [PSCustomObject]@{
        Ok = $true; Backed = $false; Text = 'all responded'
        Scope = $scope
        Sig   = (Get-PassSignature -Panels $Answers)
    }
}

# One round: send a group of panels to one computer together, bring them back,
# ask once. Returns the names of the panels that did not do the right thing.
function Invoke-TestRound {
    param($Panels, $Stays, [string]$Target, $All, [string]$This,
          [string]$Config, [int]$Hold = 8)

    if (-not (Show-MovePreamble -Panels $Panels -Stays $Stays -Target $Target -This $This -Hold $Hold)) {
        return @('(skipped)')
    }
    return (Invoke-TestRoundBody -Panels $Panels -Target $Target -All $All -This $This `
                                 -Config $Config -Hold $Hold)
}

# ONE PANEL, ONE SWING: the preamble, the move, and the questions -- the shape
# every path that moves a panel takes (specs/configure.md 10.2). Returns the
# outcome, or $null when the person declined at the preamble, which reads as
# `not checked` rather than as a failure.
function Invoke-PanelSwing {
    param($Answer, $All, [string]$Target, [string]$This, [string]$Config, [int]$Hold = 8)

    $cand = Get-SwingCandidate -Answer $Answer -Target $Target -This $This
    if (-not $cand) { return $null }

    # What stays is measured against every managed, ATTACHED panel, not just
    # this one: a panel nobody asked to check is still somewhere to put a window.
    $stays = @(Get-AttachedManaged -Panels $All | Where-Object { $_.Label -ne $Answer.Label })
    if (-not (Show-MovePreamble -Panels @($Answer) -Stays $stays -Target $cand.Name -This $This -Hold $Hold)) {
        return $null
    }
    Move-PanelsAndBack -Panels @($Answer) -Away @{ $Answer.Label = $cand.Value } `
                       -This $This -Config $Config -Hold $Hold
    return (Test-DisplayInput -Name $Answer.Name -CandidateName $cand.Name -ThisName $This `
                              -IsComputer:$cand.IsComputer)
}

# The half after the explaining: swing, then find out what happened. One
# question, and narrowing only on failure (specs/configure.md 10.3).
function Invoke-TestRoundBody {
    param($Panels, [string]$Target, $All, [string]$This, [string]$Config, [int]$Hold)

    $away = @{}
    foreach ($a in $Panels) { $away[$a.Label] = $a.Map[$Target] }
    Move-PanelsAndBack -Panels $Panels -Away $away -This $This -Config $Config -Hold $Hold

    $names = @($Panels | ForEach-Object { $_.Name })
    Write-Host ''
    $q = if ($Panels.Count -eq 1) { "  Did $($names[0]) show $Target, then come back?" }
         else                     { "  Did all of them show $Target, then come back?" }
    if (Read-YesNo $q $true) { return @() }

    # Only now does anyone have to think. One panel needs no narrowing question.
    $wrong = $Panels
    if ($Panels.Count -gt 1) {
        Write-Host ''
        Write-Host '  Which ones did not?'
        $picked = Select-Many -Items $names -Detail @($Panels | ForEach-Object { $_.Label }) `
                              -DoneLabel 'Done'
        $wrong = @($picked | ForEach-Object { $Panels[$_] })
    }

    $bad = @()
    foreach ($a in $wrong) {
        $result = Test-OneComputer -Answer $a -All $All -This $This -Target $Target -Config $Config
        if ($null -eq $result) { $bad += '(skipped)' }
        elseif (-not $result) { $bad += $a.Name }
    }
    return $bad
}

# THE FOUR OUTCOMES, asked after a swing has already happened --
# specs/configure.md 10.4. The moving is Invoke-PanelSwing's, so that every
# path that moves a panel goes through one preamble and one swing (10.2).
#
# Returns 0 correct, 1 changed to the WRONG thing, 2 changed and did not come
# back, 3 nothing happened. Four outcomes, because with a computer named the
# test asserts something real ("did the LG show the Mac?") and being shown the
# wrong computer is a wrong MAPPING, which is neither a wrong channel nor a
# wrong value for this one. Testing a bare input value cannot tell 0 from 1, so
# -IsComputer is what says which question is being asked.
#
# [CmdletBinding()] IS LOAD-BEARING. A simple function swallows an undeclared
# named argument into $args without a word, so a caller left on an old parameter
# name goes on working and quietly loses the switch -- twice now
# (windows/AGENTS.md). For a switch that decides which question a human is asked
# about their own monitors, loud is the only safe direction. The suite's stubs
# of this function carry it for the same reason.
function Test-DisplayInput {
    [CmdletBinding()]
    param([string]$Label, [string]$Name, [string]$Candidate, [string]$CandidateName,
          [string]$Current, [string]$ThisName, [switch]$IsComputer,
          [int]$Hold = 8, [string]$Config = $CONFIG)

    # Asked as it happened, in the order it happened: did it go, and did it come
    # back. One question with four answers made the reader hold every failure in
    # mind at once to find their own.
    $back = if ($ThisName) { $ThisName } else { 'this computer' }

    Write-Host ''
    Write-Host ("  Did the {0} change to {1}, and back to {2}?" -f $Name, $CandidateName, $back)
    $pick = Select-One -Default 0 -Items @(
        ("Yes, and it changed back to $back"),
        ("Yes, but it did not change back to $back"),
        'No'
    ) -Detail @(
        'everything works',
        "the input for $back is wrong",
        ''
    )
    if ($pick -eq 0) { return 0 }
    if ($pick -eq 1) { return 2 }

    # Only a "no" needs taking apart, and only when there was a computer to
    # expect: testing a bare input value, any change at all proves the transport.
    if (-not $IsComputer) { return 3 }

    Write-Host ''
    Write-Host ("  Did the {0} change at all?" -f $Name)
    $pick = Select-One -Default 1 -Items @(
        ("Yes, but it was not $CandidateName"),
        'No, nothing happened'
    ) -Detail @(
        "that input is not $CandidateName",
        'this panel does not answer on this channel'
    )
    return $(if ($pick -eq 0) { 1 } else { 3 })
}

# One panel, one computer: send it there, bring it back, act on what the human
# saw. Fixes retry IN PLACE, because bouncing out to the review menu to change
# one value and come back is a worse way to say "try that again".
#
# ONE RETRY PER FIX, then take the answer (specs/configure.md 10.4).
function Test-OneComputer {
    param($Answer, $All, [string]$This, [string]$Target, [string]$Config, [int]$Attempt = 1)

    # Written before every attempt: escalating to a dialect changes the method,
    # and the switcher reads the method from the file.
    Write-ConfigFile -Path $Config -Displays $All -Devices @() -Tier 'user' -This $This -Existing @{}

    # THE SWING, preamble included, whether this is the first attempt, a retry
    # after a repair, or the transport-only check made when no other computer is
    # configured (specs/configure.md 10.2 and 10.7).
    $outcome = Invoke-PanelSwing -Answer $Answer -All $All -Target $Target -This $This `
                                 -Config $Config
    # Null means untested, including a declined retry. Only the human's
    # confirmation can make this a pass (specs/configure.md 10.8).
    if ($null -eq $outcome) { return $null }
    if ($outcome -eq 0) { return $true }
    if ($Attempt -ge 2) { return $false }   # bounded: one retry per fix

    # 1: the panel obeys and the value for this computer is right -- that input
    # is just not the computer we thought.
    if ($outcome -eq 1 -and $Target) {
        Write-Host ''
        Write-Host ('  So that input is not {0}. Which one is?' -f $Target)
        $taken = @{}
        foreach ($m in $Answer.Map.Keys) { if ($m -ne $Target) { $taken[$Answer.Map[$m]] = $m } }
        $v = Read-InputValue -Table (Get-InputTable -Method $Answer.Method -Map $Answer.Map) `
                             -Default $Answer.Map[$Target] -Taken $taken -AllowNone `
                             -Method $Answer.Method `
                             -Prompt ("On the {0}, which input is '{1}' on?" -f $Answer.Name, $Target)
        Set-PanelAnswer -Panel $Answer -On $Target -Value ([string]$v) | Out-Null
        if ($null -eq $v) { return $null }
        return (Test-OneComputer -Answer $Answer -All $All -This $This -Target $Target -Config $Config -Attempt ($Attempt + 1))
    }

    # 2: the panel obeys, so the channel is right; the value for THIS computer
    # is not.
    if ($outcome -eq 2) {
        Write-Host ''
        Write-Host ('  So {0} responds -- the channel is right. The input for this' -f $Answer.Name)
        Write-Host '  computer is not. Use that monitor''s own buttons to bring it back,'
        Write-Host '  then tell me which input that is.'
        Write-Host ''
        if (Read-YesNo '  Do you know which input it is?' $true) {
            # -Taken, like every other input question: without it this one repair
            # let someone pick an input another computer already held, and the
            # writer then emitted the same key twice while the reader kept one
            # (specs/configure.md 6.1).
            $taken = @{}
            foreach ($m in $Answer.Map.Keys) { if ($m -ne $This) { $taken[$Answer.Map[$m]] = $m } }
            $v = Read-InputValue -Table (Get-InputTable -Method $Answer.Method -Map $Answer.Map) `
                -Default $Answer.Map[$This] -Taken $taken -Method $Answer.Method `
                -Prompt ("On the {0}, which input is '{1}' on?" -f $Answer.Name, $This)
            Set-PanelAnswer -Panel $Answer -On $This -Value ([string]$v) | Out-Null
        } else {
            $found = Invoke-BlindWalk -Answer $Answer -Config $Config -OtherPanels (@($All).Count - 1)
            if (-not $found) { return $false }
            Set-PanelAnswer -Panel $Answer -On $This -Value $found | Out-Null
        }
        return (Test-OneComputer -Answer $Answer -All $All -This $This -Target $Target -Config $Config -Attempt ($Attempt + 1))
    }

    # 3: nothing at all. The channel is wrong, so the other channel is the thing
    # to try -- OFFERED, from documented values, never probed
    # (specs/configure.md 10.5).
    #
    # SYMMETRIC: 6.2 lets someone choose the manufacturer method up front, so a
    # panel can arrive here already on it, and telling that person "no
    # manufacturer values are known" would be false and a dead end.
    $d   = $DIALECTS['{0:X4}' -f $Answer.EdidVendor]
    $alt = $null

    if ($d -and $Answer.Method -ne $d.Method) {
        Write-Host ''
        Write-Host ('  {0} did not answer the standard channel. It is {1}, and some {1}' -f $Answer.Name, $d.What)
        Write-Host '  panels put input switching on a manufacturer channel instead. These'
        Write-Host ('  values are documented for {0}, and are the only ones that will be' -f $d.What)
        Write-Host '  sent -- nothing is guessed at on a manufacturer channel:'
        $alt = @{ Method = $d.Method; Yes = ("Yes, try the {0} channel" -f $d.What); Values = $d.Inputs }
    }
    elseif ($Answer.Method -ne 'standard') {
        # On a manufacturer channel, so standard is what is left. Reached from
        # 6.2's up-front choice and from a hand-edited config naming a method no
        # table knows.
        $what = $(if ($d) { $d.What } else { $Answer.Mfg })
        Write-Host ''
        Write-Host ('  {0} is on {1}''s own method and did not answer it. The standard method' -f $Answer.Name, $what)
        Write-Host '  is the other thing to try. It is what nearly every monitor takes,'
        Write-Host '  and these are its values:'
        $alt = @{ Method = 'standard'; Yes = 'Yes, try the standard method'; Values = $MCCS_INPUTS }
    }

    if ($alt) {
        # The values are shown BEFORE the question is asked, in both directions.
        Write-Host ''
        foreach ($n in $alt.Values.Keys) { Write-Host ('    {0,-14} {1}' -f $n, $alt.Values[$n]) }
        Write-Host ''
        $go = Select-One -Default 0 -Escapable `
                  -Items @($alt.Yes, 'No, leave this monitor out') `
                  -Detail @('and say which input each computer is on',
                            'everything else stays configured')
        if ($go -ne 0) { return $false }

        # Every value in the old map addressed a channel that does not work, so
        # the map starts again. Set-PanelAnswer clears it as part of taking the
        # new method, which is why the names are captured first.
        $keep = @($Answer.Map.Keys)
        Set-PanelAnswer -Panel $Answer -Method $alt.Method | Out-Null
        $taken = @{}
        foreach ($m in $keep) {
            $v = Read-InputValue -Table (Get-InputTable -Method $alt.Method -Map $Answer.Map) `
                                 -Taken $taken -AllowNone:($m -ne $This) -Method $alt.Method `
                                 -Prompt ("On the {0}, which input is '{1}' on?" -f $Answer.Name, $m)
            if ($null -ne $v) { Set-PanelAnswer -Panel $Answer -On $m -Value $v | Out-Null; $taken[$v] = $m }
        }
        return (Test-OneComputer -Answer $Answer -All $All -This $This -Target $Target -Config $Config -Attempt ($Attempt + 1))
    }

    # On standard, and nothing else is documented for this vendor.
    Write-Host ''
    Write-Host ('  {0} did not answer the standard channel, and no manufacturer values' -f $Answer.Name)
    Write-Host ('  are known here for {0}. That panel may not support DDC/CI input' -f $Answer.Mfg)
    Write-Host '  switching at all, or may use a channel nobody has documented.'
    Write-Host ''
    Write-Host '  Everything else is still configured; this monitor just will not follow'
    Write-Host '  the switch. Leave it out with Monitors -> "Manage this monitor? no".'
    return $false
}

# --- blind value-walking, the last resort -------------------------------------

# Send one value and ask whether the panel came back. The building block of
# blind walking, and the only place a value is sent without knowing what it
# means.
function Test-OneValue {
    param([string]$Label, [string]$Name, [string]$Value, [string]$Config, [int]$Hold = 6)

    Write-Host ''
    Write-Host ('  Trying {0} ...' -f $Value)
    Send-Input -Label $Label -Value $Value -Config $Config
    Start-Sleep -Seconds $Hold
    return (Read-YesNo ("  Is the {0} showing THIS computer now?" -f $Name) $false)
}

# Send each standard input value in turn until the panel comes back --
# specs/configure.md 10.6, which permits exactly this and no more: STANDARD
# DDC/CI ONLY, MCCS values only, one at a time, never on a manufacturer
# sidechannel, and refused outright when it would take the last display.
#
# Offered, never automatic, and the cost is stated first: every wrong guess
# takes the panel somewhere else, and if none is right it stays there.
function Invoke-BlindWalk {
    param($Answer, [string]$Config, [int]$OtherPanels)

    Write-Host ''
    Write-Host '--- try the standard values one at a time ---'
    if ($Answer.Method -ne 'standard') {
        Write-Host '  Only offered on the standard channel. A manufacturer channel takes'
        Write-Host '  values from documentation or from you -- never from us guessing.'
        return $null
    }
    if ($OtherPanels -lt 1) {
        # Hard rule 4: with nothing else on this computer, a wrong guess blacks
        # out the screen this question is printed on.
        Write-Host ('  Not offered: the {0} is the only monitor on this computer, so a' -f $Answer.Name)
        Write-Host '  wrong guess would black out the screen you are reading. Use the'
        Write-Host '  monitor''s own buttons to see which input this computer is on, then'
        Write-Host '  enter that value.'
        return $null
    }

    Write-Host ('  I will send each standard input value to the {0} in turn and ask' -f $Answer.Name)
    Write-Host '  whether it came back. Your other monitor stays on this computer'
    Write-Host '  throughout, so you can keep reading this.'
    Write-Host ''
    Write-Host '  COST: every wrong value moves that panel to another input. If none of'
    Write-Host '  them is right it will stay on the last one, and you will need the'
    Write-Host '  monitor''s own buttons to bring it back.'
    if (-not (Read-YesNo '  Go ahead?' $false)) { return $null }

    foreach ($n in $MCCS_INPUTS.Keys) {
        if (Test-OneValue -Label $Answer.Label -Name $Answer.Name -Value $MCCS_INPUTS[$n] -Config $Config) {
            Write-Host ''
            Write-Host ('  Found it: {0} is {1} on this panel.' -f $MCCS_INPUTS[$n], $n)
            return $MCCS_INPUTS[$n]
        }
    }

    Write-Host ''
    Write-Host '  None of the standard values brought it back. Use the monitor''s buttons'
    Write-Host '  to return it to this computer.'
    return $null
}

# --- checking the triggers ----------------------------------------------------

# Watch for one real arrival of the chosen devices -- specs/configure.md 11.
#
# Asks event-watch.ps1 rather than re-deriving presence: it owns that question,
# and a second implementation in the installer would be free to disagree with
# the one that actually fires, which is the worst possible place for a
# disagreement since this check exists to say the trigger works.
function Invoke-TriggerTest {
    param([string[]]$Devices, $Answers, [string]$This, [switch]$Pull)

    # Nothing to watch for is not a check that fails -- it is a check that
    # cannot be run.
    if (@($Devices).Count -eq 0) {
        Write-Host ''
        Write-Host '  No trigger devices are chosen yet -- pick some first.'
        return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = 'no devices chosen' }
    }

    $ew = Get-Sibling 'event-watch.ps1'

    Write-Host ''
    Write-Host '--- test the trigger ---'
    Write-Host '  Flip your switch AWAY from this computer, then back again. The way'
    Write-Host '  back is what a trigger is: the devices ARRIVING here.'
    if ($Pull) {
        Write-Host ''
        Write-Host '  When they do, the monitors will be pulled here for real, using the'
        Write-Host '  values you just checked. That is the whole thing working end to end.'
    } else {
        Write-Host ''
        Write-Host '  The arrival will be reported but the monitors will NOT be moved:'
        Write-Host '  check them first (the row above) and this becomes the real thing.'
    }

    # THE INSTALLED WATCHER IS STOOD DOWN FOR THIS CHECK. On a re-run it would
    # otherwise see the same flip and pull against the SAVED config, after the
    # one-shot's pull, so a correct new answer would read as the monitors
    # failing. Where standing it down would need a password the person is told
    # instead, before they flip: a check must not raise a prompt of its own.
    $paused = $false
    $prior = $null
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('trigger-kvm-trig-{0}.cfg' -f $PID)
    $code = 1
    try {
        switch (Get-WatcherPauseMode) {
            'can' {
                # The lock confirms the pause; the mode only describes whether
                # this caller is allowed to change the task.
                $prior = Get-WatcherState
                $paused = Suspend-Watcher
                Write-Host ''
                if ($paused) {
                    if ($prior.Running) { Write-Host '  The running watcher is paused for this check.' }
                    else { Write-Host '  The installed watcher is stood down for this check.' }
                } else {
                    Write-Host '  The running watcher will also fire, using the saved configuration.'
                }
            }
            'needs-admin' {
                Write-Host ''
                Write-Host '  The running watcher will also fire, using the saved configuration.'
            }
        }

        # A throwaway config: the answers are not written yet, and pulling
        # against the saved config would use the previous monitor values.
        Write-ConfigFile -Path $tmp -Displays $Answers -Devices $Devices -Tier 'user' -This $This -Existing @{}

        # Piped to the host, not returned: Invoke-Sibling emits the child's
        # stdout on the success stream, so letting it fall out of this function
        # makes the caller receive [those lines..., the result object].
        Invoke-Sibling -Script $ew -Arguments @('-TestTrigger', '-Device', ($Devices -join ','),
                                                '-Config', $tmp) |
            ForEach-Object { Write-Host "$_" }
        $code = $LASTEXITCODE

        if ($code -eq 0 -and $Pull) {
            Write-Host ''
            Write-Host '  Pulling the monitors here...'
            Invoke-Sibling -Script (Get-Sibling 'trigger-kvm.ps1') -Arguments @('pull', '-Config', $tmp) |
                ForEach-Object { Write-Host "$_" }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        # Restored on EVERY way out, including the ones that throw: leaving the
        # task disabled would stop the switch working and say nothing.
        if ($null -ne $prior) { Resume-Watcher -Prior $prior }
    }

    if ($code -ne 0) {
        Write-Host ''
        Write-Host '  Nothing arrived, so these may be the wrong devices -- or they may not'
        Write-Host '  be on the switch at all. Pick Triggers again to change them.'
        return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = 'no arrival seen' }
    }

    if (-not $Pull) { return [PSCustomObject]@{ Ok = $true; Backed = $false; Text = 'arrival seen' } }

    Write-Host ''
    if (Read-YesNo '  Did the monitors come back to this computer?' $true) {
        return [PSCustomObject]@{ Ok = $true; Backed = $false; Text = 'fired, monitors followed' }
    }
    Write-Host ''
    Write-Host '  The trigger fired, so the devices are right. Something about the'
    Write-Host '  monitors is not -- check them again from the row above.'
    return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = 'fired, but the monitors did not follow' }
}
