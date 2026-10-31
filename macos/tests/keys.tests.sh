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
  # This is the ONLY file that drives the real key-driven menus through a pty,
  # so skipping it leaves the whole interactive half of the walkthrough
  # untested -- which is why it must not read as a pass.
  exit_skipped 'keys.tests.sh needs python3 to allocate a pty'
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
import os, pty, sys, time, select, signal, fcntl, termios, struct
script, keys = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["COLUMNS"] = "100"
    if "TK_TEST_ROWS" in os.environ:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", int(os.environ["TK_TEST_ROWS"]), 80, 0, 0))
    # run.sh starts each test file as a background job of a non-interactive
    # shell, which leaves SIGINT ignored -- and an ignored-at-entry signal stays
    # ignored through exec and cannot be trapped by a script. The Ctrl-C case
    # needs a real interrupt, so the child gets the default dispositions back.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    os.execv("/bin/bash", ["/bin/bash", script])
out = b""
# Give the menu a moment to draw before typing, then send each key with a gap so
# an escape sequence arrives as one burst and a lone Esc does not get a
# continuation byte glued to it.
time.sleep(0.4)
for k in keys.split(","):
    if k == "RESIZE":
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 9, 55, 0, 0))
        k = "DOWN"
    b = {"UP": b"\x1b[A", "DOWN": b"\x1b[B", "ENTER": b"\r",
         "HOME": b"\x1b[H", "END": b"\x1b[F", "PGUP": b"\x1b[5~", "PGDN": b"\x1b[6~",
         "HOME1": b"\x1b[1~", "END4": b"\x1b[4~", "HOME7": b"\x1b[7~", "END8": b"\x1b[8~",
         "HOMEO": b"\x1bOH", "ENDO": b"\x1bOF",
         "ESC": b"\x1b", "SPACE": b" ", "Q": b"q", "INT": b"\x03"}[k]
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

# The driver hard-codes a width; COLUMNS lets a test ask for a narrow terminal,
# which is where overflow shows up.
sed -i '' 's/os.environ\["COLUMNS"\] = "100"/os.environ["COLUMNS"] = os.environ.get("TK_COLS", "100")/' "$FAKE_DIR/ptydrive.py"
export TK_COLS=80

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

it 'Home and End decode the common terminal sequences'
for pair in HOME:END HOME1:END4 HOME7:END8 HOMEO:ENDO; do
  out=$(pty_run "$FAKE_DIR/menu-demo.sh" "${pair#*:},ENTER")
  assert_match "$out" 'PICK=2' "$out"
  out=$(pty_run "$FAKE_DIR/menu-demo.sh" "DOWN,${pair%:*},ENTER")
  assert_match "$out" 'PICK=0' "$out"
done

it 'page keys stop at the ends on a real terminal'
out=$(pty_run "$FAKE_DIR/menu-demo.sh" PGDN,ENTER)
assert_match "$out" 'PICK=2' "$out"
out=$(pty_run "$FAKE_DIR/menu-demo.sh" END,PGUP,ENTER)
assert_match "$out" 'PICK=0' "$out"

it 'a small real terminal keeps both long menus reachable after resize'
cat >"$FAKE_DIR/viewport-demo.sh" <<EOS
#!/bin/bash
set -euo pipefail
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
menu_reset
for i in \$(seq 1 30); do menu_add "Fixture \$i" ''; done
if [ "\${TK_MANY:-}" = 1 ]; then
  select_many --escapable
  printf 'PICKED=%s ESC=%s\n' "\$MENU_PICKED" "\$MENU_ESCAPED"
else
  select_one --escapable
  printf 'PICK=%s\n' "\$MENU_PICK"
fi
EOS
out=$(TK_TEST_ROWS=12 pty_run "$FAKE_DIR/viewport-demo.sh" END,HOME,RESIZE,ENTER)
assert_match "$out" 'PICK=1' "$out"
assert_match "$out" 'of 30'
assert_no_match "$out" 'numbered input' 'the ordinary list fits the resized viewport'
assert_equal '' "$(printf '%s' "$out" | python3 -c 'import re,sys; print("oversized" if any(int(n)>11 for n in re.findall(r"\x1b\[(\d+)A",sys.stdin.read())) else "")')"
out=$(TK_TEST_ROWS=12 TK_MANY=1 pty_run "$FAKE_DIR/viewport-demo.sh" SPACE,END,HOME,RESIZE,SPACE,END,ENTER)
assert_match "$out" 'PICKED=0 1 ESC=0' "$out"
assert_no_match "$out" 'numbered input'

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

# =============================================================================
# Nothing a menu writes may exceed the width it laid out to
# =============================================================================
#
# This is the invariant behind a redraw that stays clean. A line longer than the
# width WRAPS; a wrapped line's tail is not cleared by the next frame, so the
# previous frame shows through at the right edge; and a line landing exactly on
# the terminal's fold is counted one row short, so the frame stacks downward and
# repeats itself. Both were reported from a real 80-column terminal, and both
# came from select_many concatenating its detail instead of wrapping it.
#
# The stale tail lives in the terminal's SCREEN BUFFER, not in the byte stream,
# so it cannot be seen by reading the output. The cause can: keep every line
# inside the width and neither symptom is reachable.

it 'select_many keeps every line inside the layout width'
cat >"$FAKE_DIR/wide-many.sh" <<EOS
#!/bin/bash
set -uo pipefail
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
menu_reset
menu_add "\$(printf '%-20s %-4s' 'usb:046d:0843' 'USB')"  'Logitech Webcam C930e  (attached now)'
menu_add "\$(printf '%-20s %-4s' 'bt:0011223344ff' 'BT')" "Terry\u2019s AirPods Pro  (paired, not connected)"
menu_add "\$(printf '%-20s %-4s' 'bt:0011223344fe' 'BT')" "Terry\u2019s MacBook Pro (3)  (paired, not connected)"
select_many --checked '0' --escapable \
  --help '  Keyboards and mice often share a vendor id with something that never
  moves. The full vendor+product is matched, so pick the exact rows.'
printf 'PICKED=%s\n' "\$MENU_PICKED"
EOS
chmod +x "$FAKE_DIR/wide-many.sh"
out=$(pty_run "$FAKE_DIR/wide-many.sh" DOWN,DOWN,ENTER)
over=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9]*[A-Za-z]//g' | awk 'length($0) > 79' | head -3)
assert_equal '' "$over" 'these lines overflow an 80-column terminal and will corrupt the redraw'

it 'and wraps the detail rather than truncating it'
# Every part of the name must survive the wrap, aligned under the column.
assert_match "$out" 'AirPods Pro'
assert_match "$out" 'not connected)'
assert_no_match "$out" '...'
assert_match "$out" '[ ] bt:0011223344ff      BT' 'the item column survives wrapping'

it 'select_one keeps every line inside the width too'
cat >"$FAKE_DIR/wide-one.sh" <<EOS
#!/bin/bash
set -uo pipefail
. "$MAC_DIR/lib/common.sh"
. "$MAC_DIR/lib/menu.sh"
menu_reset
menu_add 'Triggers' 'usb:046d:0843, usb:1235:820a, bt:0011223344ff, usb:04d9:0024, bt:0011223344fd'
menu_add 'Done' ''
select_one --default 0
printf 'PICK=%s\n' "\$MENU_PICK"
EOS
chmod +x "$FAKE_DIR/wide-one.sh"
out=$(pty_run "$FAKE_DIR/wide-one.sh" ENTER)
over=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9]*[A-Za-z]//g' | awk 'length($0) > 79' | head -3)
assert_equal '' "$over" 'a wrapped detail must still fit'

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

it 'gives the terminal back on Ctrl-C too'
# Ctrl-C arrives while the reader is blocked in dd, so the normal restore never
# runs. Measured before the guard existed: the child died with 130 and left the
# pty at -icanon -echo. The menu runs as a foreground job of its own process
# group (set -m), so the pty's Ctrl-C reaches it and not the script that then
# reads the terminal state back.
cat >"$FAKE_DIR/ctrlc-demo.sh" <<EOS
#!/bin/bash
set -m
/bin/bash -c '. "$MAC_DIR/lib/common.sh"; . "$MAC_DIR/lib/menu.sh"; menu_reset; menu_add alpha ""; menu_add beta ""; select_one --default 0' >/dev/null 2>&1
rc=\$?
after=\$(stty -a </dev/tty | grep -o '\-\?icanon')
echoback=\$(stty -a </dev/tty | grep -o '\-\?echo ' | head -1)
printf 'INT RC=%s AFTER=%s ECHO=%s\n' "\$rc" "\$after" "\$echoback"
EOS
chmod +x "$FAKE_DIR/ctrlc-demo.sh"
out=$(pty_run "$FAKE_DIR/ctrlc-demo.sh" INT)
assert_match "$out" 'INT RC=130'   "the menu must die of the interrupt, not swallow it: $out"
assert_match "$out" 'AFTER=icanon' "the terminal must be canonical again after Ctrl-C: $out"
assert_match "$out" 'ECHO=echo'    "echo must be back on after Ctrl-C: $out"

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
