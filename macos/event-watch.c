// event-watch -- run a command when a watched device ARRIVES here.
//
//   event-watch --exec /path/to/trigger-kvm --arg pull \
//               --device usb:046d:0843 --device bt:0011223344ff \
//               [--debounce 3.0] [--settle 0.75] [--log PATH] [--verbose]
//   event-watch --list                   candidate trigger devices, and exit
//   event-watch --report --device ...    how each entry resolves right now
//   event-watch --lock-status            is a watcher running (from the lock)
//   event-watch --test-trigger --device ... [--timeout S]   report ONE arrival
//
// The contract is specs/detector.md. One process, N sources (USB via IOKit
// notifications, Bluetooth by polling system_profiler), one debounce, one
// lock, and the ONE owner of "is that device here?": --list and --report exist
// so the walkthrough and `status` ask this program rather than re-implementing
// the enumeration and the matching rule.
//
// Two harness seams, read only when set: TK_BT_PLIST names a plist to read in
// place of system_profiler, and TK_USB_LIST names a file of
// `vendor|product|name|where|role` rows to read in place of IOKit. With
// TK_USB_LIST the watcher polls that file (--usb-poll) instead of subscribing,
// so the suite can stage arrivals of specific devices on any Mac.
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

// The USB device class on Apple Silicon; the older IOUSBDevice name is not
// reliable here.
#define USB_CLASS "IOUSBHostDevice"
#define MAX_WATCH 16
#define MAX_ROWS  256

extern char **environ;

typedef enum { W_USB, W_BT } kind_t;

typedef struct {
    kind_t   kind;
    char     key[128];        // the entry as written: usb:VVVV:PPPP[@token[@where]] or bt:AAAAAAAAAAAA
    uint32_t vendor, product; // usb
    char     token[64];       // which device among those sharing the id; empty = any
    char     where[32];       // tiebreak among those carrying the token; empty = none
    char     addr[16];        // bt, lower-case hex, no separators
    io_iterator_t iter;
    bool     primed;          // the first callback establishes the baseline and never fires
    bool     present;
    bool     arrived;         // arrived during the current settle window
    bool     ambiguous;       // last reported state, for logging transitions only
    bool     by_where;        // last reported state, for logging transitions only
} watch_t;

static watch_t   g_watch[MAX_WATCH];
static int       g_nwatch   = 0;
static char      g_exec[1024];
static char      g_arg[64]  = "pull";
static char      g_log[1024];
static double    g_debounce = 3.0;
static double    g_settle   = 0.75;
static double    g_btpoll   = 2.0;
static double    g_usbpoll  = 0.3;
static long      g_maxlog   = 1024 * 1024;
static int       g_timeout  = 120;
static bool      g_verbose  = false;
static bool      g_testmode = false;
static CFAbsoluteTime g_last_fire = 0;
static bool      g_settle_pending = false;

// ---------------------------------------------------------------- logging --
//
// Stderr only. launchd points StandardErrorPath at the log, and the spawned
// switcher inherits stderr, so one stream carries an arrival and the switch it
// caused in order. --log names that file so the watcher knows what to rotate.

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

// Copy then TRUNCATE, never rename: launchd opened StandardErrorPath once and
// our stderr IS that descriptor, so a rename would strand every later line in
// the .1 file. Truncation keeps the inode (docs/measurements.md, "Logs").
static void rotate_log(void) {
    struct stat st;
    if (stat(g_log, &st) != 0 || st.st_size <= g_maxlog) return;

    char old[1200];
    snprintf(old, sizeof old, "%s.1", g_log);

    int src = open(g_log, O_RDONLY);
    if (src < 0) { logmsg("WARN: cannot read %s to rotate it", g_log); return; }
    int dst = open(old, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (dst < 0) { close(src); logmsg("WARN: cannot write %s", old); return; }

    char buf[65536];
    ssize_t n;
    bool copied = true;
    while ((n = read(src, buf, sizeof buf)) > 0) {
        if (write(dst, buf, (size_t)n) != n) { copied = false; break; }
    }
    if (n < 0) copied = false;
    close(dst);
    close(src);
    if (!copied) { logmsg("WARN: could not copy %s to %s; not rotating", g_log, old); return; }

    int live = open(g_log, O_WRONLY);
    if (live < 0 || ftruncate(live, 0) != 0) {
        logmsg("WARN: copied %s to %s but could not truncate it (%s)", g_log, old, strerror(errno));
        if (live >= 0) close(live);
        return;
    }
    close(live);
    logmsg("rotated log at %lld bytes (previous kept as %s)", (long long)st.st_size, old);
}

// -------------------------------------------------------------------- text --

static void cf_to_c(CFStringRef s, char *out, size_t outsz) {
    out[0] = '\0';
    if (s && CFGetTypeID(s) == CFStringGetTypeID())
        CFStringGetCString(s, out, (CFIndex)outsz, kCFStringEncodingUTF8);
}

// Reduce a device's own name into the config's token class, [a-z0-9-]
// (specs/config-format.md): a run of anything else becomes at most one dash.
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
            dash = true;
        }
    }
    out[o] = '\0';
}

// A name is shown in menus and written as a `|`-separated row: control
// characters and the separator become spaces.
static void printable(char *s) {
    for (char *p = s; *p; p++)
        if ((unsigned char)*p < 0x20 || *p == 0x7F || *p == '|') *p = ' ';
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

// ------------------------------------------------------------- USB devices --
//
// One snapshot of every attached USB device, taken once per sweep. IOKit is
// the source; TK_USB_LIST replaces it for the suite.

typedef struct {
    uint32_t vendor, product;
    char name[128];    // the device's own iProduct string
    char where[32];    // locationID as eight hex digits; the config's `where`
    char role[32];     // mouse, keyboard, or both, from the HID usage pages
} usb_dev_t;

typedef struct { usb_dev_t d[MAX_ROWS]; int n; } usb_set_t;

// What a device presents itself as, from the HID usage pages on its child
// nodes, read as properties so nothing is opened. Generic Desktop usage 2 is a
// mouse, 6 a keyboard. A receiver carrying both presents both.
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
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFSTR("USB Product Name"), NULL, 0);
    if (!v) v = IORegistryEntryCreateCFProperty(s, CFSTR("kUSBProductString"), NULL, 0);
    cf_to_c((CFStringRef)v, out, n);
    if (v) CFRelease(v);
    printable(out);
}

static int usb_int_prop(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, NULL, 0);
    int out = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &out);
    if (v) CFRelease(v);
    return out;
}

// One device from an IOKit service. False for a node that is not a device at
// all (no vendor id), the only thing the enumeration withholds.
static bool usb_dev_from_service(io_service_t s, usb_dev_t *d) {
    memset(d, 0, sizeof *d);
    d->vendor  = (uint32_t)usb_int_prop(s, CFSTR("idVendor"));
    d->product = (uint32_t)usb_int_prop(s, CFSTR("idProduct"));
    if (d->vendor == 0) return false;
    usb_name(s, d->name, sizeof d->name);
    usb_where(s, d->where, sizeof d->where);
    usb_role(s, d->role, sizeof d->role, 0);
    return true;
}

static void usb_set_add(usb_set_t *set, const usb_dev_t *d) {
    if (set->n < MAX_ROWS) set->d[set->n++] = *d;
}

// The fixture: `vendor|product|name|where|role` per line, hex ids.
static void usb_snapshot_fixture(const char *path, usb_set_t *out) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = '\0';
        usb_dev_t d; memset(&d, 0, sizeof d);
        char *field[5] = { line, NULL, NULL, NULL, NULL };
        int nf = 1;
        for (char *p = line; *p && nf < 5; p++) if (*p == '|') { *p = '\0'; field[nf++] = p + 1; }
        if (nf < 2) continue;
        d.vendor  = (uint32_t)strtoul(field[0], NULL, 16);
        d.product = (uint32_t)strtoul(field[1], NULL, 16);
        if (d.vendor == 0) continue;
        if (field[2]) snprintf(d.name,  sizeof d.name,  "%s", field[2]);
        if (field[3]) snprintf(d.where, sizeof d.where, "%s", field[3]);
        if (field[4]) snprintf(d.role,  sizeof d.role,  "%s", field[4]);
        printable(d.name);
        usb_set_add(out, &d);
    }
    fclose(f);
}

static void usb_snapshot(usb_set_t *out) {
    out->n = 0;
    const char *fixture = getenv("TK_USB_LIST");
    if (fixture) { usb_snapshot_fixture(fixture, out); return; }

    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching(USB_CLASS), &it) != KERN_SUCCESS) return;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        usb_dev_t d;
        if (usb_dev_from_service(s, &d)) usb_set_add(out, &d);
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
}

// Does this device satisfy the entry's id and token? `where` is not consulted
// here; it is a tiebreak applied over the whole set (usb_resolve).
static bool usb_dev_matches(const usb_dev_t *d, const watch_t *w) {
    if (d->vendor != w->vendor || d->product != w->product) return false;
    if (!w->token[0]) return true;
    char slug[64];
    slugify(d->name, slug, sizeof slug);
    return strcmp(slug, w->token) == 0;
}

// specs/detector.md 4.1, the matching table, over one snapshot. Returns how
// many devices the entry resolves to: 0 absent, 1 resolved, >1 ambiguous. Sets
// *by_where when the port broke a tie. Never falls back to the whole id.
static int usb_resolve(const usb_set_t *set, const watch_t *w, bool *by_where) {
    *by_where = false;
    int matched = 0, at_where = 0;
    for (int i = 0; i < set->n; i++) {
        if (!usb_dev_matches(&set->d[i], w)) continue;
        matched++;
        if (w->where[0] && !strcmp(set->d[i].where, w->where)) at_where++;
    }
    if (matched > 1 && w->where[0] && at_where == 1) { *by_where = true; return 1; }
    return matched;
}

// Say once when an entry becomes ambiguous or resolves again, and once when
// the port starts or stops deciding. Returns true when the entry is usable
// (not ambiguous) right now.
static bool usb_report_state(watch_t *w, int n, bool by_where) {
    bool ambiguous = (n > 1 && w->token[0]);
    if (ambiguous && !w->ambiguous)
        logmsg("AMBIGUOUS: %s matches %d present devices and none is at the remembered "
               "port; this trigger is disabled until that changes, the others keep watching",
               w->key, n);
    if (!ambiguous && w->ambiguous)
        logmsg("%s resolves to one device again", w->key);
    if (by_where && !w->by_where)
        logmsg("%s: the remembered port decided which device this is", w->key);
    w->ambiguous = ambiguous;
    w->by_where = by_where;
    return !ambiguous;
}

// ------------------------------------------------------- Bluetooth devices --
//
// system_profiler, not IOBluetooth: IOBluetooth is TCC-gated per binary and an
// unapproved binary's first call blocks until a human answers a prompt, with
// the process alive, so KeepAlive would never restart it (macos/AGENTS.md).
// Polled, and only when a bt: device is configured.

static CFArrayRef bt_section(CFDictionaryRef items, CFStringRef key) {
    CFTypeRef v = CFDictionaryGetValue(items, key);
    if (v && CFGetTypeID(v) == CFArrayGetTypeID()) return (CFArrayRef)v;
    return NULL;
}

// The `_items[0]` dictionary of system_profiler's plist, or NULL when
// Bluetooth is unavailable, which callers treat as "nothing connected".
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

    CFDictionaryRef items = NULL;
    if (CFGetTypeID(plist) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)plist) > 0) {
        CFDictionaryRef top = CFArrayGetValueAtIndex((CFArrayRef)plist, 0);
        if (CFGetTypeID(top) == CFDictionaryGetTypeID()) {
            CFArrayRef inner = bt_section(top, CFSTR("_items"));
            if (inner && CFArrayGetCount(inner) > 0) {
                CFTypeRef e = CFArrayGetValueAtIndex(inner, 0);
                if (CFGetTypeID(e) == CFDictionaryGetTypeID())
                    items = CFDictionaryCreateCopy(NULL, (CFDictionaryRef)e);
            }
        }
    }
    CFRelease(plist);
    return items;
}

// Walk one section, calling back with (address, name, connected). Each entry
// is a one-key dictionary { "<device name>": { device_address: ... } }; an
// entry with more keys than the buffers hold is skipped whole.
static void bt_each(CFDictionaryRef items, CFStringRef section, bool connected,
                    void (*fn)(const char *addr, const char *name, bool conn, void *ctx),
                    void *ctx) {
    CFArrayRef arr = bt_section(items, section);
    if (!arr) return;
    for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
        CFTypeRef e = CFArrayGetValueAtIndex(arr, i);
        if (CFGetTypeID(e) != CFDictionaryGetTypeID()) continue;
        CFIndex nk = CFDictionaryGetCount((CFDictionaryRef)e);
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
            printable(name);
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

// The connected set, enumerated once per sweep.
static void bt_connected(bt_set_t *out) {
    out->n = 0;
    CFDictionaryRef items = bt_read();
    if (!items) { vlog("Bluetooth enumeration unavailable; treating as none connected"); return; }
    bt_each(items, CFSTR("device_connected"), true, bt_collect, out);
    CFRelease(items);
}

static bool bt_in(const bt_set_t *s, const char *addr) {
    for (int i = 0; i < s->n; i++) if (!strcmp(s->addr[i], addr)) return true;
    return false;
}

// ---------------------------------------------------------------- presence --

static bool any_watched(kind_t kind) {
    for (int i = 0; i < g_nwatch; i++) if (g_watch[i].kind == kind) return true;
    return false;
}

// One sweep across every watched device: one USB snapshot, one Bluetooth
// enumeration. Presence for Bluetooth means CONNECTED, never paired. An
// ambiguous USB entry is not present and never produces an edge; its state is
// re-evaluated here every time, never latched.
static void presence_sweep(bool *out) {
    usb_set_t usb; usb.n = 0;
    bt_set_t bt; bt.n = 0;
    if (any_watched(W_USB)) usb_snapshot(&usb);
    if (any_watched(W_BT))  bt_connected(&bt);

    for (int i = 0; i < g_nwatch; i++) {
        watch_t *w = &g_watch[i];
        if (w->kind == W_BT) { out[i] = bt_in(&bt, w->addr); continue; }
        bool by_where;
        int n = usb_resolve(&usb, w, &by_where);
        bool usable = usb_report_state(w, n, by_where);
        out[i] = usable && n > 0;
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

// Fire only if a device that ARRIVED is still present (specs/detector.md 2).
static void settle_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    g_settle_pending = false;

    bool now[MAX_WATCH];
    presence_sweep(now);
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

// An arrival edge. Debounce, then settle, then fire.
static void arrival(watch_t *w) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_last_fire < g_debounce) {
        vlog("arrival %s within debounce (%.1fs); ignoring", w->key, now - g_last_fire);
        return;
    }
    w->arrived = true;
    if (g_settle_pending) { vlog("arrival %s; settle already pending", w->key); return; }
    logmsg("arrival %s; settling %.2fs", w->key, g_settle);
    g_settle_pending = true;
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + g_settle, 0, 0, 0, settle_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
    CFRelease(t);
}

// Devices sharing this entry's id have just arrived. The edge belongs to the
// device the entry resolves to (specs/detector.md 2): with a qualified entry,
// another device sharing the id arriving while the configured one is already
// present is not an edge. The first call per entry establishes the baseline.
static void usb_arrived(watch_t *w, const usb_set_t *arrived) {
    usb_set_t now;
    usb_snapshot(&now);
    bool by_where;
    int n = usb_resolve(&now, w, &by_where);
    bool usable = usb_report_state(w, n, by_where);

    int hit = 0;
    for (int i = 0; i < arrived->n; i++) {
        const usb_dev_t *d = &arrived->d[i];
        if (!usb_dev_matches(d, w)) continue;
        if (by_where && strcmp(d->where, w->where) != 0) continue;
        hit++;
    }

    if (!w->primed) {
        w->primed = true;
        w->present = usable && n > 0;
        vlog("armed %s (%d already present, not firing)", w->key, usable ? n : 0);
        return;
    }
    if (!usable || n == 0) return;
    if (hit == 0) { vlog("%s: a device sharing its id arrived, but not the one it names", w->key); return; }
    w->present = true;
    arrival(w);
}

// IOKit delivers the matched services for one watch; drain the iterator (or
// the notification is never re-armed) into a set and decide.
static void device_appeared(void *refcon, io_iterator_t iter) {
    watch_t *w = (watch_t *)refcon;
    usb_set_t arrived; arrived.n = 0;
    io_service_t s;
    while ((s = IOIteratorNext(iter))) {
        usb_dev_t d;
        if (usb_dev_from_service(s, &d)) usb_set_add(&arrived, &d);
        IOObjectRelease(s);
    }
    usb_arrived(w, &arrived);
}

// The fixture has no notifications, so it is polled: whatever is in the new
// snapshot and not the last one arrived.
static usb_set_t g_usb_last;
static bool usb_set_has(const usb_set_t *set, const usb_dev_t *d) {
    for (int i = 0; i < set->n; i++)
        if (set->d[i].vendor == d->vendor && set->d[i].product == d->product &&
            !strcmp(set->d[i].where, d->where) && !strcmp(set->d[i].name, d->name)) return true;
    return false;
}
static void usb_tick(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    usb_set_t now;
    usb_snapshot(&now);
    for (int i = 0; i < g_nwatch; i++) {
        watch_t *w = &g_watch[i];
        if (w->kind != W_USB) continue;
        usb_set_t arrived; arrived.n = 0;
        for (int j = 0; j < now.n; j++)
            if (now.d[j].vendor == w->vendor && now.d[j].product == w->product &&
                !usb_set_has(&g_usb_last, &now.d[j])) usb_set_add(&arrived, &now.d[j]);
        if (arrived.n > 0 || !w->primed) usb_arrived(w, &arrived);
    }
    g_usb_last = now;
}

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
    char kind[4]; char key[32]; char state[24]; char name[128];
    char role[32]; char token[64]; char where[32];
} row_t;
static row_t g_rows[MAX_ROWS];
static int   g_nrows = 0;

// One row per physical device (two devices of one model are two rows sharing
// a key); Bluetooth dedupes on the address, which really is one per device.
static void add_row(const char *kind, const char *key, const char *state,
                    const char *name, const char *role,
                    const char *token, const char *where) {
    if (!strcmp(kind, "bt"))
        for (int i = 0; i < g_nrows; i++) if (!strcmp(g_rows[i].key, key)) return;
    if (g_nrows >= MAX_ROWS) return;
    row_t *r = &g_rows[g_nrows++];
    snprintf(r->kind,  sizeof r->kind,  "%s", kind);
    snprintf(r->key,   sizeof r->key,   "%s", key);
    snprintf(r->state, sizeof r->state, "%s", state);
    snprintf(r->name,  sizeof r->name,  "%s", name);
    snprintf(r->role,  sizeof r->role,  "%s", role  ? role  : "");
    snprintf(r->token, sizeof r->token, "%s", token ? token : "");
    snprintf(r->where, sizeof r->where, "%s", where ? where : "");
}

static void bt_row(const char *addr, const char *name, bool conn, void *ctx) {
    (void)ctx;
    char key[32];
    snprintf(key, sizeof key, "bt:%s", addr);
    add_row("bt", key, conn ? "connected now" : "paired, not connected",
            name[0] ? name : "(unnamed)", "", "", "");
}

// Candidate trigger devices: every USB device attached right now and every
// Bluetooth device paired (connected or not), nothing filtered by name
// (specs/configure.md 7.1). Emits kind|key|state|name|role|token|where.
static void list_candidates(void) {
    usb_set_t usb;
    usb_snapshot(&usb);
    for (int i = 0; i < usb.n; i++) {
        const usb_dev_t *d = &usb.d[i];
        char key[32], token[64];
        snprintf(key, sizeof key, "usb:%04x:%04x", d->vendor, d->product);
        slugify(d->name, token, sizeof token);
        add_row("usb", key, "attached now", d->name[0] ? d->name : "(unnamed)",
                d->role, token, d->where);
    }

    CFDictionaryRef items = bt_read();
    if (items) {
        bt_each(items, CFSTR("device_connected"),     true,  bt_row, NULL);
        bt_each(items, CFSTR("device_not_connected"), false, bt_row, NULL);
        CFRelease(items);
    }

    for (int i = 0; i < g_nrows; i++)
        printf("%s|%s|%s|%s|%s|%s|%s\n", g_rows[i].kind, g_rows[i].key,
               g_rows[i].state, g_rows[i].name,
               g_rows[i].role, g_rows[i].token, g_rows[i].where);
}

// How each configured entry resolves right now, as key|verdict|count, from the
// same matching code the watcher fires on (specs/status.md 4.1). Takes no
// lock and starts nothing.
static int report_devices(void) {
    usb_set_t usb; usb.n = 0;
    bt_set_t bt; bt.n = 0;
    if (any_watched(W_USB)) usb_snapshot(&usb);
    if (any_watched(W_BT))  bt_connected(&bt);
    for (int i = 0; i < g_nwatch; i++) {
        watch_t *w = &g_watch[i];
        if (w->kind == W_BT) {
            bool in = bt_in(&bt, w->addr);
            printf("%s|%s|%d\n", w->key, in ? "present" : "absent", in ? 1 : 0);
            continue;
        }
        bool by_where;
        int n = usb_resolve(&usb, w, &by_where);
        const char *verdict = "absent";
        if (n > 1 && w->token[0]) verdict = "ambiguous";
        else if (n > 0 && by_where) verdict = "where";
        else if (n > 0)            verdict = "present";
        printf("%s|%s|%d\n", w->key, verdict, n);
    }
    return 0;
}

// -------------------------------------------------------------------- lock --

// One spelling of the lock path: main() takes it and --lock-status asks.
static void lock_path(char *dst, size_t dstsz) {
    const char *home = getenv("HOME");
    snprintf(dst, dstsz, "%s/Library/Application Support/trigger-kvm/watcher.lock",
             home ? home : "/tmp");
}

// Is a watcher running, answered from the lock (specs/status.md 2). A file
// that exists but cannot be opened is a RUNNING watcher, not an absent one.
// Creates nothing: a stray file would read as a watcher on the next ask.
// close() releases the flock. Prints one word; exits 0 running, 1 none.
static int lock_status(void) {
    char path[1200];
    lock_path(path, sizeof path);
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        if (errno == ENOENT) { printf("none\n"); return 1; }
        printf("running\n");
        return 0;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); printf("running\n"); return 0; }
    close(fd);
    printf("none\n");
    return 1;
}

// -------------------------------------------------------------------- args --

static void usage(const char *me) {
    fprintf(stderr,
      "usage: %s --exec PATH [--arg ARG] --device usb:VVVV:PPPP[@token[@where]]|bt:AAAAAAAAAAAA ...\n"
      "          [--debounce S] [--settle S] [--bt-poll S] [--usb-poll S] [--log PATH]\n"
      "          [--max-log-bytes N] [--verbose]\n"
      "       %s --list\n"
      "       %s --lock-status\n"
      "       %s --report --device ...\n"
      "       %s --test-trigger --device ... [--timeout S]\n", me, me, me, me, me);
    exit(2);
}

// Copy an argument or refuse: a silently truncated path is a different path.
static void copy_arg(char *dst, size_t dstsz, const char *src, const char *what) {
    if (strlen(src) >= dstsz) {
        fprintf(stderr, "event-watch: %s is too long (%zu bytes, max %zu)\n",
                what, strlen(src), dstsz - 1);
        exit(2);
    }
    snprintf(dst, dstsz, "%s", src);
}

static bool hexrun(const char *s, size_t n, char after) {
    for (size_t i = 0; i < n; i++) if (!isxdigit((unsigned char)s[i])) return false;
    return s[n] == after;
}

static bool usb_spec_ok(const char *s) { return hexrun(s, 4, ':') && hexrun(s + 5, 4, '\0'); }

// A suffix is [a-z0-9-]+, checked lower-case rather than normalised
// (specs/config-format.md).
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

// The grammar of specs/detector.md 4: usb:VVVV:PPPP[@token[@where]] (a bare
// VVVV:PPPP means usb) or bt: plus twelve hex digits. Anything else is refused.
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
        if (!strncasecmp(s, "usb:", 4)) s += 4;
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
        snprintf(w->key, sizeof w->key, "usb:%04x:%04x%s%s%s%s", v, p,
                 w->token[0] ? "@" : "", w->token,
                 w->where[0] ? "@" : "", w->where);
    }
    g_nwatch++;
    return true;
}

// Seconds: digits, or digits.digits (specs/detector.md 4). Refused by name,
// never read as zero.
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

// -------------------------------------------------------------------- main --

int main(int argc, char **argv) {
    signal(SIGCHLD, SIG_IGN);   // auto-reap the spawned switcher
    bool want_list = false, want_lock = false, want_report = false;

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
        else if (!strcmp(a, "--usb-poll"))      g_usbpoll  = parse_secs(NEXT(), "--usb-poll");
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

    // The questions: no lock, no events, no log, nothing started.
    if (want_list) { list_candidates(); return 0; }
    if (want_lock) { return lock_status(); }
    if (want_report) { return report_devices(); }

    if (g_nwatch == 0) usage(argv[0]);
    if (!g_testmode && !g_exec[0]) usage(argv[0]);

    // The one-shot (specs/detector.md 3): report one arrival and exit, before
    // the lock and before anything is armed, running nothing.
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

    // Single instance, enforced here with a flock (released by the kernel
    // when the holder dies, so there is no abandoned-lock case to take over).
    // A held lock is a redundant start and a successful no-op; any other
    // failure refuses, because a watcher must never run unlocked.
    char lockpath[1200];
    lock_path(lockpath, sizeof lockpath);
    int lockfd = open(lockpath, O_CREAT | O_RDWR | O_CLOEXEC, 0644);
    if (lockfd < 0) {
        logmsg("REFUSING to watch: cannot open the single-instance lock %s (%s)", lockpath, strerror(errno));
        return 2;
    }
    if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK) { logmsg("another watcher is already running; exiting"); return 0; }
        logmsg("REFUSING to watch: cannot take the single-instance lock %s (%s)", lockpath, strerror(errno));
        return 2;
    }

    // Rotate here and only here: after the lock, once per real start.
    if (g_log[0]) rotate_log();

    // Arm. USB subscribes through IOKit, or polls the fixture; the first
    // callback per entry is the baseline and never fires.
    if (any_watched(W_USB)) {
        if (getenv("TK_USB_LIST")) {
            g_usb_last.n = 0;
            usb_tick(NULL, NULL);
            CFRunLoopTimerRef t = CFRunLoopTimerCreate(
                NULL, CFAbsoluteTimeGetCurrent() + g_usbpoll, g_usbpoll, 0, 0, usb_tick, NULL);
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
            CFRelease(t);
        } else {
            IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
            CFRunLoopAddSource(CFRunLoopGetCurrent(),
                               IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
            for (int i = 0; i < g_nwatch; i++) {
                watch_t *w = &g_watch[i];
                if (w->kind != W_USB) continue;
                CFMutableDictionaryRef m = IOServiceMatching(USB_CLASS);
                if (!m) { logmsg("ERROR: IOServiceMatching(%s) failed", USB_CLASS); return 1; }
                CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &w->vendor);
                CFNumberRef p = CFNumberCreate(NULL, kCFNumberSInt32Type, &w->product);
                CFDictionarySetValue(m, CFSTR("idVendor"),  v);
                CFDictionarySetValue(m, CFSTR("idProduct"), p);
                CFRelease(v); CFRelease(p);
                kern_return_t kr = IOServiceAddMatchingNotification(
                    port, kIOFirstMatchNotification, m, device_appeared, w, &w->iter);
                if (kr != KERN_SUCCESS) {
                    logmsg("ERROR: IOServiceAddMatchingNotification(%s) = 0x%x", w->key, kr);
                    return 1;
                }
                device_appeared(w, w->iter);   // drains to arm; also primes
            }
        }
    }

    if (any_watched(W_BT)) {
        bt_set_t bt;
        bt_connected(&bt);
        int armed = 0;
        for (int i = 0; i < g_nwatch; i++) {
            if (g_watch[i].kind != W_BT) continue;
            g_watch[i].present = bt_in(&bt, g_watch[i].addr);
            if (g_watch[i].present) armed++;
        }
        vlog("armed bluetooth (%d already connected, not firing), polling every %.1fs", armed, g_btpoll);
        CFRunLoopTimerRef t = CFRunLoopTimerCreate(
            NULL, CFAbsoluteTimeGetCurrent() + g_btpoll, g_btpoll, 0, 0, bt_tick, NULL);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
        CFRelease(t);
    }

    // An ambiguous entry disables that entry, not the watcher, unless nothing
    // usable is left (specs/detector.md 4.1).
    int usable = 0, already = 0;
    for (int i = 0; i < g_nwatch; i++) {
        if (!g_watch[i].ambiguous) usable++;
        if (g_watch[i].present) already++;
    }
    if (usable == 0) {
        logmsg("REFUSING to watch: every configured trigger is ambiguous, so "
               "nothing could ever fire. Re-run: trigger-kvm configure");
        return 2;
    }
    logmsg("watching %d device(s); exec=%s arg=%s debounce=%.1fs settle=%.2fs",
           usable, g_exec, g_arg, g_debounce, g_settle);
    if (usable != g_nwatch)
        logmsg("%d of %d trigger(s) disabled as ambiguous; the rest keep watching",
               g_nwatch - usable, g_nwatch);
    logmsg("armed (%d already present, not firing)", already);

    CFRunLoopRun();
    return 0;
}
