// SPDX-License-Identifier: MIT
#include "../app/Sources/auth_browser.h"
#include <assert.h>
int main(void) {@autoreleasepool {
    for(NSString *s in @[@"https://accounts.cdprojektred.com/realms/cdp/protocol/openid-connect/auth?user_code=fixture",@"https://www.cyberpunk.net/en/myrewards",@"https://auth.gog.com/auth"])assert(vx_auth_browser_allowed([NSURL URLWithString:s]));
    for(NSString *s in @[@"http://accounts.cdprojektred.com/",@"https://accounts.cdprojektred.com.attacker.invalid/",@"https://user:secret@accounts.cdprojektred.com/",@"file:///tmp/login",@"javascript:alert(1)",@"https://example.com/",@"https://accounts.cdprojektred.com@attacker.invalid/"])assert(!vx_auth_browser_allowed([NSURL URLWithString:s]));
    assert(vx_auth_background_delay(10,100,0)==10);
    assert(vx_auth_background_delay(10,100,700)==600);
    assert(vx_auth_background_delay(10,699,700)==10);
    assert(vx_auth_background_delay(10,100,99999)==600);
    assert(vx_auth_background_delay(0,100,700)==0);
    puts("auth browser: exact HTTPS hosts; reject userinfo/scheme/lookalikes; bounded sign-in wait: ok");
}}
