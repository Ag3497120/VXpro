// SPDX-License-Identifier: MIT
#ifndef VXMAC_GLS_ACCOUNT_H
#define VXMAC_GLS_ACCOUNT_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
static inline uint32_t vx_gls_u32(const unsigned char *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static inline uint64_t vx_gls_u64(const unsigned char *p) {
    return (uint64_t)vx_gls_u32(p)|(uint64_t)vx_gls_u32(p+4)<<32;
}
static inline uint32_t vx_gls_crc32(const unsigned char *p,size_t size) {
    uint32_t c=~0u;
    for(size_t i=0;i<size;i++) {
        c^=p[i];for(unsigned j=0;j<8;j++)c=(c>>1)^(0xedb88320u& (0u-(c&1)));
    }
    return ~c;
}
// Read the existing game's SLGR v1 profile, including its checksum. Never edit
// profile data or accept a truncated/ambiguous credential. Return -1/0/1 for
// invalid, absent/empty, or a genuine stored opaque credential respectively.
static inline int vx_gls_refresh(const void *bytes,size_t size,char *out,size_t capacity) {
    if(out && capacity)out[0]=0;
    if(!bytes || !out || !capacity || size<16 || size>1024*1024)return -1;
    const unsigned char *p=bytes;
    if(memcmp(p,"SLGR",4) || vx_gls_u32(p+4)!=1 || vx_gls_u32(p+size-4)!=vx_gls_crc32(p,size-4))return -1;
    uint32_t count=vx_gls_u32(p+8);if(count>4096)return -1;
    const char *name="GameServicesGalaxy.RefreshToken";uint64_t wanted=UINT64_C(0xcbf29ce484222325);
    for(const unsigned char *s=(const void *)name;*s;s++)wanted=(wanted^*s)*UINT64_C(0x100000001b3);
    size_t cursor=12,length=0;const unsigned char *value=NULL;int found=0;
    for(uint32_t i=0;i<count;i++) {
        if(cursor>size-4 || size-4-cursor<12)return -1;
        uint64_t key=vx_gls_u64(p+cursor);size_t n=vx_gls_u32(p+cursor+8);cursor+=12;
        if(n>size-4-cursor)return -1;
        if(key==wanted) { if(found++)return -1;value=p+cursor;length=n; }
        cursor+=n;
    }
    if(cursor!=size-4)return -1;
    if(!value || !length)return 0;
    if(length>=capacity || length>16384)return -1;
    for(size_t i=0;i<length;i++) {
        unsigned c=value[i];
        if(!((c>='a'&&c<='z') || (c>='A'&&c<='Z') || (c>='0'&&c<='9') || strchr("-._~+/=",c)))return -1;
        if(!c)return -1;
    }
    memcpy(out,value,length);out[length]=0;return 1;
}
#endif
