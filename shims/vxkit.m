// libvxkit: the part of AppKit a macOS game uses, for visionOS (which has no AppKit), loaded in place of
// AppKit.framework by images prepared with tools/macho_prepare.py. Our own implementation from Apple's public
// AppKit documentation; no AppKit code. The classes are real Objective-C classes with AppKit's names (a game's
// NSWindow / NSView / NSWindowController subclasses bind to them as superclasses) but nothing here is drawn: a
// window is a model object (frame, style, delegate, first responder, content view), the content view's layer (the
// game's CAMetalLayer) is never put on screen, and its frames are taken at present by libvxmtl and shown by the host.
// Events come from the host (vxmac.h vxkit_post_*) through a queue that -[NSApplication nextEventMatchingMask:...]
// drains, running the calling thread's run loop while it waits (the game's main loop thread is not the process's
// main thread: UIKit keeps that one).
//
// What a program calls that is not here reaches a catch-all (+resolveInstanceMethod:, a zero-returning method),
// logged once per selector (vxkit_unknown_selectors), so a missing method is a line in the log, not a crash.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include "vxmac.h"

typedef CGRect NSRect; typedef CGPoint NSPoint; typedef CGSize NSSize;
typedef NS_ENUM(NSUInteger, VXEventType) {
    NSEventTypeLeftMouseDown = 1, NSEventTypeLeftMouseUp = 2, NSEventTypeRightMouseDown = 3, NSEventTypeRightMouseUp = 4,
    NSEventTypeMouseMoved = 5, NSEventTypeLeftMouseDragged = 6, NSEventTypeRightMouseDragged = 7,
    NSEventTypeMouseEntered = 8, NSEventTypeMouseExited = 9, NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11,
    NSEventTypeFlagsChanged = 12, NSEventTypeAppKitDefined = 13, NSEventTypeSystemDefined = 14,
    NSEventTypeApplicationDefined = 15, NSEventTypePeriodic = 16, NSEventTypeCursorUpdate = 17,
    NSEventTypeScrollWheel = 22, NSEventTypeOtherMouseDown = 25, NSEventTypeOtherMouseUp = 26,
    NSEventTypeOtherMouseDragged = 27,
};
enum { kFlagCaps = 1 << 16, kFlagShift = 1 << 17, kFlagControl = 1 << 18, kFlagOption = 1 << 19, kFlagCommand = 1 << 20,
       kFlagNumPad = 1 << 21, kFlagFunction = 1 << 23 };

// ---- log ------------------------------------------------------------------------------------------------------------
// (lines logged before the host set its sink - the shims' constructors run before the host's - are kept and given
// to the sink when it is set, so the Metal device's figures and the macOS-only methods are in the log)
static void (*g_sink)(const char *);
static char g_early[48][256]; static int g_nearly;
void vxmac_set_log_sink(void (*sink)(const char *line)) {
    g_sink = sink;
    for (int i = 0; i < g_nearly; i++) { fprintf(stderr, "vxmac: %s\n", g_early[i]); if (sink) sink(g_early[i]); }
    g_nearly = 0;
}
void vxmac_log(const char *fmt, ...) {
    char line[1024];
    va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    fprintf(stderr, "vxmac: %s\n", line);
    if (g_sink) g_sink(line);
    else if (g_nearly < 48) snprintf(g_early[g_nearly++], sizeof g_early[0], "%s", line);
}

// ---- the catch-all for methods we do not have ------------------------------------------------------------------------
static pthread_mutex_t g_unk_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_unknown[4096];
static id vx_zero_imp(id self, SEL _cmd, ...) { (void)self; (void)_cmd; return nil; }
static BOOL vx_resolve(Class cls, SEL sel, BOOL meta) {
    const char *name = sel_getName(sel);
    // (selectors the runtime itself probes for must stay unresolved)
    if (!strncmp(name, "_", 1) || !strcmp(name, "forwardingTargetForSelector:") || !strcmp(name, "methodSignatureForSelector:") ||
        !strncmp(name, ".cxx", 4) || !strcmp(name, "initialize") || !strcmp(name, "load") || !strncmp(name, "accessibility", 13))
        return NO;
    char item[200];
    snprintf(item, sizeof item, "%s %c%s", class_getName(cls), meta ? '+' : '-', name);
    pthread_mutex_lock(&g_unk_lock);
    int fresh = !strstr(g_unknown, item);
    if (fresh && strlen(g_unknown) + strlen(item) + 3 < sizeof g_unknown) { if (*g_unknown) strcat(g_unknown, ", "); strcat(g_unknown, item); }
    pthread_mutex_unlock(&g_unk_lock);
    if (fresh) vxmac_log("AppKit: not implemented: %s (returns 0)", item);
    class_addMethod(meta ? object_getClass(cls) : cls, sel, (IMP)vx_zero_imp, "@@:");
    return YES;
}
void vxkit_unknown_selectors(char *out, unsigned size) {
    pthread_mutex_lock(&g_unk_lock); snprintf(out, size, "%s", g_unknown); pthread_mutex_unlock(&g_unk_lock);
}
#define VX_CATCHALL \
    + (BOOL)resolveInstanceMethod:(SEL)sel { return vx_resolve(self, sel, NO); } \
    + (BOOL)resolveClassMethod:(SEL)sel { return vx_resolve(self, sel, YES); }

// ---- exported constants ------------------------------------------------------------------------------------------
#define NOTE(n) NSString *const n = @#n;
NOTE(NSApplicationDidBecomeActiveNotification) NOTE(NSApplicationDidResignActiveNotification)
NOTE(NSApplicationWillResignActiveNotification) NOTE(NSApplicationWillBecomeActiveNotification)
NOTE(NSApplicationDidChangeScreenParametersNotification) NOTE(NSApplicationDidFinishLaunchingNotification)
NOTE(NSApplicationWillFinishLaunchingNotification) NOTE(NSApplicationWillTerminateNotification)
NOTE(NSWindowDidBecomeKeyNotification) NOTE(NSWindowDidResignKeyNotification) NOTE(NSWindowDidResizeNotification)
NOTE(NSWindowWillCloseNotification) NOTE(NSWindowWillExitFullScreenNotification) NOTE(NSWindowDidEnterFullScreenNotification)
NOTE(NSWindowDidExitFullScreenNotification) NOTE(NSWindowDidChangeScreenNotification) NOTE(NSWindowDidMoveNotification)
NOTE(NSWindowDidBecomeMainNotification) NOTE(NSWindowDidChangeOcclusionStateNotification)
NOTE(NSWindowDidMiniaturizeNotification) NOTE(NSWindowDidDeminiaturizeNotification)
NSString *const NSEventTrackingRunLoopMode = @"NSEventTrackingRunLoopMode";
NSString *const NSModalPanelRunLoopMode = @"NSModalPanelRunLoopMode";
NSString *const NSImageHintInterpolation = @"NSImageHintInterpolation";
NSString *const NSDeviceSize = @"NSDeviceSize";
NSString *const NSDeviceResolution = @"NSDeviceResolution";
id NSApp;

// ---- the screen ------------------------------------------------------------------------------------------------------
static double g_scr_w = 1920, g_scr_h = 1080, g_scr_scale = 1, g_scr_hz = 90;
void vxkit_set_screen(double w, double h, double scale, double hz) { g_scr_w = w; g_scr_h = h; g_scr_scale = scale; g_scr_hz = hz; }
// (for libvxcg: the same figures)
void vxkit_screen(double *w, double *h, double *scale, double *hz) { *w = g_scr_w; *h = g_scr_h; *scale = g_scr_scale; *hz = g_scr_hz; }

@class NSWindow, NSView, NSEvent, NSCursor;

@interface NSResponder : NSObject
@property (weak) NSResponder *nextResponder;
@end
@implementation NSResponder
VX_CATCHALL
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
- (void)keyDown:(id)e { [self.nextResponder keyDown:e]; }
- (void)keyUp:(id)e { [self.nextResponder keyUp:e]; }
- (void)flagsChanged:(id)e { [self.nextResponder flagsChanged:e]; }
- (void)mouseDown:(id)e { [self.nextResponder mouseDown:e]; }
- (void)mouseUp:(id)e { [self.nextResponder mouseUp:e]; }
- (void)mouseDragged:(id)e { [self.nextResponder mouseDragged:e]; }
- (void)mouseMoved:(id)e { [self.nextResponder mouseMoved:e]; }
- (void)mouseEntered:(id)e { (void)e; }
- (void)mouseExited:(id)e { (void)e; }
- (void)rightMouseDown:(id)e { [self.nextResponder rightMouseDown:e]; }
- (void)rightMouseUp:(id)e { [self.nextResponder rightMouseUp:e]; }
- (void)rightMouseDragged:(id)e { [self.nextResponder rightMouseDragged:e]; }
- (void)otherMouseDown:(id)e { [self.nextResponder otherMouseDown:e]; }
- (void)otherMouseUp:(id)e { [self.nextResponder otherMouseUp:e]; }
- (void)otherMouseDragged:(id)e { [self.nextResponder otherMouseDragged:e]; }
- (void)scrollWheel:(id)e { [self.nextResponder scrollWheel:e]; }
- (void)cursorUpdate:(id)e { (void)e; }
- (void)noResponderFor:(SEL)s { (void)s; }
- (id)identifier { return objc_getAssociatedObject(self, "vxid"); }
- (void)setIdentifier:(id)i { objc_setAssociatedObject(self, "vxid", i, OBJC_ASSOCIATION_COPY); }
@end

// ---- NSScreen -------------------------------------------------------------------------------------------------------
typedef struct { CGFloat top, left, bottom, right; } VXEdgeInsets;
static NSValue *vsize(CGSize z) { return [NSValue valueWithBytes:&z objCType:@encode(CGSize)]; }
@interface NSScreen : NSObject
@end
@implementation NSScreen
VX_CATCHALL
+ (NSScreen *)mainScreen { static NSScreen *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [NSScreen new]; }); return s; }
+ (NSArray *)screens { return @[ [self mainScreen] ]; }
+ (BOOL)screensHaveSeparateSpaces { return YES; }
- (NSRect)frame { return CGRectMake(0, 0, g_scr_w, g_scr_h); }
- (NSRect)visibleFrame { return [self frame]; }
- (CGFloat)backingScaleFactor { return g_scr_scale; }
- (NSDictionary *)deviceDescription {
    return @{ @"NSScreenNumber": @1, NSDeviceSize: vsize(CGSizeMake(g_scr_w, g_scr_h)),
              NSDeviceResolution: vsize(CGSizeMake(72 * g_scr_scale, 72 * g_scr_scale)), @"NSDeviceIsScreen": @"YES" };
}
- (NSString *)localizedName { return @"Vision Pro"; }
- (NSInteger)maximumFramesPerSecond { return (NSInteger)g_scr_hz; }
- (NSTimeInterval)minimumRefreshInterval { return 1.0 / g_scr_hz; }
- (NSTimeInterval)maximumRefreshInterval { return 1.0 / g_scr_hz; }
- (NSTimeInterval)displayUpdateGranularity { return 0; }
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumReferenceExtendedDynamicRangeColorComponentValue { return 0; }
- (VXEdgeInsets)safeAreaInsets { VXEdgeInsets z = { 0 }; return z; }
- (NSInteger)depth { return 0; }
- (id)colorSpace { return nil; }
@end

// ---- NSEvent --------------------------------------------------------------------------------------------------------
@interface NSEvent : NSObject {
@public
    NSUInteger _type, _flags; uint16_t _keyCode; BOOL _repeat, _precise, _head; NSPoint _loc; CGFloat _dx, _dy, _sdx, _sdy;
    NSTimeInterval _time; NSInteger _button, _clicks; __weak NSWindow *_window; NSString *_chars; id _trackingArea;
}
@end
static pthread_mutex_t g_mon_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray *g_monitors;                 // (local monitors: { mask, handler })
static NSUInteger g_mod_flags;
static NSPoint g_mouse_screen;                      // (bottom-left origin, points)
static NSUInteger g_buttons;
@implementation NSEvent
VX_CATCHALL
+ (NSPoint)mouseLocation { return g_mouse_screen; }
+ (NSUInteger)modifierFlags { return g_mod_flags; }
+ (NSUInteger)pressedMouseButtons { return g_buttons; }
+ (NSTimeInterval)doubleClickInterval { return 0.5; }
+ (NSTimeInterval)keyRepeatDelay { return 0.5; }
+ (NSTimeInterval)keyRepeatInterval { return 0.05; }
+ (void)setMouseCoalescingEnabled:(BOOL)on { (void)on; }
+ (BOOL)isMouseCoalescingEnabled { return NO; }
+ (id)addLocalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(NSEvent *(^)(NSEvent *))handler {
    id m = @[ @(mask), [handler copy] ];
    pthread_mutex_lock(&g_mon_lock);
    if (!g_monitors) g_monitors = [NSMutableArray array];
    [g_monitors addObject:m];
    pthread_mutex_unlock(&g_mon_lock);
    return m;
}
+ (id)addGlobalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(void (^)(NSEvent *))handler { (void)mask; (void)handler; return [NSObject new]; }
+ (void)removeMonitor:(id)m { pthread_mutex_lock(&g_mon_lock); [g_monitors removeObjectIdenticalTo:m]; pthread_mutex_unlock(&g_mon_lock); }
+ (NSEvent *)otherEventWithType:(NSUInteger)type location:(NSPoint)loc modifierFlags:(NSUInteger)flags timestamp:(NSTimeInterval)t
                    windowNumber:(NSInteger)wn context:(id)ctx subtype:(short)st data1:(NSInteger)d1 data2:(NSInteger)d2 {
    (void)wn; (void)ctx; (void)st; (void)d1; (void)d2;
    NSEvent *e = [NSEvent new]; e->_type = type; e->_loc = loc; e->_flags = flags; e->_time = t; return e;
}
- (NSUInteger)type { return _type; }
- (NSUInteger)modifierFlags { return _flags; }
- (unsigned short)keyCode { return _keyCode; }
- (BOOL)isARepeat { return _repeat; }
- (NSString *)characters { return _chars ?: @""; }
- (NSString *)charactersIgnoringModifiers { return _chars ?: @""; }
- (NSPoint)locationInWindow { return _loc; }
- (CGFloat)deltaX { return _dx; }
- (CGFloat)deltaY { return _dy; }
- (CGFloat)deltaZ { return 0; }
- (CGFloat)scrollingDeltaX { return _sdx; }
- (CGFloat)scrollingDeltaY { return _sdy; }
- (BOOL)hasPreciseScrollingDeltas { return _precise; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (NSUInteger)phase { return 0; }
- (NSUInteger)momentumPhase { return 0; }
- (NSWindow *)window { return _window; }
- (NSInteger)windowNumber { return _window ? 1 : 0; }
- (NSTimeInterval)timestamp { return _time; }
- (NSInteger)buttonNumber { return _button; }
- (NSInteger)clickCount { return _clicks; }
- (float)pressure { return (_type == NSEventTypeLeftMouseDown || _type == NSEventTypeLeftMouseDragged) ? 1.f : 0.f; }
- (short)subtype { return 0; }
- (NSInteger)data1 { return 0; }
- (NSInteger)data2 { return 0; }
- (id)trackingArea { return _trackingArea; }
- (void *)userData { return NULL; }
- (void *)CGEvent { return NULL; }
- (NSUInteger)deviceID { return 0; }
@end

// ---- NSCursor, NSImage, NSMenu, NSTrackingArea, NSWorkspace ------------------------------------------------------------
static int g_cursor_hidden, g_cursor_assoc = 1;
int vxkit_cursor_hidden(void) { return g_cursor_hidden > 0; }
int vxkit_cursor_associated(void) { return g_cursor_assoc; }
void vxkit_set_cursor_associated(int on) { g_cursor_assoc = on; }   // (libvxcg)

@interface NSImage : NSObject { @public NSSize _size; NSString *_name; NSMutableArray *_reps; }
@end
@implementation NSImage
VX_CATCHALL
- (instancetype)initWithSize:(NSSize)s { if ((self = [super init])) _size = s; return self; }
- (instancetype)initWithContentsOfFile:(NSString *)p { (void)p; return [self initWithSize:CGSizeMake(32, 32)]; }
- (instancetype)initWithData:(NSData *)d { (void)d; return [self initWithSize:CGSizeMake(32, 32)]; }
- (instancetype)initWithCGImage:(CGImageRef)img size:(NSSize)s {
    if (s.width == 0 && img) s = CGSizeMake(CGImageGetWidth(img), CGImageGetHeight(img));
    return [self initWithSize:s];
}
- (NSSize)size { return _size; }
- (void)setSize:(NSSize)s { _size = s; }
- (NSString *)name { return _name; }
- (BOOL)setName:(NSString *)n { _name = [n copy]; return YES; }
- (void)lockFocus {}
- (void)unlockFocus {}
- (void)drawInRect:(NSRect)r {}
- (void)drawInRect:(NSRect)r fromRect:(NSRect)f operation:(NSUInteger)op fraction:(CGFloat)a respectFlipped:(BOOL)rf hints:(NSDictionary *)h {}
- (void)drawInRect:(NSRect)r fromRect:(NSRect)f operation:(NSUInteger)op fraction:(CGFloat)a {}
- (void)addRepresentation:(id)rep { if (!_reps) _reps = [NSMutableArray array]; if (rep) [_reps addObject:rep]; }
- (NSArray *)representations { return _reps ?: @[]; }
- (CGImageRef)CGImageForProposedRect:(NSRect *)r context:(id)c hints:(NSDictionary *)h { return NULL; }
- (NSData *)TIFFRepresentation { return nil; }
- (void)setDelegate:(id)d { (void)d; }
- (BOOL)isValid { return YES; }
- (void)setTemplate:(BOOL)t { (void)t; }
@end

@interface NSCursor : NSObject { @public NSImage *_image; NSPoint _hot; }
@end
static NSCursor *g_current_cursor;
@implementation NSCursor
VX_CATCHALL
+ (NSCursor *)arrowCursor { static NSCursor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [NSCursor new]; }); return c; }
+ (NSCursor *)currentCursor { return g_current_cursor ?: [self arrowCursor]; }
+ (NSCursor *)currentSystemCursor { return [self currentCursor]; }
+ (NSCursor *)IBeamCursor { return [self arrowCursor]; }
+ (NSCursor *)pointingHandCursor { return [self arrowCursor]; }
+ (NSCursor *)crosshairCursor { return [self arrowCursor]; }
+ (NSCursor *)openHandCursor { return [self arrowCursor]; }
+ (NSCursor *)closedHandCursor { return [self arrowCursor]; }
+ (void)hide { g_cursor_hidden++; }
+ (void)unhide { if (g_cursor_hidden > 0) g_cursor_hidden--; }
+ (void)setHiddenUntilMouseMoves:(BOOL)f { (void)f; }
- (instancetype)initWithImage:(NSImage *)img hotSpot:(NSPoint)hot { if ((self = [super init])) { _image = img; _hot = hot; } return self; }
- (NSImage *)image { return _image; }
- (NSPoint)hotSpot { return _hot; }
- (void)set { g_current_cursor = self; }
- (void)push { g_current_cursor = self; }
- (void)pop {}
- (void)mouseEntered:(id)e { (void)e; }
- (void)mouseExited:(id)e { (void)e; }
@end

@interface NSMenu : NSObject { NSString *_title; NSMutableArray *_items; }
@end
static BOOL g_menubar_visible = YES;
@implementation NSMenu
VX_CATCHALL
+ (void)setMenuBarVisible:(BOOL)v { g_menubar_visible = v; }
+ (BOOL)menuBarVisible { return g_menubar_visible; }
+ (CGFloat)menuBarHeight { return 0; }
- (instancetype)initWithTitle:(NSString *)t { if ((self = [super init])) { _title = [t copy]; _items = [NSMutableArray array]; } return self; }
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)t { _title = [t copy]; }
- (void)addItem:(id)i { if (i) [_items addObject:i]; }
- (id)addItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k { (void)a; (void)k; id i = t; [_items addObject:i]; return nil; }
- (NSArray *)itemArray { return _items; }
- (void)setDelegate:(id)d { (void)d; }
- (void)setSubmenu:(id)m forItem:(id)i { (void)m; (void)i; }
@end

@interface NSTrackingArea : NSObject { NSRect _rect; NSUInteger _options; __weak id _owner; NSDictionary *_info; }
@end
@implementation NSTrackingArea
VX_CATCHALL
- (instancetype)initWithRect:(NSRect)r options:(NSUInteger)o owner:(id)owner userInfo:(NSDictionary *)info {
    if ((self = [super init])) { _rect = r; _options = o; _owner = owner; _info = info; } return self;
}
- (NSRect)rect { return _rect; }
- (NSUInteger)options { return _options; }
- (id)owner { return _owner; }
- (NSDictionary *)userInfo { return _info; }
@end

@interface NSWorkspace : NSObject { NSNotificationCenter *_nc; }
@end
@implementation NSWorkspace
VX_CATCHALL
+ (NSWorkspace *)sharedWorkspace { static NSWorkspace *w; static dispatch_once_t o; dispatch_once(&o, ^{ w = [NSWorkspace new]; }); return w; }
- (NSNotificationCenter *)notificationCenter { if (!_nc) _nc = [NSNotificationCenter new]; return _nc; }
- (BOOL)openURL:(NSURL *)u { vxmac_log("AppKit: openURL %s (not opened)", u.absoluteString.UTF8String); return NO; }
- (id)frontmostApplication { return nil; }
- (NSArray *)runningApplications { return @[]; }
- (BOOL)accessibilityDisplayShouldReduceMotion { return NO; }
- (BOOL)accessibilityDisplayShouldIncreaseContrast { return NO; }
@end

// ---- NSView ---------------------------------------------------------------------------------------------------------
@interface NSView : NSResponder {
@public
    NSRect _frame; __weak NSWindow *_window; __weak NSView *_superview; NSMutableArray *_subviews; CALayer *_layer;
    BOOL _wantsLayer; NSUInteger _autoresizing; NSMutableArray *_tracking;
}
@end
@interface NSWindow : NSResponder {
@public
    NSRect _frame; NSUInteger _style; NSView *_content; __weak id _delegate; NSResponder *_first; NSString *_title;
    BOOL _visible, _key, _main, _mouseMoved, _mini, _fullscreen; NSUInteger _collection; NSInteger _level;
    __weak id _controller; NSSize _minSize, _maxSize, _aspect;
}
- (void)sendEvent:(NSEvent *)e;
@end
static __weak NSWindow *g_key_window;
static NSMutableArray *g_windows;
static double kTitlebar = 0;                     // (no title bar on visionOS: content = frame)

@implementation NSView
- (instancetype)initWithFrame:(NSRect)f { if ((self = [super init])) { _frame = f; _subviews = [NSMutableArray array]; _tracking = [NSMutableArray array]; } return self; }
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)f { _frame = f; [self updateLayerSize]; }
- (void)setFrameOrigin:(NSPoint)p { _frame.origin = p; }
- (void)setFrameSize:(NSSize)s { _frame.size = s; [self updateLayerSize]; }
- (NSRect)bounds { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }
- (void)setBounds:(NSRect)b { (void)b; }
- (NSWindow *)window { return _window; }
- (void)vx_setWindow:(NSWindow *)w { _window = w; for (NSView *v in _subviews) [v vx_setWindow:w]; [self viewDidMoveToWindow]; }
- (void)viewDidMoveToWindow {}
- (void)viewWillMoveToWindow:(NSWindow *)w { (void)w; }
- (NSView *)superview { return _superview; }
- (NSArray *)subviews { return _subviews; }
- (void)addSubview:(NSView *)v { if (!v) return; [_subviews addObject:v]; v->_superview = self; v.nextResponder = self; [v vx_setWindow:_window]; }
- (void)removeFromSuperview { [_superview->_subviews removeObjectIdenticalTo:self]; _superview = nil; }
- (CALayer *)layer { return _layer; }
- (void)setLayer:(CALayer *)l { _layer = l; l.delegate = (id)self; [self updateLayerSize]; }
- (BOOL)wantsLayer { return _wantsLayer; }
- (void)setWantsLayer:(BOOL)w { _wantsLayer = w; if (w && !_layer) _layer = [self makeBackingLayer]; }
- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (BOOL)wantsUpdateLayer { return NO; }
- (void)updateLayer {}
- (void)updateLayerSize { _layer.bounds = [self bounds]; }
- (void)setAutoresizingMask:(NSUInteger)m { _autoresizing = m; }
- (NSUInteger)autoresizingMask { return _autoresizing; }
- (void)addTrackingArea:(NSTrackingArea *)t { if (t) [_tracking addObject:t]; }
- (void)removeTrackingArea:(NSTrackingArea *)t { [_tracking removeObjectIdenticalTo:t]; }
- (NSArray *)trackingAreas { return _tracking; }
- (void)updateTrackingAreas {}
- (void)resetCursorRects {}
- (void)addCursorRect:(NSRect)r cursor:(NSCursor *)c { (void)r; [c set]; }
- (void)discardCursorRects {}
- (BOOL)canBecomeKeyView { return YES; }
- (void)layout {}
- (void)setNeedsLayout:(BOOL)f { (void)f; }
- (void)setNeedsDisplay:(BOOL)f { (void)f; }
- (void)display {}
- (NSRect)safeAreaRect { return [self bounds]; }
- (CGFloat)backingScaleFactor { return g_scr_scale; }
- (void)lockFocus {}
- (void)unlockFocus {}
- (void)setOpaque:(BOOL)o { (void)o; }
- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return NO; }
- (BOOL)isHidden { return NO; }
- (void)setHidden:(BOOL)h { (void)h; }
- (void)setBackgroundColor:(id)c { (void)c; }
- (void)setPostsFrameChangedNotifications:(BOOL)f { (void)f; }
- (void)setWantsBestResolutionOpenGLSurface:(BOOL)f { (void)f; }
- (void)setLayerContentsRedrawPolicy:(NSInteger)p { (void)p; }
- (void)setCanDrawSubviewsIntoLayer:(BOOL)f { (void)f; }
- (NSPoint)convertPoint:(NSPoint)p fromView:(NSView *)v { (void)v; return p; }
- (NSPoint)convertPoint:(NSPoint)p toView:(NSView *)v { (void)v; return p; }
- (NSRect)convertRect:(NSRect)r fromView:(NSView *)v { (void)v; return r; }
- (NSRect)convertRect:(NSRect)r toView:(NSView *)v { (void)v; return r; }
- (NSRect)convertRectToBacking:(NSRect)r { CGFloat s = g_scr_scale; return CGRectMake(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s); }
- (NSSize)convertSizeToBacking:(NSSize)z { return CGSizeMake(z.width * g_scr_scale, z.height * g_scr_scale); }
- (NSPoint)convertPointToBacking:(NSPoint)p { return CGPointMake(p.x * g_scr_scale, p.y * g_scr_scale); }
- (id<CAAction>)actionForLayer:(CALayer *)l forKey:(NSString *)k { (void)l; (void)k; return (id<CAAction>)[NSNull null]; }
- (void)drawLayer:(CALayer *)l inContext:(CGContextRef)c { (void)l; (void)c; }
- (void)displayLayer:(CALayer *)l { (void)l; }
- (void)viewDidChangeBackingProperties {}
@end

// ---- NSWindow --------------------------------------------------------------------------------------------------------
// (2.5.0: a small native window of the game's (its crash / mod.io text panel, NSTextViewDelegate) names these; nothing
//  is drawn on visionOS: model objects with the catch-all, the views as NSViews)
NSString *const NSFontAttributeName = @"NSFont";
NSString *const NSForegroundColorAttributeName = @"NSColor";
void NSRectFill(NSRect r) { (void)r; }
@interface NSColor : NSObject @end
@implementation NSColor VX_CATCHALL @end
@interface NSFont : NSObject @end
@implementation NSFont VX_CATCHALL @end
@interface NSBezierPath : NSObject @end
@implementation NSBezierPath VX_CATCHALL @end
@interface NSButton : NSView @end
@implementation NSButton VX_CATCHALL @end
@interface NSScroller : NSView @end
@implementation NSScroller VX_CATCHALL @end
@interface NSScrollView : NSView @end
@implementation NSScrollView VX_CATCHALL @end
@interface NSTextView : NSView @end
@implementation NSTextView VX_CATCHALL @end

@implementation NSWindow
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSUInteger)style backing:(NSUInteger)b defer:(BOOL)d {
    if ((self = [super init])) {
        _frame = r; _style = style; _title = @"";
        _content = [[NSView alloc] initWithFrame:CGRectMake(0, 0, r.size.width, r.size.height)];
        [_content vx_setWindow:self]; _content.nextResponder = self;
        if (!g_windows) g_windows = [NSMutableArray array];
        @synchronized (g_windows) { [g_windows addObject:self]; }
        vxmac_log("AppKit: window %s %.0fx%.0f style %#lx", class_getName([self class]), r.size.width, r.size.height, (unsigned long)style);
    }
    return self;
}
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSUInteger)s backing:(NSUInteger)b defer:(BOOL)d screen:(id)sc {
    return [self initWithContentRect:r styleMask:s backing:b defer:d];
}
- (NSView *)contentView { return _content; }
- (void)setContentView:(NSView *)v {
    _content = v; [v vx_setWindow:self]; v.nextResponder = self;
    if (v && CGSizeEqualToSize(v->_frame.size, CGSizeZero)) [v setFrame:CGRectMake(0, 0, _frame.size.width, _frame.size.height)];
}
- (NSRect)frame { return _frame; }
- (void)vx_resized:(NSRect)f {
    BOOL changed = !CGSizeEqualToSize(f.size, _frame.size);
    _frame = f;
    [_content setFrame:CGRectMake(0, 0, f.size.width, f.size.height - kTitlebar)];
    if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResizeNotification object:self];
}
- (void)setFrame:(NSRect)f display:(BOOL)d { (void)d; [self vx_resized:f]; }
- (void)setFrame:(NSRect)f display:(BOOL)d animate:(BOOL)a { (void)d; (void)a; [self vx_resized:f]; }
- (void)setFrameOrigin:(NSPoint)p { _frame.origin = p; }
- (void)setFrameTopLeftPoint:(NSPoint)p { _frame.origin = CGPointMake(p.x, p.y - _frame.size.height); }
- (void)setContentSize:(NSSize)s { [self vx_resized:CGRectMake(_frame.origin.x, _frame.origin.y, s.width, s.height + kTitlebar)]; }
- (NSRect)contentRectForFrameRect:(NSRect)f { return f; }
- (NSRect)frameRectForContentRect:(NSRect)c { return c; }
+ (NSRect)contentRectForFrameRect:(NSRect)f styleMask:(NSUInteger)s { (void)s; return f; }
+ (NSRect)frameRectForContentRect:(NSRect)c styleMask:(NSUInteger)s { (void)s; return c; }
- (NSRect)contentLayoutRect { return CGRectMake(0, 0, _frame.size.width, _frame.size.height - kTitlebar); }
- (NSUInteger)styleMask { return _style; }
- (void)setStyleMask:(NSUInteger)s { _style = s; }
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)t { _title = [t copy]; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (id)windowController { return _controller; }
- (void)setWindowController:(id)c { _controller = c; }
- (void)vx_becomeKey {
    NSWindow *old = g_key_window;
    if (old == self) return;
    if (old) { old->_key = NO; [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignKeyNotification object:old]; }
    g_key_window = self; _key = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeKeyNotification object:self];
}
- (void)makeKeyAndOrderFront:(id)s { (void)s; _visible = YES; [self vx_becomeKey]; [self makeMainWindow]; }
- (void)makeKeyWindow { [self vx_becomeKey]; }
- (void)makeMainWindow { if (!_main) { _main = YES; [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeMainNotification object:self]; } }
- (void)orderFront:(id)s { (void)s; _visible = YES; }
- (void)orderFrontRegardless { _visible = YES; }
- (void)orderOut:(id)s { (void)s; _visible = NO; }
- (void)orderBack:(id)s { (void)s; }
- (BOOL)isKeyWindow { return _key; }
- (BOOL)isMainWindow { return _main; }
- (BOOL)isVisible { return _visible; }
- (void)setIsVisible:(BOOL)v { _visible = v; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (NSResponder *)firstResponder { return _first ?: (NSResponder *)self; }
- (BOOL)makeFirstResponder:(NSResponder *)r {
    if (r && ![r acceptsFirstResponder]) return NO;
    [_first resignFirstResponder]; _first = r; [r becomeFirstResponder]; return YES;
}
- (NSScreen *)screen { return [NSScreen mainScreen]; }
- (NSScreen *)deepestScreen { return [NSScreen mainScreen]; }
- (CGFloat)backingScaleFactor { return g_scr_scale; }
- (NSRect)convertRectToBacking:(NSRect)r { return [_content convertRectToBacking:r]; }
- (void)setAcceptsMouseMovedEvents:(BOOL)a { _mouseMoved = a; }
- (BOOL)acceptsMouseMovedEvents { return _mouseMoved; }
- (void)setCollectionBehavior:(NSUInteger)c { _collection = c; }
- (NSUInteger)collectionBehavior { return _collection; }
- (void)setContentAspectRatio:(NSSize)s { _aspect = s; }
- (void)setMinSize:(NSSize)s { _minSize = s; }
- (void)setMaxSize:(NSSize)s { _maxSize = s; }
- (void)setContentMinSize:(NSSize)s { _minSize = s; }
- (void)setContentMaxSize:(NSSize)s { _maxSize = s; }
- (void)setParentWindow:(NSWindow *)w { (void)w; }
- (void)center { _frame.origin = CGPointMake((g_scr_w - _frame.size.width) / 2, (g_scr_h - _frame.size.height) / 2); }
- (NSPoint)convertPointFromScreen:(NSPoint)p { return CGPointMake(p.x - _frame.origin.x, p.y - _frame.origin.y); }
- (NSPoint)convertPointToScreen:(NSPoint)p { return CGPointMake(p.x + _frame.origin.x, p.y + _frame.origin.y); }
- (NSRect)convertRectToScreen:(NSRect)r { r.origin = [self convertPointToScreen:r.origin]; return r; }
- (NSRect)convertRectFromScreen:(NSRect)r { r.origin = [self convertPointFromScreen:r.origin]; return r; }
- (NSPoint)mouseLocationOutsideOfEventStream { return [self convertPointFromScreen:g_mouse_screen]; }
- (BOOL)hasTitleBar { return NO; }
- (CGFloat)titlebarHeight { return kTitlebar; }
- (void)invalidateCursorRectsForView:(NSView *)v { [v resetCursorRects]; }
- (void)resetCursorRects {}
- (void)disableCursorRects {}
- (void)enableCursorRects {}
- (void)performMiniaturize:(id)s { (void)s; }
- (void)miniaturize:(id)s { (void)s; }
- (void)deminiaturize:(id)s { (void)s; }
- (BOOL)isMiniaturized { return NO; }
- (BOOL)isZoomed { return YES; }
- (void)zoom:(id)s { (void)s; }
- (void)toggleFullScreen:(id)s {
    (void)s; _fullscreen = !_fullscreen;
    NSString *n = _fullscreen ? NSWindowDidEnterFullScreenNotification : NSWindowDidExitFullScreenNotification;
    if (!_fullscreen) [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillExitFullScreenNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:n object:self];
}
- (NSUInteger)occlusionState { return 1 << 1; }   // (NSWindowOcclusionStateVisible)
- (NSDictionary *)deviceDescription { return [[NSScreen mainScreen] deviceDescription]; }
- (void)setOpaque:(BOOL)o { (void)o; }
- (void)setBackgroundColor:(id)c { (void)c; }
- (void)setHasShadow:(BOOL)h { (void)h; }
- (void)setLevel:(NSInteger)l { _level = l; }
- (NSInteger)level { return _level; }
- (void)setReleasedWhenClosed:(BOOL)r { (void)r; }
- (void)setRestorable:(BOOL)r { (void)r; }
- (void)setIgnoresMouseEvents:(BOOL)i { (void)i; }
- (void)setTitlebarAppearsTransparent:(BOOL)t { (void)t; }
- (void)setTitleVisibility:(NSInteger)v { (void)v; }
- (void)setMovableByWindowBackground:(BOOL)m { (void)m; }
- (void)setMovable:(BOOL)m { (void)m; }
- (void)setAllowsConcurrentViewDrawing:(BOOL)a { (void)a; }
- (void)setAnimationBehavior:(NSInteger)a { (void)a; }
- (void)setTabbingMode:(NSInteger)m { (void)m; }
- (void)setColorSpace:(id)c { (void)c; }
- (void)setDisplaysWhenScreenProfileChanges:(BOOL)d { (void)d; }
- (NSInteger)windowNumber { return 1; }
- (void)display {}
- (void)update {}
- (void)close {
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillCloseNotification object:self];
    _visible = NO; @synchronized (g_windows) { [g_windows removeObjectIdenticalTo:self]; }
}
- (void)performClose:(id)s { (void)s; [self close]; }
// (an event to the window: as AppKit's, mouse events to the content view, keys to the first responder)
- (void)sendEvent:(NSEvent *)e {
    NSResponder *keyTarget = _first ?: (NSResponder *)_content ?: (NSResponder *)self;
    NSResponder *mouseTarget = _content ?: (NSResponder *)self;
    switch (e->_type) {
    case NSEventTypeKeyDown: [keyTarget keyDown:e]; break;
    case NSEventTypeKeyUp: [keyTarget keyUp:e]; break;
    case NSEventTypeFlagsChanged: [keyTarget flagsChanged:e]; break;
    case NSEventTypeLeftMouseDown: [mouseTarget mouseDown:e]; break;
    case NSEventTypeLeftMouseUp: [mouseTarget mouseUp:e]; break;
    case NSEventTypeLeftMouseDragged: [mouseTarget mouseDragged:e]; break;
    case NSEventTypeRightMouseDown: [mouseTarget rightMouseDown:e]; break;
    case NSEventTypeRightMouseUp: [mouseTarget rightMouseUp:e]; break;
    case NSEventTypeRightMouseDragged: [mouseTarget rightMouseDragged:e]; break;
    case NSEventTypeOtherMouseDown: [mouseTarget otherMouseDown:e]; break;
    case NSEventTypeOtherMouseUp: [mouseTarget otherMouseUp:e]; break;
    case NSEventTypeOtherMouseDragged: [mouseTarget otherMouseDragged:e]; break;
    // (always: a view's tracking area with NSTrackingMouseMoved gets them in AppKit even without
    //  acceptsMouseMovedEvents; the game's mouse look reads deltaX/Y here: h10's calibration saw no response)
    case NSEventTypeMouseMoved: { static int n; if (n++ < 2) vxmac_log("AppKit: mouseMoved (%.1f, %.1f) to %s", e->_dx, e->_dy, class_getName([mouseTarget class])); [mouseTarget mouseMoved:e]; break; }
    case NSEventTypeScrollWheel: [mouseTarget scrollWheel:e]; break;
    case NSEventTypeMouseEntered: [mouseTarget mouseEntered:e]; break;
    case NSEventTypeMouseExited: [mouseTarget mouseExited:e]; break;
    default: break;
    }
}
- (NSEvent *)nextEventMatchingMask:(unsigned long long)m untilDate:(NSDate *)d inMode:(NSString *)mode dequeue:(BOOL)q {
    return [NSApp nextEventMatchingMask:m untilDate:d inMode:mode dequeue:q];
}
- (NSEvent *)nextEventMatchingMask:(unsigned long long)m { return [self nextEventMatchingMask:m untilDate:[NSDate distantFuture] inMode:NSDefaultRunLoopMode dequeue:YES]; }
@end

void vxkit_window_size(double *w, double *h) {
    NSWindow *k = g_key_window;
    *w = k ? k->_content->_frame.size.width : 0; *h = k ? k->_content->_frame.size.height : 0;
}
void *vxkit_metal_layer(void) {
    NSWindow *k = g_key_window;
    CALayer *l = k ? k->_content->_layer : nil;
    return [l isKindOfClass:[CAMetalLayer class]] ? (__bridge void *)l : NULL;
}

// ---- NSWindowController ----------------------------------------------------------------------------------------------
@interface NSWindowController : NSResponder { NSWindow *_win; }
@end
@implementation NSWindowController
- (instancetype)initWithWindow:(NSWindow *)w { if ((self = [super init])) { _win = w; w->_controller = self; } return self; }
- (instancetype)initWithWindowNibName:(NSString *)n { (void)n; return [self initWithWindow:nil]; }
- (NSWindow *)window { return _win; }
- (void)setWindow:(NSWindow *)w { _win = w; w->_controller = self; }
- (void)windowDidLoad {}
- (void)windowWillLoad {}
- (void)loadWindow {}
- (BOOL)isWindowLoaded { return _win != nil; }
- (void)showWindow:(id)s { [_win makeKeyAndOrderFront:s]; }
- (void)close { [_win close]; }
- (id)owner { return self; }
@end

// ---- NSApplication: the event queue -----------------------------------------------------------------------------------
static pthread_mutex_t g_q_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray<NSEvent *> *g_queue;
static int g_active = 1;
static void send1(id o, SEL s, id a) { if ([o respondsToSelector:s]) ((void (*)(id, SEL, id))objc_msgSend)(o, s, a); }

static unsigned long long mask_of(NSUInteger type) { return 1ull << type; }
static void enqueue(NSEvent *e) {
    pthread_mutex_lock(&g_q_lock);
    if (!g_queue) g_queue = [NSMutableArray array];
    if (g_queue.count < 4096) [g_queue addObject:e];
    pthread_mutex_unlock(&g_q_lock);
    // (the waiting nextEventMatchingMask: polls its run loop in short slices; nothing to signal)
}
static void taken(NSEvent *e);
static void (*g_poll_hook)(void); static int g_drained = 1;
void vxkit_set_poll_hook(void (*hook)(void)) { g_poll_hook = hook; }
static NSEvent *dequeue(unsigned long long mask, BOOL remove) {
    NSEvent *e = nil;
    pthread_mutex_lock(&g_q_lock);
    for (NSUInteger i = 0; i < g_queue.count; i++)
        if (mask_of(g_queue[i]->_type) & mask) { e = g_queue[i]; if (remove) [g_queue removeObjectAtIndex:i]; break; }
    pthread_mutex_unlock(&g_q_lock);
    return e;
}

@interface NSApplication : NSResponder {
@public
    __weak id _delegate; BOOL _running, _launched; NSUInteger _presentation; id _mainMenu; NSEvent *_current; NSInteger _policy;
}
@end
@implementation NSApplication
+ (NSApplication *)sharedApplication {
    static dispatch_once_t o;
    dispatch_once(&o, ^{ NSApp = [self new]; vxmac_log("AppKit: %s sharedApplication (libvxkit)", class_getName(self)); });
    return NSApp;
}
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (void)finishLaunching {
    if (_launched) return;
    _launched = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSNotification *n = [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:self];
    send1(_delegate, sel_registerName("applicationWillFinishLaunching:"), n);
    [nc postNotification:n];
    n = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:self];
    send1(_delegate, sel_registerName("applicationDidFinishLaunching:"), n);
    [nc postNotification:n];
    if (g_active) {
        n = [NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:self];
        send1(_delegate, sel_registerName("applicationDidBecomeActive:"), n);
        [nc postNotification:n];
    }
    vxmac_log("AppKit: finishLaunching (delegate %s)", _delegate ? class_getName([_delegate class]) : "none");
}
- (void)run {
    [self finishLaunching];
    _running = YES;
    while (_running) @autoreleasepool {
        NSEvent *e = [self nextEventMatchingMask:~0ull untilDate:[NSDate distantFuture] inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e) [self sendEvent:e];
    }
}
- (void)stop:(id)s { (void)s; _running = NO; }
- (void)terminate:(id)s {
    (void)s;
    // (h53: AppKit's reply values - NSTerminateCancel 0, NSTerminateNow 1, NSTerminateLater 2: with Later the program
    //  finishes its own shutdown and answers with replyToApplicationShouldTerminate:)
    if ([_delegate respondsToSelector:sel_registerName("applicationShouldTerminate:")]) {
        NSUInteger r = ((NSUInteger (*)(id, SEL, id))objc_msgSend)(_delegate, sel_registerName("applicationShouldTerminate:"), self);
        vxmac_log("AppKit: terminate: the program's applicationShouldTerminate: answered %lu (0 cancel, 1 now, 2 later)", (unsigned long)r);
        if (r == 0 || r == 2) return;
    }
    [self vx_finishTerminate];
}
- (void)replyToApplicationShouldTerminate:(BOOL)yes {
    vxmac_log("AppKit: replyToApplicationShouldTerminate: %d", yes);
    if (yes) [self vx_finishTerminate];
}
- (void)vx_finishTerminate {
    NSNotification *n = [NSNotification notificationWithName:NSApplicationWillTerminateNotification object:self];
    send1(_delegate, sel_registerName("applicationWillTerminate:"), n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
    vxmac_log("AppKit: terminate: the program exits");
    exit(0);
}
- (BOOL)isRunning { return _running || _launched; }
- (BOOL)isActive { return g_active; }
- (BOOL)isHidden { return NO; }
- (void)activateIgnoringOtherApps:(BOOL)f { (void)f; }
- (void)activate {}
- (BOOL)setActivationPolicy:(NSInteger)p { _policy = p; return YES; }
- (NSInteger)activationPolicy { return _policy; }
- (void)hide:(id)s { (void)s; }
- (void)unhide:(id)s { (void)s; }
- (void)hideOtherApplications:(id)s { (void)s; }
- (NSWindow *)keyWindow { return g_key_window; }
- (NSWindow *)mainWindow { return g_key_window; }
- (NSArray *)windows { @synchronized (g_windows) { return [g_windows copy] ?: @[]; } }
- (NSUInteger)presentationOptions { return _presentation; }
- (void)setPresentationOptions:(NSUInteger)o { _presentation = o; }
- (NSUInteger)currentSystemPresentationOptions { return _presentation; }
- (id)mainMenu { return _mainMenu; }
- (void)setMainMenu:(id)m { _mainMenu = m; }
- (void)setWindowsMenu:(id)m { (void)m; }
- (void)setServicesMenu:(id)m { (void)m; }
- (void)setHelpMenu:(id)m { (void)m; }
- (void)setApplicationIconImage:(id)i { (void)i; }
- (NSInteger)requestUserAttention:(NSInteger)t { (void)t; return 0; }
- (void)updateWindows {}
- (void)setWindowsNeedUpdate:(BOOL)f { (void)f; }
- (NSUInteger)occlusionState { return 1 << 1; }
- (NSEvent *)currentEvent { return _current; }
- (void)postEvent:(NSEvent *)e atStart:(BOOL)front {
    if (!e) return;
    pthread_mutex_lock(&g_q_lock);
    if (!g_queue) g_queue = [NSMutableArray array];
    if (front) [g_queue insertObject:e atIndex:0]; else [g_queue addObject:e];
    pthread_mutex_unlock(&g_q_lock);
}
- (void)discardEventsMatchingMask:(unsigned long long)m beforeEvent:(NSEvent *)last {
    (void)last; while (dequeue(m, YES)) {}
}
// The program's event pump: our queue, with the calling thread's run loop run in short slices while it waits (the
// program's timers, display links and performSelector:s on this thread fire then, as in AppKit's).
- (NSEvent *)nextEventMatchingMask:(unsigned long long)mask untilDate:(NSDate *)until inMode:(NSString *)mode dequeue:(BOOL)remove {
    // (h38: the poll hook - the first take of a new drain (the one before returned nothing) lets the host put the head's
    //  delta in first, sampled now: one delta a game frame, no frames with none or two)
    if (remove && g_poll_hook && g_drained) { g_drained = 0; g_poll_hook(); }
    NSTimeInterval end = until ? until.timeIntervalSinceReferenceDate : 0;
    CFStringRef m = (__bridge CFStringRef)(mode ?: NSDefaultRunLoopMode);
    if (CFEqual(m, (__bridge CFStringRef)NSEventTrackingRunLoopMode)) m = kCFRunLoopDefaultMode;
    for (;;) {
        NSEvent *e = dequeue(mask, remove);
        if (e && remove) taken(e);
        if (e) {
            // (local monitors, newest first: each can change or swallow the event)
            NSArray *mons;
            pthread_mutex_lock(&g_mon_lock); mons = [g_monitors copy]; pthread_mutex_unlock(&g_mon_lock);
            for (NSArray *mon in mons.reverseObjectEnumerator) {
                if (!(mask_of(e->_type) & [mon[0] unsignedLongLongValue])) continue;
                NSEvent *(^h)(NSEvent *) = mon[1];
                e = h(e);
                if (!e) break;
            }
            if (!e) continue;
            _current = e;
            return e;
        }
        double now = [NSDate timeIntervalSinceReferenceDate];
        // (h62: each slice of the run loop in an autorelease pool of its own - what AppKit's observers on a Mac's main run
        //  loop do (a pool popped and pushed before each wait and at the exit): objects the run loop's callouts (timers,
        //  performSelector:s, sources on the program's thread) autorelease are freed after the slice, not left in the
        //  program thread's pool, which a pthread of ours never drains)
        if (now >= end) {
            @autoreleasepool { CFRunLoopRunInMode(m, 0, true); }   // (a pass over the run loop's sources, as AppKit's does)
            e = dequeue(mask, remove);
            if (!e) { if (remove) g_drained = 1; return nil; }
            if (remove) taken(e);
            _current = e; return e;
        }
        double slice = end - now; if (slice > 0.002) slice = 0.002;
        @autoreleasepool { CFRunLoopRunInMode(m, slice, true); }
    }
}
- (void)sendEvent:(NSEvent *)e {
    _current = e;
    NSWindow *w = e->_window ?: g_key_window;
    if (w) [w sendEvent:e];
}
@end

// ---- events from the host ---------------------------------------------------------------------------------------------
void vxkit_set_active(int active) {
    if (active == g_active) return;
    g_active = active;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *n = active ? NSApplicationDidBecomeActiveNotification : NSApplicationDidResignActiveNotification;
        if (!active) [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationWillResignActiveNotification object:NSApp];
        id d = NSApp ? ((NSApplication *)NSApp)->_delegate : nil;
        SEL s = sel_registerName(active ? "applicationDidBecomeActive:" : "applicationDidResignActive:");
        NSNotification *note = [NSNotification notificationWithName:n object:NSApp];
        send1(d, s, note);
        [[NSNotificationCenter defaultCenter] postNotification:note];
    });
}
static NSEvent *make_event(NSUInteger type) {
    NSEvent *e = [NSEvent new];
    e->_type = type; e->_flags = g_mod_flags; e->_time = CACurrentMediaTime(); e->_window = g_key_window;
    NSWindow *w = g_key_window;
    e->_loc = w ? [w convertPointFromScreen:g_mouse_screen] : g_mouse_screen;
    return e;
}
static int g_last_button = -1;
void vxkit_post_mouse_pos(double x, double y) {
    NSWindow *w = g_key_window;
    double h = w ? w->_content->_frame.size.height : g_scr_h;
    NSPoint np = CGPointMake(x + (w ? w->_frame.origin.x : 0), (h - y) + (w ? w->_frame.origin.y : 0));
    double dx = np.x - g_mouse_screen.x, dy = -(np.y - g_mouse_screen.y);   // (deltas: y down, as AppKit's)
    g_mouse_screen = np;
    // (the game's mouse look on (the cursor dissociated): a pointer's jumps are not mouse motion - the hand ray's
    //  pointer turned the camera in game, h14; only the head's deltas (vxkit_post_mouse_delta) move it then)
    if (!g_cursor_assoc) dx = dy = 0;
    NSUInteger t = (g_buttons & 1) ? NSEventTypeLeftMouseDragged : (g_buttons & 2) ? NSEventTypeRightMouseDragged :
                   (g_buttons & 4) ? NSEventTypeOtherMouseDragged : NSEventTypeMouseMoved;
    NSEvent *e = make_event(t); e->_dx = dx; e->_dy = dy;
    enqueue(e);
}
void vxkit_post_mouse_delta(double dx, double dy) {
    static int n; if (n++ < 4) vxmac_log("AppKit: head delta (%.0f, %.0f), mouse look %s", dx, dy, g_cursor_assoc ? "off" : "on");
    NSUInteger t = (g_buttons & 1) ? NSEventTypeLeftMouseDragged : (g_buttons & 2) ? NSEventTypeRightMouseDragged : NSEventTypeMouseMoved;
    NSEvent *e = make_event(t); e->_dx = dx; e->_dy = dy; e->_head = YES;
    enqueue(e);
}
// (h28: how many of the head's deltas the program has taken from the queue: the presenter stamps each frame with the
//  turn the game had actually been given, not the one sent by some time)
static _Atomic unsigned long g_head_taken;
unsigned long vxkit_head_consumed(void) { return g_head_taken; }
static void taken(NSEvent *e) { if (e && e->_head) g_head_taken++; }
void vxkit_post_mouse_button(int button, int down) {
    static const NSUInteger types[3][2] = { { NSEventTypeLeftMouseUp, NSEventTypeLeftMouseDown },
                                            { NSEventTypeRightMouseUp, NSEventTypeRightMouseDown },
                                            { NSEventTypeOtherMouseUp, NSEventTypeOtherMouseDown } };
    if (button < 0 || button > 2) return;
    if (down) g_buttons |= 1u << button; else g_buttons &= ~(1u << button);
    NSEvent *e = make_event(types[button][down ? 1 : 0]);
    e->_button = button; e->_clicks = 1;
    static double last_down[3];
    if (down) { double now = CACurrentMediaTime(); if (button == g_last_button && now - last_down[button] < 0.4) e->_clicks = 2; last_down[button] = now; g_last_button = button; }
    enqueue(e);
}
void vxkit_post_scroll(double dx, double dy, int precise) {
    NSEvent *e = make_event(NSEventTypeScrollWheel);
    e->_dx = dx; e->_dy = dy; e->_sdx = precise ? dx * 10 : dx; e->_sdy = precise ? dy * 10 : dy; e->_precise = precise != 0;
    enqueue(e);
}
// (kVK_* of the modifier keys and their flag bits)
static NSUInteger flag_of(uint16_t kc) {
    switch (kc) {
    case 0x38: case 0x3C: return kFlagShift;
    case 0x3B: case 0x3E: return kFlagControl;
    case 0x3A: case 0x3D: return kFlagOption;
    case 0x37: case 0x36: return kFlagCommand;
    case 0x39: return kFlagCaps;
    case 0x3F: return kFlagFunction;
    }
    return 0;
}
static uint8_t g_down[128];
void vxkit_post_key(uint16_t kc, int down, const char *chars) {
    NSUInteger f = flag_of(kc);
    if (f) {
        if (kc == 0x39) { if (down) g_mod_flags ^= f; } else if (down) g_mod_flags |= f; else g_mod_flags &= ~f;
        NSEvent *e = make_event(NSEventTypeFlagsChanged); e->_keyCode = kc; enqueue(e);
        return;
    }
    NSEvent *e = make_event(down ? NSEventTypeKeyDown : NSEventTypeKeyUp);
    e->_keyCode = kc;
    if (kc < 128) { e->_repeat = down && g_down[kc]; g_down[kc] = down != 0; }
    e->_chars = chars ? @(chars) : @"";
    enqueue(e);
}
// USB HID keyboard usages (page 7) to macOS virtual key codes and their characters (US layout)
void vxkit_post_hid_key(uint32_t u, int down) {
    static const uint16_t letters[26] = { 0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                          0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06 };
    static const uint16_t digits[10] = { 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D };   // (1..9, 0)
    static const uint16_t fkeys[12] = { 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F };
    char c[8] = ""; int kc = -1;
    int shift = (g_mod_flags & kFlagShift) != 0;
    if (u >= 0x04 && u <= 0x1D) { kc = letters[u - 4]; c[0] = (char)((shift ? 'A' : 'a') + (u - 4)); }
    else if (u >= 0x1E && u <= 0x27) { kc = digits[u - 0x1E]; c[0] = shift ? ")!@#$%^&*("[(u - 0x1D) % 10] : (char)('0' + (u - 0x1D) % 10); }
    else if (u >= 0x3A && u <= 0x45) kc = fkeys[u - 0x3A];
    else switch (u) {
        case 0x28: kc = 0x24; c[0] = '\r'; break;   case 0x29: kc = 0x35; c[0] = 0x1b; break;
        case 0x2A: kc = 0x33; c[0] = 0x7f; break;   case 0x2B: kc = 0x30; c[0] = '\t'; break;
        case 0x2C: kc = 0x31; c[0] = ' '; break;    case 0x2D: kc = 0x1B; c[0] = shift ? '_' : '-'; break;
        case 0x2E: kc = 0x18; c[0] = shift ? '+' : '='; break; case 0x2F: kc = 0x21; c[0] = shift ? '{' : '['; break;
        case 0x30: kc = 0x1E; c[0] = shift ? '}' : ']'; break; case 0x31: kc = 0x2A; c[0] = shift ? '|' : '\\'; break;
        case 0x33: kc = 0x29; c[0] = shift ? ':' : ';'; break; case 0x34: kc = 0x27; c[0] = shift ? '"' : '\''; break;
        case 0x35: kc = 0x32; c[0] = shift ? '~' : '`'; break; case 0x36: kc = 0x2B; c[0] = shift ? '<' : ','; break;
        case 0x37: kc = 0x2F; c[0] = shift ? '>' : '.'; break; case 0x38: kc = 0x2C; c[0] = shift ? '?' : '/'; break;
        case 0x39: kc = 0x39; break;
        case 0x4A: kc = 0x73; break; case 0x4B: kc = 0x74; break; case 0x4C: kc = 0x75; break;
        case 0x4D: kc = 0x77; break; case 0x4E: kc = 0x79; break;
        case 0x4F: kc = 0x7C; break; case 0x50: kc = 0x7B; break; case 0x51: kc = 0x7D; break; case 0x52: kc = 0x7E; break;
        case 0xE0: kc = 0x3B; break; case 0xE1: kc = 0x38; break; case 0xE2: kc = 0x3A; break; case 0xE3: kc = 0x37; break;
        case 0xE4: kc = 0x3E; break; case 0xE5: kc = 0x3C; break; case 0xE6: kc = 0x3D; break; case 0xE7: kc = 0x36; break;
    }
    if (kc >= 0) vxkit_post_key((uint16_t)kc, down, c);
}

// ---- the program's thread as its "main thread" for notifications ---------------------------------------------------
// On macOS the game's loop runs on the main thread, so notifications the system posts there (GameController's
// connects, the application's) reach its observers between its own calls. Here the main thread is UIKit's and the
// game's loop has a thread of its own: an observer the program registers from its thread is called on that thread
// (performSelector:onThread:, run by its event pump), never concurrently with it. Blocks registered for the main
// queue (or no queue) likewise. vxkit_set_program_thread: the host, before the program's main.
static NSThread *g_program_thread;
static volatile int g_program_ready;
void vxkit_set_program_thread(void) { g_program_thread = [NSThread currentThread]; }
// (h53: the program asked to quit as a Mac app is - Cmd+Q / the menu's Quit: [NSApp terminate:] on its own thread,
//  through its delegate's applicationShouldTerminate:, so its own shutdown runs. Never a kill)
void vxkit_request_quit(void) {
    NSThread *pt = g_program_thread; id app = NSApp;
    vxmac_log("AppKit: quit requested by the host (terminate: on the program's thread)");
    if (pt && app) [app performSelector:@selector(terminate:) onThread:pt withObject:nil waitUntilDone:NO];
}
void vxkit_set_program_ready(void) { if (!g_program_ready) { g_program_ready = 1; vxmac_log("AppKit: the program's first frame: GameController notifications delivered from now on"); } }
@interface VXNoteHop : NSObject
@property (weak) id target;
@property SEL sel;
@property (copy) void (^block)(NSNotification *);
@end
@implementation VXNoteHop
- (void)fire:(NSNotification *)n {
    if (self.block) self.block(n);
    else { id t = self.target; if (t) ((void (*)(id, SEL, id))objc_msgSend)(t, self.sel, n); }
}
// (GameController's connects wait for the program's first frame: on macOS they come after its input system is up;
// here a controller already on at launch is announced at once, and the game's handler found no input system, h8)
- (void)later:(NSNotification *)n {
    if (!g_program_ready) { [self performSelector:@selector(later:) withObject:n afterDelay:0.25]; return; }
    [self fire:n];
}
- (void)note:(NSNotification *)n {
    NSThread *pt = g_program_thread;
    if (!g_program_ready && [n.name hasPrefix:@"GC"]) {
        if (pt && [NSThread currentThread] != pt) [self performSelector:@selector(later:) onThread:pt withObject:n waitUntilDone:NO];
        else [self later:n];
        return;
    }
    if (!pt || [NSThread currentThread] == pt) [self fire:n];
    else [self performSelector:@selector(fire:) onThread:pt withObject:n waitUntilDone:NO];
}
@end
static const void *kHops = &kHops;
typedef void (*add_imp)(id, SEL, id, SEL, NSNotificationName, id);
typedef id (*add_block_imp)(id, SEL, NSNotificationName, id, NSOperationQueue *, void (^)(NSNotification *));
typedef void (*remove_imp)(id, SEL, id);
typedef void (*remove3_imp)(id, SEL, id, NSNotificationName, id);
static add_imp o_add; static add_block_imp o_add_block; static remove_imp o_remove; static remove3_imp o_remove3;
static BOOL on_program_thread(void) { return g_program_thread && [NSThread currentThread] == g_program_thread; }
static void h_add(id self, SEL s, id observer, SEL sel, NSNotificationName name, id obj) {
    if (!on_program_thread() || !observer) { o_add(self, s, observer, sel, name, obj); return; }
    VXNoteHop *h = [VXNoteHop new]; h.target = observer; h.sel = sel;
    NSMutableArray *hops = objc_getAssociatedObject(observer, kHops);
    if (!hops) { hops = [NSMutableArray array]; objc_setAssociatedObject(observer, kHops, hops, OBJC_ASSOCIATION_RETAIN); }
    @synchronized (hops) { [hops addObject:@[ h, name ?: (id)[NSNull null], obj ?: (id)[NSNull null] ]]; }
    o_add(self, s, h, @selector(note:), name, obj);
}
static id h_add_block(id self, SEL s, NSNotificationName name, id obj, NSOperationQueue *q, void (^block)(NSNotification *)) {
    if (!on_program_thread() || (q && q != [NSOperationQueue mainQueue])) return o_add_block(self, s, name, obj, q, block);
    VXNoteHop *h = [VXNoteHop new]; h.block = block;
    id token = o_add_block(self, s, name, obj, nil, ^(NSNotification *n) { [h note:n]; });
    return token;
}
static void drop_hops(id center, id observer, NSNotificationName name, id obj, BOOL all) {
    NSMutableArray *hops = observer ? objc_getAssociatedObject(observer, kHops) : nil;
    if (!hops) return;
    @synchronized (hops) {
        for (NSArray *e in [hops copy]) {
            if (!all && name && ![e[1] isEqual:name]) continue;
            if (!all && obj && e[2] != obj) continue;
            o_remove(center, @selector(removeObserver:), e[0]);
            [hops removeObject:e];
        }
    }
}
static void h_remove(id self, SEL s, id observer) { drop_hops(self, observer, nil, nil, YES); o_remove(self, s, observer); }
static void h_remove3(id self, SEL s, id observer, NSNotificationName name, id obj) { drop_hops(self, observer, name, obj, NO); o_remove3(self, s, observer, name, obj); }
// ---- (h62) NSProcessInfo.physicalMemory: the game's images ask it as well as sysctl hw.memsize (libvxsystem):
// VXMAC_MEMSIZE_MB answers both (off by default); the first query from outside the host app's own code is logged with
// its caller and the figure it got.
#include <dlfcn.h>
typedef unsigned long long (*physmem_imp)(id, SEL);
static physmem_imp o_physmem;
static unsigned long long h_physmem(id self, SEL s) {
    unsigned long long real = o_physmem(self, s), v = real;
    const char *e = getenv("VXMAC_MEMSIZE_MB");
    if (e && *e) v = strtoull(e, NULL, 10) << 20;
    static int logged;
    if (!logged) {
        Dl_info di; void *ra = __builtin_return_address(0);
        if (dladdr(ra, &di) && di.dli_fname && strstr(di.dli_fname, ".dylib") && !strstr(di.dli_fname, "/usr/lib/") && !strstr(di.dli_fname, "/System/")) {
            logged = 1; const char *b = strrchr(di.dli_fname, '/');
            vxmac_log("Foundation: physicalMemory asked by %s+%#lx: %llu MB%s", b ? b + 1 : di.dli_fname, (unsigned long)((uintptr_t)ra - (uintptr_t)di.dli_fbase),
                      v >> 20, v != real ? " (VXMAC_MEMSIZE_MB)" : "");
        }
    }
    return v;
}
__attribute__((constructor)) static void vxkit_physmem_init(void) {
    Method m = class_getInstanceMethod([NSProcessInfo class], @selector(physicalMemory));
    if (m) o_physmem = (physmem_imp)method_setImplementation(m, (IMP)h_physmem);
}
__attribute__((constructor)) static void vxkit_notes_init(void) {
    Class c = [NSNotificationCenter class];
    o_add = (add_imp)method_setImplementation(class_getInstanceMethod(c, @selector(addObserver:selector:name:object:)), (IMP)h_add);
    o_add_block = (add_block_imp)method_setImplementation(class_getInstanceMethod(c, @selector(addObserverForName:object:queue:usingBlock:)), (IMP)h_add_block);
    o_remove = (remove_imp)method_setImplementation(class_getInstanceMethod(c, @selector(removeObserver:)), (IMP)h_remove);
    o_remove3 = (remove3_imp)method_setImplementation(class_getInstanceMethod(c, @selector(removeObserver:name:object:)), (IMP)h_remove3);
}

// ---- (2.5.0) BackgroundAssets' asset packs, read from the game's own data -------------------------------------------
// 2.5.0 keeps its non-English voices in Apple-hosted asset packs (Info.plist BAUsesAppleHosting): the game asks
// BAAssetPackManager for a pack (getAssetPackWithIdentifier: "lang_<code>" / "bg-lang--<code>"), makes it local
// (ensureLocalAvailabilityOfAssetPack:) and opens content/<lang>_voice.archive and ep1/<lang>_voice.archive through
// fileDescriptorForPath:searchingInAssetPackWithIdentifier:. Those packs are served only to the App Store app itself, so
// +[BAAssetPackManager sharedManager] answers with this stand-in: the pack root is the game's archive folder
// (Documents/Cyberpunk2077.app/Contents/Data/archive/mac), a pack is present when its language's voice archives are
// there (a pack copied from the Mac, or the 2.3.2 one still on the headset), nothing is downloaded. Every call logged
// once. VXMAC_ASSET_PACKS=0: the system's manager.
#include <fcntl.h>
#include <dlfcn.h>
@interface VXAssetPack : NSObject
@property (copy) NSString *identifier; @property NSInteger downloadSize, version; @property (copy) NSData *userInfo;
@end
@implementation VXAssetPack
VX_CATCHALL
@end
@interface VXAssetPackManager : NSObject
@property (weak) id delegate;
@end
static NSString *ap_root(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("VXMAC_EXECUTABLE_PATH");   // (.../Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077)
        NSString *c = e ? [[@(e) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] : nil;
        for (NSString *a in @[ @"Data/archive/mac", @"Data/archive/Mac" ]) {
            NSString *p = [c stringByAppendingPathComponent:a];
            BOOL d = NO; if (p && [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&d] && d) { root = p; break; }
        }
        vxmac_log("BackgroundAssets: asset packs read from %s", root ? root.UTF8String : "(no archive folder)");
    });
    return root;
}
static NSString *ap_lang(NSString *ident) {   // ("lang_ja" / "bg-lang--ja" / "...ja_voice" -> "ja")
    NSString *s = ident;
    for (NSString *p in @[ @"bg-lang--", @"lang_", @"lang-" ]) if ([s hasPrefix:p]) s = [s substringFromIndex:p.length];
    if ([s hasSuffix:@"_voice"]) s = [s substringToIndex:s.length - 6];
    return s;
}
static BOOL ap_present(NSString *ident) {
    NSString *r = ap_root(), *l = ap_lang(ident);
    if (!r || !l.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:[r stringByAppendingFormat:@"/content/lang_%@_voice.archive", l]] ||
           [fm fileExistsAtPath:[r stringByAppendingFormat:@"/content/%@_voice.archive", l]];
}
static NSError *ap_err(NSString *what) { return [NSError errorWithDomain:@"BAManagedErrorDomain" code:0 userInfo:@{ NSLocalizedDescriptionKey: what }]; }
static void ap_note(const char *what, NSString *arg, int r) {
    static NSMutableSet *seen; static pthread_mutex_t l = PTHREAD_MUTEX_INITIALIZER;
    NSString *k = [NSString stringWithFormat:@"%s %@ %d", what, arg ?: @"-", r];
    pthread_mutex_lock(&l); if (!seen) seen = [NSMutableSet set]; BOOL fresh = ![seen containsObject:k]; [seen addObject:k]; pthread_mutex_unlock(&l);
    if (fresh) vxmac_log("BackgroundAssets: %s %s -> %d", what, arg ? arg.UTF8String : "-", r);
}
static VXAssetPack *ap_make(NSString *ident) { VXAssetPack *p = [VXAssetPack new]; p.identifier = ident; p.version = 1; return p; }
@implementation VXAssetPackManager
VX_CATCHALL
- (void)getAllAssetPacksWithCompletionHandler:(void (^)(NSSet *, NSError *))h {
    NSMutableSet *s = [NSMutableSet set];
    NSString *r = ap_root();
    for (NSString *f in r ? [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[r stringByAppendingPathComponent:@"content"] error:nil] : @[])
        if ([f hasPrefix:@"lang_"] && [f hasSuffix:@"_voice.archive"]) [s addObject:ap_make([f stringByDeletingPathExtension])];
    ap_note("getAllAssetPacks", nil, (int)s.count);
    if (h) dispatch_async(dispatch_get_global_queue(0, 0), ^{ h(s, nil); });
}
- (void)getAssetPackWithIdentifier:(NSString *)i completionHandler:(void (^)(id, NSError *))h {
    BOOL ok = ap_present(i); ap_note("getAssetPack", i, ok);
    if (h) dispatch_async(dispatch_get_global_queue(0, 0), ^{ h(ok ? ap_make(i) : nil, ok ? nil : ap_err(@"not on this device")); });
}
- (void)getStatusOfAssetPackWithIdentifier:(NSString *)i completionHandler:(void (^)(NSUInteger, NSError *))h {
    BOOL ok = ap_present(i); ap_note("getStatus", i, ok);
    if (h) dispatch_async(dispatch_get_global_queue(0, 0), ^{ h(ok ? (1u << 2) : 0, ok ? nil : ap_err(@"not on this device")); });
}
- (void)ensureLocalAvailabilityOfAssetPack:(id)p completionHandler:(void (^)(NSError *))h {
    NSString *i = [p respondsToSelector:@selector(identifier)] ? [p identifier] : nil;
    BOOL ok = i && ap_present(i); ap_note("ensureLocalAvailability", i, ok);
    if (h) dispatch_async(dispatch_get_global_queue(0, 0), ^{ h(ok ? nil : ap_err(@"not on this device (nothing is downloaded)")); });
}
- (void)checkForUpdatesWithCompletionHandler:(void (^)(NSSet *, NSSet *, NSError *))h {
    ap_note("checkForUpdates", nil, 0);
    if (h) dispatch_async(dispatch_get_global_queue(0, 0), ^{ h([NSSet set], [NSSet set], nil); });
}
- (void)removeAssetPackWithIdentifier:(NSString *)i completionHandler:(void (^)(NSError *))h {
    ap_note("removeAssetPack (kept)", i, 0);
    if (h) dispatch_async(dispatch_get_global_queue(0, 0), ^{ h(nil); });
}
- (int)fileDescriptorForPath:(NSString *)path searchingInAssetPackWithIdentifier:(NSString *)i error:(NSError **)err {
    NSString *r = ap_root(); int fd = r ? open([r stringByAppendingPathComponent:path].fileSystemRepresentation, O_RDONLY) : -1;
    ap_note("fileDescriptorForPath", path, fd >= 0);
    if (fd < 0 && err) *err = ap_err(@"no such file in the asset packs");
    return fd;
}
- (NSData *)contentsAtPath:(NSString *)path searchingInAssetPackWithIdentifier:(NSString *)i options:(NSDataReadingOptions)o error:(NSError **)err {
    NSString *r = ap_root(); NSData *d = r ? [NSData dataWithContentsOfFile:[r stringByAppendingPathComponent:path] options:o error:err] : nil;
    ap_note("contentsAtPath", path, d != nil);
    return d;
}
- (NSURL *)URLForPath:(NSString *)path error:(NSError **)err {
    NSString *r = ap_root(); ap_note("URLForPath", path, r != nil);
    return r ? [NSURL fileURLWithPath:[r stringByAppendingPathComponent:path]] : nil;
}
@end
static id g_apm;
static id h_ap_shared(id self, SEL s) { (void)self; (void)s; return g_apm; }
__attribute__((constructor)) static void vxkit_assetpacks_init(void) {
    const char *e = getenv("VXMAC_ASSET_PACKS"); if (e && !strcmp(e, "0")) return;
    dlopen("/System/Library/Frameworks/BackgroundAssets.framework/BackgroundAssets", RTLD_LAZY);   // (the game links it; loaded here so its class can be answered for)
    Class c = objc_getClass("BAAssetPackManager");
    if (!c) return;
    g_apm = [VXAssetPackManager new];
    Method m = class_getClassMethod(c, sel_registerName("sharedManager"));
    if (m) method_setImplementation(m, (IMP)h_ap_shared); else class_addMethod(object_getClass(c), sel_registerName("sharedManager"), (IMP)h_ap_shared, "@@:");
    vxmac_log("BackgroundAssets: +[BAAssetPackManager sharedManager] answered by VX Mac (asset packs from the game's archive folder)");
}
