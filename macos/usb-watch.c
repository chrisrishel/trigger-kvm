// usb-watch — fire a command when a watched USB device is plugged in.
//
// Built for trigger-kvm: when the USB switch hands this Mac the shared
// peripherals, pull both monitors to this machine.
//
//   usb-watch --exec /path/to/trigger-kvm.sh --arg mac \
//             --device 046d:0843 --device 1235:820a \
//             [--debounce 3.0] [--settle 0.75] [--verbose]
//
// Two deliberate safety behaviours, both there because a spurious device arrival
// would yank both displays out from under whatever you are doing:
//
//   debounce — ignore any arrival within N seconds of the last fire. Stops two
//              watched devices arriving together from firing twice, and stops a
//              flapping device from thrashing the displays.
//   settle   — after an arrival, wait, then confirm the device is STILL present
//              before acting. A device that appears and immediately vanishes was
//              a glitch, not a switch.
//
// Devices already present at startup do not fire. The first callback per watch is
// used only to drain and arm the notification.
//
// Build: clang -O2 -Wall -o usb-watch usb-watch.c -framework IOKit -framework CoreFoundation

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// Observed class on Apple Silicon / macOS 26. The older "IOUSBDevice" name is not
// reliable here; ioreg reports IOUSBHostDevice.
#define USB_CLASS "IOUSBHostDevice"
#define MAX_WATCH 8

extern char **environ;

typedef struct {
    uint32_t vendor;
    uint32_t product;
    io_iterator_t iter;
    bool primed;      // first callback drains pre-existing devices without firing
} watch_t;

static watch_t   g_watch[MAX_WATCH];
static int       g_nwatch    = 0;
static char      g_exec[1024];
static char      g_arg[64]   = "mac";
static double    g_debounce  = 3.0;
static double    g_settle    = 0.75;
static bool      g_verbose   = false;
static CFAbsoluteTime g_last_fire = 0;
static bool      g_settle_pending = false;

static void logmsg(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(stderr, "%s usb-watch: ", ts);
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

// Is any watched device currently attached?
static bool any_device_present(void) {
    for (int i = 0; i < g_nwatch; i++) {
        CFMutableDictionaryRef m = IOServiceMatching(USB_CLASS);
        if (!m) continue;
        CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &g_watch[i].vendor);
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberSInt32Type, &g_watch[i].product);
        CFDictionarySetValue(m, CFSTR("idVendor"),  v);
        CFDictionarySetValue(m, CFSTR("idProduct"), p);
        CFRelease(v); CFRelease(p);

        io_iterator_t it = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS) {
            io_service_t s = IOIteratorNext(it);
            bool found = (s != IO_OBJECT_NULL);
            if (s) IOObjectRelease(s);
            while ((s = IOIteratorNext(it))) IOObjectRelease(s);
            IOObjectRelease(it);
            if (found) return true;
        }
    }
    return false;
}

static void run_exec(void) {
    char *argv[] = { g_exec, g_arg, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, g_exec, NULL, NULL, argv, environ);
    if (rc != 0) logmsg("ERROR: posix_spawn(%s) failed: %s", g_exec, strerror(rc));
    else         logmsg("fired: %s %s", g_exec, g_arg);
}

static void settle_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    g_settle_pending = false;
    if (!any_device_present()) {
        logmsg("device vanished during settle window; ignoring (glitch, not a switch)");
        return;
    }
    g_last_fire = CFAbsoluteTimeGetCurrent();
    run_exec();
}

static void device_appeared(void *refcon, io_iterator_t iter) {
    watch_t *w = (watch_t *)refcon;

    int n = 0;
    io_service_t s;
    while ((s = IOIteratorNext(iter))) { n++; IOObjectRelease(s); }

    if (!w->primed) {
        w->primed = true;
        if (g_verbose)
            logmsg("armed %04x:%04x (%d already present, not firing)",
                   w->vendor, w->product, n);
        return;
    }
    if (n == 0) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_last_fire < g_debounce) {
        if (g_verbose)
            logmsg("arrival %04x:%04x within debounce (%.1fs); ignoring",
                   w->vendor, w->product, now - g_last_fire);
        return;
    }
    if (g_settle_pending) {
        if (g_verbose) logmsg("arrival %04x:%04x; settle already pending", w->vendor, w->product);
        return;
    }

    logmsg("arrival %04x:%04x; settling %.2fs", w->vendor, w->product, g_settle);
    g_settle_pending = true;
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + g_settle, 0, 0, 0, settle_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
    CFRelease(t);
}

static void usage(const char *me) {
    fprintf(stderr,
      "usage: %s --exec PATH [--arg ARG] --device VVVV:PPPP [--device ...]\n"
      "          [--debounce SECONDS] [--settle SECONDS] [--verbose]\n", me);
    exit(2);
}

int main(int argc, char **argv) {
    signal(SIGCHLD, SIG_IGN);   // auto-reap the spawned script

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--exec") && i + 1 < argc) {
            snprintf(g_exec, sizeof g_exec, "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--arg") && i + 1 < argc) {
            snprintf(g_arg, sizeof g_arg, "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--device") && i + 1 < argc) {
            if (g_nwatch >= MAX_WATCH) { logmsg("too many --device"); return 2; }
            unsigned v, p;
            if (sscanf(argv[++i], "%x:%x", &v, &p) != 2) usage(argv[0]);
            g_watch[g_nwatch].vendor  = v;
            g_watch[g_nwatch].product = p;
            g_nwatch++;
        } else if (!strcmp(argv[i], "--debounce") && i + 1 < argc) {
            g_debounce = atof(argv[++i]);
        } else if (!strcmp(argv[i], "--settle") && i + 1 < argc) {
            g_settle = atof(argv[++i]);
        } else if (!strcmp(argv[i], "--verbose")) {
            g_verbose = true;
        } else usage(argv[0]);
    }
    if (!g_exec[0] || g_nwatch == 0) usage(argv[0]);

    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(port),
                       kCFRunLoopDefaultMode);

    for (int i = 0; i < g_nwatch; i++) {
        CFMutableDictionaryRef m = IOServiceMatching(USB_CLASS);
        if (!m) { logmsg("ERROR: IOServiceMatching(%s) failed", USB_CLASS); return 1; }
        CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &g_watch[i].vendor);
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberSInt32Type, &g_watch[i].product);
        CFDictionarySetValue(m, CFSTR("idVendor"),  v);
        CFDictionarySetValue(m, CFSTR("idProduct"), p);
        CFRelease(v); CFRelease(p);

        kern_return_t kr = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, m,      // consumes `m`
            device_appeared, &g_watch[i], &g_watch[i].iter);
        if (kr != KERN_SUCCESS) {
            logmsg("ERROR: IOServiceAddMatchingNotification(%04x:%04x) = 0x%x",
                   g_watch[i].vendor, g_watch[i].product, kr);
            return 1;
        }
        // Required: drain the iterator to arm the notification. Also primes.
        device_appeared(&g_watch[i], g_watch[i].iter);
    }

    logmsg("watching %d device(s); exec=%s arg=%s debounce=%.1fs settle=%.2fs",
           g_nwatch, g_exec, g_arg, g_debounce, g_settle);
    CFRunLoopRun();
    return 0;
}
