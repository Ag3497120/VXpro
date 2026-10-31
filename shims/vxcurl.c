// libvxcurl: the libcurl calls the game makes (16: easy and multi interfaces, slists), offline. visionOS has no
// libcurl; every transfer ends at once with CURLE_COULDNT_RESOLVE_HOST (6), what the Mac build reports with no
// network (testapp: "curl perform=6"), so the game's own offline paths run. No network code, nothing downloaded.
// (A real transfer would need a libcurl built for visionOS: not done, see docs/DESIGN.md.)
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "vxmac.h"

typedef struct vx_easy { char url[512]; void *priv; struct vx_easy *next_done; int done, in_multi; } vx_easy;
typedef struct curl_slist { char *data; struct curl_slist *next; } curl_slist;
typedef struct { int msg; vx_easy *easy_handle; union { void *whatever; int result; } data; } vx_msg;
typedef struct { vx_easy *h[256]; int n; vx_msg msg; int read_at; } vx_multi;
enum { E_OK = 0, E_COULDNT_RESOLVE_HOST = 6, E_UNKNOWN_OPTION = 48, M_OK = 0, MSG_DONE = 1,
       OPT_URL = 10002, OPT_PRIVATE = 10103, INFO_RESPONSE_CODE = 0x200002, INFO_PRIVATE = 0x100015, INFO_EFFECTIVE_URL = 0x100001 };

int curl_global_init_mem(long flags, void *m, void *f, void *r, void *s, void *c) { (void)flags; (void)m; (void)f; (void)r; (void)s; (void)c; vxmac_log("curl: offline (libvxcurl)"); return E_OK; }
int curl_global_init(long flags) { return curl_global_init_mem(flags, 0, 0, 0, 0, 0); }
void curl_global_cleanup(void) {}
void *curl_easy_init(void) { return calloc(1, sizeof(vx_easy)); }
void curl_easy_cleanup(void *h) { free(h); }
int curl_easy_setopt(void *hp, int opt, ...) {
    vx_easy *h = hp; va_list ap; va_start(ap, opt);
    if (opt == OPT_URL) { const char *u = va_arg(ap, const char *); snprintf(h->url, sizeof h->url, "%s", u ? u : ""); }
    else if (opt == OPT_PRIVATE) h->priv = va_arg(ap, void *);
    va_end(ap);
    return E_OK;
}
int curl_easy_perform(void *hp) { vx_easy *h = hp; vxmac_log("curl: %s: offline", h ? h->url : "?"); return E_COULDNT_RESOLVE_HOST; }
int curl_easy_getinfo(void *hp, int info, ...) {
    vx_easy *h = hp; va_list ap; va_start(ap, info);
    void *out = va_arg(ap, void *);
    va_end(ap);
    if (!out) return E_OK;
    if (info == INFO_RESPONSE_CODE) *(long *)out = 0;
    else if (info == INFO_PRIVATE) *(void **)out = h->priv;
    else if (info == INFO_EFFECTIVE_URL) *(const char **)out = h->url;
    else if ((info & 0xf00000) == 0x200000) *(long *)out = 0;
    else if ((info & 0xf00000) == 0x300000) *(double *)out = 0;
    else *(void **)out = NULL;
    return E_OK;
}
const char *curl_easy_strerror(int e) { return e == E_OK ? "No error" : e == E_COULDNT_RESOLVE_HOST ? "Couldn't resolve host name" : "Error (offline)"; }
void *curl_multi_init(void) { return calloc(1, sizeof(vx_multi)); }
int curl_multi_cleanup(void *m) { free(m); return M_OK; }
int curl_multi_add_handle(void *mp, void *e) {
    vx_multi *m = mp; if (m->n < 256) { m->h[m->n++] = e; ((vx_easy *)e)->done = 0; ((vx_easy *)e)->in_multi = 1; } return M_OK;
}
int curl_multi_remove_handle(void *mp, void *e) {
    vx_multi *m = mp;
    for (int i = 0; i < m->n; i++) if (m->h[i] == e) { m->h[i] = m->h[--m->n]; if (m->read_at > m->n) m->read_at = m->n; break; }
    return M_OK;
}
int curl_multi_perform(void *mp, int *running) {
    vx_multi *m = mp;
    for (int i = 0; i < m->n; i++) if (!m->h[i]->done) { m->h[i]->done = 1; vxmac_log("curl: %s: offline", m->h[i]->url); }
    if (running) *running = 0;
    return M_OK;
}
void *curl_multi_info_read(void *mp, int *left) {
    vx_multi *m = mp;
    for (int i = 0; i < m->n; i++) if (m->h[i]->done == 1) {
        m->h[i]->done = 2;
        m->msg.msg = MSG_DONE; m->msg.easy_handle = m->h[i]; m->msg.data.result = E_COULDNT_RESOLVE_HOST;
        int l = 0; for (int k = 0; k < m->n; k++) l += m->h[k]->done == 1;
        if (left) *left = l;
        return &m->msg;
    }
    if (left) *left = 0;
    return NULL;
}
curl_slist *curl_slist_append(curl_slist *list, const char *s) {
    curl_slist *n = calloc(1, sizeof *n); if (!n) return NULL;
    n->data = strdup(s ? s : "");
    if (!list) return n;
    curl_slist *t = list; while (t->next) t = t->next; t->next = n; return list;
}
void curl_slist_free_all(curl_slist *l) { while (l) { curl_slist *n = l->next; free(l->data); free(l); l = n; } }
