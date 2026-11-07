// Physical head displacement, independent of the game's per-frame camera pose.
#pragma once
#include <math.h>
#include <string.h>
typedef struct { float anchor[3], last[3]; int valid, mode; } vx_room_view;
static inline void vx_room_view_update(vx_room_view *s, const float head[16], int tracked, int reset, int mode) {
    if (!tracked) return;
    for (int i=0;i<3;i++) if (!isfinite(head[12+i])) return;
    float jump=0;
    if (s->valid) for(int i=0;i<3;i++) jump+=(head[12+i]-s->last[i])*(head[12+i]-s->last[i]);
    // A tracking-origin reset is not a physical step. Recenter also seats the new viewpoint.
    if (!s->valid || reset || mode!=s->mode || jump>1.f) memcpy(s->anchor,head+12,sizeof s->anchor);
    memcpy(s->last,head+12,sizeof s->last); s->valid=1; s->mode=mode;
}
static inline void vx_room_view_offset(const vx_room_view *s, const float view[16], float out[3]) {
    for(int r=0;r<3;r++) {
        out[r]=0;
        if(s->valid) for(int c=0;c<3;c++) out[r]+=view[c*4+r]*(s->anchor[c]-s->last[c]);
    }
}
