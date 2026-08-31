LABEL   := com.chrisrishel.trigger-kvm
PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin
LIBDIR  := $(PREFIX)/share/trigger-kvm
LADIR   := $(HOME)/Library/LaunchAgents
PLIST   := $(LADIR)/$(LABEL).plist
LOGDIR  := $(HOME)/Library/Logs
UID     := $(shell id -u)

CFLAGS  := -O2 -Wall -Wextra

.PHONY: all clean test lint install uninstall status logs plist

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
test: display-probe
	@bash tests/run.sh

lint:
	@bash tests/run.sh --no-lint >/dev/null && shellcheck -x -P SCRIPTDIR -s bash \
	  trigger-kvm lib/*.sh tests/*.sh

# A passing test proves nothing until it can fail. Reintroduces each bug the
# suite is supposed to catch and checks that something goes red.
mutate:
	@bash tests/mutate.sh

# Generate the LaunchAgent plist. Split out from `install` so it can be
# validated without loading anything:
#     make plist PLIST=/tmp/t.plist && plutil -lint /tmp/t.plist
#
# The agent runs `trigger-kvm watch`, which reads the config and execs the
# watcher. So NO configuration is baked into the plist: which devices to watch,
# the debounce and the settle all live in the config, and an edit takes effect
# on the next `trigger-kvm restart`. That is why there is no apply step.
#
# The watcher runs `trigger-kvm pull` and nothing else. Never another computer's
# name: a name other than computer.this describes inputs on hardware this
# machine cannot observe, and a stale one would then be able to cause an
# AUTOMATIC switch to a dead input.
plist:
	@mkdir -p $(dir $(PLIST))
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>$(LABEL)</string>' \
	  '  <key>ProgramArguments</key><array>' \
	  '    <string>$(LIBDIR)/trigger-kvm</string>' \
	  '    <string>watch</string>' \
	  '  </array>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>KeepAlive</key><true/>' \
	  '  <key>ProcessType</key><string>Background</string>' \
	  '  <key>StandardOutPath</key><string>$(LOGDIR)/trigger-kvm.log</string>' \
	  '  <key>StandardErrorPath</key><string>$(LOGDIR)/trigger-kvm.log</string>' \
	  '</dict></plist>' > $(PLIST)
	@plutil -lint $(PLIST)

# Only a directory holding the launcher goes on PATH -- one symlink, never the
# program directory, which would publish every file in it as a command.
install: all plist
	@mkdir -p $(LIBDIR)/lib $(BINDIR) $(LOGDIR)
	install -m 755 trigger-kvm    $(LIBDIR)/trigger-kvm
	install -m 755 event-watch    $(LIBDIR)/event-watch
	install -m 755 display-probe  $(LIBDIR)/display-probe
	install -m 644 lib/*.sh       $(LIBDIR)/lib/
	ln -sf $(LIBDIR)/trigger-kvm  $(BINDIR)/trigger-kvm
	@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$(UID) $(PLIST)
	@echo "installed and loaded. logs: $(LOGDIR)/trigger-kvm.log"

uninstall:
	@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST) $(BINDIR)/trigger-kvm
	rm -rf $(LIBDIR)
	@echo "uninstalled. config and log kept."

status:
	@launchctl print gui/$(UID)/$(LABEL) 2>/dev/null | head -20 || echo "not loaded"

logs:
	@tail -f $(LOGDIR)/trigger-kvm.log
