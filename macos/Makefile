
CFLAGS  := -O2 -Wall -Wextra

.PHONY: all clean test lint mutate install uninstall status logs

all: event-watch display-probe

# Identity and the m1ddc handle in one place. See the header comment for why it
# uses CoreGraphics and IOKit together rather than either alone.
display-probe: display-probe.c
	clang $(CFLAGS) -o $@ $< -framework CoreFoundation -framework IOKit -framework ApplicationServices

# USB via IOKit notifications, Bluetooth by polling system_profiler. One owner
# of "is that device here?", so the list the walkthrough offers and the presence
# that actually fires can never disagree.
event-watch: event-watch.c
	clang $(CFLAGS) -o $@ $< -framework IOKit -framework CoreFoundation

clean:
	rm -f event-watch display-probe

# The suite runs without hardware and cannot move a monitor: it points M1DDC at
# a recorder and display-probe at a fixture.
test: all
	@bash tests/run.sh

lint:
	@bash tests/run.sh --no-lint >/dev/null && shellcheck -x -P SCRIPTDIR -s bash \
	  trigger-kvm lib/*.sh tests/*.sh

# A passing test proves nothing until it can fail. Reintroduces each bug the
# suite is supposed to catch and checks that something goes red.
mutate:
	@bash tests/mutate.sh

# Installing is what install.sh does; the Makefile does not keep a second copy
# of it. The installer copies ITSELF alongside the program, so managing and
# removing keep working after the source tree is gone.
install: all
	@./install.sh

uninstall:
	@./install.sh uninstall

status:
	@./trigger-kvm status

logs:
	@./trigger-kvm logs
