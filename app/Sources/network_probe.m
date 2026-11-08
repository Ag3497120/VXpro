// SPDX-License-Identifier: MIT
// One opt-in, unauthenticated read of the issuer's public metadata, through the
// exact network adapter used by the game. Never request/store an account token.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "../../shims/vxcurl.h"
extern void vxmac_jlog(const char *,const char *);
extern NSDictionary *vxmac_native_sdk_public_probe(void);
static size_t probe_write(char *bytes,size_t size,size_t count,void *context) {
    NSMutableData *data=(__bridge NSMutableData *)context;
    if(size && count>SIZE_MAX/size)return 0;size_t n=size*count;
    if(n>256*1024-data.length)return 0;[data appendBytes:bytes length:n];return n;
}
void vxmac_network_probe_start(void) {
    const char *flag=getenv("VXMAC_NETWORK_PROBE");if(!flag || strcmp(flag,"1"))return;
    const char *online=getenv("VXMAC_NETWORK");if(!online || strcmp(online,"1"))return;
    // Complete before the entry point: no concurrent initialization of the SDK's
    // private HTTP globals, and no game account operation is started by this probe.
    NSDictionary *native=vxmac_native_sdk_public_probe();
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [[NSJSONSerialization dataWithJSONObject:native options:NSJSONWritingPrettyPrinted error:NULL]
        writeToURL:[documents URLByAppendingPathComponent:@"vxmac_native_network_probe.json"] options:NSDataWritingAtomic error:NULL];
    NSString *nativeFields=[NSString stringWithFormat:@"\"result\":%@,\"status\":%@,\"backend\":%@,\"issuer_valid\":%@,\"authenticated\":0",
        native[@"transport_result"],native[@"http_status"],native[@"tls_backend_id"],native[@"issuer_valid"]];
    vxmac_jlog("native_network_probe",nativeFields.UTF8String);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {
        void *(*create)(void)=dlsym(RTLD_DEFAULT,"curl_easy_init");
        int (*set)(void *,int,...)=dlsym(RTLD_DEFAULT,"curl_easy_setopt");
        int (*perform)(void *)=dlsym(RTLD_DEFAULT,"curl_easy_perform");
        int (*info)(void *,int,...)=dlsym(RTLD_DEFAULT,"curl_easy_getinfo");
        void (*destroy)(void *)=dlsym(RTLD_DEFAULT,"curl_easy_cleanup");
        int code=2;long status=0;NSMutableData *data=[NSMutableData new];BOOL valid=NO;
        if(create && set && perform && info && destroy) {
            void *handle=create();
            code=set(handle,VX_CURLOPT_URL,"https://accounts.cdprojektred.com/realms/cdp/.well-known/openid-configuration");
            if(!code)code=set(handle,VX_CURLOPT_WRITEFUNCTION,probe_write);
            if(!code)code=set(handle,VX_CURLOPT_WRITEDATA,(__bridge void *)data);
            if(!code)code=set(handle,VX_CURLOPT_TIMEOUT,15L);
            if(!code)code=perform(handle);info(handle,VX_CURLINFO_RESPONSE_CODE,&status);destroy(handle);
            NSDictionary *body=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
            valid=[body isKindOfClass:NSDictionary.class] && [body[@"issuer"] isEqual:@"https://accounts.cdprojektred.com/realms/cdp"] &&
                [body[@"device_authorization_endpoint"] isEqual:@"https://accounts.cdprojektred.com/realms/cdp/protocol/openid-connect/auth/device"];
        }
        NSDictionary *result=@{@"transport_result":@(code),@"http_status":@(status),@"issuer_and_device_endpoint_valid":@(valid),
            @"authenticated":@NO,@"save_sync_verified":@NO};
        NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToURL:[docs URLByAppendingPathComponent:@"vxmac_network_probe.json"] options:NSDataWritingAtomic error:NULL];
        NSString *fields=[NSString stringWithFormat:@"\"result\":%d,\"status\":%ld,\"issuer_valid\":%d,\"authenticated\":0,\"save_sync_verified\":0",code,status,valid];
        vxmac_jlog("network_probe",fields.UTF8String);
    }});
}
