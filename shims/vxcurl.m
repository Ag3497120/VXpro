// SPDX-License-Identifier: MIT
// libcurl ABI adapter for the owned Mac game's easy/multi HTTP calls. NSURLSession
// supplies HTTPS and platform certificate validation; callbacks run only on the
// thread driving curl, never on a URLSession delegate thread. Opt in with
// VXMAC_NETWORK=1. Offline remains the default until account/saves are verified.
#import <Foundation/Foundation.h>
#include "vxcurl.h"
#include "vxmac.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef size_t (*vx_curl_io)(char *,size_t,size_t,void *);
typedef int (*vx_curl_progress)(void *,int64_t,int64_t,int64_t,int64_t);
typedef int (*vx_curl_legacy_progress)(void *,double,double,double,double);
static const size_t body_limit=32*1024*1024, header_limit=64*1024;
static int network_on(void) { const char *e=getenv("VXMAC_NETWORK");return e && !strcmp(e,"1"); }
@class VXCurlMulti;
@interface VXCurlEasy : NSObject
@property(nonatomic,strong) NSCondition *condition;
@property(nonatomic,copy) NSString *url,*method,*agent,*referer,*encoding,*effectiveURL,*contentType;
@property(nonatomic,strong) NSData *copiedPost;
@property(nonatomic) const void *post;
@property(nonatomic) int64_t postSize,inputSize;
@property(nonatomic) curl_slist *headers;
@property(nonatomic) void *privateData,*writeData,*readData,*headerData,*progressData;
@property(nonatomic) char *errorBuffer;
@property(nonatomic) vx_curl_io writer,reader,headerWriter;
@property(nonatomic) vx_curl_progress progress;
@property(nonatomic) vx_curl_legacy_progress legacyProgress;
@property(nonatomic) BOOL postMethod,upload,noBody,follow,includeHeader,failHTTP,noProgress;
@property(nonatomic) BOOL started,ready,delivered,reported,disposed;
@property(nonatomic) long maxRedirects,status,redirects;
@property(nonatomic) double timeout,connectTimeout,startedAt,elapsed;
@property(nonatomic) size_t downloaded,uploaded;
@property(nonatomic) int error;
@property(nonatomic) unsigned generation;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,strong) NSData *responseHeaders;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,weak) VXCurlMulti *owner;
@end
@implementation VXCurlEasy
- (instancetype)init {
    if((self=[super init])) { _condition=[NSCondition new];_postSize=_inputSize=-1;_timeout=30;_connectTimeout=15;_maxRedirects=10;_noProgress=YES; }
    return self;
}
@end
@interface VXCurlMulti : NSObject
@property(nonatomic,strong) NSMutableArray<VXCurlEasy *> *handles;
@property(nonatomic) vx_curl_msg message;
- (void *)messagePointer;
@end
@implementation VXCurlMulti
- (instancetype)init { if((self=[super init])) _handles=[NSMutableArray new];return self; }
- (void *)messagePointer { return &_message; }
@end
static VXCurlEasy *easy(void *p) { return (__bridge VXCurlEasy *)p; }
static VXCurlMulti *multi(void *p) { return (__bridge VXCurlMulti *)p; }
static NSString *string(const char *p) { return p?[NSString stringWithUTF8String:p]:nil; }
static double clock_now(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL allowed_url(NSURL *url) {
    if(!url.host.length || url.user || url.password) return NO;
    if([url.scheme.lowercaseString isEqualToString:@"https"]) return YES;
    // Only loopback HTTP is useful to the local fixture server. Never downgrade
    // account traffic or accept file:// through this network adapter.
    return [url.scheme.lowercaseString isEqualToString:@"http"] &&
        [@[@"127.0.0.1",@"::1",@"[::1]"] containsObject:url.host.lowercaseString];
}
static void finish_locked(VXCurlEasy *h,int error) {
    if(h.ready) return;
    h.error=error;h.ready=YES;h.elapsed=clock_now()-h.startedAt;[h.condition broadcast];
}
static int map_error(NSError *e) {
    if(!e) return VX_CURL_OK;
    switch(e.code) {
        case NSURLErrorTimedOut:return VX_CURL_TIMEOUT;
        case NSURLErrorCannotFindHost:case NSURLErrorDNSLookupFailed:return VX_CURL_RESOLVE;
        case NSURLErrorServerCertificateHasBadDate:case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:case NSURLErrorServerCertificateNotYetValid:return VX_CURL_CERTIFICATE_ERROR;
        case NSURLErrorSecureConnectionFailed:case NSURLErrorClientCertificateRejected:
        case NSURLErrorClientCertificateRequired:return VX_CURL_SSL_ERROR;
        case NSURLErrorCancelled:return VX_CURL_ABORTED;
        default:return VX_CURL_CONNECT;
    }
}
@interface VXCurlDelegate : NSObject<NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic,weak) VXCurlEasy *handle;
@property(nonatomic) unsigned generation;
@end
@implementation VXCurlDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    VXCurlEasy *h=self.handle;if(!h) {completion(NSURLSessionResponseCancel);return;}
    [h.condition lock];
    if(h.generation!=self.generation || h.ready) { [h.condition unlock];completion(NSURLSessionResponseCancel);return; }
    NSHTTPURLResponse *r=(NSHTTPURLResponse *)response;
    h.status=r.statusCode;h.effectiveURL=r.URL.absoluteString;h.contentType=[r valueForHTTPHeaderField:@"Content-Type"];
    NSMutableString *lines=[NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n",(long)r.statusCode,[NSHTTPURLResponse localizedStringForStatusCode:r.statusCode]];
    for(NSString *key in [[r.allHeaderFields allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [lines appendFormat:@"%@: %@\r\n",key,r.allHeaderFields[key]];
    [lines appendString:@"\r\n"];h.responseHeaders=[lines dataUsingEncoding:NSUTF8StringEncoding];
    int error=h.responseHeaders.length>header_limit || response.expectedContentLength>(int64_t)body_limit ? VX_CURL_FILESIZE_EXCEEDED:0;
    if(error) finish_locked(h,error);
    [h.condition unlock];completion(error?NSURLSessionResponseCancel:NSURLSessionResponseAllow);
    (void)session;(void)task;
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    VXCurlEasy *h=self.handle;if(!h)return;
    [h.condition lock];BOOL cancel=NO;
    if(h.generation==self.generation && !h.ready) {
        if(data.length>body_limit-h.body.length) {finish_locked(h,VX_CURL_FILESIZE_EXCEEDED);cancel=YES;}
        else {[h.body appendData:data];h.downloaded=h.body.length;}
    }
    [h.condition unlock];if(cancel)[task cancel];(void)session;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    VXCurlEasy *h=self.handle;
    if(h) {[h.condition lock];if(h.generation==self.generation)finish_locked(h,map_error(error));[h.condition unlock];}
    [session finishTasksAndInvalidate];(void)task;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    VXCurlEasy *h=self.handle;if(!h){completion(nil);return;}
    [h.condition lock];BOOL follow=h.follow && h.generation==self.generation && !h.ready;
    if(follow && !allowed_url(request.URL)) {finish_locked(h,VX_CURL_UNSUPPORTED_PROTOCOL);follow=NO;}
    if(follow && h.redirects>=h.maxRedirects) {finish_locked(h,VX_CURL_TOO_MANY_REDIRECTS);follow=NO;}
    if(follow)h.redirects++;
    [h.condition unlock];
    NSMutableURLRequest *next=[request mutableCopy];
    if(![response.URL.host.lowercaseString isEqualToString:request.URL.host.lowercaseString]) {
        [next setValue:nil forHTTPHeaderField:@"Authorization"];
        [next setValue:nil forHTTPHeaderField:@"Cookie"];
    }
    completion(follow?next:nil);(void)session;(void)task;
}
@end
static void cancel(VXCurlEasy *h) {
    [h.condition lock];h.generation++;NSURLSession *session=h.session;h.task=nil;h.session=nil;
    finish_locked(h,VX_CURL_ABORTED);[h.condition unlock];[session invalidateAndCancel];
}
static void start(VXCurlEasy *h) {
    if(h.started)return;
    h.started=YES;h.startedAt=clock_now();h.ready=h.delivered=h.reported=NO;h.error=0;h.status=h.redirects=0;
    h.body=[NSMutableData new];h.responseHeaders=nil;h.effectiveURL=h.url;h.contentType=nil;h.downloaded=h.uploaded=0;
    if(h.errorBuffer)h.errorBuffer[0]=0;
    if(!network_on()) {[h.condition lock];finish_locked(h,VX_CURL_RESOLVE);[h.condition unlock];return;}
    NSURL *url=h.url?[NSURL URLWithString:h.url]:nil;
    int error=!url?VX_CURL_URL_MALFORMAT:!allowed_url(url)?VX_CURL_UNSUPPORTED_PROTOCOL:0;
    NSMutableURLRequest *request=url?[NSMutableURLRequest requestWithURL:url]:nil;
    request.HTTPMethod=h.method ?: h.noBody?@"HEAD":(h.postMethod||h.post||h.copiedPost)?@"POST":h.upload?@"PUT":@"GET";
    request.timeoutInterval=h.connectTimeout>0?h.connectTimeout:30;
    if(h.agent)[request setValue:h.agent forHTTPHeaderField:@"User-Agent"];
    if(h.referer)[request setValue:h.referer forHTTPHeaderField:@"Referer"];
    if(h.encoding)[request setValue:h.encoding.length?h.encoding:@"gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
    @try {
        size_t length=0;
        for(curl_slist *s=h.headers;s && !error;s=s->next) {
            NSString *line=string(s->data);NSRange colon=[line rangeOfString:@":"];
            if(!line || !colon.length || colon.location==0 || [line rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].length) {error=VX_CURL_BAD_ARGUMENT;break;}
            length+=strlen(s->data);if(length>header_limit){error=VX_CURL_BAD_ARGUMENT;break;}
            [request setValue:[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] forHTTPHeaderField:[line substringToIndex:colon.location]];
        }
        if(h.copiedPost)request.HTTPBody=h.copiedPost;
        else if(h.post) {
            size_t n=h.postSize>=0?(size_t)h.postSize:strnlen(h.post,body_limit+1);
            if(n>body_limit)error=VX_CURL_FILESIZE_EXCEEDED;else request.HTTPBody=[NSData dataWithBytes:h.post length:n];
        } else if(h.upload || (h.postMethod && h.reader)) {
            if(!h.reader)error=VX_CURL_READ_ERROR;
            else {
                NSMutableData *body=[NSMutableData new];char bytes[16384];
                while(!error) {
                    size_t capacity=sizeof bytes;
                    if(h.inputSize>=0)capacity=(size_t)MIN((int64_t)capacity,h.inputSize-(int64_t)body.length);
                    if(!capacity)break;
                    size_t n=h.reader(bytes,1,capacity,h.readData);
                    if(n==0x10000000u){error=VX_CURL_ABORTED;break;}
                    if(n>capacity){error=VX_CURL_READ_ERROR;break;}
                    if(!n)break;
                    if(n>body_limit-body.length){error=VX_CURL_FILESIZE_EXCEEDED;break;}
                    [body appendBytes:bytes length:n];
                }
                if(!error && h.inputSize>=0 && (int64_t)body.length!=h.inputSize)error=VX_CURL_READ_ERROR;
                request.HTTPBody=body;
            }
        }
    } @catch(NSException *exception) {error=VX_CURL_BAD_ARGUMENT;(void)exception;}
    if(error){[h.condition lock];finish_locked(h,error);[h.condition unlock];return;}
    h.uploaded=request.HTTPBody.length;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache=nil;config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest=request.timeoutInterval;config.timeoutIntervalForResource=h.timeout>0?h.timeout:300;
    config.HTTPMaximumConnectionsPerHost=4;
    VXCurlDelegate *delegate=[VXCurlDelegate new];delegate.handle=h;delegate.generation=++h.generation;
    h.session=[NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];
    h.task=[h.session dataTaskWithRequest:request];[h.task resume];
}
static BOOL write_bytes(VXCurlEasy *h,const void *bytes,size_t length,BOOL header) {
    vx_curl_io callback=header?h.headerWriter:h.writer;void *data=header?h.headerData:h.writeData;
    // Do not put an account token on stdout if the caller forgot its receiver.
    if(callback)return callback((char *)bytes,1,length,data)==length;
    return data && fwrite(bytes,1,length,(FILE *)data)==length;
}
static void drain(VXCurlEasy *h) {
    [h.condition lock];BOOL ready=h.ready;size_t downloaded=h.downloaded,uploaded=h.uploaded;[h.condition unlock];
    if(!h.noProgress && !h.disposed) {
        int abort=h.progress?h.progress(h.progressData,(int64_t)downloaded,(int64_t)downloaded,(int64_t)uploaded,(int64_t)uploaded):
            h.legacyProgress?h.legacyProgress(h.progressData,downloaded,downloaded,uploaded,uploaded):0;
        if(abort){cancel(h);ready=YES;}
    }
    if(!ready || h.delivered || h.disposed)return;
    h.delivered=YES;
    if(!h.error && h.responseHeaders.length) {
        const char *bytes=h.responseHeaders.bytes;size_t n=h.responseHeaders.length,pos=0;
        while(pos<n && !h.error && !h.disposed) {
            size_t end=pos;while(end<n && bytes[end]!='\n')end++;if(end<n)end++;
            if(h.headerWriter && !write_bytes(h,bytes+pos,end-pos,YES))h.error=VX_CURL_WRITE_ERROR;
            if(h.includeHeader && !write_bytes(h,bytes+pos,end-pos,NO))h.error=VX_CURL_WRITE_ERROR;
            pos=end;
        }
    }
    if(!h.error && h.failHTTP && h.status>=400)h.error=VX_CURL_HTTP_ERROR;
    if(!h.error && !h.disposed && h.body.length && !h.noBody) {
        const char *bytes=h.body.bytes;size_t n=h.body.length;
        for(size_t pos=0;pos<n && !h.disposed;pos+=MIN((size_t)16384,n-pos))
            if(!write_bytes(h,bytes+pos,MIN((size_t)16384,n-pos),NO)){h.error=VX_CURL_WRITE_ERROR;break;}
    }
    h.body=nil;h.responseHeaders=nil;h.task=nil;h.session=nil;
    if(h.errorBuffer && h.error)snprintf(h.errorBuffer,256,"VX HTTP: %s",curl_easy_strerror(h.error));
    // Never log URLs, headers, bodies, account IDs, device codes or tokens.
    vxmac_log("http: status=%ld result=%d bytes=%zu",h.status,h.error,h.downloaded);
}
int curl_global_init_mem(long flags,void *m,void *f,void *r,void *s,void *c) {
    (void)flags;(void)m;(void)f;(void)r;(void)s;(void)c;vxmac_log("curl: %s",network_on()?"Foundation HTTPS enabled":"offline (libvxcurl)");return 0;
}
int curl_global_init(long flags){return curl_global_init_mem(flags,0,0,0,0,0);}
void curl_global_cleanup(void){}
void *curl_easy_init(void){return (void *)CFBridgingRetain([VXCurlEasy new]);}
void curl_easy_cleanup(void *p){if(!p)return;VXCurlEasy *h=easy(p);h.disposed=YES;[h.owner.handles removeObjectIdenticalTo:h];h.owner=nil;cancel(h);CFBridgingRelease(p);}
int curl_easy_setopt(void *p,int option,...) {
    if(!p)return VX_CURL_BAD_ARGUMENT;VXCurlEasy *h=easy(p);va_list ap;va_start(ap,option);int error=0;
    switch(option) {
        case VX_CURLOPT_URL:h.url=string(va_arg(ap,const char *));break;
        case VX_CURLOPT_CUSTOMREQUEST:h.method=string(va_arg(ap,const char *));break;
        case VX_CURLOPT_USERAGENT:h.agent=string(va_arg(ap,const char *));break;
        case VX_CURLOPT_REFERER:h.referer=string(va_arg(ap,const char *));break;
        case VX_CURLOPT_ACCEPT_ENCODING:h.encoding=string(va_arg(ap,const char *));break;
        case VX_CURLOPT_PRIVATE:h.privateData=va_arg(ap,void *);break;
        case VX_CURLOPT_WRITEDATA:h.writeData=va_arg(ap,void *);break;
        case VX_CURLOPT_READDATA:h.readData=va_arg(ap,void *);break;
        case VX_CURLOPT_HEADERDATA:h.headerData=va_arg(ap,void *);break;
        case VX_CURLOPT_XFERINFODATA:h.progressData=va_arg(ap,void *);break;
        case VX_CURLOPT_ERRORBUFFER:h.errorBuffer=va_arg(ap,char *);break;
        case VX_CURLOPT_HTTPHEADER:h.headers=va_arg(ap,curl_slist *);break;
        case VX_CURLOPT_WRITEFUNCTION:h.writer=va_arg(ap,vx_curl_io);break;
        case VX_CURLOPT_READFUNCTION:h.reader=va_arg(ap,vx_curl_io);break;
        case VX_CURLOPT_HEADERFUNCTION:h.headerWriter=va_arg(ap,vx_curl_io);break;
        case VX_CURLOPT_XFERINFOFUNCTION:h.progress=va_arg(ap,vx_curl_progress);break;
        case 20056:h.legacyProgress=va_arg(ap,vx_curl_legacy_progress);break;
        case VX_CURLOPT_POSTFIELDS:h.post=va_arg(ap,const void *);h.copiedPost=nil;h.postMethod=YES;break;
        case VX_CURLOPT_COPYPOSTFIELDS: {
            const void *s=va_arg(ap,const void *);size_t n=s?(h.postSize>=0?(size_t)h.postSize:strnlen(s,body_limit+1)):0;
            if(n>body_limit)error=VX_CURL_FILESIZE_EXCEEDED;else {h.copiedPost=[NSData dataWithBytes:s length:n];h.post=NULL;h.postMethod=YES;}break;
        }
        case VX_CURLOPT_POSTFIELDSIZE:h.postSize=va_arg(ap,long);break;
        case VX_CURLOPT_POSTFIELDSIZE_LARGE:h.postSize=va_arg(ap,int64_t);break;
        case VX_CURLOPT_INFILESIZE:h.inputSize=va_arg(ap,long);break;
        case VX_CURLOPT_INFILESIZE_LARGE:h.inputSize=va_arg(ap,int64_t);break;
        case VX_CURLOPT_POST:h.postMethod=va_arg(ap,long)!=0;break;
        case VX_CURLOPT_UPLOAD:h.upload=va_arg(ap,long)!=0;break;
        case VX_CURLOPT_NOBODY:h.noBody=va_arg(ap,long)!=0;break;
        case VX_CURLOPT_HTTPGET:if(va_arg(ap,long)){h.upload=h.postMethod=h.noBody=NO;h.post=NULL;h.copiedPost=nil;}break;
        case VX_CURLOPT_HEADER:h.includeHeader=va_arg(ap,long)!=0;break;
        case VX_CURLOPT_FAILONERROR:h.failHTTP=va_arg(ap,long)!=0;break;
        case VX_CURLOPT_FOLLOWLOCATION:h.follow=va_arg(ap,long)!=0;break;
        case VX_CURLOPT_NOPROGRESS:h.noProgress=va_arg(ap,long)!=0;break;
        case VX_CURLOPT_MAXREDIRS:h.maxRedirects=va_arg(ap,long);if(h.maxRedirects<0)h.maxRedirects=50;break;
        case VX_CURLOPT_TIMEOUT:h.timeout=(double)va_arg(ap,long);break;
        case VX_CURLOPT_TIMEOUT_MS:h.timeout=(double)va_arg(ap,long)/1000;break;
        case VX_CURLOPT_CONNECTTIMEOUT:h.connectTimeout=(double)va_arg(ap,long);break;
        case VX_CURLOPT_CONNECTTIMEOUT_MS:h.connectTimeout=(double)va_arg(ap,long)/1000;break;
        case VX_CURLOPT_SSL_VERIFYPEER:if(!va_arg(ap,long))error=VX_CURL_BAD_ARGUMENT;break;
        case VX_CURLOPT_SSL_VERIFYHOST:if(va_arg(ap,long)!=2)error=VX_CURL_BAD_ARGUMENT;break;
        case VX_CURLOPT_VERBOSE:case VX_CURLOPT_NOSIGNAL:case VX_CURLOPT_HTTP_VERSION:
        case 98:case 121:case 213:case 214:case 215:case 74:case 75:case 157:case 158:
            (void)va_arg(ap,long);break; // scheduling/buffer hints; URLSession owns those details
        default:
            if(network_on()){vxmac_log("http: unsupported option=%d",option);error=VX_CURL_UNKNOWN_OPTION;}break;
    }
    va_end(ap);return error;
}
int curl_easy_perform(void *p) {
    if(!p)return VX_CURL_BAD_ARGUMENT;VXCurlEasy *h=easy(p);h.started=NO;start(h);
    while(!h.delivered && !h.disposed) {
        drain(h);if(h.delivered)break;
        [h.condition lock];if(!h.ready)[h.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];[h.condition unlock];
    }
    return h.error;
}
int curl_easy_getinfo(void *p,int info,...) {
    if(!p)return VX_CURL_BAD_ARGUMENT;VXCurlEasy *h=easy(p);va_list ap;va_start(ap,info);void *out=va_arg(ap,void *);va_end(ap);
    if(!out)return VX_CURL_BAD_ARGUMENT;
    switch(info) {
        case VX_CURLINFO_RESPONSE_CODE:*(long *)out=h.status;return 0;
        case VX_CURLINFO_REDIRECT_COUNT:*(long *)out=h.redirects;return 0;
        case VX_CURLINFO_PRIVATE:*(void **)out=h.privateData;return 0;
        case VX_CURLINFO_EFFECTIVE_URL:*(const char **)out=(h.effectiveURL?:h.url).UTF8String;return 0;
        case VX_CURLINFO_CONTENT_TYPE:*(const char **)out=h.contentType.UTF8String;return 0;
        case VX_CURLINFO_TOTAL_TIME:*(double *)out=h.elapsed;return 0;
        case VX_CURLINFO_SIZE_UPLOAD:*(double *)out=h.uploaded;return 0;
        case VX_CURLINFO_SIZE_DOWNLOAD:*(double *)out=h.downloaded;return 0;
        case VX_CURLINFO_NAMELOOKUP_TIME:case VX_CURLINFO_CONNECT_TIME:case VX_CURLINFO_PRETRANSFER_TIME:
        case VX_CURLINFO_STARTTRANSFER_TIME:case VX_CURLINFO_APPCONNECT_TIME:*(double *)out=0;return 0;
        default:return VX_CURL_UNKNOWN_OPTION;
    }
}
const char *curl_easy_strerror(int error) {
    switch(error) {
        case 0:return "No error";case 1:return "Unsupported URL protocol";case 3:return "Malformed URL";
        case 6:return "Could not resolve host or networking is disabled";case 7:return "Could not connect";
        case 22:return "HTTP error";case 23:return "Receiver rejected data";case 26:return "Upload reader failed";
        case 27:return "Out of memory";case 28:return "Transfer timed out";case 35:return "TLS connection failed";
        case 42:return "Transfer cancelled";case 43:return "Invalid or unsupported argument";
        case 47:return "Too many redirects";case 48:return "Unsupported option";case 60:return "Certificate validation failed";
        case 63:return "Response exceeds memory limit";default:return "HTTP transfer failed";
    }
}
void *curl_multi_init(void){return (void *)CFBridgingRetain([VXCurlMulti new]);}
int curl_multi_cleanup(void *p){if(!p)return 1;VXCurlMulti *m=multi(p);for(VXCurlEasy *h in m.handles){cancel(h);h.owner=nil;}[m.handles removeAllObjects];CFBridgingRelease(p);return 0;}
int curl_multi_add_handle(void *mp,void *p) {
    if(!mp || !p)return 1;VXCurlMulti *m=multi(mp);VXCurlEasy *h=easy(p);if(h.owner)return 7;
    if(m.handles.count>=256)return 3;h.owner=m;h.started=h.ready=h.delivered=h.reported=NO;[m.handles addObject:h];return 0;
}
int curl_multi_remove_handle(void *mp,void *p){if(!mp || !p)return 1;VXCurlMulti *m=multi(mp);VXCurlEasy *h=easy(p);if(h.owner!=m)return 2;cancel(h);h.owner=nil;[m.handles removeObjectIdenticalTo:h];return 0;}
int curl_multi_perform(void *mp,int *running) {
    if(!mp)return 1;VXCurlMulti *m=multi(mp);int active=0;
    for(VXCurlEasy *h in m.handles)if(h.started && !h.delivered)active++;
    for(VXCurlEasy *h in [m.handles copy]) {
        if(!h.started && active<4){start(h);active++;}
        if(h.started)drain(h);
    }
    int left=0;for(VXCurlEasy *h in m.handles)if(!h.delivered)left++;
    if(running)*running=left;return 0;
}
void *curl_multi_info_read(void *mp,int *remaining) {
    if(!mp)return NULL;VXCurlMulti *m=multi(mp);VXCurlEasy *next=nil;int left=0;
    for(VXCurlEasy *h in m.handles)if(h.delivered && !h.reported){if(!next)next=h;else left++;}
    if(remaining)*remaining=left;if(!next)return NULL;next.reported=YES;
    m.message=(vx_curl_msg){.msg=1,.easy_handle=(__bridge void *)next,.data.result=next.error};return [m messagePointer];
}
curl_slist *curl_slist_append(curl_slist *list,const char *s) {
    if(!s)return NULL;curl_slist *n=calloc(1,sizeof *n);if(!n)return NULL;
    n->data=strdup(s);if(!n->data){free(n);return NULL;}if(!list)return n;
    curl_slist *tail=list;while(tail->next)tail=tail->next;tail->next=n;return list;
}
void curl_slist_free_all(curl_slist *list){while(list){curl_slist *next=list->next;free(list->data);free(list);list=next;}}
