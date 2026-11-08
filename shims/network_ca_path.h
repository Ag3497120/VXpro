// SPDX-License-Identifier: MIT
#ifndef VXMAC_NETWORK_CA_PATH_H
#define VXMAC_NETWORK_CA_PATH_H
#include <stdio.h>
#include <string.h>
// Restore the Mac SDK's standard CA-file read inside the app's container. The
// bundle is provisioned privately from this player's Mac, never in the repo.
// Writes, other paths, and offline operation must retain their original meaning.
static inline const char *vx_network_ca_path(const char *path,int readonly,
        const char *online,const char *home,char *out,size_t capacity) {
    if(!path || !readonly || (strcmp(path,"/etc/ssl/cert.pem") && strcmp(path,"/private/etc/ssl/cert.pem")) ||
       !online || strcmp(online,"1") || !home || home[0]!='/')return path;
    int n=snprintf(out,capacity,"%s/Documents/vxmac_network/cert.pem",home);
    return n>=0 && (size_t)n<capacity ? out:path;
}
#endif
