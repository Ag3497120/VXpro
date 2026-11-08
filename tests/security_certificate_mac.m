// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Security/SecCertificate.h>
#include <assert.h>
#include <stdarg.h>
void vxmac_log(const char *format,...) {(void)format;}
int main(int argc,char **argv) {@autoreleasepool {
    assert(argc==2);NSData *pem=[NSData dataWithContentsOfFile:@(argv[1])];assert(pem);
    CFArrayRef certificates=NULL;SecExternalFormat format=kSecFormatUnknown;SecExternalItemType type=kSecItemTypeUnknown;
    unsetenv("VXMAC_NETWORK");assert(SecItemImport((__bridge CFDataRef)pem,NULL,&format,&type,0,NULL,NULL,&certificates)==-4 && !certificates);
    setenv("VXMAC_NETWORK","1",1);assert(!SecItemImport((__bridge CFDataRef)pem,NULL,&format,&type,0,NULL,NULL,&certificates));
    assert(CFArrayGetCount(certificates)==1 && format==10 && type==4);
    SecCertificateRef cert=(SecCertificateRef)CFArrayGetValueAtIndex(certificates,0);CFDataRef der=NULL,armored=NULL;
    assert(!SecItemExport(cert,9,0,NULL,&der));CFDataRef expected=SecCertificateCopyData(cert);assert(CFEqual(der,expected));CFRelease(expected);
    assert(!SecItemExport(cert,10,1,NULL,&armored));
    CFArrayRef roundtrip=NULL;format=kSecFormatUnknown;type=kSecItemTypeUnknown;assert(!SecItemImport(der,NULL,&format,&type,0,NULL,NULL,&roundtrip));
    assert(CFEqual(CFArrayGetValueAtIndex(roundtrip,0),cert));CFRelease(roundtrip);roundtrip=NULL;
    format=kSecFormatUnknown;type=kSecItemTypeUnknown;assert(!SecItemImport(armored,NULL,&format,&type,0,NULL,NULL,&roundtrip));assert(CFEqual(CFArrayGetValueAtIndex(roundtrip,0),cert));CFRelease(roundtrip);
    NSMutableData *two=[pem mutableCopy];[two appendData:pem];format=kSecFormatUnknown;type=kSecItemTypeUnknown;
    assert(!SecItemImport((__bridge CFDataRef)two,NULL,&format,&type,0,NULL,NULL,&roundtrip));assert(CFArrayGetCount(roundtrip)==2 && type==5);CFRelease(roundtrip);
    for(NSString *bad in @[@"-----BEGIN CERTIFICATE-----\nnot!base64\n-----END CERTIFICATE-----",@"-----BEGIN CERTIFICATE-----\nAA==",@"-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----"]) {
        NSData *bytes=[bad dataUsingEncoding:NSUTF8StringEncoding];format=kSecFormatUnknown;type=kSecItemTypeUnknown;roundtrip=NULL;
        assert(SecItemImport((__bridge CFDataRef)bytes,NULL,&format,&type,0,NULL,NULL,&roundtrip)!=0 && !roundtrip);
    }
    format=kSecFormatUnknown;type=kSecItemTypeUnknown;roundtrip=NULL;assert(SecItemImport((__bridge CFDataRef)pem,NULL,&format,&type,0,NULL,(void *)1,&roundtrip)==-4 && !roundtrip);
    CFRelease(certificates);CFRelease(der);CFRelease(armored);
    puts("certificate compatibility: real DER/PEM roundtrip/bundle; reject malformed/keychain writes; no trust changes: ok");
}}
