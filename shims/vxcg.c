// libvxcg: CoreGraphics for a macOS program on visionOS: the real CoreGraphics re-exported, and the display calls
// visionOS lacks (CGDisplay*, CGDisplayMode*, the cursor and event-source calls) answered for one display: the
// screen libvxkit reports (vxkit_set_screen). Display modes are CF dictionaries (real CF objects: CFRetain/CFRelease
// work), read back by the CGDisplayMode getters.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include "vxmac.h"

void vxkit_screen(double *w, double *h, double *scale, double *hz);   // (libvxkit)
void vxkit_set_cursor_associated(int on);

typedef uint32_t VXDisplayID;
typedef CFDictionaryRef VXDisplayModeRef;
const CFStringRef kCGDisplayShowDuplicateLowResolutionModes = CFSTR("kCGDisplayShowDuplicateLowResolutionModes");

VXDisplayID CGMainDisplayID(void) { return 1; }
int32_t CGGetActiveDisplayList(uint32_t max, VXDisplayID *ids, uint32_t *count) {
    if (ids && max) ids[0] = 1;
    if (count) *count = ids ? (max ? 1 : 0) : 1;
    return 0;
}
CGRect CGDisplayBounds(VXDisplayID d) { (void)d; double w, h, s, hz; vxkit_screen(&w, &h, &s, &hz); return CGRectMake(0, 0, w, h); }
size_t CGDisplayPixelsWide(VXDisplayID d) { (void)d; double w, h, s, hz; vxkit_screen(&w, &h, &s, &hz); return (size_t)(w * s); }
size_t CGDisplayPixelsHigh(VXDisplayID d) { (void)d; double w, h, s, hz; vxkit_screen(&w, &h, &s, &hz); return (size_t)(h * s); }
uint32_t CGDisplayIsBuiltin(VXDisplayID d) { (void)d; return 1; }
uint32_t CGDisplayIsInMirrorSet(VXDisplayID d) { (void)d; return 0; }
uint32_t CGDisplayModelNumber(VXDisplayID d) { (void)d; return 0x5650; }
uint32_t CGDisplayVendorNumber(VXDisplayID d) { (void)d; return 0x610; }
uint32_t CGDisplaySerialNumber(VXDisplayID d) { (void)d; return 1; }
uint32_t CGDisplayIOServicePort(VXDisplayID d) { (void)d; return 0; }

static CFDictionaryRef make_mode(double w, double h, double s, double hz) {
    double v[5] = { w, h, w * s, h * s, hz };
    const void *keys[5] = { CFSTR("w"), CFSTR("h"), CFSTR("pw"), CFSTR("ph"), CFSTR("hz") };
    CFNumberRef nums[5];
    for (int i = 0; i < 5; i++) nums[i] = CFNumberCreate(NULL, kCFNumberDoubleType, &v[i]);
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, (const void **)nums, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (int i = 0; i < 5; i++) CFRelease(nums[i]);
    return d;
}
static double mode_get(VXDisplayModeRef m, CFStringRef k) {
    double v = 0;
    if (!m || CFGetTypeID(m) != CFDictionaryGetTypeID()) return 0;
    CFNumberRef n = CFDictionaryGetValue(m, k);
    if (n) CFNumberGetValue(n, kCFNumberDoubleType, &v);
    return v;
}
VXDisplayModeRef CGDisplayCopyDisplayMode(VXDisplayID d) { (void)d; double w, h, s, hz; vxkit_screen(&w, &h, &s, &hz); return make_mode(w, h, s, hz); }
CFArrayRef CGDisplayCopyAllDisplayModes(VXDisplayID d, CFDictionaryRef opts) {
    (void)opts;
    // (the screen's own mode first, then smaller ones at its aspect the program can pick to save memory: 16:9 for
    //  1920x1080, h31's near-square screen: 1280 / 1040 / 832 wide, heights even)
    double w, h, s, hz; vxkit_screen(&w, &h, &s, &hz); (void)d;
    static const double widths[] = { 1600, 1280, 1040, 832 };
    VXDisplayModeRef m[5]; int n = 0;
    m[n++] = make_mode(w, h, s, hz);
    for (int i = 0; i < 4; i++) if (widths[i] < w) { double hh = 2 * floor(widths[i] * h / w / 2 + 0.5); m[n++] = make_mode(widths[i], hh, s, hz); }
    CFArrayRef a = CFArrayCreate(NULL, (const void **)m, n, &kCFTypeArrayCallBacks);
    for (int i = 0; i < n; i++) CFRelease(m[i]);
    return a;
}
size_t CGDisplayModeGetWidth(VXDisplayModeRef m) { return (size_t)mode_get(m, CFSTR("w")); }
size_t CGDisplayModeGetHeight(VXDisplayModeRef m) { return (size_t)mode_get(m, CFSTR("h")); }
size_t CGDisplayModeGetPixelWidth(VXDisplayModeRef m) { return (size_t)mode_get(m, CFSTR("pw")); }
size_t CGDisplayModeGetPixelHeight(VXDisplayModeRef m) { return (size_t)mode_get(m, CFSTR("ph")); }
double CGDisplayModeGetRefreshRate(VXDisplayModeRef m) { return mode_get(m, CFSTR("hz")); }
uint32_t CGDisplayModeGetIOFlags(VXDisplayModeRef m) { (void)m; return 0x00000003; }   // (valid | safe)
bool CGDisplayModeIsUsableForDesktopGUI(VXDisplayModeRef m) { (void)m; return true; }
void CGDisplayModeRelease(VXDisplayModeRef m) { if (m) CFRelease(m); }
VXDisplayModeRef CGDisplayModeRetain(VXDisplayModeRef m) { if (m) CFRetain(m); return m; }

// (the cursor: nothing to move on visionOS; the program's wish is kept for the host)
int32_t CGWarpMouseCursorPosition(CGPoint p) { static int n; if (n++ < 3) vxmac_log("CG: warp cursor to %.0f,%.0f", p.x, p.y); return 0; }
int32_t CGAssociateMouseAndMouseCursorPosition(uint32_t connected) {
    static int last = -1;
    if ((int)connected != last) { last = (int)connected; vxmac_log("CG: mouse and cursor %s (the game's mouse look %s)", connected ? "associated" : "dissociated", connected ? "off" : "on"); }
    vxkit_set_cursor_associated(connected != 0); return 0;
}
int32_t CGDisplayHideCursor(VXDisplayID d) { (void)d; return 0; }
int32_t CGDisplayShowCursor(VXDisplayID d) { (void)d; return 0; }
CFTypeRef CGEventSourceCreate(int32_t state) {
    (void)state;
    return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
void CGEventSourceSetLocalEventsSuppressionInterval(CFTypeRef src, double seconds) { (void)src; (void)seconds; }
