// libvxsec: Security re-exported, and the four calls visionOS lacks (macOS keychain import/export, identity from a
// certificate, a long description): unimplemented, as their documented error. Nothing here touches a check: the
// callers (GOG Galaxy's TLS client in libREDGalaxy64) get the error the API defines for "not available".
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#define errSecUnimplemented (-4)
CFStringRef SecCertificateCopyLongDescription(CFAllocatorRef a, const void *cert, CFErrorRef *error) { (void)a; (void)cert; if (error) *error = NULL; return NULL; }
int32_t SecIdentityCreateWithCertificate(CFTypeRef keychainOrArray, const void *cert, void **identity) { (void)keychainOrArray; (void)cert; if (identity) *identity = NULL; return errSecUnimplemented; }
int32_t SecItemExport(CFTypeRef items, uint32_t format, uint32_t flags, const void *params, CFDataRef *out) { (void)items; (void)format; (void)flags; (void)params; if (out) *out = NULL; return errSecUnimplemented; }
int32_t SecItemImport(CFDataRef data, CFStringRef name, uint32_t *format, uint32_t *type, uint32_t flags, const void *params, void *keychain, CFArrayRef *out) {
    (void)data; (void)name; (void)format; (void)type; (void)flags; (void)params; (void)keychain; if (out) *out = NULL; return errSecUnimplemented;
}
