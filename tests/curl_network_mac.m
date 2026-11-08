// SPDX-License-Identifier: MIT
// The caller uses Apple's real libcurl headers, while linking our adapter. This
// checks ABI/option numbers too, against local HTTP/TLS fixture servers only.
#import <Foundation/Foundation.h>
#include <curl/curl.h>
#include <assert.h>
#include <pthread.h>
#include <stdarg.h>
#include <unistd.h>
void vxmac_log(const char *format,...) { (void)format; }
typedef struct { __unsafe_unretained NSMutableData *body;pthread_t thread;unsigned calls;int abort; } receiver;
static size_t receive(char *p,size_t size,size_t n,void *data) {
    receiver *r=data;assert(pthread_equal(r->thread,pthread_self()));r->calls++;
    if(r->abort)return 0;[r->body appendBytes:p length:size*n];return size*n;
}
static CURL *handle(NSString *url,receiver *r) {
    CURL *h=curl_easy_init();assert(h);
    assert(curl_easy_setopt(h,CURLOPT_URL,url.UTF8String)==0);
    assert(curl_easy_setopt(h,CURLOPT_WRITEFUNCTION,receive)==0);
    assert(curl_easy_setopt(h,CURLOPT_WRITEDATA,r)==0);
    assert(curl_easy_setopt(h,CURLOPT_TIMEOUT_MS,3000L)==0);return h;
}
static unsigned checks;
static NSString *perform(CURL *h,receiver *r,int expected,long status) {
    [r->body setLength:0];int got=curl_easy_perform(h);if(got!=expected)fprintf(stderr,"case %u result=%d expected=%d\n",checks,got,expected);assert(got==expected);
    long actual=-1;assert(curl_easy_getinfo(h,CURLINFO_RESPONSE_CODE,&actual)==0);assert(actual==status);checks++;
    return [[NSString alloc]initWithData:r->body encoding:NSUTF8StringEncoding];
}
static int abort_progress(void *data,curl_off_t a,curl_off_t b,curl_off_t c,curl_off_t d) {
    (void)a;(void)b;(void)c;(void)d;assert(pthread_equal(((receiver *)data)->thread,pthread_self()));return 1;
}
static size_t upload(char *buffer,size_t size,size_t count,void *data) {
    NSMutableData *bytes=(__bridge NSMutableData *)data;size_t n=MIN(size*count,bytes.length);memcpy(buffer,bytes.bytes,n);
    [bytes replaceBytesInRange:NSMakeRange(0,n) withBytes:NULL length:0];return n;
}
int main(int argc,char **argv) {@autoreleasepool {
    assert(argc==4);NSString *base=@(argv[1]),*tls=@(argv[2]);
    NSMutableData *data=[NSMutableData new];receiver r={data,pthread_self(),0,0};
    unsetenv("VXMAC_NETWORK");CURL *h=handle([base stringByAppendingString:@"/ok"],&r);
    perform(h,&r,CURLE_COULDNT_RESOLVE_HOST,0);assert(!r.calls);curl_easy_cleanup(h);
    setenv("VXMAC_NETWORK","1",1);assert(curl_global_init(CURL_GLOBAL_DEFAULT)==0);
    h=handle([base stringByAppendingString:@"/ok"],&r);assert([perform(h,&r,0,200) isEqual:@"fixture-ok"]);
    int marker=37;assert(!curl_easy_setopt(h,CURLOPT_PRIVATE,&marker));void *privateData=NULL;
    assert(!curl_easy_getinfo(h,CURLINFO_PRIVATE,&privateData) && privateData==&marker);
    curl_easy_setopt(h,CURLOPT_URL,[base stringByAppendingString:@"/redirect"].UTF8String);
    perform(h,&r,0,302);curl_easy_setopt(h,CURLOPT_FOLLOWLOCATION,1L);
    assert([perform(h,&r,0,200) isEqual:@"fixture-ok"]);long redirects=0;
    curl_easy_getinfo(h,CURLINFO_REDIRECT_COUNT,&redirects);assert(redirects==1);
    curl_easy_setopt(h,CURLOPT_URL,[base stringByAppendingString:@"/loop"].UTF8String);curl_easy_setopt(h,CURLOPT_MAXREDIRS,2L);
    perform(h,&r,CURLE_TOO_MANY_REDIRECTS,0);curl_easy_cleanup(h);
    h=handle([base stringByAppendingString:@"/missing"],&r);perform(h,&r,0,404);
    curl_easy_setopt(h,CURLOPT_FAILONERROR,1L);perform(h,&r,CURLE_HTTP_RETURNED_ERROR,404);curl_easy_cleanup(h);
    h=handle([base stringByAppendingString:@"/echo"],&r);
    struct curl_slist *headers=curl_slist_append(NULL,"X-Fixture: private-fixture-value");assert(headers);
    curl_easy_setopt(h,CURLOPT_HTTPHEADER,headers);curl_easy_setopt(h,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)5);
    char body[5]={'a',0,'b','c','d'};curl_easy_setopt(h,CURLOPT_COPYPOSTFIELDS,body);body[0]='z';
    perform(h,&r,0,200);NSDictionary *echo=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    assert([echo[@"method"] isEqual:@"POST"] && [echo[@"body"] isEqual:@"a\0bcd"] && [echo[@"fixture"] isEqual:@"private-fixture-value"]);
    curl_easy_cleanup(h);curl_slist_free_all(headers);
    h=handle([base stringByAppendingString:@"/echo"],&r);NSMutableData *up=[[@"upload-content" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    curl_easy_setopt(h,CURLOPT_UPLOAD,1L);curl_easy_setopt(h,CURLOPT_READFUNCTION,upload);curl_easy_setopt(h,CURLOPT_READDATA,(__bridge void *)up);
    curl_easy_setopt(h,CURLOPT_INFILESIZE_LARGE,(curl_off_t)up.length);perform(h,&r,0,200);
    echo=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];assert([echo[@"method"] isEqual:@"PUT"] && [echo[@"body"] isEqual:@"upload-content"]);curl_easy_cleanup(h);
    h=handle([base stringByAppendingString:@"/ok"],&r);NSMutableData *headersData=[NSMutableData new];receiver hr={headersData,pthread_self(),0,0};
    curl_easy_setopt(h,CURLOPT_HEADERFUNCTION,receive);curl_easy_setopt(h,CURLOPT_HEADERDATA,&hr);perform(h,&r,0,200);
    assert(hr.calls>=3 && [[[NSString alloc]initWithData:headersData encoding:NSUTF8StringEncoding] hasPrefix:@"HTTP/1.1 200 "]);curl_easy_cleanup(h);
    h=handle([base stringByAppendingString:@"/big"],&r);perform(h,&r,CURLE_FILESIZE_EXCEEDED,200);assert(!data.length);curl_easy_cleanup(h);
    h=handle([base stringByAppendingString:@"/slow"],&r);curl_easy_setopt(h,CURLOPT_TIMEOUT_MS,150L);perform(h,&r,CURLE_OPERATION_TIMEDOUT,0);curl_easy_cleanup(h);
    h=handle([base stringByAppendingString:@"/slow"],&r);curl_easy_setopt(h,CURLOPT_NOPROGRESS,0L);curl_easy_setopt(h,CURLOPT_XFERINFOFUNCTION,abort_progress);curl_easy_setopt(h,CURLOPT_XFERINFODATA,&r);
    perform(h,&r,CURLE_ABORTED_BY_CALLBACK,0);curl_easy_cleanup(h);
    r.abort=1;h=handle([base stringByAppendingString:@"/ok"],&r);perform(h,&r,CURLE_WRITE_ERROR,200);curl_easy_cleanup(h);r.abort=0;
    for(NSString *url in @[@"file:///etc/passwd",@"http://example.com",@"https://user:password@example.com"]) {
        h=handle(url,&r);perform(h,&r,CURLE_UNSUPPORTED_PROTOCOL,0);curl_easy_cleanup(h);
    }
    h=handle(tls,&r);int code=curl_easy_perform(h);assert(code==CURLE_PEER_FAILED_VERIFICATION || code==CURLE_SSL_CONNECT_ERROR);
    assert(curl_easy_setopt(h,CURLOPT_SSL_VERIFYPEER,0L)==CURLE_BAD_FUNCTION_ARGUMENT);curl_easy_cleanup(h);checks++;
    // Multi calls must stay nonblocking; completion callbacks stay on this thread.
    CURLM *m=curl_multi_init();h=handle([base stringByAppendingString:@"/short-delay"],&r);assert(!curl_multi_add_handle(m,h));int running=0;
    double start=NSProcessInfo.processInfo.systemUptime;assert(!curl_multi_perform(m,&running));assert(running==1 && NSProcessInfo.processInfo.systemUptime-start<.1);
    for(int i=0;running && i<1000;i++){usleep(2000);assert(!curl_multi_perform(m,&running));}assert(!running);
    int remaining=-1;CURLMsg *msg=curl_multi_info_read(m,&remaining);assert(msg && msg->msg==CURLMSG_DONE && msg->easy_handle==h && msg->data.result==CURLE_OK && !remaining);
    assert(!curl_multi_info_read(m,&remaining));assert(!curl_multi_remove_handle(m,h));curl_easy_cleanup(h);
    h=handle([base stringByAppendingString:@"/slow"],&r);curl_multi_add_handle(m,h);curl_multi_perform(m,&running);assert(running);
    curl_multi_remove_handle(m,h);curl_easy_cleanup(h);assert(!curl_multi_info_read(m,&remaining));curl_multi_cleanup(m);checks+=2;
    // Churn cancellation while delegates still complete: no stale callbacks/UAF.
    for(int i=0;i<80;i++) {m=curl_multi_init();h=handle([base stringByAppendingString:@"/short-delay"],&r);curl_multi_add_handle(m,h);curl_multi_perform(m,&running);curl_multi_remove_handle(m,h);curl_easy_cleanup(h);curl_multi_cleanup(m);}
    checks++;
    NSDictionary *result=@{@"passed":@YES,@"checks":@(checks),@"caller_uses_system_curl_headers":@YES,@"callbacks_on_driving_thread":@YES,
        @"self_signed_TLS_rejected":@YES,@"offline_default":@YES,@"device_authentication":@"not tested",@"cloud_save_sync":@"not tested"};
    assert([[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:@(argv[3]) atomically:YES]);
    printf("HTTP adapter: %u checks, real curl caller ABI, callbacks, multi/cancel, verified TLS rejection: ok\n",checks);
}}
