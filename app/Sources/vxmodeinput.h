// SPDX-License-Identifier: MIT
#pragma once
#import <GameController/GameController.h>

// Some split Joy-Cons expose their one menu button as buttonMenu on both
// halves. Resolve physical names and remappings before using profile defaults.
static void vx_mode_inputs(GCController *controller,GCControllerButtonInput **plus,GCControllerButtonInput **minus) {
    GCPhysicalInputProfile *profile=controller.physicalInputProfile;
    GCExtendedGamepad *pad=controller.extendedGamepad;
    NSString *p=[profile mappedElementAliasForPhysicalInputName:GCInputButtonMenu];
    NSString *m=[profile mappedElementAliasForPhysicalInputName:GCInputButtonOptions];
    *plus=profile.buttons[p?:GCInputButtonMenu]?:pad.buttonMenu;
    *minus=profile.buttons[m?:GCInputButtonOptions]?:pad.buttonOptions;
    if(!*minus && *plus) {
        NSString *symbol=(*plus).unmappedSfSymbolsName;
        NSString *name=(*plus).unmappedLocalizedName;
        NSString *product=[NSString stringWithFormat:@"%@ %@",controller.vendorName?:@"",controller.productCategory?:@""];
        if([symbol hasPrefix:@"minus"] || [name isEqualToString:@"−"] || [name isEqualToString:@"-"] ||
           ([product containsString:@"Joy-Con"] && [product containsString:@"(L)"])) {
            *minus=*plus;*plus=nil;
        }
    }
    if(*plus==*minus)*minus=nil;
    // Default system gesture recognition can withhold a long-pressed Options
    // button entirely. The in-game chord owns these two buttons while active.
    (*plus).preferredSystemGestureState=GCSystemGestureStateDisabled;
    (*minus).preferredSystemGestureState=GCSystemGestureStateDisabled;
}
