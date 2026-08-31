// display-probe -- every attached display, identified by the EDID the GPU read off
// the output, plus the handle m1ddc takes.
//
// Emits one pipe-delimited row per online display:
//
//   vendor|product|mfg|connector|serial|uuid|name
//   1E6D|9E9F|GSM|DP|00001111|AAAAAAAA-0000-4000-8000-000000000001|LG ULTRAGEAR+
//
// Name is LAST because it is the only free-text field; any '|' in it is replaced
// with a space so the row stays splittable. Everything before it is fixed-width
// hex or a UUID.
//
// WHY CoreGraphics AND IOKit, and not either alone:
//
//   CoreGraphics gives identity and the handle in one call.
//   CGDisplayVendorNumber/CGDisplayModelNumber return exactly the EDID
//   manufacturer and product code -- verified against the raw EDID bytes in
//   ioreg on 2026-08-31, 0x1E6D/0x9E9F and 0x06B3/0x42E0 -- and
//   CGDisplayCreateUUIDFromDisplayID returns the same UUID `m1ddc display list`
//   prints, which is what `m1ddc display <uuid> set ...` takes. So the identity
//   the config matches on and the handle the write is aimed at come from one
//   place and cannot drift apart.
//
//   IOKit supplies the panel's own NAME, which CoreGraphics has no API for. It
//   lives in EDID descriptor tag 0xFC, so the raw EDID has to be read, and it is
//   in the I/O registry. Asking the hardware beats a table, which only ever knows
//   the monitors its author owned.
//
// The two are joined on vendor+product+SERIAL. That is strictly stronger than
// what the switcher itself matches on (vendor+product, which it refuses when it
// is ambiguous), so the join can never be the weak link.
//
// NEVER an index. m1ddc's [1]/[2] numbers shift when a display drops, and on
// Windows the two DISPLAYn numbers were observed swapping outright across a
// reboot. Index 1 silently becoming the other monitor would aim LG
// service-channel writes at the ASUS. Nothing here caches, and nothing here
// writes an ordering down.
//
// Reads nothing over DDC and writes nothing at all: this program cannot move a
// monitor.
//
// Build: clang -O2 -Wall -Wextra -o display-probe display-probe.c \
//          -framework CoreFoundation -framework IOKit -framework ApplicationServices

#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <ApplicationServices/ApplicationServices.h>

#define MAX_DISPLAYS 16
#define MAX_EDIDS    64

typedef struct {
    uint16_t vendor;
    uint16_t product;
    uint32_t serial;
    char     name[16];        // EDID 0xFC is 13 bytes max
    char     connector[24];
} edid_t;

static edid_t g_edid[MAX_EDIDS];
static int    g_nedid = 0;

// EDID manufacturer id: three 5-bit letters packed big-endian in bytes 8-9.
static void decode_mfg(uint16_t id, char out[4]) {
    out[0] = (char)(((id >> 10) & 0x1F) + 64);
    out[1] = (char)(((id >> 5)  & 0x1F) + 64);
    out[2] = (char)((id         & 0x1F) + 64);
    out[3] = '\0';
}

// The model name the panel reports about itself: descriptor tag 0xFC, in one of
// the four 18-byte blocks at 54/72/90/108. Absent is legal and not rare on cheap
// panels, and yields "".
static void decode_name(const uint8_t *e, CFIndex len, char *out, size_t outsz) {
    out[0] = '\0';
    if (len < 128) return;
    for (int b = 54; b + 18 <= 126; b += 18) {
        // A descriptor with a non-zero pixel clock is a timing block, not text.
        if (e[b] || e[b + 1] || e[b + 2]) continue;
        if (e[b + 3] != 0xFC) continue;
        size_t n = 0;
        for (int i = b + 5; i < b + 18 && n + 1 < outsz; i++) {
            uint8_t c = e[i];
            if (c == 0x0A) break;                 // the field is newline-terminated
            if (c < 0x20 || c > 0x7E) continue;
            out[n++] = (char)c;
        }
        while (n > 0 && out[n - 1] == ' ') n--;   // trailing pad
        out[n] = '\0';
        return;
    }
}

static void copy_cfstring(CFStringRef s, char *out, size_t outsz) {
    out[0] = '\0';
    if (!s || CFGetTypeID(s) != CFStringGetTypeID()) return;
    CFStringGetCString(s, out, (CFIndex)outsz, kCFStringEncodingUTF8);
}

// Record one EDID blob, with whatever the node says about its connector.
static void note_edid(CFDataRef data, CFDictionaryRef meta) {
    if (g_nedid >= MAX_EDIDS) return;
    CFIndex len = CFDataGetLength(data);
    if (len < 128) return;
    const uint8_t *e = CFDataGetBytePtr(data);
    if (e[0] != 0x00 || e[1] != 0xFF) return;     // not an EDID header

    edid_t *r = &g_edid[g_nedid];
    memset(r, 0, sizeof *r);
    r->vendor  = (uint16_t)((e[8] << 8) | e[9]);
    r->product = (uint16_t)(e[10] | (e[11] << 8));
    r->serial  = (uint32_t)(e[12] | (e[13] << 8) | (e[14] << 16) | ((uint32_t)e[15] << 24));
    decode_name(e, len, r->name, sizeof r->name);
    if (meta && CFGetTypeID(meta) == CFDictionaryGetTypeID()) {
        copy_cfstring((CFStringRef)CFDictionaryGetValue(meta, CFSTR("DFP Type Description")),
                      r->connector, sizeof r->connector);
    }
    g_nedid++;
}

// Walk the whole I/O registry for nodes carrying an EDID. Deliberately not keyed
// on a class name: the node holding it is IOPortTransportStateDisplayPort on this
// machine, which is an implementation detail of one macOS version and one GPU
// family. The property is the stable thing.
static void collect_edids(void) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                 kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return;

    io_object_t node;
    while ((node = IOIteratorNext(it))) {
        CFTypeRef edid = IORegistryEntryCreateCFProperty(node, CFSTR("EDID"),
                                                         kCFAllocatorDefault, 0);
        if (edid) {
            if (CFGetTypeID(edid) == CFDataGetTypeID()) {
                CFTypeRef meta = IORegistryEntryCreateCFProperty(node, CFSTR("Metadata"),
                                                                 kCFAllocatorDefault, 0);
                note_edid((CFDataRef)edid, (CFDictionaryRef)meta);
                if (meta) CFRelease(meta);
            }
            CFRelease(edid);
        }
        IOObjectRelease(node);
    }
    IOObjectRelease(it);
}

static const edid_t *find_edid(uint16_t vendor, uint16_t product, uint32_t serial) {
    for (int i = 0; i < g_nedid; i++) {
        if (g_edid[i].vendor == vendor && g_edid[i].product == product &&
            g_edid[i].serial == serial) return &g_edid[i];
    }
    return NULL;
}

int main(void) {
    collect_edids();

    CGDirectDisplayID ids[MAX_DISPLAYS];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(MAX_DISPLAYS, ids, &n) != kCGErrorSuccess) {
        fprintf(stderr, "display-probe: CGGetOnlineDisplayList failed\n");
        return 1;
    }

    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID d = ids[i];

        // A built-in panel has no input to switch and no DDC to switch it with.
        // Listing it would put a row in every menu that can never be an answer.
        if (CGDisplayIsBuiltin(d)) continue;

        uint16_t vendor  = (uint16_t)CGDisplayVendorNumber(d);
        uint16_t product = (uint16_t)CGDisplayModelNumber(d);
        uint32_t serial  = CGDisplaySerialNumber(d);

        char uuid[64] = "";
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d);
        if (u) {
            CFStringRef s = CFUUIDCreateString(NULL, u);
            copy_cfstring(s, uuid, sizeof uuid);
            if (s) CFRelease(s);
            CFRelease(u);
        }
        // Without the UUID there is no way to aim a write at this panel, and an
        // unaimed write is the thing this project refuses to make possible.
        if (!uuid[0]) continue;

        char mfg[4];
        decode_mfg(vendor, mfg);

        const edid_t *e = find_edid(vendor, product, serial);
        char name[16] = "";
        const char *connector = "";
        if (e) {
            snprintf(name, sizeof name, "%s", e->name);
            connector = e->connector[0] ? e->connector : "";
        }
        for (char *p = name; *p; p++) if (*p == '|') *p = ' ';

        printf("%04X|%04X|%s|%s|%08X|%s|%s\n",
               vendor, product, mfg, connector, serial, uuid, name);
    }
    return 0;
}
