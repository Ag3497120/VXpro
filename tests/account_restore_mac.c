// SPDX-License-Identifier: MIT
#include "../app/Sources/gls_account.h"
#include "../app/Sources/account_restore_policy.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static void put32(unsigned char *p,uint32_t n){for(int i=0;i<4;i++)p[i]=(unsigned char)(n>>(8*i));}
static void put64(unsigned char *p,uint64_t n){for(int i=0;i<8;i++)p[i]=(unsigned char)(n>>(8*i));}
static uint64_t key(void){uint64_t h=UINT64_C(0xcbf29ce484222325);for(const char *p="GameServicesGalaxy.RefreshToken";*p;p++)h=(h^(unsigned char)*p)*UINT64_C(0x100000001b3);return h;}
static size_t fixture(unsigned char *p,const char *value,int duplicate) {
    size_t length=strlen(value),end=12;memcpy(p,"SLGR",4);put32(p+4,1);put32(p+8,duplicate?2:1);
    for(int i=0;i<(duplicate?2:1);i++){put64(p+end,key());put32(p+end+8,(uint32_t)length);memcpy(p+end+12,value,length);end+=12+length;}
    put32(p+end,vx_gls_crc32(p,end));return end+4;
}
static void recheck(unsigned char *p,size_t n){put32(p+n-4,vx_gls_crc32(p,n-4));}
int main(int argc,char **argv) {
    char out[128];unsigned char data[512];size_t n;
    assert(vx_gls_crc32((const unsigned char *)"123456789",9)==0xcbf43926u);
    n=fixture(data,"fixture.refresh.credential",0);assert(vx_gls_refresh(data,n,out,sizeof(out))==1 && !strcmp(out,"fixture.refresh.credential"));
    assert(vx_gls_refresh(data,n,out,4)==-1 && !out[0]);
    data[n-1]^=1;assert(vx_gls_refresh(data,n,out,sizeof(out))==-1);data[n-1]^=1;
    for(size_t i=0;i<n;i++)assert(vx_gls_refresh(data,i,out,sizeof(out))==-1);
    put32(data+4,2);recheck(data,n);assert(vx_gls_refresh(data,n,out,sizeof(out))==-1);
    n=fixture(data,"",0);assert(vx_gls_refresh(data,n,out,sizeof(out))==0 && !out[0]);
    n=fixture(data,"fixture",1);assert(vx_gls_refresh(data,n,out,sizeof(out))==-1);
    n=fixture(data,"line\nbreak",0);assert(vx_gls_refresh(data,n,out,sizeof(out))==-1);
    n=fixture(data,"fixture",0);put32(data+20,0xffffffffu);recheck(data,n);assert(vx_gls_refresh(data,n,out,sizeof(out))==-1);
    n=fixture(data,"fixture",0);put64(data+12,1);recheck(data,n);assert(vx_gls_refresh(data,n,out,sizeof(out))==0);
    VXAccountRestore s={0};assert(vx_account_restore_step(&s,0,0,0)==VX_ACCOUNT_WAIT);
    assert(vx_account_restore_step(&s,4,1,0)==VX_ACCOUNT_WAIT);
    assert(vx_account_restore_step(&s,5,1,0)==VX_ACCOUNT_REQUEST);
    assert(vx_account_restore_step(&s,6,1,0)==VX_ACCOUNT_WAIT);
    assert(vx_account_restore_step(&s,7,1,1)==VX_ACCOUNT_COMPLETE);
    assert(vx_account_restore_step(&s,8,1,0)==VX_ACCOUNT_WAIT); // explicit logout cannot trigger a retry
    s=(VXAccountRestore){0};assert(vx_account_restore_step(&s,100,1,1)==VX_ACCOUNT_ALREADY_SIGNED_IN);
    assert(vx_account_restore_step(&s,110,1,0)==VX_ACCOUNT_WAIT);
    s=(VXAccountRestore){0};vx_account_restore_step(&s,100,0,0);assert(vx_account_restore_step(&s,161,0,0)==VX_ACCOUNT_GIVE_UP);
    s=(VXAccountRestore){0};vx_account_restore_step(&s,100,0,0);assert(vx_account_restore_step(&s,105,1,0)==VX_ACCOUNT_REQUEST);assert(vx_account_restore_step(&s,136,1,0)==VX_ACCOUNT_GIVE_UP);
    if(argc==2) {
        FILE *f=fopen(argv[1],"rb");assert(f);unsigned char *b=malloc(1024*1024);size_t size=fread(b,1,1024*1024,f);fclose(f);
        char *secret=calloc(16385,1);int result=vx_gls_refresh(b,size,secret,16385);assert(result==1);
        for(volatile char *p=secret;p<secret+16385;p++)*p=0;free(secret);free(b);
        puts("private existing profile: checksum and nonempty credential validated (value not emitted)");
    }
    puts("account restore: profile bounds/checksum, invalid inputs, startup delay, one request, logout and timeout: ok");
}
