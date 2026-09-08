
CFLAGS  := -O2 -Wall -Wextra

.PHONY: all clean test lint mutate install uninstall status logs

all: event-watch display-probe

# Identity and the m1ddc handle in one place.
display-probe: display-probe.c
	clang $(CFLAGS) -o $@ $< -framework CoreFoundation -framework IOKit -framework ApplicationServices

# The watcher: USB via IOKit notifications, Bluetooth by polling system_profiler.
event-watch: event-watch.c
	clang $(CFLAGS) -o $@ $< -framework IOKit -framework CoreFoundation

# A measuring instrument for the Intel-Mac route (docs/decisions/004). Not part
# of `all` and never installed.
intel-ddc-probe: intel-ddc-probe.c
	clang $(CFLAGS) -o $@ $< -framework IOKit -framework CoreFoundation -framework ApplicationServices

clean:
	rm -f event-watch display-probe intel-ddc-probe

# The suite runs without hardware and cannot move a monitor: it points M1DDC at
# a recorder and display-probe at a fixture.
test: all
	@bash tests/run.sh

lint:
	@shellcheck -x -P SCRIPTDIR -s bash trigger-kvm install.sh ../specs/check-conformance.sh \
	  lib/*.sh tests/*.sh

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
