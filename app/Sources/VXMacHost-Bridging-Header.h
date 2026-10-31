// What the Swift side of VX Mac Host (VXMacApp.swift, VXMacImmersive.swift) calls: host.m's helpers, the immersive
// presenter (../../vr/xros_vr.h) and the shims' host interface (../../shims/vxmac.h).
#import <UIKit/UIKit.h>
#include "xros_vr.h"
#include "vxmac.h"

int vxmac_present_vr(void);                          // (host.m: -present vr (default) or flat)
void vxmac_jlog(const char *event, const char *fields);   // (host.m: a line in Documents/vxmac_host.jsonl)
void vxmac_boot(void);                               // (host.m: the program starts, once)
UIViewController *vxmac_make_root_controller(void);  // (host.m: the flat window's controller: -present flat)
void vxmac_set_foreground(int fg);                   // (host.m: the scene phase to the program's NSApplication)
void vxmac_vr_space_set(int open);
int vxmac_vr_space_open(void);
int vxmac_keep_window(void);
void vxmac_request_quit(const char *why);           // (host.m, h53: the game's own quit path)                         // (host.m: -window keep: the window stays in VR)
