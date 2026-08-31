#!/bin/bash
#
# The REAL key reader, driven through a pty.
#
# menu.tests.sh stubs menu_read_key so it can script a sequence, which exercises
# every menu behaviour but deliberately not the decoding itself: turning bytes
# from a terminal into Up/Down/Enter/Escape. That decoding is the one part of
# the interactive half a stub cannot cover, and it is fiddly for a reason --
# bash 3.2 rejects a fractional `read -t`, so a lone Esc is told apart from an
# arrow's escape SEQUENCE using stty VTIME rather than a short read timeout.
#
# So: allocate a real pty, run a real menu in it, and type at it. python3 is
# only needed here, and the file skips itself if it is missing.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP  keys.tests.sh (no python3 to allocate a pty)" >&2
  exit 0
fi

fake_setup

# A menu, run for real, printing its answer where the harness can read it.
cat >"$FAKE_DIR/menu-demo.sh" <<EOS
#!/bin/bash
set -euo pipefail
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
menu_reset
menu_add alpha one
menu_add beta  two
menu_add gamma three
select_one --default 0 --escapable
printf 'PICK=%s\n' "\$MENU_PICK"
EOS
chmod +x "$FAKE_DIR/menu-demo.sh"

cat >"$FAKE_DIR/many-demo.sh" <<EOS
#!/bin/bash
set -euo pipefail
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
menu_reset
menu_add one   ''
menu_add two   ''
menu_add three ''
select_many --escapable
printf 'PICKED=%s ESC=%s\n' "\$MENU_PICKED" "\$MENU_ESCAPED"
EOS
chmod +x "$FAKE_DIR/many-demo.sh"

# Run a script on a pty, type the given bytes at it, return everything it wrote.
cat >"$FAKE_DIR/ptydrive.py" <<'EOS'
import os, pty, sys, time, select
script, keys = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["COLUMNS"] = "100"
    os.execv("/bin/bash", ["/bin/bash", script])
out = b""
# Give the menu a moment to draw before typing, then send each key with a gap so
# an escape sequence arrives as one burst and a lone Esc does not get a
# continuation byte glued to it.
time.sleep(0.4)
for k in keys.split(","):
    b = {"UP": b"\x1b[A", "DOWN": b"\x1b[B", "ENTER": b"\r",
         "ESC": b"\x1b", "SPACE": b" ", "Q": b"q"}[k]
    os.write(fd, b)
    time.sleep(0.25)
    while select.select([fd], [], [], 0)[0]:
        try:
            c = os.read(fd, 65536)
        except OSError:
            c = b""
        if not c:
            break
        out += c
deadline = time.time() + 3
while time.time() < deadline:
    r = select.select([fd], [], [], 0.2)[0]
    if not r:
        if b"PICK" in out:
            break
        continue
    try:
        c = os.read(fd, 65536)
    except OSError:
        break
    if not c:
        break
    out += c
os.close(fd)
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
sys.stdout.write(out.decode("utf-8", "replace"))
EOS

pty_run() { python3 "$FAKE_DIR/ptydrive.py" "$1" "$2"; }

# =============================================================================

it 'enter on a real terminal chooses the highlighted row'
out=$(pty_run "$FAKE_DIR/menu-demo.sh" ENTER)
assert_match "$out" 'PICK=0' "$out"

it 'the down-arrow escape sequence moves the cursor'
# \x1b[B, not a lone Esc. Telling those apart is the whole reason this file
# exists.
out=$(pty_run "$FAKE_DIR/menu-demo.sh" DOWN,ENTER)
assert_match "$out" 'PICK=1' "$out"

it 'the up-arrow escape sequence moves the other way, and wraps'
out=$(pty_run "$FAKE_DIR/menu-demo.sh" UP,ENTER)
assert_match "$out" 'PICK=2' "$out"

it 'two downs move two rows'
out=$(pty_run "$FAKE_DIR/menu-demo.sh" DOWN,DOWN,ENTER)
assert_match "$out" 'PICK=2' "$out"

it 'a LONE esc is not mistaken for an arrow, and backs out'
# This is the case bash 3.2 cannot handle with a read timeout: an arrow sends
# three bytes at once, a lone Esc sends one and nothing follows. stty VTIME
# gives the reader 0.1s to find out which.
out=$(pty_run "$FAKE_DIR/menu-demo.sh" ESC)
assert_match "$out" 'PICK=-1' "$out"

it 'an arrow after an esc is still read as an arrow, not two escapes'
out=$(pty_run "$FAKE_DIR/menu-demo.sh" DOWN,DOWN,UP,ENTER)
assert_match "$out" 'PICK=1' "$out"

it 'the menu actually draws on a real terminal'
out=$(pty_run "$FAKE_DIR/menu-demo.sh" ENTER)
assert_match "$out" 'alpha'
assert_match "$out" 'up/down move'
assert_match "$out" 'esc back'

it 'enter toggles a row in select_many on a real terminal'
out=$(pty_run "$FAKE_DIR/many-demo.sh" ENTER,DOWN,DOWN,DOWN,ENTER)
assert_match "$out" 'PICKED=0 ' "$out"

it 'space toggles on a real terminal too'
out=$(pty_run "$FAKE_DIR/many-demo.sh" SPACE,DOWN,DOWN,DOWN,ENTER)
assert_match "$out" 'PICKED=0 ' "$out"

it 'esc backs out of select_many on a real terminal'
out=$(pty_run "$FAKE_DIR/many-demo.sh" ESC)
assert_match "$out" 'ESC=1' "$out"

it 'gives the terminal back when it is done'
# A menu that returns leaving the terminal in raw mode leaves the shell it was
# called from unusable -- no echo, no line editing. Nothing else in the suite
# looks at the state AFTER the menu exits, and a mutation that removed the
# restore went unnoticed until this existed.
cat >"$FAKE_DIR/restore-demo.sh" <<EOS
#!/bin/bash
set -uo pipefail
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
before=\$(stty -a </dev/tty | grep -o '\-\?icanon')
menu_reset; menu_add alpha ''; menu_add beta ''
select_one --default 0 >/dev/null 2>&1
after=\$(stty -a </dev/tty | grep -o '\-\?icanon')
echoback=\$(stty -a </dev/tty | grep -o '\-\?echo ' | head -1)
printf 'PICK BEFORE=%s AFTER=%s ECHO=%s\n' "\$before" "\$after" "\$echoback"
EOS
chmod +x "$FAKE_DIR/restore-demo.sh"
out=$(pty_run "$FAKE_DIR/restore-demo.sh" ENTER)
assert_match "$out" 'AFTER=icanon' "the terminal must be canonical again: $out"
assert_match "$out" 'ECHO=echo'    "echo must be back on: $out"

it 'reads Enter on a terminal that does NOT translate carriage return'
# ICRNL is on by default, so Enter arrives as 10 and the 13 branch is never
# reached there. A terminal with -icrnl sends 13, and this is the only thing
# that exercises it.
cat >"$FAKE_DIR/nocr-demo.sh" <<EOS
#!/bin/bash
set -uo pipefail
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
stty -icrnl </dev/tty
menu_reset; menu_add alpha ''; menu_add beta ''
select_one --default 1
printf 'PICK=%s\n' "\$MENU_PICK"
EOS
chmod +x "$FAKE_DIR/nocr-demo.sh"
out=$(pty_run "$FAKE_DIR/nocr-demo.sh" ENTER)
assert_match "$out" 'PICK=1' "$out"

finish
