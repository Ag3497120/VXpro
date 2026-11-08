// SPDX-License-Identifier: MIT
// Read only public OIDC metadata using the same adapter as the headset game.
#import <Foundation/Foundation.h>
#include "../shims/vxcurl.h"
#include <assert.h>
#include <stdarg.h>
void vxmac_log(const char *format,...) {(void)format;}
static size_t receive(char *p,size_t size,size_t count,void *context) {
    NSMutableData *data=(__bridge NSMutableData *)context;if(size && count>SIZE_MAX/size)return 0;
    size_t n=size*count;if(n>256*1024-data.length)return 0;[data appendBytes:p length:n];return n;
}
int main(int argc,char **argv) {@autoreleasepool {
    assert(argc==2);setenv("VXMAC_NETWORK","1",1);NSMutableData *data=[NSMutableData new];void *h=curl_easy_init();assert(h);
    assert(!curl_easy_setopt(h,VX_CURLOPT_URL,"https://accounts.cdprojektred.com/realms/cdp/.well-known/openid-configuration"));
    assert(!curl_easy_setopt(h,VX_CURLOPT_WRITEFUNCTION,receive));assert(!curl_easy_setopt(h,VX_CURLOPT_WRITEDATA,(__bridge void *)data));
    assert(!curl_easy_setopt(h,VX_CURLOPT_TIMEOUT,15L));int code=curl_easy_perform(h);long status=0;curl_easy_getinfo(h,VX_CURLINFO_RESPONSE_CODE,&status);curl_easy_cleanup(h);
    NSDictionary *body=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    BOOL valid=[body isKindOfClass:NSDictionary.class] && [body[@"issuer"] isEqual:@"https://accounts.cdprojektred.com/realms/cdp"] &&
        [body[@"device_authorization_endpoint"] isEqual:@"https://accounts.cdprojektred.com/realms/cdp/protocol/openid-connect/auth/device"];
    NSDictionary *result=@{@"transport_result":@(code),@"http_status":@(status),@"issuer_and_device_endpoint_valid":@(valid),@"authenticated":@NO,@"save_sync_verified":@NO};
    assert([[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:@(argv[1]) atomically:YES]);
    printf("public discovery: transport=%d HTTP=%ld issuer_valid=%d; no account or save request\n",code,status,valid);
    return code || status!=200 || !valid;
}}
