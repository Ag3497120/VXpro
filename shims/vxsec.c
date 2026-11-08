// SPDX-License-Identifier: MIT
// Security is re-exported. The owned SDK also imports macOS-only certificate
// helpers: support DER/PEM certificates without importing keys or changing trust.
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "vxmac.h"
#define errSecUnimplemented (-4)
#define errSecParam (-50)
#define errSecDecode (-26275)
extern CFTypeID SecCertificateGetTypeID(void);
extern CFTypeRef SecCertificateCreateWithData(CFAllocatorRef,CFDataRef);
extern CFDataRef SecCertificateCopyData(CFTypeRef);
static int online(void) { const char *e=getenv("VXMAC_NETWORK");return e && !strcmp(e,"1"); }
CFStringRef SecCertificateCopyLongDescription(CFAllocatorRef a, const void *cert, CFErrorRef *error) {
    (void)a;if(error)*error=NULL;
    return online() && cert && CFGetTypeID(cert)==SecCertificateGetTypeID()?CFCopyDescription(cert):NULL;
}
int32_t SecIdentityCreateWithCertificate(CFTypeRef keychainOrArray, const void *cert, void **identity) { (void)keychainOrArray; (void)cert; if (identity) *identity = NULL; return errSecUnimplemented; }
static const unsigned char *find(const unsigned char *p,size_t n,const char *s) {
    size_t k=strlen(s);if(k>n)return NULL;
    for(size_t i=0;i<=n-k;i++)if(!memcmp(p+i,s,k))return p+i;
    return NULL;
}
static int b64(unsigned c) {
    if(c>='A'&&c<='Z')return c-'A';if(c>='a'&&c<='z')return c-'a'+26;
    if(c>='0'&&c<='9')return c-'0'+52;return c=='+'?62:c=='/'?63:-1;
}
static CFDataRef decode(const unsigned char *p,size_t n) {
    CFMutableDataRef data=CFDataCreateMutable(NULL,0);unsigned acc=0,bits=0,padding=0,chars=0;
    if(!data)return NULL;
    for(size_t i=0;i<n;i++) {
        unsigned c=p[i];if(c==' '||c=='\r'||c=='\n'||c=='\t')continue;
        if(c=='='){padding++;if(padding>2)goto bad;chars++;continue;}
        int v=b64(c);if(v<0 || padding)goto bad;
        chars++;acc=(acc<<6)|(unsigned)v;bits+=6;
        if(bits>=8){bits-=8;unsigned char byte=(unsigned char)(acc>>bits);CFDataAppendBytes(data,&byte,1);}
    }
    if(!chars || chars%4 || (padding==1 && bits!=2) || (padding==2 && bits!=4) || (padding==0 && bits) || (bits && (acc&((1u<<bits)-1))))goto bad;
    return data;
bad:CFRelease(data);return NULL;
}
static int append_cert(CFMutableArrayRef list,CFDataRef data) {
    CFTypeRef cert=SecCertificateCreateWithData(NULL,data);if(!cert)return 0;
    CFArrayAppendValue(list,cert);CFRelease(cert);return 1;
}
int32_t SecItemExport(CFTypeRef items, uint32_t format, uint32_t flags, const void *params, CFDataRef *out) {
    (void)params;if(out)*out=NULL;if(!online())return errSecUnimplemented;
    if(!items || !out)return errSecParam;
    // Certificate export only. In particular, never export identity/private keys.
    if(CFGetTypeID(items)!=SecCertificateGetTypeID() || (format!=0 && format!=9 && format!=10))return errSecUnimplemented;
    CFDataRef der=SecCertificateCopyData(items);if(!der)return errSecDecode;
    if(!(flags&1) && format!=10){*out=der;return 0;}
    static const char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    CFMutableDataRef pem=CFDataCreateMutable(NULL,0);
    const char *begin="-----BEGIN CERTIFICATE-----\n",*end="-----END CERTIFICATE-----\n";
    CFDataAppendBytes(pem,(const UInt8 *)begin,(CFIndex)strlen(begin));
    const UInt8 *p=CFDataGetBytePtr(der);size_t n=(size_t)CFDataGetLength(der),col=0;
    for(size_t i=0;i<n;i+=3) {
        unsigned v=(unsigned)p[i]<<16;if(i+1<n)v|=(unsigned)p[i+1]<<8;if(i+2<n)v|=p[i+2];
        unsigned char q[4]={alphabet[(v>>18)&63],alphabet[(v>>12)&63],i+1<n?alphabet[(v>>6)&63]:'=',i+2<n?alphabet[v&63]:'='};
        CFDataAppendBytes(pem,q,4);col+=4;if(col==64){CFDataAppendBytes(pem,(const UInt8 *)"\n",1);col=0;}
    }
    if(col)CFDataAppendBytes(pem,(const UInt8 *)"\n",1);
    CFDataAppendBytes(pem,(const UInt8 *)end,(CFIndex)strlen(end));CFRelease(der);*out=pem;return 0;
}
int32_t SecItemImport(CFDataRef data, CFStringRef name, uint32_t *format, uint32_t *type, uint32_t flags, const void *params, void *keychain, CFArrayRef *out) {
    (void)name;(void)flags;(void)params;if(out)*out=NULL;if(!online())return errSecUnimplemented;
    if(!data || !out || CFGetTypeID(data)!=CFDataGetTypeID())return errSecParam;
    if(keychain || (format && *format!=0 && *format!=9 && *format!=10) || (type && *type!=0 && *type!=4 && *type!=5))return errSecUnimplemented;
    size_t n=(size_t)CFDataGetLength(data);const UInt8 *p=CFDataGetBytePtr(data);
    if(!n || n>4*1024*1024)return errSecDecode;
    CFMutableArrayRef list=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);if(!list)return -108;
    const char *begin="-----BEGIN CERTIFICATE-----",*end="-----END CERTIFICATE-----";
    const UInt8 *first=find(p,n,begin);int error=0;
    if(first) {
        if(find(p,n,"PRIVATE KEY")){error=errSecUnimplemented;goto done;}
        const UInt8 *cursor=p,*limit=p+n;
        for(;;) {
            const UInt8 *a=find(cursor,(size_t)(limit-cursor),begin);if(!a)break;a+=strlen(begin);
            const UInt8 *b=find(a,(size_t)(limit-a),end);if(!b){error=errSecDecode;break;}
            CFDataRef der=decode(a,(size_t)(b-a));
            int ok=der && CFArrayGetCount(list)<512 && append_cert(list,der);if(der)CFRelease(der);
            if(!ok){error=errSecDecode;break;}cursor=b+strlen(end);
        }
    } else if(!append_cert(list,data))error=errSecDecode;
done:
    if(!error && !CFArrayGetCount(list))error=errSecDecode;
    vxmac_log("security_compat: certificate_import result=%d count=%ld",error,(long)CFArrayGetCount(list));
    if(error){CFRelease(list);return error;}
    if(format)*format=first?10:9;if(type)*type=CFArrayGetCount(list)>1?5:4;*out=list;return 0;
}
