// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include "../app/Sources/vxmodeinput.h"
#include "../app/Sources/vxrawinput.h"
#include "../vr/control_chord.h"
#include <assert.h>
@interface SplitMenuProfile : NSObject
@property NSDictionary *buttons;
@property NSDictionary *remapped;
- (NSString *)mappedElementAliasForPhysicalInputName:(NSString *)name;
@end
@implementation SplitMenuProfile
- (NSString *)mappedElementAliasForPhysicalInputName:(NSString *)name {return self.remapped[name]?:name;}
@end
@interface SplitMenuPad : NSObject
@property GCControllerButtonInput *buttonMenu;
@property GCControllerButtonInput *buttonOptions;
@end
@implementation SplitMenuPad
@end
@interface SplitMenuController : NSObject
@property SplitMenuProfile *physicalInputProfile;
@property SplitMenuPad *extendedGamepad;
@property NSString *vendorName;
@property NSString *productCategory;
@end
@implementation SplitMenuController
@end

int main(void) { @autoreleasepool {
    GCController *controller=[GCController controllerWithExtendedGamepad];
    GCExtendedGamepad *g=controller.extendedGamepad;
    GCControllerButtonInput *plus=nil,*minus=nil;vx_mode_inputs(controller,&plus,&minus);
    assert(plus==g.buttonMenu && minus==g.buttonOptions && plus && minus && plus!=minus);
    assert(plus.preferredSystemGestureState==GCSystemGestureStateDisabled);
    assert(minus.preferredSystemGestureState==GCSystemGestureStateDisabled);
    vx_control_chord chord={0};
    [plus setValue:1];assert(vx_raw_button_value(plus)==1);
    assert(!vx_control_chord_update(&chord,vx_raw_button_pressed(plus),vx_raw_button_pressed(minus),1));
    assert(!chord.taps);
    [minus setValue:1];assert(!vx_control_chord_update(&chord,vx_raw_button_pressed(plus),vx_raw_button_pressed(minus),1.03));
    assert(vx_control_chord_update(&chord,vx_raw_button_pressed(plus),vx_raw_button_pressed(minus),2.04));
    [plus setValue:0];assert(!vx_control_chord_update(&chord,0,1,2.1));
    [minus setValue:0];assert(!vx_control_chord_update(&chord,0,0,2.2) && !chord.taps);
    // A short chord also suppresses both menus; neither half leaks on release.
    assert(!vx_control_chord_update(&chord,0,1,3));assert(!vx_control_chord_update(&chord,1,1,3.02));
    assert(!vx_control_chord_update(&chord,0,0,3.1) && !chord.taps);
    for(unsigned role=1;role<=2;role++) {
        assert(!vx_control_chord_update(&chord,role==1,role==2,4));
        assert(!chord.taps);
        assert(!vx_control_chord_update(&chord,0,0,4.1) && chord.taps==role);
        assert(!vx_control_chord_update(&chord,0,0,4.2) && !chord.taps);
    }
    SplitMenuController *left=[SplitMenuController new];left.physicalInputProfile=[SplitMenuProfile new];
    left.extendedGamepad=[SplitMenuPad new];left.extendedGamepad.buttonMenu=g.buttonMenu;
    left.vendorName=@"Joy-Con (L)";left.productCategory=@"HID";
    vx_mode_inputs((id)left,&plus,&minus);assert(!plus && minus==g.buttonMenu);
    SplitMenuController *right=[SplitMenuController new];right.physicalInputProfile=[SplitMenuProfile new];
    right.extendedGamepad=[SplitMenuPad new];right.extendedGamepad.buttonMenu=g.buttonOptions;
    right.vendorName=@"Joy-Con (R)";right.productCategory=@"HID";
    vx_mode_inputs((id)right,&plus,&minus);assert(plus==g.buttonOptions && !minus);
    left.physicalInputProfile.buttons=@{GCInputButtonMenu:g.buttonMenu,GCInputButtonOptions:g.buttonOptions};
    left.physicalInputProfile.remapped=@{GCInputButtonMenu:GCInputButtonOptions,GCInputButtonOptions:GCInputButtonMenu};
    vx_mode_inputs((id)left,&plus,&minus);assert(plus==g.buttonOptions && minus==g.buttonMenu);
    puts("mode inputs: public GameController profiles, system long-press disabled, staggered chord, one toggle, no chord menus, single-release menu: ok");
} }
