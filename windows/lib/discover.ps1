# What this computer can see right now: the displays, and the devices that could
# be a trigger. The `discover` verb, and the lists the walkthrough picks from.
#
# BOTH ENUMERATIONS ARE ASKED OF THE SCRIPT THAT OWNS THEM -- trigger-kvm.ps1
# for displays, event-watch.ps1 for USB and Bluetooth. The watcher owns the
# device bindings because they are what matches a token on every presence sweep,
# and a second copy here would drift with a nasty shape: a walkthrough writing a
# token the watcher cannot find.

# One `trigger-kvm list -Raw` line -> the row the walkthrough and `status` both
# read. ONE parser: the fields are APPEND-ONLY, so every reader has to default
# the ones an older switcher does not send, and a rule like that only stays
# consistent in a single place.
#
# Returns $null for a line that is not a row, so a caller filters rather than
# guarding on field counts itself.
function ConvertFrom-DisplayRow {
    param([string]$Line)

    $f = "$Line" -split '\|'
    if ($f.Count -lt 4) { return $null }
    return [PSCustomObject]@{
        EdidVendor  = [Convert]::ToInt32($f[0], 16)
        EdidProduct = [Convert]::ToInt32($f[1], 16)
        Mfg         = $f[2]
        Connector   = $f[3]
        Name        = $(if ($f.Count -ge 6) { $f[5] } else { '' })
        # Which transports can SEE this panel, comma-joined. Absent means nvapi,
        # the same default specs/config-format.md gives the key, so an installer
        # newer than the switcher beside it asks nothing.
        Transports  = $(if ($f.Count -ge 7 -and $f[6]) {
                            @($f[6] -split ',' | Where-Object { $_ })
                        } else { @('nvapi') })
        # How many ATTACHED panels answer to this id (specs/configure.md 6.4).
        # Absent means one, which is what every desk without twins reports.
        Panels      = $(if ($f.Count -ge 8 -and $f[7] -match '^\d+$') {
                            [int]$f[7]
                        } else { 1 })
    }
}

# --- naming a device ----------------------------------------------------------

# Names Windows hands out when it has nothing specific to say. Matching one
# identifies a CLASS of device, not a device.
$GENERIC_NAMES = '^(USB Input Device|USB Composite Device|USB Device|HID-compliant [a-z ]+|Generic USB [A-Za-z]+|USB Attached SCSI \(UAS\) Mass Storage Device)$'

# The best of the names one device reports about itself
# (specs/configure.md 7.1: ask for the best name a platform has, not the first).
#
# It TESTS THE NAME. Ranking by how specific a node's device CLASS is inverts
# the proxy, because HID nodes are exactly the ones Windows names generically:
# on this desk that made a keyboard's row read `USB Input Device` while a
# sibling node already said `G915 X LIGHTSPEED TKL`.
#
# A NAME BEGINNING "USB " IS DESCRIBING THE BUS, NOT THE DEVICE -- true of every
# generic name measured here and of none of the manufacturers' own strings. It
# beats keeping a list of weak names, which would only ever describe the desks
# somebody happened to own.
function Get-BestDeviceName {
    param([string[]]$Names)

    $all = @($Names | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($all.Count -eq 0) { return '' }

    $named = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES -and $_ -notmatch '^USB ' })
    if ($named.Count -gt 0) { return $named[0] }
    $good = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES })
    if ($good.Count -gt 0) { return $good[0] }
    # Everything it reports is generic. Say the generic thing rather than
    # nothing: an empty row is worse than a vague one.
    return $all[0]
}

# What each VID:PID presents itself as, from its HID children -- the `HID\VID_`
# nodes the USB pass skips because it matches `USB\` only
# (specs/configure.md 7.1).
#
# It also shows when one dongle carries both a keyboard and a mouse, which is a
# fact people need: that is ONE vendor+product and therefore one row, and there
# is no way to trigger on just the mouse.
function Get-DeviceRoles {
    param($Devices)

    $roles = @{}
    foreach ($d in @($Devices)) {
        if ("$($d.InstanceId)" -notmatch '^HID\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
        $key = ('usb:{0}:{1}' -f $Matches[1], $Matches[2]).ToLower()
        # Mouse and Keyboard only. Every such device also presents a bare
        # HIDClass node, which says nothing a person can use.
        if ($d.Class -notin @('Mouse', 'Keyboard')) { continue }
        $r = "$($d.Class)".ToLower()
        if (-not $roles.Contains($key)) { $roles[$key] = @() }
        if ($roles[$key] -notcontains $r) { $roles[$key] += $r }
    }
    return $roles
}

# WHAT THE DEVICE IS: its name, and what it presents itself as. Built once,
# because both places that show candidates want exactly this.
#
# The STATE is deliberately not in here: connected-vs-paired is a fact about
# right now, not about what a device IS, and folding it in made one column carry
# both and pushed the id column out of alignment for every row beneath.
function Get-CandidateLabel {
    param($Candidate)
    $s = "$($Candidate.Name)"
    if ($Candidate.Roles) { $s += ('  ({0})' -f (@($Candidate.Roles) -join ', ')) }
    # A device that cannot be told from its twin is not a device you can pick,
    # and the row says so rather than looking like a choice
    # (specs/detector.md 4.1: no token is written where none is unique).
    if ($Candidate.Ambiguous) { $s += '  [cannot be told from its twin]' }
    return $s
}

# Candidate trigger devices: USB attached right now, plus every PAIRED
# Bluetooth device (specs/configure.md 7).
#
# "Right now" does most of the work for USB, and it comes from how installing
# happens: you run this on the computer currently holding the peripherals, so
# whatever travels is present. Bluetooth is the opposite and deliberately so --
# a trigger fires on ARRIVAL, so the device that is disconnected right now is
# precisely the one that will produce one. Show the state; never filter on it.
#
# ONE list across both, with a column saying which. You think "the stuff that
# moves when I switch", not "my USB things and separately my Bluetooth things".
function Get-TriggerCandidates {
    # Fields from -ListUsb: container|vid|pid|token|where|name, one line per
    # candidate name. One row per PHYSICAL device (specs/detector.md 4.1).
    $devices = @{}
    $ew = Get-Sibling 'event-watch.ps1'
    foreach ($line in (Invoke-Sibling -Script $ew -Arguments @('-ListUsb') 2>$null)) {
        $f = "$line" -split '\|', 6
        if ($f.Count -lt 6) { continue }
        $key = ('usb:{0}:{1}' -f $f[1], $f[2]).ToLower()
        # A failed enumeration is not addressable at all.
        if ($key -like 'usb:0000:*') { continue }
        $id = '{0}|{1}' -f $f[0], $key
        if (-not $devices.Contains($id)) {
            $devices[$id] = [PSCustomObject]@{
                Container = $f[0]; Key = $key; Tokens = @(); Names = @(); Where = $f[4]
            }
        }
        if ($f[3] -and $devices[$id].Tokens -notcontains $f[3]) { $devices[$id].Tokens += $f[3] }
        if ($f[5] -and $devices[$id].Names  -notcontains $f[5]) { $devices[$id].Names  += $f[5] }
    }

    # Roles come from the HID children, which the USB listing never sees. Cheap,
    # and the most recognisable thing on a row.
    $roles = Get-DeviceRoles -Devices @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)

    # A VENDOR:PRODUCT PAIR CAN NAME MORE THAN ONE DEVICE, so the token that
    # distinguishes them is chosen HERE, per id, where the other candidates are
    # visible -- specs/detector.md 4.1's writer rule. Choosing the "best" name
    # per device in isolation is not enough: measured on this desk both
    # receivers report `usb-receiver` and only one reports `g915-x-lightspeed-tkl`.
    $usb = @()
    foreach ($grp in ($devices.Values | Group-Object Key)) {
        $mine  = @($grp.Group)
        $alone = ($mine.Count -eq 1)
        foreach ($d in $mine) {
            # THE WRITER RULE, in its three cases -- specs/detector.md 4.1. It
            # chooses for UNIQUENESS, not for quality.
            $token  = ''
            $shared = $false
            if (-not $alone) {
                # 1. A token held by exactly ONE device here, written alone. The
                #    spot is then never consulted when matching, so a device
                #    moved to another socket still matches.
                $token = @($d.Tokens | Where-Object {
                    $t = $_
                    (@($mine | Where-Object { $_.Tokens -contains $t }).Count -eq 1)
                } | Select-Object -First 1)
                if ($token -isnot [string]) { $token = [string]$token }

                # 2. Every candidate token is shared, but the devices sit at
                #    DIFFERENT PLACES: the shared token PLUS where. `where` is
                #    never written without a token, so this is the only path
                #    that produces one.
                if (-not $token -and $d.Where) {
                    $sameSpot = @($mine | Where-Object { $_.Container -ne $d.Container -and $_.Where -eq $d.Where })
                    if ($sameSpot.Count -eq 0) {
                        $token = @($d.Tokens | Select-Object -First 1)
                        if ($token -isnot [string]) { $token = [string]$token }
                        $shared = [bool]$token
                    }
                }

                # 3. Nothing distinguishes them: the BARE ID, because a
                #    placeholder would match nothing and never fire, which is
                #    worse than matching all of them. The row says so.
            }
            $name = Get-BestDeviceName -Names $d.Names
            if (-not $name) { continue }
            # NOTHING IS FILTERED BY NAME, hubs included -- specs/configure.md
            # 7.1. A hub that never moves is a bad trigger and a visible one;
            # hiding it made the list disagree with what `discover` had shown a
            # moment earlier, and the only judgement a name can support is the
            # person's. The one thing withheld is a node that is not a device at
            # all, which is the failed-enumeration check above.

            # THE ENTRY THIS ROW WOULD BE WRITTEN AS, and the IDENTITY it is
            # matched by, which are two different things when a token is shared.
            #
            # Key is the identity: no spot, because a device that moved sockets
            # is still the same entry, and that is what the "currently a
            # trigger" marker and the config round trip compare.
            #
            # Entry adds the spot in case 2 above, where the token alone cannot
            # say which device this row is. Without it two rows would be written
            # identically and picking either would configure the other.
            $ident = $d.Key + $(if ($token) { "@$token" } else { '' })
            $usb += [PSCustomObject]@{
                Key   = $ident
                Entry = $ident + $(if ($token -and $shared -and $d.Where) { "@$($d.Where)" } else { '' })
                Bus   = 'USB'
                Name  = $name
                Roles = @($roles[$d.Key] | Where-Object { $_ })
                Class = ''
                Spot  = $d.Where
                Twinned = (-not $alone)
                Ambiguous = ((-not $alone) -and (-not $token))
                # Case 2: the token is shared and the SPOT is what makes this
                # row a different answer from its twin's.
                Shared = $shared
                State = ''
                # Rank answers only HOW LIKELY THIS IS TO TRAVEL. It never
                # picks the row's name; see Get-BestDeviceName.
                Rank  = $(if ($roles[$d.Key]) { 0 }
                          elseif ($name -match 'Audio|Camera|Webcam') { 1 }
                          else { 3 })
            }
        }
    }

    # PnP cannot answer connected-vs-paired at all: a paired device keeps its
    # node for years after it last connected (windows/AGENTS.md). event-watch.ps1
    # owns the Bluetooth binding, so ask it -- a drifted struct layout is a
    # marshalling bug that presents as WRONG DATA rather than an error.
    $bt = @()
    try {
        $rows = Invoke-Sibling -Script (Get-Sibling 'event-watch.ps1') `
                               -Arguments @('-ListBluetooth') 2>$null
        foreach ($row in $rows) {
            $parts = "$row" -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            $bt += [PSCustomObject]@{
                Key = 'bt:' + $parts[0]; Entry = 'bt:' + $parts[0]
                Bus = 'BT'; Name = $parts[2]; Class = 'Bluetooth'; Shared = $false
                # Present and empty rather than absent: Set-StrictMode makes
                # reading a property that is not there terminating, and every
                # consumer of a candidate reads these. A Bluetooth address
                # already names one device, so none of the disambiguation
                # applies and the classic API reports no HID usage page.
                Roles = @()
                Spot = ''; Twinned = $false; Ambiguous = $false
                State = $(if ($parts[1] -eq 'True') { 'connected now' } else { 'paired, not connected' })
                Rank = 1
            }
        }
    } catch {
        # No radio, or the API is unavailable. Not a reason to fail discovery.
        Write-Log "note: Bluetooth enumeration unavailable ($($_.Exception.Message))"
    }

    return @(@($usb) + @($bt) | Sort-Object Rank, Name)
}

# The `discover` verb: what is attached, in the form the config wants.
function Invoke-Discover {
    Write-Host ''
    Write-Host '=== displays on this computer ==='
    # Piped to the host, not returned: Invoke-Sibling emits the child's stdout
    # on the SUCCESS stream, so letting it fall out of this function would make
    # it part of the verb's return value -- which is the exit code.
    Invoke-Sibling -Script (Get-Sibling 'trigger-kvm.ps1') -Arguments @('list', '-Config', $CONFIG) |
        ForEach-Object { Write-Host "$_" }

    Write-Host ''
    Write-Host '=== devices that could be a trigger ==='
    Write-Host ''
    Write-Host 'The trigger is whatever MOVES when you flip the switch. Pick the ones that'
    Write-Host 'travel; USB rows are what is attached right now, Bluetooth rows what is paired.'
    Write-Host ''

    # Canonicalised to the same form the candidate keys use, through the one
    # parser every consumer uses. ONLY a well-formed entry earns a marker: the
    # watcher will not start on a malformed one, so marking its row as
    # configured would be a third screen disagreeing with the file.
    $cur = @()
    if (Test-Path -LiteralPath $CONFIG) {
        $c = Read-Config -Path $CONFIG
        if ($c.Contains('trigger.device')) {
            $cur = @(ConvertFrom-TriggerDevices $c['trigger.device'] |
                     Where-Object { $_.Ok } | ForEach-Object { $_.Identity })
        }
    }

    foreach ($d in (Get-TriggerCandidates)) {
        $mark = $(if ($cur -contains $d.Key) { ' <- currently a trigger' } else { '' })
        # Same order as the Triggers menu: what it is, then what identifies it.
        Write-Host ('  {0,-40} {1,-36} {2,-4}{3}{4}' -f (Get-CandidateLabel $d), $d.Key, $d.Bus,
                    $(if ($d.State) { '  ' + $d.State } else { '' }), $mark)
    }

    Write-Host ''
    Write-Host 'Bluetooth entries are every PAIRED device. One that is not connected right now'
    Write-Host 'is still a fine trigger -- better, even: a trigger fires on ARRIVAL, and that is'
    Write-Host 'what connecting is. USB rows are only devices attached at this moment, because'
    Write-Host 'PnP cannot tell you about a USB device that is somewhere else.'

    Write-Host ''
    Write-Host 'TRAP: match the FULL vendor+product pair. A keyboard and mouse often share a'
    Write-Host 'vendor id with a webcam and are always present, so a vendor-only match fires'
    Write-Host 'constantly.'
    Write-Host ''
    Write-Host 'To change what is watched:  trigger-kvm configure'
    Write-Host 'Or edit the config and then:  trigger-kvm restart'
    Write-Host ("config: {0}" -f $CONFIG)
}
