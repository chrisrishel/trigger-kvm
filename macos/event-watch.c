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
    char     key[32];         // "usb:046d:0843" or "bt:0011223344ff"
    uint32_t vendor, product; // usb
    char     addr[16];        // bt, lower-case hex, no separators
    io_iterator_t iter;
    bool     primed;          // first callback drains pre-existing devices
    bool     present;
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

static bool usb_present(uint32_t vendor, uint32_t product) {
    CFMutableDictionaryRef m = usb_match(vendor, product);
    if (!m) return false;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return false;
    io_service_t s = IOIteratorNext(it);
    bool found = (s != IO_OBJECT_NULL);
    if (s) IOObjectRelease(s);
    while ((s = IOIteratorNext(it))) IOObjectRelease(s);
    IOObjectRelease(it);
    return found;
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

static void cf_to_c(CFStringRef s, char *out, size_t outsz) {
    out[0] = '\0';
    if (s && CFGetTypeID(s) == CFStringGetTypeID())
        CFStringGetCString(s, out, (CFIndex)outsz, kCFStringEncodingUTF8);
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
        } else {
            out[i] = usb_present(g_watch[i].vendor, g_watch[i].product);
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
    bool any = false;
    for (int i = 0; i < g_nwatch; i++) { g_watch[i].present = now[i]; if (now[i]) any = true; }

    if (!any) {
        logmsg("device vanished during settle window; ignoring (glitch, not a switch)");
        return;
    }
    g_last_fire = CFAbsoluteTimeGetCurrent();
    run_exec();
}

// An arrival edge was seen. Debounce, then settle, then fire.
static void arrival(const char *what) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_last_fire < g_debounce) {
        vlog("arrival %s within debounce (%.1fs); ignoring", what, now - g_last_fire);
        return;
    }
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

    int n = 0;
    io_service_t s;
    while ((s = IOIteratorNext(iter))) { n++; IOObjectRelease(s); }

    if (!w->primed) {
        w->primed = true;
        w->present = (n > 0);
        vlog("armed %s (%d already present, not firing)", w->key, n);
        return;
    }
    if (n == 0) return;
    w->present = true;
    arrival(w->key);
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
        if (now && !was) arrival(g_watch[i].key);
    }
}

// -------------------------------------------------------------------- list --

typedef struct { char key[32]; char name[128]; char state[24]; char kind[4]; } row_t;
static row_t g_rows[MAX_ROWS];
static int   g_nrows = 0;

static void add_row(const char *kind, const char *key, const char *state, const char *name) {
    for (int i = 0; i < g_nrows; i++) if (!strcmp(g_rows[i].key, key)) return;  // one row per id
    if (g_nrows >= MAX_ROWS) return;
    row_t *r = &g_rows[g_nrows++];
    snprintf(r->kind, sizeof r->kind, "%s", kind);
    snprintf(r->key,  sizeof r->key,  "%s", key);
    snprintf(r->state,sizeof r->state,"%s", state);
    snprintf(r->name, sizeof r->name, "%s", name);
    for (char *p = r->name; *p; p++) if (*p == '|') *p = ' ';
}

static void bt_row(const char *addr, const char *name, bool conn, void *ctx) {
    (void)ctx;
    char key[32];
    snprintf(key, sizeof key, "bt:%s", addr);
    add_row("bt", key, conn ? "connected now" : "paired, not connected",
            name[0] ? name : "(unnamed)");
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
            CFTypeRef n = IORegistryEntryCreateCFProperty(s, CFSTR("USB Product Name"), NULL, 0);
            int vid = 0, pid = 0;
            char name[128] = "";
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &vid);
            if (p && CFGetTypeID(p) == CFNumberGetTypeID()) CFNumberGetValue(p, kCFNumberIntType, &pid);
            cf_to_c((CFStringRef)n, name, sizeof name);
            if (v) CFRelease(v);
            if (p) CFRelease(p);
            if (n) CFRelease(n);
            IOObjectRelease(s);

            // Hubs and controllers are attached permanently and never move; a
            // failed enumeration (vid 0) is not addressable at all.
            if (vid == 0) continue;
            if (strcasestr(name, "hub") || strcasestr(name, "host controller") ||
                strcasestr(name, "root complex")) continue;

            char key[32];
            snprintf(key, sizeof key, "usb:%04x:%04x", vid, pid);
            add_row("usb", key, "attached now", name[0] ? name : "(unnamed)");
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

    for (int i = 0; i < g_nrows; i++)
        printf("%s|%s|%s|%s\n", g_rows[i].kind, g_rows[i].key, g_rows[i].state, g_rows[i].name);
}

// -------------------------------------------------------------------- args --

static void usage(const char *me) {
    fprintf(stderr,
      "usage: %s --exec PATH [--arg ARG] --device usb:VVVV:PPPP|bt:AAAAAAAAAAAA ...\n"
      "          [--debounce S] [--settle S] [--bt-poll S] [--log PATH]\n"
      "          [--max-log-bytes N] [--verbose]\n"
      "       %s --list\n"
      "       %s --test-trigger --device ... [--timeout S]\n", me, me, me);
    exit(2);
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

static bool add_device(const char *spec) {
    if (g_nwatch >= MAX_WATCH) return false;
    watch_t *w = &g_watch[g_nwatch];
    memset(w, 0, sizeof *w);

    const char *s = spec;
    if (!strncasecmp(s, "bt:", 3)) {
        char addr[16];
        bt_normalize(s + 3, addr, sizeof addr);
        if (strlen(addr) != 12) return false;
        w->kind = W_BT;
        snprintf(w->addr, sizeof w->addr, "%s", addr);
        snprintf(w->key, sizeof w->key, "bt:%s", addr);
    } else {
        // A bare VVVV:PPPP means usb, so a config written before Bluetooth
        // existed keeps working unchanged.
        if (!strncasecmp(s, "usb:", 4)) s += 4;
        unsigned v, p;
        if (sscanf(s, "%x:%x", &v, &p) != 2) return false;
        w->kind = W_USB;
        w->vendor = v; w->product = p;
        snprintf(w->key, sizeof w->key, "usb:%04x:%04x", v, p);
    }
    g_nwatch++;
    return true;
}

// -------------------------------------------------------------------- main --

int main(int argc, char **argv) {
    signal(SIGCHLD, SIG_IGN);   // auto-reap the spawned switcher
    bool want_list = false;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT() (i + 1 < argc ? argv[++i] : (usage(argv[0]), ""))
        if      (!strcmp(a, "--exec"))          copy_arg(g_exec, sizeof g_exec, NEXT(), "--exec");
        else if (!strcmp(a, "--arg"))           copy_arg(g_arg,  sizeof g_arg,  NEXT(), "--arg");
        else if (!strcmp(a, "--log"))           copy_arg(g_log,  sizeof g_log,  NEXT(), "--log");
        else if (!strcmp(a, "--device"))      { if (!add_device(NEXT())) usage(argv[0]); }
        else if (!strcmp(a, "--debounce"))      g_debounce = atof(NEXT());
        else if (!strcmp(a, "--settle"))        g_settle   = atof(NEXT());
        else if (!strcmp(a, "--bt-poll"))       g_btpoll   = atof(NEXT());
        else if (!strcmp(a, "--max-log-bytes")) g_maxlog   = atol(NEXT());
        else if (!strcmp(a, "--timeout"))       g_timeout  = atoi(NEXT());
        else if (!strcmp(a, "--list"))          want_list  = true;
        else if (!strcmp(a, "--test-trigger"))  g_testmode = true;
        else if (!strcmp(a, "--verbose"))       g_verbose  = true;
        else usage(argv[0]);
        #undef NEXT
    }

    // Answer and stop. Takes no lock, registers no events, writes no log and
    // starts nothing, so it cannot disturb a running watcher.
    if (want_list) { list_candidates(); return 0; }

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
    const char *home = getenv("HOME");
    snprintf(lockpath, sizeof lockpath,
             "%s/Library/Application Support/trigger-kvm/watcher.lock", home ? home : "/tmp");
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

    int already = 0;
    for (int i = 0; i < g_nwatch; i++) if (g_watch[i].present) already++;

    logmsg("watching %d device(s); exec=%s arg=%s debounce=%.1fs settle=%.2fs",
           g_nwatch, g_exec, g_arg, g_debounce, g_settle);
    logmsg("armed (%d already present, not firing)", already);

    CFRunLoopRun();
    return 0;
}
