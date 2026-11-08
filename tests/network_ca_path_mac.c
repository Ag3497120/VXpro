// SPDX-License-Identifier: MIT
#include "../shims/network_ca_path.h"
#include <assert.h>
int main(void) {
    char out[256];const char *ca="/etc/ssl/cert.pem";
    assert(vx_network_ca_path(ca,1,"0","/app",out,sizeof(out))==ca);
    assert(vx_network_ca_path(ca,0,"1","/app",out,sizeof(out))==ca);
    assert(vx_network_ca_path(ca,1,"1",NULL,out,sizeof(out))==ca);
    assert(vx_network_ca_path(ca,1,"1","relative",out,sizeof(out))==ca);
    assert(vx_network_ca_path(ca,1,"1","/app",out,4)==ca);
    assert(!strcmp(vx_network_ca_path(ca,1,"1","/app",out,sizeof(out)),"/app/Documents/vxmac_network/cert.pem"));
    assert(!strcmp(vx_network_ca_path("/private/etc/ssl/cert.pem",1,"1","/app",out,sizeof(out)),"/app/Documents/vxmac_network/cert.pem"));
    const char *other="/etc/ssl/cert.pem.backup";
    assert(vx_network_ca_path(other,1,"1","/app",out,sizeof(out))==other);
    assert(vx_network_ca_path(NULL,1,"1","/app",out,sizeof(out))==NULL);
    puts("CA read mapping: exact paths only; offline/writes/invalid paths unchanged: ok");
}
