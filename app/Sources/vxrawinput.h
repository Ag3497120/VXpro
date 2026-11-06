// Preserve the hardware state for our poll even when the game's nested value reads are masked.
#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>

static _Thread_local unsigned vx_raw_button_depth;
static BOOL vx_raw_button_pressed(id button) {
    if (!button) return NO;
    vx_raw_button_depth++;
    BOOL result = ((BOOL (*)(id, SEL))objc_msgSend)(button, @selector(isPressed));
    vx_raw_button_depth--;
    return result;
}
static float vx_raw_button_value(id button) {
    if (!button) return 0;
    vx_raw_button_depth++;
    float result = ((float (*)(id, SEL))objc_msgSend)(button, @selector(value));
    vx_raw_button_depth--;
    return result;
}
