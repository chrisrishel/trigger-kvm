LABEL   := com.chrisrishel.displayswitch
PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin
LADIR   := $(HOME)/Library/LaunchAgents
PLIST   := $(LADIR)/$(LABEL).plist
LOGDIR  := $(HOME)/Library/Logs
UID     := $(shell id -u)

# Watched USB devices — the peripherals that actually move through the USB switch.
# Keyboard and mouse are wired directly to the Windows PC and never move, so they
# cannot be the trigger. Keep in sync with ../displays.toml.
DEVICES := --device 046d:0843 --device 1235:820a
DEBOUNCE := 3.0
SETTLE   := 0.75

CFLAGS  := -O2 -Wall -Wextra
LDFLAGS := -framework IOKit -framework CoreFoundation

.PHONY: all clean install uninstall status logs plist

all: usb-watch

usb-watch: usb-watch.c
	clang $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f usb-watch

# Generate the LaunchAgent plist. Split out from `install` so it can be validated
# without loading anything:  make plist PLIST=/tmp/t.plist && plutil -lint /tmp/t.plist
plist:
	@mkdir -p $(dir $(PLIST))
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>$(LABEL)</string>' \
	  '  <key>ProgramArguments</key><array>' \
	  '    <string>$(BINDIR)/usb-watch</string>' \
	  '    <string>--exec</string><string>$(BINDIR)/switch-displays.sh</string>' \
	  '    <string>--arg</string><string>mac</string>' \
	  '    <string>--debounce</string><string>$(DEBOUNCE)</string>' \
	  '    <string>--settle</string><string>$(SETTLE)</string>' \
	  $(foreach d,$(DEVICES),'    <string>$(d)</string>') \
	  '  </array>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>KeepAlive</key><true/>' \
	  '  <key>ProcessType</key><string>Background</string>' \
	  '  <key>StandardOutPath</key><string>$(LOGDIR)/displayswitch.log</string>' \
	  '  <key>StandardErrorPath</key><string>$(LOGDIR)/displayswitch.log</string>' \
	  '</dict></plist>' > $(PLIST)
	@plutil -lint $(PLIST)

install: usb-watch plist
	@mkdir -p $(BINDIR) $(LOGDIR)
	install -m 755 usb-watch          $(BINDIR)/usb-watch
	install -m 755 switch-displays.sh $(BINDIR)/switch-displays.sh
	@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$(UID) $(PLIST)
	@echo "installed and loaded. logs: $(LOGDIR)/displayswitch.log"

uninstall:
	@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST) $(BINDIR)/usb-watch $(BINDIR)/switch-displays.sh
	@echo "uninstalled."

status:
	@launchctl print gui/$(UID)/$(LABEL) 2>/dev/null | head -20 || echo "not loaded"

logs:
	@tail -f $(LOGDIR)/displayswitch.log
