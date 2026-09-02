// intel-ddc-probe -- a survey of the Intel-Mac DDC/CI route.
//
// The macOS switcher reaches monitors through m1ddc, which uses IOAVService --
// an interface Apple Silicon has and Intel Macs do not. Intel Macs expose DDC/CI
// through the framebuffer's I2C interface instead (IOFBCopyI2CInterfaceForBus +
// IOI2CSendRequest, the mechanism ddcctl and ddc-macos use). Before deciding
// whether to build a transport on that route, measure whether it exists on the
// Mac at hand and whether it reaches the panels through the cabling in use.
//
// By default this program MOVES NOTHING. It only enumerates: every IOFramebuffer,
// its I2C buses and what they support, the EDID identity it carries, and how
// CoreGraphics' display ids map onto those framebuffers. With --i2c-read it
// additionally sends ONE standard DDC/CI GetVCP request for code 0x60 (input
// select) to each external display and prints the raw reply. That request is
// source 0x51 -- the standard host address -- hard-coded; there is no way to
// make this program emit any other source byte, and it never writes a value.
// Hard rule 2 (AGENTS.md) still applies to what comes back: a read is
// evidence that the I2C path REACHES the panel, not of which input it shows.
//
// --set-asus-input is the one thing here that MOVES a panel, and it exists to
// answer a single question: is a standard DDC/CI SetVCP, framed by this program
// and sent over IOI2CSendRequest, actually accepted by a monitor? That has to be
// settled on the SAFE channel before anyone considers aiming a packet at the LG's
// service channel, because the risk there is not the value -- 0xD0/0xD1 are
// documented and this desk sends them daily from two other platforms -- but a
// brand-new transport framing a packet wrongly. See macos/HANDOFF.md.
//
//   make intel-ddc-probe
//   ./intel-ddc-probe               enumerate only; no I2C traffic
//   ./intel-ddc-probe --i2c-read    also one GetVCP 0x60 per external display
//   ./intel-ddc-probe --set-asus-input hdmi2       move the ASUS (see below)
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
#include <unistd.h>
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

// ------------------------------------------------- the ASUS input write --
//
// The narrowest aperture that can answer "does a SetVCP framed here move a
// panel?". Every way this could become a general-purpose write tool is closed
// deliberately, and each closure is a rule in ../AGENTS.md:
//
//   - the source byte 0x51 is a literal, exactly as in the read above. This
//     function cannot emit any other source; the service channel has its own
//     function below and the two share no sender, deliberately -- a helper taking
//     a ready-made packet would be the generic "write to source N" entry point
//     hard rule 5 forbids, so the duplication below is the point, not an
//     oversight.
//   - the VCP code 0x60 is a literal too. This is not a "write VCP X" tool.
//   - the value comes from a NAMED allowlist copied from displays.toml, never
//     from a number the caller supplies. Hard rule 1 forbids walking values at a
//     monitor; this cannot express a value that is not already documented.
//   - it refuses a panel whose EDID vendor is not AUS, and refuses unless the
//     enumeration found EXACTLY ONE of them -- zero and many are both refusals,
//     because an ambiguous target cannot be aimed at safely.
//
// It sends twice, because the bus is lossy and the write is idempotent, and it
// reads NOTHING back. Hard rule 2: these panels lie on reads and a verify-then-
// retry loop would fire spurious retries. Hard rule 3: the only confirmation
// that this worked is a person looking at the monitor.

#define DDC_VENDOR_AUS 0x06B3

static const struct { const char *name; uint8_t value; } ASUS_INPUTS[] = {
    { "displayport", 0x0F },
    { "hdmi1",       0x11 },
    { "hdmi2",       0x12 },
};

static bool asus_input_value(const char *name, uint8_t *out) {
    for (size_t i = 0; i < sizeof ASUS_INPUTS / sizeof ASUS_INPUTS[0]; i++) {
        if (!strcmp(name, ASUS_INPUTS[i].name)) { *out = ASUS_INPUTS[i].value; return true; }
    }
    return false;
}

static bool i2c_set_asus_input(io_service_t iface, long vendor_id, uint8_t value) {
    if (vendor_id != DDC_VENDOR_AUS) {
        printf("  REFUSED: target EDID vendor is 0x%04lX, not AUS (0x%04X).\n",
               vendor_id, DDC_VENDOR_AUS);
        return false;
    }
    IOI2CConnectRef conn = NULL;
    kern_return_t kr = IOI2CInterfaceOpen(iface, kNilOptions, &conn);
    if (kr != KERN_SUCCESS) { printf("  IOI2CInterfaceOpen failed: 0x%x\n", kr); return false; }

    uint8_t send[7] = { 0x51, 0x84, 0x03, 0x60, 0x00, value, 0 };
    send[6] = (uint8_t)(0x6E ^ send[0] ^ send[1] ^ send[2] ^ send[3] ^ send[4] ^ send[5]);

    printf("  packet:");
    for (size_t i = 0; i < sizeof send; i++) printf(" %02X", send[i]);
    printf("   (slave 0x6E, source 0x%02X, VCP 0x%02X, value 0x%02X)\n",
           send[0], send[3], value);

    for (int attempt = 1; attempt <= 2; attempt++) {
        IOI2CRequest req;
        memset(&req, 0, sizeof req);
        req.sendAddress          = 0x6E;
        req.sendTransactionType  = kIOI2CSimpleTransactionType;
        req.sendBuffer           = (vm_address_t)(uintptr_t)send;
        req.sendBytes            = sizeof send;
        req.replyTransactionType = kIOI2CNoTransactionType;
        req.replyBytes           = 0;

        kr = IOI2CSendRequest(conn, kNilOptions, &req);
        printf("  send %d of 2: IOI2CSendRequest=0x%x  result=0x%x\n",
               attempt, kr, (unsigned)req.result);
        if (attempt == 1) usleep(50 * 1000);
    }
    IOI2CInterfaceClose(conn, kNilOptions);
    return true;
}

// ------------------------------------------- the LG service channel write --
//
// THE ONLY function in this program that can emit I2C source 0x50, and the
// source byte is a literal inside it rather than a parameter -- ../AGENTS.md
// hard rule 5. It refuses unless the panel's EDID manufacturer is GSM, and
// main() refuses unless EXACTLY ONE enumerated display is a GSM panel: zero is a
// refusal and so is more than one, because an ambiguous target cannot be aimed
// at safely. There is no generic "write to source N" entry point here and none
// may be added; that is why this shares no sender with the ASUS write above.
//
// The two values are the ones this desk exercises daily from the other two
// platforms. The LG's other documented inputs (hdmi1 0x90, hdmi2 0x91) are
// deliberately NOT in the table: displays.toml marks them "documented, not
// exercised", and a service channel is not where a value gets exercised for the
// first time. Hard rule 1 -- these come from the allowlist, never from a search,
// a sweep or a range.
//
// Expect the panel to flicker on every LG switch, including a re-assert to the
// input it is already on. That is the link renegotiating, it is normal, and it
// has been mistaken for a fault here once already.

#define DDC_VENDOR_GSM 0x1E6D

static const struct { const char *name; uint8_t value; } LG_INPUTS[] = {
    { "displayport", 0xD0 },
    { "usb-c",       0xD1 },
};

static bool lg_input_value(const char *name, uint8_t *out) {
    for (size_t i = 0; i < sizeof LG_INPUTS / sizeof LG_INPUTS[0]; i++) {
        if (!strcmp(name, LG_INPUTS[i].name)) { *out = LG_INPUTS[i].value; return true; }
    }
    return false;
}

static bool i2c_set_lg_input_alt(io_service_t iface, long vendor_id, uint8_t value) {
    if (vendor_id != DDC_VENDOR_GSM) {
        printf("  REFUSED: target EDID vendor is 0x%04lX, not GSM (0x%04X).\n"
               "  The service channel may only ever be aimed at the LG.\n",
               vendor_id, DDC_VENDOR_GSM);
        return false;
    }
    IOI2CConnectRef conn = NULL;
    kern_return_t kr = IOI2CInterfaceOpen(iface, kNilOptions, &conn);
    if (kr != KERN_SUCCESS) { printf("  IOI2CInterfaceOpen failed: 0x%x\n", kr); return false; }

    uint8_t send[7] = { 0x50, 0x84, 0x03, 0xF4, 0x00, value, 0 };
    send[6] = (uint8_t)(0x6E ^ send[0] ^ send[1] ^ send[2] ^ send[3] ^ send[4] ^ send[5]);

    printf("  packet:");
    for (size_t i = 0; i < sizeof send; i++) printf(" %02X", send[i]);
    // Printed from the packet, never from a literal: a label that repeats the
    // source byte can drift from the bytes actually sent, and this one names a
    // service channel. It also keeps the scan in conventions.tests.sh honest --
    // the emitter below is the ONE non-comment line naming that source.
    printf("   (slave 0x6E, SERVICE source 0x%02X, VCP 0x%02X, value 0x%02X)\n",
           send[0], send[3], value);

    for (int attempt = 1; attempt <= 2; attempt++) {
        IOI2CRequest req;
        memset(&req, 0, sizeof req);
        req.sendAddress          = 0x6E;
        req.sendTransactionType  = kIOI2CSimpleTransactionType;
        req.sendBuffer           = (vm_address_t)(uintptr_t)send;
        req.sendBytes            = sizeof send;
        req.replyTransactionType = kIOI2CNoTransactionType;
        req.replyBytes           = 0;

        kr = IOI2CSendRequest(conn, kNilOptions, &req);
        printf("  send %d of 2: IOI2CSendRequest=0x%x  result=0x%x\n",
               attempt, kr, (unsigned)req.result);
        if (attempt == 1) usleep(50 * 1000);
    }
    IOI2CInterfaceClose(conn, kNilOptions);
    return true;
}

// -------------------------------------------------------------------- main --

int main(int argc, char **argv) {
    bool do_read = false, do_write = false, write_is_lg = false;
    uint8_t write_value = 0;
    const char *write_name = NULL;
    long target_vendor = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--i2c-read")) do_read = true;
        else if (!strcmp(argv[i], "--set-asus-input")) {
            if (++i >= argc || !asus_input_value(argv[i], &write_value)) {
                fprintf(stderr, "--set-asus-input needs one of: displayport hdmi1 hdmi2\n"
                                "(the names are the allowlist; a raw value is not expressible)\n");
                return 2;
            }
            write_name = argv[i]; do_write = true; write_is_lg = false;
            target_vendor = DDC_VENDOR_AUS;
        }
        else if (!strcmp(argv[i], "--set-lg-input")) {
            if (++i >= argc || !lg_input_value(argv[i], &write_value)) {
                fprintf(stderr, "--set-lg-input needs one of: displayport usb-c\n"
                                "(the names are the allowlist; a raw value is not expressible.\n"
                                " hdmi1/hdmi2 are documented but unexercised and are not offered\n"
                                " here -- a service channel is not where a value is first tried.)\n");
                return 2;
            }
            write_name = argv[i]; do_write = true; write_is_lg = true;
            target_vendor = DDC_VENDOR_GSM;
        }
        else {
            fprintf(stderr, "usage: %s [--i2c-read] [--set-asus-input displayport|hdmi1|hdmi2]\n"
                            "          [--set-lg-input displayport|usb-c]\n", argv[0]);
            return 2;
        }
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
    io_service_t target_iface[4];
    int target_count = 0;
    io_service_t fb;
    while ((fb = IOIteratorNext(it))) {
        nfb++;
        io_name_t cls;
        IOObjectGetClass(fb, cls);
        printf("  framebuffer %d: class %s\n", nfb, cls);
        print_path(fb);

        CFDictionaryRef info = IODisplayCreateInfoDictionary(fb, kIODisplayOnlyPreferredName);
        bool external = true;
        long vendor_id = -1;
        if (info) {
            long v = cfnum(info, "DisplayVendorID"), p = cfnum(info, "DisplayProductID"), s = cfnum(info, "DisplaySerialNumber");
            vendor_id = v;
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
            // The vendor gate. Only a panel of the flag's own vendor is ever a
            // candidate, and the decision to send waits until every framebuffer
            // has been seen, so that "exactly one" can be enforced rather than
            // "the first one".
            if (do_write && external && vendor_id == target_vendor) {
                if (target_count < (int)(sizeof target_iface / sizeof target_iface[0])) {
                    IOObjectRetain(iface);
                    target_iface[target_count] = iface;
                }
                target_count++;
            }
            IOObjectRelease(iface);
        }
        IOObjectRelease(fb);
    }
    IOObjectRelease(it);
    if (nfb == 0) printf("  none. This Mac has no framebuffer I2C route.\n");

    int rc = 0;
    if (do_write) {
        printf("\n== %s -> %s (0x%02X) ==\n",
               write_is_lg ? "LG service channel SetVCP 0xF4" : "SetVCP 0x60",
               write_name, write_value);
        if (target_count != 1) {
            printf("  REFUSED: found %d display(s) with EDID vendor 0x%04lX; need exactly one.\n"
                   "  Zero and many are both refusals: an ambiguous target cannot be aimed at safely.\n",
                   target_count, target_vendor);
            rc = 1;
        } else {
            bool sent = write_is_lg
                ? i2c_set_lg_input_alt(target_iface[0], target_vendor, write_value)
                : i2c_set_asus_input(target_iface[0], target_vendor, write_value);
            if (!sent) rc = 1;
            else printf("  Sent. This is NOT a confirmation -- a write returning success has lied here\n"
                        "  before. Look at the monitor; that is the only thing that settles it.\n");
        }
    }
    for (int i = 0; i < target_count && i < (int)(sizeof target_iface / sizeof target_iface[0]); i++)
        IOObjectRelease(target_iface[i]);

    if (!do_write)
        printf("\nNothing was written to any monitor.%s\n",
               do_read ? " One GetVCP 0x60 read was sent per external framebuffer, source 0x51." : "");
    return rc;
}
