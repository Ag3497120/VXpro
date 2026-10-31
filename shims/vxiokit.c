// libvxiokit: IOKit re-exported, and the two display calls visionOS lacks (IODisplay*): no display service, so no
// info and no parameters (brightness, luminance): the program's own fallbacks apply.
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
CFDictionaryRef IODisplayCreateInfoDictionary(uint32_t framebuffer, uint32_t options) {
    (void)framebuffer; (void)options;
    return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
int IODisplayGetFloatParameter(uint32_t service, uint32_t options, CFStringRef name, float *value) {
    (void)service; (void)options; (void)name; (void)value;
    return (int)0xe00002c7;                 // (kIOReturnUnsupported)
}
