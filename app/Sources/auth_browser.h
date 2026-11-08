// SPDX-License-Identifier: MIT
#pragma once
#import <Foundation/Foundation.h>
#include <math.h>
static inline BOOL vx_auth_browser_allowed(NSURL *url) {
    if(![url.scheme.lowercaseString isEqualToString:@"https"] || url.user || url.password)return NO;
    return [@[@"accounts.cdprojektred.com",@"cyberpunk.net",@"www.cyberpunk.net",@"auth.gog.com",@"login.gog.com"] containsObject:url.host.lowercaseString];
}
static inline double vx_auth_background_delay(double normal,double now,double until) {
    if(normal<=0 || !isfinite(now) || !isfinite(until))return normal;
    return fmax(normal,fmin(600,fmax(0,until-now)));
}
