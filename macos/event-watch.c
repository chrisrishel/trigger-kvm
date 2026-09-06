// event-watch -- fire a command when a watched device ARRIVES here.
//
// Built for trigger-kvm: when the USB switch hands this Mac the shared
// peripherals, pull both monitors to this machine.
//
//   event-watch --exec /path/to/trigger-kvm --arg pull \
//               --device usb:046d:0843 --device bt:0011223344ff \
//               [--debounce 3.0] [--settle 0.75] [--log PATH] [--verbose]
//
//   event-watch --list           what could be a trigger, and exit
//   event-watch --test-trigger   report ONE arrival and exit, running nothing
//
// Renamed from usb-watch: it is no longer USB-only, and the Windows side made
// the same rename for the same reason.
//
// ONE PROCESS, N EVENT SOURCES. Do not add a second persistent process and do
// not tell users to run one. Two watchers would each hold their own in-memory
// debounce and both fire when a USB device and a Bluetooth device arrive
// together -- the double-fire the single-instance lock exists to prevent.
//
// This is also the ONE OWNER OF "is that device here?". `--list` exists so the
// walkthrough can ask this program rather than keeping a second copy of the
// enumeration: a second implementation would be free to disagree with the one
// that actually fires, which is the worst possible place for a disagreement.
//
// Two safety behaviours, both because a spurious arrival would yank both
// displays out from under whatever you are doing:
//
//   debounce -- ignore any arrival within N seconds of the last fire. Stops two
//               watched devices arriving together from firing twice, and stops
//               a flapping device from thrashing the displays. It is not belt
//               and braces: one physical plug produces dozens of events, so
//               without it a single arrival would fire the switcher repeatedly.
//   settle   -- after an arrival, wait, then confirm the device is STILL
//               present before acting. A device that appears and immediately
//               vanishes was a glitch, not a switch.
//
// Devices already present at startup do not fire. The first callback per watch
// is used only to drain and arm the notification.
//
// WHATEVER FIRES, IT RUNS `pull` -- never another computer's name. A name other
// than computer.this describes inputs on hardware this machine cannot observe,
// so a stale one must never be reachable from anything automatic. This program
// takes --arg from its caller and the caller is trigger-kvm, which passes pull.
//
// Build: clang -O2 -Wall -Wextra -o event-watch event-watch.c \
//          -framework IOKit -framework CoreFoundation

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <stdbool.h>
#include <ctype.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// Observed class on Apple Silicon / macOS 26. The older "IOUSBDevice" name is
// not reliable here; ioreg reports IOUSBHostDevice.
#define USB_CLASS "IOUSBHostDevice"
#define MAX_WATCH 16
#define MAX_ROWS  256

extern char **environ;

typedef enum { W_USB, W_BT } kind_t;

typedef struct {
    kind_t   kind;
    char     key[64];         // "usb:046d:0843[@token[@where]]" or "bt:0011223344ff"
    uint32_t vendor, product; // usb
    // specs/detector.md 4.1. Both optional and empty for every config written
    // before they existed, in which case an entry means exactly what it always
    // meant -- so nothing needs migrating.
    char     token[64];       // which device, among those sharing the id
    char     where[32];       // a TIEBREAK only, never consulted while token resolves
    bool     ambiguous;       // token left several, none at where: entry disabled
    bool     by_where;        // where decided the last match, and status says so
    char     addr[16];        // bt, lower-case hex, no separators
    io_iterator_t iter;
    bool     primed;          // first callback drains pre-existing devices
    bool     present;
    bool     arrived;         // arrived during the current settle window
} watch_t;

static watch_t   g_watch[MAX_WATCH];
static int       g_nwatch   = 0;
static char      g_exec[1024];
static char      g_arg[64]  = "pull";
static char      g_log[1024];
static double    g_debounce = 3.0;
static double    g_settle   = 0.75;
static double    g_btpoll   = 2.0;
static long      g_maxlog   = 1024 * 1024;
static int       g_timeout  = 120;
static bool      g_verbose  = false;
static bool      g_testmode = false;
static CFAbsoluteTime g_last_fire = 0;
static bool      g_settle_pending = false;

// ---------------------------------------------------------------- logging --
//
// STDERR ONLY, and --log names the file that stderr is ALREADY pointed at
// rather than a second place to write.
//
// The LaunchAgent sets StandardErrorPath to the log, so writing to both put
// every line in twice -- visible in the first real install. It matters beyond
// tidiness: the switcher this program spawns inherits stderr, so one stream
// keeps the arrival and the switch it caused in the order they happened, with
// no second writer to interleave with.
//
// --log therefore exists for exactly one thing: knowing which file to rotate.

static void logmsg(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));

    va_list ap;
    va_start(ap, fmt);
    char body[1024];
    vsnprintf(body, sizeof body, fmt, ap);
    va_end(ap);

    fprintf(stderr, "%s event-watch: %s\n", ts, body);
    fflush(stderr);
}

static void vlog(const char *fmt, ...) {
    if (!g_verbose) return;
    va_list ap; va_start(ap, fmt);
    char body[1024];
    vsnprintf(body, sizeof body, fmt, ap);
    va_end(ap);
    logmsg("%s", body);
}

// COPY then TRUNCATE, never rename.
//
// launchd opens StandardErrorPath once, when it starts the job, and our stderr
// IS that descriptor. Renaming the file would leave that descriptor pointing at
// the renamed inode, so every line after the first rotation would land in
// trigger-kvm.log.1 and the live log would stay empty -- a rotation that
// silently swaps which file is the log. Truncating keeps the inode, so the
// descriptor stays valid.
//
// This relies on launchd opening the path with O_APPEND, which makes each write
// recompute the offset and so leaves no NUL hole after a truncation. Measured
// on this machine rather than assumed; see macos/README.md.
static void rotate_log(void) {
    struct stat st;
    if (stat(g_log, &st) != 0 || st.st_size <= g_maxlog) return;

    char old[1200];
    snprintf(old, sizeof old, "%s.1", g_log);

    int src = open(g_log, O_RDONLY);
    if (src < 0) { fprintf(stderr, "WARN: cannot read %s to rotate it\n", g_log); return; }
    int dst = open(old, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (dst < 0) { close(src); fprintf(stderr, "WARN: cannot write %s\n", old); return; }

    char buf[65536];
    ssize_t n;
    while ((n = read(src, buf, sizeof buf)) > 0) {
        if (write(dst, buf, (size_t)n) != n) break;
    }
    close(dst);
    close(src);

    // Truncate the live file rather than replacing it. One generation kept.
    int live = open(g_log, O_WRONLY);
    if (live >= 0) { (void)!ftruncate(live, 0); close(live); }

    fprintf(stderr, "rotated log at %lld bytes (previous kept as %s)\n",
            (long long)st.st_size, old);
}

// ------------------------------------------------------------- USB present --

// Defined here rather than beside the Bluetooth reader that used to be its only
// caller: the USB naming below needs it too, and one helper with two callers
// belongs above both.
static void cf_to_c(CFStringRef s, char *out, size_t outsz) {
    out[0] = '\0';
    if (s && CFGetTypeID(s) == CFStringGetTypeID())
        CFStringGetCString(s, out, (CFIndex)outsz, kCFStringEncodingUTF8);
}

static CFMutableDictionaryRef usb_match(uint32_t vendor, uint32_t product) {
    CFMutableDictionaryRef m = IOServiceMatching(USB_CLASS);
    if (!m) return NULL;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &vendor);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberSInt32Type, &product);
    CFDictionarySetValue(m, CFSTR("idVendor"),  v);
    CFDictionarySetValue(m, CFSTR("idProduct"), p);
    CFRelease(v); CFRelease(p);
    return m;
}

// Reduce whatever a device calls itself INTO the config's token class.
//
// specs/config-format.md: `[a-z0-9-]` is the class computer and display names
// already follow, and the only one that survives the trigger list's existing
// handling unchanged -- no `#` for the reader to cut, no `,` to split the list,
// no whitespace or case for a reader that strips both. So the raw string is
// never stored, and a token is compared literally rather than interpreted.
static void slugify(const char *in, char *out, size_t n) {
    size_t o = 0;
    bool dash = false;
    for (const char *p = in; *p && o + 1 < n; p++) {
        char c = *p;
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            if (dash && o > 0 && o + 2 < n) out[o++] = '-';
            dash = false;
            out[o++] = c;
        } else if (o > 0) {
            dash = true;    // a run of anything else becomes at most one dash
        }
    }
    out[o] = '\0';
}

// What a device presents itself AS -- mouse, keyboard -- from the HID usage
// pages on its child nodes. specs/configure.md 7.1: the most recognisable thing
// on the row, and read as a PROPERTY, so nothing is opened and no device is
// disturbed. Generic Desktop (page 1) usage 2 is a mouse and usage 6 a keyboard.
//
// Measured 2026-09-06: a LIGHTSPEED receiver presents BOTH whatever is paired to
// it, so this names the row and does NOT tell two of them apart. Saying what is
// true is the job here; 7.1 also bars it from becoming a filter.
static void usb_role(io_service_t s, char *out, size_t n, int depth) {
    if (depth == 0) out[0] = '\0';
    if (depth > 6) return;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(s, kIOServicePlane, &it) != KERN_SUCCESS) return;
    io_service_t c;
    while ((c = IOIteratorNext(it))) {
        CFTypeRef pg = IORegistryEntryCreateCFProperty(c, CFSTR("PrimaryUsagePage"), NULL, 0);
        CFTypeRef us = IORegistryEntryCreateCFProperty(c, CFSTR("PrimaryUsage"),     NULL, 0);
        int page = 0, usage = 0;
        if (pg && CFGetTypeID(pg) == CFNumberGetTypeID()) CFNumberGetValue(pg, kCFNumberIntType, &page);
        if (us && CFGetTypeID(us) == CFNumberGetTypeID()) CFNumberGetValue(us, kCFNumberIntType, &usage);
        if (pg) CFRelease(pg);
        if (us) CFRelease(us);
        const char *role = NULL;
        if (page == 1 && usage == 2) role = "mouse";
        if (page == 1 && usage == 6) role = "keyboard";
        if (role && !strstr(out, role)) {
            size_t have = strlen(out);
            snprintf(out + have, n - have, "%s%s", have ? ", " : "", role);
        }
        usb_role(c, out, n, depth + 1);
        IOObjectRelease(c);
    }
    IOObjectRelease(it);
}

// Where a device is plugged in, as the config's `where` suffix.
//
// specs/detector.md 4.1: a TIEBREAK ONLY, consulted when and only when `token`
// still matches more than one present device. `locationID` is macOS's port
// handle, and is the only thing that differs between the two identical
// receivers on the reference desk (measured 2026-09-06).
static void usb_where(io_service_t s, char *out, size_t n) {
    out[0] = '\0';
    CFTypeRef l = IORegistryEntryCreateCFProperty(s, CFSTR("locationID"), NULL, 0);
    int loc = 0;
    if (l && CFGetTypeID(l) == CFNumberGetTypeID()) CFNumberGetValue(l, kCFNumberIntType, &loc);
    if (l) CFRelease(l);
    if (loc) snprintf(out, n, "%08x", (unsigned)loc);
}

static void usb_name(io_service_t s, char *out, size_t n) {
    out[0] = '\0';
    // ONE name source, and it is already the device's own iProduct string.
    // Measured 2026-09-06: `USB Product Name` and `kUSBProductString` are the
    // same value on every device here, so 7.1's "best name, not the first" costs
    // this platform nothing -- unlike Windows, which needed a second source to
    // escape `USB Input Device`.
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFSTR("USB Product Name"), NULL, 0);
    if (!v) v = IORegistryEntryCreateCFProperty(s, CFSTR("kUSBProductString"), NULL, 0);
    cf_to_c((CFStringRef)v, out, n);
    if (v) CFRelease(v);
}

// How many devices with this id are present, and -- when `token` and `where` are
// given -- how many survive them. specs/detector.md 4.1's table, in one place.
//
// `token` selects among the devices sharing an id; `where` breaks a tie among
// those, and is consulted ONLY when the token still leaves more than one,
// because a device moved to another socket must not stop matching. Whether
// `where` decided is reported back, since a remembered location that has gone
// stale is dangerous only while it is silent.
//
// NEVER falls back to the whole id. Firing on any device sharing an id is not
// what the config asked for, and the cost is concrete: a visitor's identical
// dongle would produce an arrival edge and pull the monitors over unbidden.
static int usb_count(uint32_t vendor, uint32_t product,
                     const char *token, const char *where, bool *by_where) {
    if (by_where) *by_where = false;
    CFMutableDictionaryRef m = usb_match(vendor, product);
    if (!m) return 0;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return 0;

    int matched = 0, at_where = 0;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        if (token[0]) {
            char name[128], slug[64];
            usb_name(s, name, sizeof name);
            slugify(name, slug, sizeof slug);
            if (strcmp(slug, token) != 0) { IOObjectRelease(s); continue; }
        }
        matched++;
        if (where[0]) {
            char w[32];
            usb_where(s, w, sizeof w);
            if (!strcmp(w, where)) at_where++;
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);

    if (matched > 1 && where[0] && at_where == 1) {
        if (by_where) *by_where = true;
        return 1;
    }
    return matched;
}


// --------------------------------------------------------- BT, via plist ----
//
// system_profiler, not IOBluetooth -- and the reason is a PERMISSION GATE, not
// a broken API.
//
// IOBluetooth needs TCC Bluetooth permission, granted PER BINARY. An unapproved
// binary's first call BLOCKS until a human approves a prompt, and that prompt
// can arrive minutes later. Once approved the API is fine, from a terminal and
// from a LaunchAgent alike -- measured 2026-08-31 both ways with one probe:
// 10 paired devices with connected state, no run loop needed, exits cleanly.
//
// The problem is the FIRST run on a fresh install. The watcher's first
// Bluetooth sweep would block until someone happened to notice a prompt, with
// the process still ALIVE -- so KeepAlive would not restart it, and the trigger
// would silently never fire until the prompt was answered.
//
// system_profiler never raises that prompt: it is Apple-signed and carries its
// own entitlement, which is why it answered on the very first attempt here,
// before any prompt had been seen. It costs about 60ms, and -xml is a property
// list, so CoreFoundation parses it with no JSON dependency.
//
// So this is not "IOBluetooth is broken". It is "IOBluetooth makes an
// unattended first run wait for a human", which is a thing a background watcher
// must not do.
//
// It answers both questions this project needs and keeps them distinct:
// firing is on CONNECTED, offering is on PAIRED. Conflating them cost the
// Windows side a round -- a trigger fires on arrival, so the device that is
// disconnected right now is exactly the one that will produce one. Show the
// state; never filter on it.

static CFArrayRef bt_section(CFDictionaryRef items, CFStringRef key) {
    CFTypeRef v = CFDictionaryGetValue(items, key);
    if (v && CFGetTypeID(v) == CFArrayGetTypeID()) return (CFArrayRef)v;
    return NULL;
}

// Read system_profiler's plist. Returns NULL when Bluetooth is unavailable,
// which callers must treat as "nothing connected" -- an absence, and absences
// never fire. A missing or disabled radio must not take the watcher down; the
// USB half has to keep working.
//
// TK_BT_PLIST names a file to read INSTEAD of running system_profiler. It is
// how the suite feeds this parser a known paired/connected set, so "offers
// every paired device" is asserted against a fixture rather than against
// whatever happens to be paired with the developer's Mac -- the same reason
// the switcher's probe and m1ddc are overridable. Nothing installed sets it.
static CFDictionaryRef bt_read(void) {
    const char *fixture = getenv("TK_BT_PLIST");
    FILE *p = fixture ? fopen(fixture, "r")
                      : popen("/usr/sbin/system_profiler SPBluetoothDataType -xml 2>/dev/null", "r");
    if (!p) return NULL;

    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    unsigned char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, p)) > 0) CFDataAppendBytes(data, buf, (CFIndex)n);
    if (fixture) fclose(p); else pclose(p);

    CFTypeRef plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    if (!plist) return NULL;

    // [ { _items: [ { device_connected: [...], device_not_connected: [...] } ] } ]
    CFDictionaryRef items = NULL;
    if (CFGetTypeID(plist) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)plist) > 0) {
        CFDictionaryRef top = CFArrayGetValueAtIndex((CFArrayRef)plist, 0);
        if (CFGetTypeID(top) == CFDictionaryGetTypeID()) {
            CFArrayRef inner = bt_section(top, CFSTR("_items"));
            if (inner && CFArrayGetCount(inner) > 0) {
                CFTypeRef e = CFArrayGetValueAtIndex(inner, 0);
                if (CFGetTypeID(e) == CFDictionaryGetTypeID()) {
                    items = CFDictionaryCreateCopy(NULL, (CFDictionaryRef)e);
                }
            }
        }
    }
    CFRelease(plist);
    return items;
}

// "00:11:22:33:44:FD" -> "0011223344fd"
static void bt_normalize(const char *in, char *out, size_t outsz) {
    size_t n = 0;
    for (const char *p = in; *p && n + 1 < outsz; p++) {
        if (*p == ':' || *p == '-') continue;
        out[n++] = (char)tolower((unsigned char)*p);
    }
    out[n] = '\0';
}

// Walk one section, calling back with (address, name, connected).
static void bt_each(CFDictionaryRef items, CFStringRef section, bool connected,
                    void (*fn)(const char *addr, const char *name, bool conn, void *ctx),
                    void *ctx) {
    CFArrayRef arr = bt_section(items, section);
    if (!arr) return;
    for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
        CFTypeRef e = CFArrayGetValueAtIndex(arr, i);
        if (CFGetTypeID(e) != CFDictionaryGetTypeID()) continue;
        // Each entry is a one-key dict: { "<device name>": { device_address: ... } }
        CFIndex nk = CFDictionaryGetCount((CFDictionaryRef)e);
        // CFDictionaryGetKeysAndValues writes EVERY pair, so an entry with more
        // keys than the buffers hold must be skipped, not clamped: clamping the
        // count after the call was a stack overflow waiting for system_profiler
        // to change shape. Today each entry has exactly one key.
        if (nk < 1 || nk > 8) continue;
        const void *keys[8], *vals[8];
        CFDictionaryGetKeysAndValues((CFDictionaryRef)e, keys, vals);
        for (CFIndex k = 0; k < nk; k++) {
            if (CFGetTypeID(vals[k]) != CFDictionaryGetTypeID()) continue;
            CFStringRef a = CFDictionaryGetValue((CFDictionaryRef)vals[k], CFSTR("device_address"));
            if (!a) continue;
            char raw[64], addr[16], name[128];
            cf_to_c(a, raw, sizeof raw);
            bt_normalize(raw, addr, sizeof addr);
            cf_to_c((CFStringRef)keys[k], name, sizeof name);
            fn(addr, name, connected, ctx);
        }
    }
}

typedef struct { char addr[MAX_ROWS][16]; int n; } bt_set_t;

static void bt_collect(const char *addr, const char *name, bool conn, void *ctx) {
    (void)name; (void)conn;
    bt_set_t *s = (bt_set_t *)ctx;
    if (s->n >= MAX_ROWS) return;
    snprintf(s->addr[s->n++], 16, "%s", addr);
}

// The connected set, enumerated ONCE per presence sweep. The API walks the
// whole paired set every call and a single USB plug produces dozens of change
// events, each triggering a sweep -- so this is deliberately not per-device.
// Skipped entirely when nothing Bluetooth is watched.
static void bt_connected(bt_set_t *out) {
    out->n = 0;
    CFDictionaryRef items = bt_read();
    if (!items) {
        vlog("Bluetooth enumeration unavailable; treating as none connected");
        return;
    }
    bt_each(items, CFSTR("device_connected"), true, bt_collect, out);
    CFRelease(items);
}

static bool bt_in(const bt_set_t *s, const char *addr) {
    for (int i = 0; i < s->n; i++) if (!strcmp(s->addr[i], addr)) return true;
    return false;
}

// ---------------------------------------------------------------- presence --

static bool any_bt_watched(void) {
    for (int i = 0; i < g_nwatch; i++) if (g_watch[i].kind == W_BT) return true;
    return false;
}

// One sweep across every watched device, whatever its transport.
static void presence_sweep(bool *out) {
    bt_set_t bt; bt.n = 0;
    if (any_bt_watched()) bt_connected(&bt);

    for (int i = 0; i < g_nwatch; i++) {
        if (g_watch[i].kind == W_BT) {
            // CONNECTED, not paired. A paired-but-absent device stays paired for
            // years, so its presence would never change and the trigger would
            // silently never fire -- the worst failure shape available here.
            out[i] = bt_in(&bt, g_watch[i].addr);
        } else if (g_watch[i].ambiguous) {
            // A disabled entry is never present, so it never produces an edge.
            // specs/detector.md 4.1: disabling the ENTRY and not the watcher --
            // an ambiguous entry has its devices present and only "which"
            // unresolved, so refusing to run over it would turn a cosmetic
            // uncertainty into total non-operation.
            out[i] = false;
        } else {
            bool by_where = false;
            int n = usb_count(g_watch[i].vendor, g_watch[i].product,
                              g_watch[i].token, g_watch[i].where, &by_where);
            // Several match the token and none is at `where`: which one this
            // entry meant is unresolved, and there is no safe guess. NOT a
            // fallback to the whole id -- a visitor's identical dongle would
            // then pull the monitors over unbidden.
            if (n > 1 && g_watch[i].token[0]) {
                if (!g_watch[i].ambiguous) {
                    g_watch[i].ambiguous = true;
                    logmsg("AMBIGUOUS: %s matches %d present devices and none is at "
                           "the remembered port; this trigger is disabled, the others "
                           "keep watching", g_watch[i].key, n);
                }
                out[i] = false;
                continue;
            }
            if (by_where && !g_watch[i].by_where)
                logmsg("%s: the remembered port decided which device this is", g_watch[i].key);
            g_watch[i].by_where = by_where;
            out[i] = n > 0;
        }
    }
}

// -------------------------------------------------------------------- fire --

static void run_exec(void) {
    char *argv[] = { g_exec, g_arg, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, g_exec, NULL, NULL, argv, environ);
    if (rc != 0) logmsg("ERROR: posix_spawn(%s) failed: %s", g_exec, strerror(rc));
    else         logmsg("fired: %s %s (pid %d)", g_exec, g_arg, (int)pid);
}

static void settle_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    g_settle_pending = false;

    bool now[MAX_WATCH];
    presence_sweep(now);
    // The test is on a device that ARRIVED, not on any watched device: with
    // two devices that travel together "is anything present?" is always yes,
    // and appear-then-vanish would fire anyway (specs/detector.md 2).
    bool still = false;
    for (int i = 0; i < g_nwatch; i++) {
        g_watch[i].present = now[i];
        if (g_watch[i].arrived && now[i]) still = true;
        g_watch[i].arrived = false;
    }

    if (!still) {
        logmsg("device vanished during settle window; ignoring (glitch, not a switch)");
        return;
    }
    g_last_fire = CFAbsoluteTimeGetCurrent();
    run_exec();
}

// An arrival edge was seen. Debounce, then settle, then fire.
static void arrival(watch_t *w) {
    const char *what = w->key;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_last_fire < g_debounce) {
        vlog("arrival %s within debounce (%.1fs); ignoring", what, now - g_last_fire);
        return;
    }
    w->arrived = true;
    if (g_settle_pending) {
        vlog("arrival %s; settle already pending", what);
        return;
    }
    logmsg("arrival %s; settling %.2fs", what, g_settle);
    g_settle_pending = true;
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + g_settle, 0, 0, 0, settle_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
    CFRelease(t);
}

static void device_appeared(void *refcon, io_iterator_t iter) {
    watch_t *w = (watch_t *)refcon;

    // The iterator MUST be drained whatever we decide, or the notification is
    // not re-armed and this watch goes deaf after one event.
    int raw = 0;
    io_service_t s;
    while ((s = IOIteratorNext(iter))) { raw++; IOObjectRelease(s); }

    // IOKit matches on vendor+product only, so the iterator cannot express a
    // token or a port. Re-ask through the one function that can, or a watch
    // carrying `@token` would arm and fire on any device sharing the id -- which
    // is the "never fall back to the whole id" rule, broken at the one moment
    // nobody would look (specs/detector.md 4.1).
    bool by_where = false;
    int n = raw;
    if (w->token[0] || w->where[0])
        n = usb_count(w->vendor, w->product, w->token, w->where, &by_where);

    // Several carry this token and none is at the remembered port: which device
    // the entry meant is unresolved, and there is no safe guess. Checked on the
    // priming pass too -- an entry already ambiguous when the watcher starts is
    // the likeliest case of all, and priming it as merely "present" would leave
    // it silently never firing.
    bool now_ambiguous = (n > 1 && w->token[0]);
    if (now_ambiguous && !w->ambiguous) {
        w->ambiguous = true;
        logmsg("AMBIGUOUS: %s matches %d present devices and none is at the "
               "remembered port; this trigger is disabled, the others keep watching",
               w->key, n);
    }

    if (!w->primed) {
        w->primed = true;
        w->present = (!now_ambiguous && n > 0);
        vlog("armed %s (%d already present, not firing)", w->key, n);
        if (by_where)
            logmsg("%s: the remembered port decided which device this is", w->key);
        w->by_where = by_where;
        return;
    }
    if (n == 0 || now_ambiguous) return;
    if (by_where && !w->by_where)
        logmsg("%s: the remembered port decided which device this is", w->key);
    w->by_where = by_where;
    w->present = true;
    arrival(w);
}

// Bluetooth has no notification reachable from a command-line binary, so it is
// polled. A fallback, not a design -- and it costs nothing when no bt: device
// is configured, because the timer is only installed then.
static void bt_tick(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    bt_set_t bt;
    bt_connected(&bt);
    for (int i = 0; i < g_nwatch; i++) {
        if (g_watch[i].kind != W_BT) continue;
        bool now = bt_in(&bt, g_watch[i].addr);
        bool was = g_watch[i].present;
        g_watch[i].present = now;
        if (now && !was) arrival(&g_watch[i]);
    }
}

// -------------------------------------------------------------------- list --

typedef struct {
    char key[32]; char name[128]; char state[24]; char kind[4];
    char role[32];    // what it presents itself as -- 7.1
    char token[64];   // its slugified name, the candidate `token` suffix
    char where[32];   // its port, the candidate `where` suffix
} row_t;
static row_t g_rows[MAX_ROWS];
static int   g_nrows = 0;

// ONE ROW PER PHYSICAL DEVICE, not one per id.
//
// This used to return early on a duplicate key, and that was the bug
// specs/detector.md 4.1 is written about: the reference desk has two receivers
// reporting 046D:C547, so the list showed ONE row for two devices, named after
// whichever won, and there was no way to trigger on one of them. Worse, presence
// was per id, so with only one of them travelling the id never went absent, the
// edge never happened and the trigger never fired -- silently.
//
// Bluetooth still dedupes, on the address, which really is one per device.
static void add_row(const char *kind, const char *key, const char *state,
                    const char *name, const char *role,
                    const char *token, const char *where) {
    if (!strcmp(kind, "bt"))
        for (int i = 0; i < g_nrows; i++) if (!strcmp(g_rows[i].key, key)) return;
    if (g_nrows >= MAX_ROWS) return;
    row_t *r = &g_rows[g_nrows++];
    snprintf(r->kind, sizeof r->kind, "%s", kind);
    snprintf(r->key,  sizeof r->key,  "%s", key);
    snprintf(r->state,sizeof r->state,"%s", state);
    snprintf(r->name, sizeof r->name, "%s", name);
    snprintf(r->role, sizeof r->role, "%s", role  ? role  : "");
    snprintf(r->token,sizeof r->token,"%s", token ? token : "");
    snprintf(r->where,sizeof r->where,"%s", where ? where : "");
    // The list is `|`-separated and a panel-supplied string must not split a row.
    for (char *p = r->name; *p; p++) if (*p == '|') *p = ' ';
}

static void bt_row(const char *addr, const char *name, bool conn, void *ctx) {
    (void)ctx;
    char key[32];
    snprintf(key, sizeof key, "bt:%s", addr);
    add_row("bt", key, conn ? "connected now" : "paired, not connected",
            name[0] ? name : "(unnamed)", "", "", "");
}

// Candidate trigger devices: things attached or paired RIGHT NOW.
//
// "Right now" does most of the filtering, and it comes from how installing
// actually happens -- you run this on the machine currently holding the
// peripherals, so whatever moves is by definition present. Far more
// discriminating than any heuristic about device class.
static void list_candidates(void) {
    // --- USB: every attached device, minus infrastructure ---
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching(USB_CLASS), &it) == KERN_SUCCESS) {
        io_service_t s;
        while ((s = IOIteratorNext(it))) {
            CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFSTR("idVendor"),  NULL, 0);
            CFTypeRef p = IORegistryEntryCreateCFProperty(s, CFSTR("idProduct"), NULL, 0);
            int vid = 0, pid = 0;
            char name[128] = "", role[32] = "", token[64] = "", where[32] = "";
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &vid);
            if (p && CFGetTypeID(p) == CFNumberGetTypeID()) CFNumberGetValue(p, kCFNumberIntType, &pid);
            usb_name(s, name, sizeof name);
            usb_role(s, role, sizeof role, 0);
            usb_where(s, where, sizeof where);
            slugify(name, token, sizeof token);
            if (v) CFRelease(v);
            if (p) CFRelease(p);
            IOObjectRelease(s);

            // Hubs and controllers are attached permanently and never move; a
            // failed enumeration (vid 0) is not addressable at all.
            if (vid == 0) continue;
            if (strcasestr(name, "hub") || strcasestr(name, "host controller") ||
                strcasestr(name, "root complex")) continue;

            char key[32];
            snprintf(key, sizeof key, "usb:%04x:%04x", vid, pid);
            add_row("usb", key, "attached now", name[0] ? name : "(unnamed)",
                    role, token, where);
        }
        IOObjectRelease(it);
    }

    // --- Bluetooth: every PAIRED device, connected or not ---
    //
    // Not filtered to connected. A trigger fires on ARRIVAL, so the device that
    // is disconnected right now is precisely the one that will produce one --
    // the headphones on the other machine connect to this one when you flip the
    // switch. Filtering hid the choice a user most wants.
    CFDictionaryRef items = bt_read();
    if (items) {
        bt_each(items, CFSTR("device_connected"),     true,  bt_row, NULL);
        bt_each(items, CFSTR("device_not_connected"), false, bt_row, NULL);
        CFRelease(items);
    }

    // kind|key|state|name|role|token|where. The three new fields are empty for
    // Bluetooth and for a USB device that reports nothing useful; a reader that
    // only wants the first four is unaffected.
    for (int i = 0; i < g_nrows; i++)
        printf("%s|%s|%s|%s|%s|%s|%s\n", g_rows[i].kind, g_rows[i].key,
               g_rows[i].state, g_rows[i].name,
               g_rows[i].role, g_rows[i].token, g_rows[i].where);
}

// How each configured entry resolves RIGHT NOW, as "key|verdict|count".
//
// specs/detector.md 4.1 requires `status` to say when `where` decided a match
// and when an entry is ambiguous. The matching rules live in usb_count and are
// asked here rather than reimplemented in the shell: a second implementation
// would be free to disagree with the one that actually fires, which is the worst
// possible place for a disagreement.
//
// Takes no lock and starts nothing, like --list, so it can run beside a watcher.
static int report_devices(void) {
    for (int i = 0; i < g_nwatch; i++) {
        watch_t *w = &g_watch[i];
        if (w->kind == W_BT) {
            bt_set_t bt; bt_connected(&bt);
            printf("%s|%s|%d\n", w->key,
                   bt_in(&bt, w->addr) ? "present" : "absent",
                   bt_in(&bt, w->addr) ? 1 : 0);
            continue;
        }
        bool by_where = false;
        int n = usb_count(w->vendor, w->product, w->token, w->where, &by_where);
        const char *verdict = "absent";
        if (n > 1 && w->token[0]) verdict = "ambiguous";
        else if (n > 0 && by_where) verdict = "where";
        else if (n > 0)            verdict = "present";
        printf("%s|%s|%d\n", w->key, verdict, n);
    }
    return 0;
}

// -------------------------------------------------------------------- args --

static void usage(const char *me) {
    fprintf(stderr,
      "usage: %s --exec PATH [--arg ARG] --device usb:VVVV:PPPP|bt:AAAAAAAAAAAA ...\n"
      "          [--debounce S] [--settle S] [--bt-poll S] [--log PATH]\n"
      "          [--max-log-bytes N] [--verbose]\n"
      "       %s --list\n"
      "       %s --lock-status\n"
      "       %s --report --device ... \n"
      "       %s --test-trigger --device ... [--timeout S]\n", me, me, me, me, me);
    exit(2);
}

// The single-instance lock's path, in ONE place. main() takes the lock and
// --lock-status asks about it; two spellings of one path could disagree, and the
// one that disagreed would report "no watcher" with a watcher running.
static void lock_path(char *dst, size_t dstsz) {
    const char *home = getenv("HOME");
    snprintf(dst, dstsz, "%s/Library/Application Support/trigger-kvm/watcher.lock",
             home ? home : "/tmp");
}

// Is a watcher running? Answered from the LOCK and never by counting processes
// (specs/status.md 2). The lock is what makes a second watcher impossible, so it
// is the authority on both halves of the question, and it is a STATE not a count.
//
// Creates nothing: O_CREAT here would leave a lock file behind on a machine that
// has never run a watcher, and the next reader could not tell that file from a
// real one. A file that is absent means no watcher has ever started; a file that
// EXISTS BUT CANNOT BE OPENED is a RUNNING watcher, not an absent one -- that is
// what a watcher in another session looks like from here, and reading it as
// absent is the failure that rule exists to prevent.
//
// Prints one word and exits 0 when a watcher holds it, 1 when none does, so a
// caller can branch on either.
static int lock_status(void) {
    char path[1200];
    lock_path(path, sizeof path);

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        if (errno == ENOENT) { printf("none\n"); return 1; }
        printf("running\n");   // present and unopenable: held by someone else
        return 0;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        printf("running\n");
        return 0;
    }
    // We took it, so nobody held it. close() releases the flock -- the kernel
    // drops it with the last descriptor referring to the file, which is the same
    // property that makes a killed watcher leave nothing behind. An explicit
    // LOCK_UN here was tried and removed: it changed nothing, and a mutation
    // deleting it could not be caught, which is what dead code looks like.
    close(fd);
    printf("none\n");
    return 1;
}

// Copy an argument, or refuse. Silent truncation put a DIFFERENT path on the
// command line than the one asked for -- caught when a mutation test spawned
// /usr/bin/touch against a truncated marker and the assertion saw nothing. A
// wrong path that looks like success is exactly the failure shape this project
// refuses everywhere else.
static void copy_arg(char *dst, size_t dstsz, const char *src, const char *what) {
    if (strlen(src) >= dstsz) {
        fprintf(stderr, "event-watch: %s is too long (%zu bytes, max %zu)\n",
                what, strlen(src), dstsz - 1);
        exit(2);
    }
    snprintf(dst, dstsz, "%s", src);
}

// Exactly n hex digits at s, and then the given terminator.
static bool hexrun(const char *s, size_t n, char after) {
    for (size_t i = 0; i < n; i++) if (!isxdigit((unsigned char)s[i])) return false;
    return s[n] == after;
}

// The device grammar is STRICT (specs/detector.md 4): usb:VVVV:PPPP is exactly
// four hex digits, a colon and four; bt: is exactly twelve hex digits with no
// separators. `%x:%x` used to accept usb:46d:843, 0x046d:0x0843 and trailing
// junk, and a separated Bluetooth address that the config-side marker could
// never match. A watcher armed on a mis-parsed entry runs and never fires.
static bool usb_spec_ok(const char *s) { return hexrun(s, 4, ':') && hexrun(s + 5, 4, '\0'); }

// A suffix is `[a-z0-9-]+`, CHECKED lower-case rather than normalised
// (specs/config-format.md). The id half is case-insensitive and the suffix half
// is not, deliberately: a suffix silently lower-cased on one platform and
// refused on another is precisely the disagreement the shared corpus exists to
// prevent. Copies it out and returns false on anything else, so a malformed
// entry is REFUSED by name rather than quietly meaning something narrower.
static bool copy_suffix(const char *s, size_t n, char *dst, size_t dstsz) {
    if (n == 0 || n >= dstsz) return false;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    }
    memcpy(dst, s, n);
    dst[n] = '\0';
    return true;
}

static bool add_device(const char *spec) {
    if (g_nwatch >= MAX_WATCH) return false;
    watch_t *w = &g_watch[g_nwatch];
    memset(w, 0, sizeof *w);

    const char *s = spec;
    if (!strncasecmp(s, "bt:", 3)) {
        if (!hexrun(s + 3, 12, '\0')) return false;
        char addr[16];
        bt_normalize(s + 3, addr, sizeof addr);
        w->kind = W_BT;
        snprintf(w->addr, sizeof w->addr, "%s", addr);
        snprintf(w->key, sizeof w->key, "bt:%s", addr);
    } else {
        // A bare VVVV:PPPP means usb, so a config written before Bluetooth
        // existed keeps working unchanged.
        if (!strncasecmp(s, "usb:", 4)) s += 4;

        // Up to two optional `@` suffixes: usb:VVVV:PPPP[@token[@where]]
        // (specs/detector.md 4.1). ABSENT -- which is every config written so far
        // -- an entry means exactly what it has always meant, so there is nothing
        // to migrate and stopping here is still conformant for every existing
        // desk.
        const char *at = strchr(s, '@');
        if (at) {
            const char *at2 = strchr(at + 1, '@');
            size_t tlen = (size_t)((at2 ? at2 : at + strlen(at)) - (at + 1));
            if (!copy_suffix(at + 1, tlen, w->token, sizeof w->token)) return false;
            if (at2 && !copy_suffix(at2 + 1, strlen(at2 + 1), w->where, sizeof w->where)) return false;
        }
        char ids[16];
        size_t idlen = at ? (size_t)(at - s) : strlen(s);
        if (idlen >= sizeof ids) return false;
        memcpy(ids, s, idlen); ids[idlen] = '\0';

        if (!usb_spec_ok(ids)) return false;
        unsigned v, p;
        if (sscanf(ids, "%x:%x", &v, &p) != 2) return false;
        w->kind = W_USB;
        w->vendor = v; w->product = p;
        // The key echoes the entry back, suffixes and all, so the log and
        // `status` name what the config actually said rather than a prefix of it.
        snprintf(w->key, sizeof w->key, "usb:%04x:%04x%s%s%s%s", v, p,
                 w->token[0] ? "@" : "", w->token,
                 w->where[0] ? "@" : "", w->where);
    }
    g_nwatch++;
    return true;
}

// -------------------------------------------------------------------- main --

// A number of seconds: digits, or digits.digits (specs/detector.md 4). atof
// read `three` as 0.0, which switched the debounce and the settle OFF and made
// every event in a plug's burst a fire -- a watcher that ran and did the wrong
// thing. Refuse by name instead.
static double parse_secs(const char *s, const char *what) {
    const char *p = s;
    bool ok = isdigit((unsigned char)*p) != 0;
    while (isdigit((unsigned char)*p)) p++;
    if (*p == '.') { p++; ok = ok && isdigit((unsigned char)*p) != 0; while (isdigit((unsigned char)*p)) p++; }
    if (!ok || *p != '\0') {
        fprintf(stderr, "event-watch: %s must be seconds like 3 or 0.75, not '%s'\n", what, s);
        exit(2);
    }
    return atof(s);
}

int main(int argc, char **argv) {
    signal(SIGCHLD, SIG_IGN);   // auto-reap the spawned switcher
    bool want_list = false;
    bool want_lock = false;
    bool want_report = false;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT() (i + 1 < argc ? argv[++i] : (usage(argv[0]), ""))
        if      (!strcmp(a, "--exec"))          copy_arg(g_exec, sizeof g_exec, NEXT(), "--exec");
        else if (!strcmp(a, "--arg"))           copy_arg(g_arg,  sizeof g_arg,  NEXT(), "--arg");
        else if (!strcmp(a, "--log"))           copy_arg(g_log,  sizeof g_log,  NEXT(), "--log");
        else if (!strcmp(a, "--device")) {
            const char *d = NEXT();
            if (!add_device(d)) {
                fprintf(stderr, "event-watch: bad --device '%s': want usb:VVVV:PPPP[@token[@where]] (4+4 hex, each suffix lower-case [a-z0-9-]) or bt:AAAAAAAAAAAA (12 hex)\n", d);
                exit(2);
            }
        }
        else if (!strcmp(a, "--debounce"))      g_debounce = parse_secs(NEXT(), "--debounce");
        else if (!strcmp(a, "--settle"))        g_settle   = parse_secs(NEXT(), "--settle");
        else if (!strcmp(a, "--bt-poll"))       g_btpoll   = parse_secs(NEXT(), "--bt-poll");
        else if (!strcmp(a, "--max-log-bytes")) g_maxlog   = atol(NEXT());
        else if (!strcmp(a, "--timeout"))       g_timeout  = atoi(NEXT());
        else if (!strcmp(a, "--list"))          want_list  = true;
        else if (!strcmp(a, "--lock-status"))   want_lock  = true;
        else if (!strcmp(a, "--report"))        want_report = true;
        else if (!strcmp(a, "--test-trigger"))  g_testmode = true;
        else if (!strcmp(a, "--verbose"))       g_verbose  = true;
        else usage(argv[0]);
        #undef NEXT
    }

    // Answer and stop. Takes no lock, registers no events, writes no log and
    // starts nothing, so it cannot disturb a running watcher.
    if (want_list) { list_candidates(); return 0; }
    if (want_lock) { return lock_status(); }
    if (want_report) { return report_devices(); }

    if (g_nwatch == 0) usage(argv[0]);
    if (!g_testmode && !g_exec[0]) usage(argv[0]);

    // ---- one-shot: report an arrival and go ------------------------------
    //
    // Deliberately before the lock and before anything is armed: this is a
    // question about the devices, not a second watcher, so a real watcher may
    // run alongside it. It takes no lock and RUNS NOTHING -- the installer
    // decides whether to pull afterwards, because until the input values have
    // been confirmed by someone looking at a screen, a pull would aim
    // unverified values at panels.
    if (g_testmode) {
        bool state[MAX_WATCH];
        presence_sweep(state);
        printf("\n");
        for (int i = 0; i < g_nwatch; i++)
            printf("  %-20s %s\n", g_watch[i].key, state[i] ? "here now" : "not here");
        printf("\n  Flip your switch AWAY from this computer, then back again.\n");
        printf("  Waiting up to %ds. Ctrl+C to give up.\n\n", g_timeout);
        fflush(stdout);

        time_t deadline = time(NULL) + g_timeout;
        while (time(NULL) < deadline) {
            usleep(700 * 1000);
            bool now[MAX_WATCH];
            presence_sweep(now);
            for (int i = 0; i < g_nwatch; i++) {
                if (now[i] == state[i]) continue;
                if (now[i]) {
                    printf("  %s arrived -- this is what fires the switch.\n", g_watch[i].key);
                    fflush(stdout);
                    return 0;
                }
                printf("  %s left.\n", g_watch[i].key);
                fflush(stdout);
            }
            memcpy(state, now, sizeof state);
        }
        printf("  Nothing arrived.\n");
        return 1;
    }

    // ---- single instance --------------------------------------------------
    //
    // Enforced here rather than by whoever launches us. Two watchers would each
    // see the same arrival and each fire the switcher, and the debounce is
    // per-process so it cannot dedupe across them.
    //
    // flock, and note what that means: the kernel releases it when the holding
    // process dies, however it dies. So the ABANDONED-LOCK condition the
    // Windows side has to catch and take over does not exist here -- a
    // force-killed watcher leaves no lock behind, and there is deliberately no
    // takeover code to go looking for. (Windows uses a named mutex, which
    // survives its owner and throws AbandonedMutexException at the next
    // acquirer.) launchd's KeepAlive restarts us in about a hundredth of a
    // second, so the window in which no watcher holds it is not worth
    // engineering around.
    char lockpath[1200];
    lock_path(lockpath, sizeof lockpath);
    int lockfd = open(lockpath, O_CREAT | O_RDWR, 0644);
    if (lockfd < 0) {
        logmsg("WARN: cannot open %s (%s); continuing without a single-instance lock",
               lockpath, strerror(errno));
    } else if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) {
        logmsg("another watcher is already running; exiting");
        return 0;
    }

    // ---- the log ----------------------------------------------------------
    //
    // Rotate here and only here: AFTER the lock, so a redundant start (launchd
    // ticking while a watcher is alive) never rotates, and once per real start
    // rather than per write, so the switcher -- a separate process appending to
    // the same file -- can never race a rename mid-switch. The watcher is the
    // long-lived owner, so its startup is the one safe moment.
    if (g_log[0]) rotate_log();

    // ---- arm --------------------------------------------------------------

    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);

    for (int i = 0; i < g_nwatch; i++) {
        if (g_watch[i].kind != W_USB) continue;
        CFMutableDictionaryRef m = usb_match(g_watch[i].vendor, g_watch[i].product);
        if (!m) { logmsg("ERROR: IOServiceMatching(%s) failed", USB_CLASS); return 1; }
        kern_return_t kr = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, m,      // consumes `m`
            device_appeared, &g_watch[i], &g_watch[i].iter);
        if (kr != KERN_SUCCESS) {
            logmsg("ERROR: IOServiceAddMatchingNotification(%s) = 0x%x", g_watch[i].key, kr);
            return 1;
        }
        // Required: drain the iterator to arm the notification. Also primes.
        device_appeared(&g_watch[i], g_watch[i].iter);
    }

    // Bluetooth is polled, and ONLY when something Bluetooth is watched, so the
    // common USB-only setup pays nothing for it.
    if (any_bt_watched()) {
        bt_set_t bt;
        bt_connected(&bt);
        int armed = 0;
        for (int i = 0; i < g_nwatch; i++) {
            if (g_watch[i].kind != W_BT) continue;
            g_watch[i].present = bt_in(&bt, g_watch[i].addr);
            if (g_watch[i].present) armed++;
        }
        vlog("armed %d bluetooth device(s) (%d already connected, not firing), polling every %.1fs",
             g_nwatch, armed, g_btpoll);
        CFRunLoopTimerRef t = CFRunLoopTimerCreate(
            NULL, CFAbsoluteTimeGetCurrent() + g_btpoll, g_btpoll, 0, 0, bt_tick, NULL);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
        CFRelease(t);
    }

    // An ambiguous entry disables that ENTRY, not the watcher -- UNLESS nothing
    // usable is left (specs/detector.md 4.1). That is the one case where the
    // watcher would run and never fire, which someone meets as "it just stopped
    // working" with no visible cause; refusing is the kinder answer, and under a
    // supervisor it is loud in the log, which is the point.
    //
    // Deliberately NOT the treatment a malformed entry gets: a malformed entry
    // can never match, while an ambiguous one has its devices present and only
    // "which" unresolved, so refusing over one would turn a cosmetic uncertainty
    // into total non-operation.
    int usable = 0;
    for (int i = 0; i < g_nwatch; i++) if (!g_watch[i].ambiguous) usable++;
    if (usable == 0) {
        logmsg("REFUSING to watch: every configured trigger is ambiguous, so "
               "nothing could ever fire. Re-run: trigger-kvm configure");
        return 2;
    }

    int already = 0;
    for (int i = 0; i < g_nwatch; i++) if (g_watch[i].present) already++;

    logmsg("watching %d device(s); exec=%s arg=%s debounce=%.1fs settle=%.2fs",
           usable, g_exec, g_arg, g_debounce, g_settle);
    if (usable != g_nwatch)
        logmsg("%d of %d trigger(s) disabled as ambiguous; the rest keep watching",
               g_nwatch - usable, g_nwatch);
    logmsg("armed (%d already present, not firing)", already);

    CFRunLoopRun();
    return 0;
}
