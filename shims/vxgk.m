// libvxgk: GameKit re-exported (Game Center itself is the real visionOS GameKit, untouched), and GKDialogController,
// the macOS-only class that presents Game Center's view controllers in a window: here it presents nothing.
#import <Foundation/Foundation.h>
@interface GKDialogController : NSObject
@property (weak) id parentWindow;
@end
@implementation GKDialogController
+ (GKDialogController *)sharedDialogController { static GKDialogController *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [GKDialogController new]; }); return c; }
- (BOOL)presentViewController:(id)vc { (void)vc; NSLog(@"vxmac: GameKit: GKDialogController present (not shown on visionOS)"); return NO; }
- (void)dismiss:(id)sender { (void)sender; }
@end
