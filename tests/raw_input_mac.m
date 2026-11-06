// Reproduce a button whose isPressed getter asks its separately hooked value getter.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "vxrawinput.h"
#include <assert.h>

@interface FakeTrigger : NSObject
@property(nonatomic, readonly) float value;
@property(nonatomic, readonly, getter=isPressed) BOOL pressed;
@end
@implementation FakeTrigger
- (float)value { return 1.f; }
- (BOOL)isPressed { return self.value > .5f; }
@end
@interface SpecializedTrigger : FakeTrigger
@property(nonatomic) BOOL hardwareDown;
@end
@implementation SpecializedTrigger
- (BOOL)isPressed { return self.hardwareDown && [super isPressed]; }
@end
static float (*original_value)(id, SEL);
static float masked_value(id self, SEL selector) {
    return vx_raw_button_depth ? original_value(self, selector) : 0.f;
}
int main(void) {
    @autoreleasepool {
        Method value = class_getInstanceMethod(FakeTrigger.class, @selector(value));
        original_value = (void *)method_setImplementation(value, (IMP)masked_value);
        BOOL (*pressed)(id, SEL) = (void *)method_getImplementation(class_getInstanceMethod(FakeTrigger.class, @selector(isPressed)));
        FakeTrigger *trigger = [FakeTrigger new];
        assert(!trigger.pressed); // The game's masked view.
        assert(vx_raw_button_pressed(trigger)); // The host's nested read sees the real trigger.
        assert(vx_raw_button_value(trigger) == 1.f);
        SpecializedTrigger *special = [SpecializedTrigger new];
        assert(!vx_raw_button_pressed(special)); // Do not bypass an overridden getter with the base IMP.
        vx_raw_button_depth++;
        assert(pressed(special, @selector(isPressed))); // The old direct IMP read incorrectly reports pressed.
        vx_raw_button_depth--;
        special.hardwareDown = YES;
        assert(vx_raw_button_pressed(special));
        special.hardwareDown = NO;
        assert(!vx_raw_button_pressed(special));
        assert(!trigger.pressed && vx_raw_button_depth == 0);
        puts("raw controller poll bypasses nested trigger masking: ok");
    }
}
