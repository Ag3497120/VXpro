// macsnap: a Mac test helper (DYLD_INSERT_LIBRARIES): every MACSNAP_S seconds (default 10) the presented drawable as
// MACSNAP_DIR/snapN.png (BGRA8 drawables), to see what a program shows without screen capture permission; and
// MACSNAP_CMD: a file of commands, read every 0.2 s and emptied: "key <keyCode>" (a key press posted to the app, for
// navigating a test run's menus as the person asked), "snap" (a snapshot at the next present).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#include <objc/runtime.h>
#import <AppKit/AppKit.h>
static IMP o_present, o_present_t, o_present_a; static double g_last; static int g_n; static volatile int g_force;
static void snap(id<MTLCommandBuffer> cb, id<MTLTexture> t) {
    if (t.pixelFormat != MTLPixelFormatBGRA8Unorm && t.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) return;
    NSUInteger w = t.width, h = t.height, row = w * 4;
    id<MTLBuffer> b = [cb.device newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [e endEncoding];
    int n = g_n++;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(b.contents, w, h, 8, row, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        const char *d = getenv("MACSNAP_DIR");
        NSURL *u = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/snap%03d.png", d ? d : "/tmp", n]];
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)u, CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst);
        CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    }];
}
static void maybe(id cb, id d) {
    double now = CACurrentMediaTime(), every = getenv("MACSNAP_S") ? atof(getenv("MACSNAP_S")) : 10;
    if (g_force || now - g_last >= every) { g_force = 0; g_last = now; snap(cb, ((id<CAMetalDrawable>)d).texture); }
}
static void h_present(id self, SEL s, id d) { maybe(self, d); ((void (*)(id, SEL, id))o_present)(self, s, d); }
static void h_present_t(id self, SEL s, id d, double t) { maybe(self, d); ((void (*)(id, SEL, id, double))o_present_t)(self, s, d, t); }
static void h_present_a(id self, SEL s, id d, double t) { maybe(self, d); ((void (*)(id, SEL, id, double))o_present_a)(self, s, d, t); }
// (a drawable presented on its own - the game's path on the Mac: CAMetalDisplayLink + [drawable present] - snapped
//  through a queue of our own)
static IMP o_dpresent, o_next; static id<MTLCommandQueue> g_q;
static void h_dpresent(id self, SEL s) {
    double now = CACurrentMediaTime(), every = getenv("MACSNAP_S") ? atof(getenv("MACSNAP_S")) : 10;
    if (g_force || now - g_last >= every) {
        g_force = 0; g_last = now;
        id<MTLTexture> t = ((id<CAMetalDrawable>)self).texture;
        if (!g_q) g_q = [t.device newCommandQueue];
        id<MTLCommandBuffer> cb = [g_q commandBuffer]; snap(cb, t); [cb commit];
    }
    ((void (*)(id, SEL))o_dpresent)(self, s);
}
static IMP o_upd_drawable2;
static id h_next(id self, SEL s) {
    id d = s == @selector(drawable) ? ((id (*)(id, SEL))o_upd_drawable2)(self, s) : ((id (*)(id, SEL))o_next)(self, s);
    static dispatch_once_t once;
    if (d) dispatch_once(&once, ^{
        Class dc = object_getClass(d);
        o_dpresent = method_setImplementation(class_getInstanceMethod(dc, @selector(present)), (IMP)h_dpresent);
        fprintf(stderr, "macsnap: drawable class %s hooked\n", class_getName(dc));
    });
    return d;
}
static IMP o_upd_drawable;
static id h_upd_drawable(id self, SEL s) { return h_next(self, s); }
// (the game's main thread does not drain the main queue while it runs: the events are handed to the window from
//  this thread, MACSNAP_MAIN=1 to go through the main queue)
static void on_main(dispatch_block_t b) { if (getenv("MACSNAP_MAIN")) dispatch_async(dispatch_get_main_queue(), b); else b(); }
static void click(double x, double y) {   // (window content coordinates, top-left origin)
    on_main(^{
        NSWindow *w = NSApp.keyWindow ?: NSApp.windows.firstObject;
        NSPoint p = NSMakePoint(x, w.contentView.bounds.size.height - y);
        for (int down = 1; down >= 0; down--) {
            NSEvent *e = [NSEvent mouseEventWithType:down ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp location:p modifierFlags:0
                                           timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:down];
            [w sendEvent:e];
            usleep(80000);
        }
        NSView *v = w.contentView;
        fprintf(stderr, "macsnap: click %.0f,%.0f in %s %.0fx%.0f first responder %s\n", x, y, class_getName([v class]), v.bounds.size.width, v.bounds.size.height, class_getName([w.firstResponder class]));
    });
}
static void post_key(unsigned short kc) {
    on_main(^{
        NSWindow *w = NSApp.keyWindow ?: NSApp.windows.firstObject;
        for (int down = 1; down >= 0; down--) {
            NSEvent *e = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0
                                         timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil
                                        characters:kc == 36 ? @"\r" : kc == 49 ? @" " : kc == 53 ? @"\x1b" : @"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:kc];
            if (getenv("MACSNAP_POST")) [NSApp postEvent:e atStart:NO]; else [w sendEvent:e];
        }
    });
}
__attribute__((constructor)) static void init(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    Class c = [[[dev newCommandQueue] commandBuffer] class];
    o_present = method_setImplementation(class_getInstanceMethod(c, @selector(presentDrawable:)), (IMP)h_present);
    o_present_t = method_setImplementation(class_getInstanceMethod(c, @selector(presentDrawable:atTime:)), (IMP)h_present_t);
    o_present_a = method_setImplementation(class_getInstanceMethod(c, @selector(presentDrawable:afterMinimumDuration:)), (IMP)h_present_a);
    o_next = method_setImplementation(class_getInstanceMethod(objc_getClass("CAMetalLayer"), @selector(nextDrawable)), (IMP)h_next);
    Method um = class_getInstanceMethod(objc_getClass("CAMetalDisplayLinkUpdate"), @selector(drawable));
    if (um) o_upd_drawable2 = method_setImplementation(um, (IMP)h_upd_drawable);
    const char *cmdf = getenv("MACSNAP_CMD");
    if (cmdf) {
        NSString *path = @(cmdf);
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
        dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 5, NSEC_PER_SEC / 50);
        dispatch_source_set_event_handler(t, ^{
            NSString *c = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!c.length) return;
            [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
            for (NSString *line in [c componentsSeparatedByString:@"\n"]) {
                NSArray *w = [line componentsSeparatedByString:@" "];
                if ([w[0] isEqual:@"key"] && w.count > 1) { post_key((unsigned short)[w[1] intValue]); usleep(150000); }
                else if ([w[0] isEqual:@"snap"]) g_force = 1;
                else if ([w[0] isEqual:@"click"] && w.count > 2) { click([w[1] doubleValue], [w[2] doubleValue]); usleep(300000); }
                else if ([w[0] isEqual:@"move"] && w.count > 2) dispatch_async(dispatch_get_main_queue(), ^{
                    NSWindow *win = NSApp.keyWindow ?: NSApp.windows.firstObject;
                    NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:NSMakePoint([w[1] doubleValue], win.contentView.bounds.size.height - [w[2] doubleValue])
                                               modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
                    [win sendEvent:e]; });
                else if ([w[0] isEqual:@"activate"]) dispatch_async(dispatch_get_main_queue(), ^{ [NSApp activateIgnoringOtherApps:YES]; [NSApp.windows.firstObject makeKeyAndOrderFront:nil]; });
            }
        });
        dispatch_resume(t);
        static dispatch_source_t keep; keep = t;
    }
}
