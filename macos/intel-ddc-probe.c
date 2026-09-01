// intel-ddc-probe -- a READ-ONLY survey of the Intel-Mac DDC/CI route.
//
// The macOS switcher reaches monitors through m1ddc, which uses IOAVService --
// an interface Apple Silicon has and Intel Macs do not. Intel Macs expose DDC/CI
// through the framebuffer's I2C interface instead (IOFBCopyI2CInterfaceForBus +
// IOI2CSendRequest, the mechanism ddcctl and ddc-macos use). Before deciding
// whether to build a transport on that route, measure whether it exists on the
// Mac at hand and whether it reaches the panels through the cabling in use.
//
// This program MOVES NOTHING. By default it only enumerates: every IOFramebuffer,
// its I2C buses and what they support, the EDID identity it carries, and how
// CoreGraphics' display ids map onto those framebuffers. With --i2c-read it
// additionally sends ONE standard DDC/CI GetVCP request for code 0x60 (input
// select) to each external display and prints the raw reply. That request is
// source 0x51 -- the standard host address -- hard-coded; there is no way to
// make this program emit any other source byte, and it never writes a value.
// Hard rule 2 (AGENTS.md) still applies to what comes back: a read is
// evidence that the I2C path REACHES the panel, not of which input it shows.
//
//   make intel-ddc-probe
//   ./intel-ddc-probe               enumerate only; no I2C traffic
//   ./intel-ddc-probe --i2c-read    also one GetVCP 0x60 per external display
//
// On Apple Silicon it reports that there are no IOFramebuffer services, which is
// the expected answer there and is why m1ddc exists.
//
// Build: clang -O2 -Wall -Wextra -o intel-ddc-probe intel-ddc-probe.c \
//          -framework IOKit -framework CoreFoundation -framework ApplicationServices

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/utsname.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <ApplicationServices/ApplicationServices.h>

// ------------------------------------------------------------- EDID decode --
// The same decoding display-probe.c uses, so the two agree on identity.

static void decode_mfg(uint16_t id, char out[4]) {
    out[0] = (char)(((id >> 10) & 0x1F) + 64);
    out[1] = (char)(((id >> 5)  & 0x1F) + 64);
    out[2] = (char)((id         & 0x1F) + 64);
    out[3] = '\0';
}

static void decode_name(const uint8_t *e, CFIndex len, char *out, size_t outsz) {
    out[0] = '\0';
    if (len < 128) return;
    for (int b = 54; b + 18 <= 126; b += 18) {
        if (e[b] || e[b + 1] || e[b + 2]) continue;   // a timing block, not text
        if (e[b + 3] != 0xFC) continue;
        size_t n = 0;
        for (int i = b + 5; i < b + 18 && n + 1 < outsz; i++) {
            uint8_t c = e[i];
            if (c == 0x0A) break;
            if (c < 0x20 || c > 0x7E) continue;
            out[n++] = (char)c;
        }
        while (n > 0 && out[n - 1] == ' ') n--;
        out[n] = '\0';
        return;
    }
}

static void print_edid(CFDataRef data) {
    CFIndex len = CFDataGetLength(data);
    const uint8_t *e = CFDataGetBytePtr(data);
    if (len < 128 || e[0] != 0x00 || e[1] != 0xFF) {
        printf("    EDID: %ld bytes, not an EDID header\n", (long)len);
        return;
    }
    uint16_t vendor  = (uint16_t)((e[8] << 8) | e[9]);
    uint16_t product = (uint16_t)(e[10] | (e[11] << 8));
    uint32_t serial  = (uint32_t)(e[12] | (e[13] << 8) | (e[14] << 16) | ((uint32_t)e[15] << 24));
    char mfg[4], name[16];
    decode_mfg(vendor, mfg);
    decode_name(e, len, name, sizeof name);
    printf("    EDID: vendor 0x%04X (%s)  product 0x%04X  serial 0x%08X  name \"%s\"  (%ld bytes)\n",
           vendor, mfg, product, serial, name, (long)len);
}

// ------------------------------------------------------------------ helpers --

static long cfnum(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
    return out;
}

static long propnum(io_registry_entry_t e, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    long out = -1;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
        CFRelease(v);
    }
    return out;
}

static void print_path(io_registry_entry_t e) {
    io_string_t path;
    if (IORegistryEntryGetPath(e, kIOServicePlane, path) == KERN_SUCCESS) printf("    path: %s\n", path);
}

// ------------------------------------------------------------ the I2C read --
//
// One standard DDC/CI GetVCP for 0x60. Source byte 0x51 is a literal here and
// nowhere else in this program; the reply is printed raw and never acted on.

static void i2c_read_vcp60(io_service_t iface, uint32_t types) {
    IOI2CConnectRef conn = NULL;
    kern_return_t kr = IOI2CInterfaceOpen(iface, kNilOptions, &conn);
    if (kr != KERN_SUCCESS) { printf("      IOI2CInterfaceOpen failed: 0x%x\n", kr); return; }

    uint8_t send[5] = { 0x51, 0x82, 0x01, 0x60, 0 };
    send[4] = (uint8_t)(0x6E ^ send[0] ^ send[1] ^ send[2] ^ send[3]);
    uint8_t reply[11];
    memset(reply, 0, sizeof reply);

    bool ddcci_reply = (types & (1u << kIOI2CDDCciReplyTransactionType)) != 0;

    IOI2CRequest req;
    memset(&req, 0, sizeof req);
    req.sendAddress          = 0x6E;                       // DDC/CI slave 0x37, write
    req.sendTransactionType  = kIOI2CSimpleTransactionType;
    req.sendBuffer           = (vm_address_t)(uintptr_t)send;
    req.sendBytes            = sizeof send;
    req.replyAddress         = 0x6F;                       // DDC/CI slave 0x37, read
    req.replySubAddress      = 0x51;
    req.replyTransactionType = ddcci_reply ? kIOI2CDDCciReplyTransactionType : kIOI2CSimpleTransactionType;
    req.replyBuffer          = (vm_address_t)(uintptr_t)reply;
    req.replyBytes           = sizeof reply;
    req.minReplyDelay        = 30 * kMillisecondScale;

    kr = IOI2CSendRequest(conn, kNilOptions, &req);
    IOI2CInterfaceClose(conn, kNilOptions);

    printf("      GetVCP 0x60 (source 0x51, %s reply): IOI2CSendRequest=0x%x  result=0x%x\n",
           ddcci_reply ? "DDCci" : "simple", kr, (unsigned)req.result);
    printf("      reply:");
    for (size_t i = 0; i < sizeof reply; i++) printf(" %02X", reply[i]);
    printf("\n");
    if (kr == KERN_SUCCESS && req.result == 0 && reply[0] == 0x6E && reply[1] == 0x88) {
        printf("      decoded: current 0x%02X%02X, max 0x%02X%02X  (a READ; evidence the path reaches the panel, nothing more)\n",
               reply[8], reply[9], reply[6], reply[7]);
    } else {
        printf("      decoded: no well-formed DDC/CI reply (also a valid measurement: some panels do not answer reads)\n");
    }
}

// -------------------------------------------------------------------- main --

int main(int argc, char **argv) {
    bool do_read = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--i2c-read")) do_read = true;
        else { fprintf(stderr, "usage: %s [--i2c-read]\n", argv[0]); return 2; }
    }

    struct utsname u;
    uname(&u);
    printf("intel-ddc-probe on %s (%s)\n", u.machine, u.release);
    if (!strcmp(u.machine, "arm64"))
        printf("  Apple Silicon: no IOFramebuffer I2C route is expected here (m1ddc's IOAVService route is the one that exists).\n");

    // ---- CoreGraphics' view: ids, built-in flag, vendor/model, framebuffer link
    printf("\n== CoreGraphics displays ==\n");
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    CGGetOnlineDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        printf("  display %u: vendor 0x%04X model 0x%04X serial 0x%08X%s\n",
               (unsigned)ids[i], (unsigned)CGDisplayVendorNumber(ids[i]),
               (unsigned)CGDisplayModelNumber(ids[i]), (unsigned)CGDisplaySerialNumber(ids[i]),
               CGDisplayIsBuiltin(ids[i]) ? "  (built-in)" : "");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        io_service_t port = CGDisplayIOServicePort(ids[i]);   // deprecated; 0 on Apple Silicon
#pragma clang diagnostic pop
        if (port) print_path(port); else printf("    CGDisplayIOServicePort: none\n");
    }

    // ---- The framebuffer route
    printf("\n== IOFramebuffer services ==\n");
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &it) != KERN_SUCCESS) {
        printf("  IOServiceGetMatchingServices failed\n");
        return 1;
    }
    int nfb = 0;
    io_service_t fb;
    while ((fb = IOIteratorNext(it))) {
        nfb++;
        io_name_t cls;
        IOObjectGetClass(fb, cls);
        printf("  framebuffer %d: class %s\n", nfb, cls);
        print_path(fb);

        CFDictionaryRef info = IODisplayCreateInfoDictionary(fb, kIODisplayOnlyPreferredName);
        bool external = true;
        if (info) {
            long v = cfnum(info, "DisplayVendorID"), p = cfnum(info, "DisplayProductID"), s = cfnum(info, "DisplaySerialNumber");
            printf("    IODisplay: vendor 0x%04lX product 0x%04lX serial 0x%08lX\n", v, p, s);
            CFTypeRef edid = CFDictionaryGetValue(info, CFSTR("IODisplayEDID"));
            if (edid && CFGetTypeID(edid) == CFDataGetTypeID()) print_edid((CFDataRef)edid);
            else printf("    EDID: none in the info dictionary\n");
            // Apple's own panels carry this; an external monitor does not.
            if (CFDictionaryGetValue(info, CFSTR("IODisplayIsBuiltin")) ||
                (v == 0x610 && s == 0)) external = false;
            CFRelease(info);
        } else {
            printf("    IODisplayCreateInfoDictionary: none (no display attached to this framebuffer?)\n");
            external = false;
        }

        IOItemCount buses = 0;
        kern_return_t kr = IOFBGetI2CInterfaceCount(fb, &buses);
        printf("    I2C buses: %u (IOFBGetI2CInterfaceCount=0x%x)\n", (unsigned)buses, kr);
        for (IOItemCount b = 0; b < buses; b++) {
            io_service_t iface = IO_OBJECT_NULL;
            if (IOFBCopyI2CInterfaceForBus(fb, b, &iface) != KERN_SUCCESS || !iface) {
                printf("      bus %u: IOFBCopyI2CInterfaceForBus failed\n", (unsigned)b);
                continue;
            }
            long types = propnum(iface, kIOI2CTransactionTypesKey);
            long flags = propnum(iface, kIOI2CSupportedCommFlagsKey);
            printf("      bus %u: transaction types 0x%lX%s%s%s  comm flags 0x%lX\n", (unsigned)b, types,
                   (types & (1 << kIOI2CSimpleTransactionType))     ? " simple"   : "",
                   (types & (1 << kIOI2CDDCciReplyTransactionType)) ? " DDCci"    : "",
                   (types & (1 << kIOI2CCombinedTransactionType))   ? " combined" : "",
                   flags);
            if (do_read && external) i2c_read_vcp60(iface, (uint32_t)(types < 0 ? 0 : types));
            else if (do_read) printf("      (built-in or empty framebuffer: no read sent)\n");
            IOObjectRelease(iface);
        }
        IOObjectRelease(fb);
    }
    IOObjectRelease(it);
    if (nfb == 0) printf("  none. This Mac has no framebuffer I2C route.\n");

    printf("\nNothing was written to any monitor.%s\n",
           do_read ? " One GetVCP 0x60 read was sent per external framebuffer, source 0x51." : "");
    return 0;
}
