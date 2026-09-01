# The install path's decisions, taken apart where they can be reached.
#
# Registering a task, editing a PATH and deleting a program directory are all
# things a suite must not actually do, so what is testable is the thing DECIDED
# just before: the command the task will carry, the arguments the watcher hands
# the switcher, and whether a directory is ours to remove.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'install.ps1'     -Functions @('Get-WatcherCommand')
Import-Subject -Script 'event-watch.ps1' -Functions @('Get-SwitcherArguments')

# ---- the task action carries every path, the config included -----------------
#
# An at-startup S4U task can run before the user's profile is loaded, so
# %LOCALAPPDATA% in the watcher is not necessarily the installing user's. A
# watcher that read the wrong config would find no trigger.device, throw into a
# console-less wscript host, and be relaunched every minute by the self-heal
# trigger to do it again.

$cmd = Get-WatcherCommand -Watcher 'C:\p\event-watch.ps1' -Switcher 'C:\p\trigger-kvm.ps1' `
                          -LogFile 'C:\l\trigger-kvm.log' -ConfigFile 'C:\l\config'

Assert-Match $cmd '-File "C:\\p\\event-watch\.ps1"'      'the watcher, by absolute path'
Assert-Match $cmd '-Exec "C:\\p\\trigger-kvm\.ps1"'      'the switcher it runs'
Assert-Match $cmd '-Arg pull'                            'and pull, never another computer'
Assert-Match $cmd '-LogFile "C:\\l\\trigger-kvm\.log"'
Assert-Match $cmd '-Config "C:\\l\\config"'              'and WHICH config, resolved at registration'

# A profile path with a space in it is the common case, not an exotic one.
$cmd = Get-WatcherCommand -Watcher 'C:\Users\First Last\p\event-watch.ps1' `
                          -Switcher 'C:\Users\First Last\p\trigger-kvm.ps1' `
                          -LogFile 'C:\Users\First Last\l\trigger-kvm.log' `
                          -ConfigFile 'C:\Users\First Last\l\config'
Assert-Match $cmd '-Config "C:\\Users\\First Last\\l\\config"' 'every path is quoted'

# ---- and the watcher hands the same answer to the switcher -------------------
#
# The other half of the same defect: the watcher knows which config it was told
# to read, and a child left to re-derive it answers for whoever the child runs
# as.

$a = @(Get-SwitcherArguments -Switcher 'C:\p\trigger-kvm.ps1' -Verb 'pull' `
                             -LogFile 'C:\l\trigger-kvm.log' -ConfigFile 'C:\l\config')
$joined = $a -join ' '

Assert-Match $joined '-File "C:\\p\\trigger-kvm\.ps1" pull' 'the verb follows the file, positionally'
Assert-Match $joined '-Config "C:\\l\\config"'              'and the config is passed down, not re-derived'
Assert-Match $joined '-LogFile "C:\\l\\trigger-kvm\.log"'   'so its lines land beside the watcher''s'

# Run by hand with no log, the switcher must not be handed an empty -LogFile:
# powershell -File would take the next argument as its value.
$a = @(Get-SwitcherArguments -Switcher 'C:\p\trigger-kvm.ps1' -Verb 'pull' `
                             -LogFile '' -ConfigFile 'C:\l\config')
Assert-NoMatch ($a -join ' ') '-LogFile' 'an absent log is absent, not an empty flag'
Assert-Match   ($a -join ' ') '-Config'  'and the config is still handed over'

exit 0
