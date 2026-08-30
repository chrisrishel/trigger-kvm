# Rejected: autologin as a pre-login install tier

**Status:** rejected 2026-08-30, by the user, during the pre-login design discussion.
Do not re-propose without new information that addresses the blocking objection below.

## The idea

Pre-login switching is hard because the Windows switcher needs a desktop, and no
desktop exists before someone logs in. A way to sidestep the whole problem without
writing any privileged code: configure Windows to log the user in automatically at
boot and immediately lock the workstation.

The session then exists from boot, the existing logon Scheduled Task runs, the
watcher is alive behind the lock screen, and "pre-login" collapses into the
already-solved post-login case. It would have been a config change rather than a
rewrite of the most hazardous code path in the repo.

It was going to be offered as the middle rung of a permission ladder: no admin =
post-login only; autologin = covers boot; SYSTEM service = covers everything.

## Why it was rejected

**The blocking objection is not how well the credential is stored.** That distinction
matters, because it is what makes this a closed question rather than an engineering
problem someone can come back and solve.

There are two variants and they are not equally bad. Setting `DefaultPassword` in the
registry under `Winlogon` is literal plaintext and indefensible. Sysinternals
Autologon is meaningfully better -- it stores the password as an LSA secret,
encrypted at rest with the machine key -- but it is still recoverable by any local
administrator, and if the account is a Microsoft account, that is the credential
behind the user's email and cloud storage, not just this machine.

**The objection that actually settles it: autologin converts "powered on" into
"session live."** The machine boots straight into a logged-in session, with only a
lock screen that a script raced to put in front of it. DPAPI keys are unlocked and
the session is running. If the disk is BitLocker-protected in TPM-only mode -- the
common default -- physical possession gets an attacker to that point with no secret
at all.

That argument survives *perfect* credential storage. There is no version of this
that gets fixed by storing the password better. Hence: closed, not deferred.

**And it is worse as a published recommendation than as a personal choice.** This
repo is intended to be shareable. Shipping an installer tier that says "enable
autologin" hands that trade to people whose threat model is unknown -- laptops,
shared offices, corporate machines where it likely violates policy. The maintainer of
`haimgel/display-switch` declined an entire feature over precisely this concern
(issue #17: *"I'd prefer this to require as few permissions as possible, to allow
this to be run on corp computers where the user does not necessarily have admin
rights"*).

A repo whose documentation is this careful about which bytes are safe to put on a
monitor's service channel should not casually tell strangers to weaken
authentication.

## What it cost to drop, and what replaced it

Little, as it turns out. The tier had an incoherent trade anyway: **autologin fires
at boot and does nothing after a logoff**, so it covered only half of the requested
capability ("pre the first login or after a logoff") while being the hardest rung to
reason about.

Removing it leaves a legible ladder -- no admin means post-login only; admin buys
everything -- plus one live candidate that carries none of this objection:

**An S4U scheduled task** ("do not store password" in Task Scheduler) uses a service
ticket rather than cached credentials. It is explicitly *not* a credential-storage
approach, and it may run at startup as the user with no elevation at all.

**That question has since been answered, and the answer favours S4U further.**
Measured 2026-08-30: NVAPI reaches the GPU with no desktop, in session 0, including
from an at-startup task after a cold boot. So an S4U task delivers what this idea
was reaching for, without converting "powered on" into "session live". Its one cost
is admin rights *to register* -- at runtime it holds ordinary user privileges.

See [[nvapi-transport]] for the transport it depends on and the measurements.
