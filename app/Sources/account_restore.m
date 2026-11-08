// SPDX-License-Identifier: MIT
// Use the game's own saved refresh credential with its genuine account API.
// A request is made at most once at startup; success comes only from the SDK.
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include "gls_account.h"
#include "account_restore_policy.h"
extern void *vxmac_native_sdk_function(const char *);
extern void vxmac_jlog(const char *,const char *);

static void account_status(const char *state,int present,int request_error) {
    NSDictionary *result=@{@"state":@(state),@"stored_credential_present":@(present),@"request_error":@(request_error)};
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL]
        writeToURL:[docs URLByAppendingPathComponent:@"vxmac_account_restore.json"] options:NSDataWritingAtomic error:NULL];
    NSString *fields=[NSString stringWithFormat:@"\"state\":\"%s\",\"credential_present\":%d,\"request_error\":%d",state,present,request_error];
    vxmac_jlog("account_restore",fields.UTF8String);
}

void vxmac_account_restore_poll(void) {
    const char *online=getenv("VXMAC_NETWORK"),*enabled=getenv("VXMAC_ACCOUNT_RESTORE");
    if(!online || strcmp(online,"1") || (enabled && !strcmp(enabled,"0")))return;
    static VXAccountRestore state;static double last;static dispatch_queue_t queue;
    double now=NSProcessInfo.processInfo.systemUptime;
    if(state.finished || now-last<1)return;last=now;
    if(!queue)queue=dispatch_queue_create("vxmac.account.restore",DISPATCH_QUEUE_SERIAL);
    // This hook is on the game's thread. A separate serial queue keeps SDK error
    // state thread-local to this bridge. Synchronous dispatch also prevents the
    // game thread from shutting the SDK down during an API call. The SDK queues
    // authentication asynchronously; no network wait or ProcessData call here.
    dispatch_sync(queue,^{@autoreleasepool {
        static void *(*user_api)(void);static bool (*signed_in)(void *);
        static void (*smart_login)(void *,const char *,void *);static void *(*get_error)(void);
        if(!user_api)user_api=vxmac_native_sdk_function("__ZN9redgalaxy3api4UserEv");
        if(!get_error)get_error=vxmac_native_sdk_function("__ZN9redgalaxy3api8GetErrorEv");
        if(!signed_in)signed_in=vxmac_native_sdk_function("__ZThn80_N6galaxy4peer6facade14UserFacadeBase8SignedInEv");
        if(!smart_login)smart_login=vxmac_native_sdk_function("__ZThn80_N6galaxy4peer6facade14PeerUserFacade16SignInSmartLoginEPKcPN9redgalaxy3api13IAuthListenerE");
        BOOL bindings=user_api && signed_in && smart_login && get_error;
        void *user=bindings?user_api():NULL;BOOL active=user && signed_in(user);
        int action=vx_account_restore_step(&state,now,user!=NULL,active);
        if(action==VX_ACCOUNT_WAIT)return;
        if(action==VX_ACCOUNT_ALREADY_SIGNED_IN){account_status("already_signed_in",0,0);return;}
        if(action==VX_ACCOUNT_COMPLETE){account_status("restored",1,0);return;}
        if(action==VX_ACCOUNT_GIVE_UP){account_status(bindings?"not_restored":"unsupported_sdk",state.attempted,0);return;}
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *path=[support URLByAppendingPathComponent:@"CD Projekt Red/Cyberpunk 2077/saves/user.gls"];
        NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:path.path error:NULL];
        unsigned long long size=[attrs fileSize];
        NSData *profile=size && size<=1024*1024?[NSData dataWithContentsOfURL:path options:NSDataReadingMappedIfSafe error:NULL]:nil;
        char *credential=calloc(16385,1);
        int found=credential?vx_gls_refresh(profile.bytes,profile.length,credential,16385):-1;
        if(found==1) {
            smart_login(user,credential,NULL);int error=get_error()!=NULL;
            account_status("requested",1,error);if(error)state.finished=1;
        } else {state.finished=1;account_status(found<0?"invalid_or_unreadable_profile":"no_stored_credential",0,0);}
        if(credential){for(volatile char *p=credential;p<credential+16385;p++)*p=0;free(credential);}
    }});
}
