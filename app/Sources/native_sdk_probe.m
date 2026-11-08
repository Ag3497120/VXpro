// SPDX-License-Identifier: MIT
// Diagnostic only: exercise the owned SDK's own TLS path before the game starts.
// Resolving its existing local C symbols does not patch the image or bypass login.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include "../../shims/vxcurl.h"

static void *sdk_function(NSData *file, intptr_t slide, const char *name) {
    if (file.length < sizeof(struct mach_header_64)) return NULL;
    const uint8_t *bytes=file.bytes;
    const struct mach_header_64 *header=(const void *)bytes;
    if (header->magic!=MH_MAGIC_64 || header->sizeofcmds>file.length-sizeof(*header)) return NULL;
    size_t cursor=sizeof(*header),end=cursor+header->sizeofcmds;
    const struct symtab_command *table=NULL;uint64_t text_start=0,text_size=0;
    for(uint32_t i=0;i<header->ncmds;i++) {
        if(cursor>end || end-cursor<sizeof(struct load_command))return NULL;
        const struct load_command *command=(const void *)(bytes+cursor);
        if(command->cmdsize<sizeof(*command) || command->cmdsize>end-cursor)return NULL;
        if(command->cmd==LC_SYMTAB && command->cmdsize>=sizeof(struct symtab_command))table=(const void *)command;
        if(command->cmd==LC_SEGMENT_64 && command->cmdsize>=sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment=(const void *)command;
            if(!strncmp(segment->segname,"__TEXT",16) && (segment->initprot&VM_PROT_EXECUTE)) {
                text_start=segment->vmaddr;text_size=segment->vmsize;
            }
        }
        cursor+=command->cmdsize;
    }
    if(!table || !text_size || table->symoff>file.length || table->stroff>file.length ||
       table->strsize>file.length-table->stroff || table->nsyms>(file.length-table->symoff)/sizeof(struct nlist_64))return NULL;
    const struct nlist_64 *symbols=(const void *)(bytes+table->symoff);
    const char *strings=(const void *)(bytes+table->stroff);
    for(uint32_t i=0;i<table->nsyms;i++) {
        uint32_t index=symbols[i].n_un.n_strx;uint64_t value=symbols[i].n_value;
        if((symbols[i].n_type&N_STAB) || (symbols[i].n_type&N_TYPE)!=N_SECT || index>=table->strsize ||
           value<text_start || value-text_start>=text_size)continue;
        const char *symbol=strings+index;
        if(!memchr(symbol,0,table->strsize-index))return NULL;
        if(!strcmp(symbol,name))return (void *)(value+slide);
    }
    return NULL;
}

// Shared by the account startup bridge. Resolve only existing executable symbols
// from the exact owned SDK already loaded by dyld, never guessed byte offsets.
void *vxmac_native_sdk_function(const char *name) {
    static NSData *file;static intptr_t slide;
    if(!file)for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char *path=_dyld_get_image_name(i);
        if(path && [@(path).lastPathComponent isEqual:@"libREDGalaxy64.dylib"]) {
            file=[NSData dataWithContentsOfFile:@(path) options:NSDataReadingMappedIfSafe error:NULL];
            slide=_dyld_get_image_vmaddr_slide(i);break;
        }
    }
    return sdk_function(file,slide,name);
}

static size_t native_write(char *bytes,size_t size,size_t count,void *context) {
    NSMutableData *data=(__bridge NSMutableData *)context;
    if(size && count>SIZE_MAX/size)return 0;size_t n=size*count;
    if(n>256*1024-data.length)return 0;[data appendBytes:bytes length:n];return n;
}

NSDictionary *vxmac_native_sdk_public_probe(void) {
    NSData *file=nil;intptr_t slide=0;
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char *path=_dyld_get_image_name(i);
        if(path && [@(path).lastPathComponent isEqual:@"libREDGalaxy64.dylib"]) {
            file=[NSData dataWithContentsOfFile:@(path) options:NSDataReadingMappedIfSafe error:NULL];
            slide=_dyld_get_image_vmaddr_slide(i);break;
        }
    }
    int (*initialize)(long)=sdk_function(file,slide,"_curl_global_init");
    void *(*create)(void)=sdk_function(file,slide,"_curl_easy_init");
    int (*set)(void *,int,...)=sdk_function(file,slide,"_curl_easy_setopt");
    int (*perform)(void *)=sdk_function(file,slide,"_curl_easy_perform");
    int (*info)(void *,int,...)=sdk_function(file,slide,"_curl_easy_getinfo");
    void (*destroy)(void *)=sdk_function(file,slide,"_curl_easy_cleanup");
    void (*cleanup)(void)=sdk_function(file,slide,"_curl_global_cleanup");
    int (*backend)(void)=sdk_function(file,slide,"_Curl_ssl_backend");
    BOOL resolved=initialize && create && set && perform && info && destroy && cleanup && backend;
    int code=2,backend_id=0;long status=0;BOOL valid=NO;char error[256]={0};
    if(resolved && !(code=initialize(3L))) {
        backend_id=backend();void *handle=create();NSMutableData *data=[NSMutableData new];
        if(handle) {
            code=set(handle,VX_CURLOPT_URL,"https://accounts.cdprojektred.com/realms/cdp/.well-known/openid-configuration");
            if(!code)code=set(handle,VX_CURLOPT_WRITEFUNCTION,native_write);
            if(!code)code=set(handle,VX_CURLOPT_WRITEDATA,(__bridge void *)data);
            if(!code)code=set(handle,VX_CURLOPT_ERRORBUFFER,error);
            if(!code)code=set(handle,VX_CURLOPT_TIMEOUT,12L);
            if(!code)code=set(handle,VX_CURLOPT_NOSIGNAL,1L);
            if(!code)code=perform(handle);
            info(handle,VX_CURLINFO_RESPONSE_CODE,&status);destroy(handle);
            NSDictionary *body=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
            valid=[body isKindOfClass:NSDictionary.class] && [body[@"issuer"] isEqual:@"https://accounts.cdprojektred.com/realms/cdp"];
        } else code=27;
        cleanup();
    }
    NSString *message=[[NSString alloc] initWithBytes:error length:strnlen(error,sizeof(error)) encoding:NSUTF8StringEncoding]?:@"";
    NSMutableArray *categories=[NSMutableArray new];
    for(NSString *word in @[@"certificate",@"CAfile",@"CApath",@"resolve",@"connect",@"timed out",@"SSL",@"HTTP"])
        if([message rangeOfString:word options:NSCaseInsensitiveSearch].location!=NSNotFound)[categories addObject:word];
    return @{@"symbols_resolved":@(resolved),@"transport_result":@(code),@"http_status":@(status),
             @"tls_backend_id":@(backend_id),@"issuer_valid":@(valid),@"error_categories":categories,
             @"authenticated":@NO,@"save_sync_verified":@NO};
}
