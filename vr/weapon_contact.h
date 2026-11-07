// SPDX-License-Identifier: MIT
// Visual palm contact against a gun-local box, expanded by the palm radius.
#pragma once
#include <math.h>
#include <string.h>
static inline int vx_weapon_box_contact(const float prev[3], const float p[3],
                                       const float lo[3], const float hi[3], float out[3]) {
    memcpy(out,p,3*sizeof(float));
    int inside=1;
    for(int i=0;i<3;i++) { if(!isfinite(p[i])) return 0; if(p[i]<lo[i] || p[i]>hi[i]) inside=0; }
    // Sweep from the last displayed contact, so fast motion cannot pass through.
    float enter=0,exit=1; int face=-1; float side=0;
    if(prev) {
        for(int i=0;i<3;i++) {
            float d=p[i]-prev[i];
            if(fabsf(d)<1e-7f) { if(prev[i]<lo[i] || prev[i]>hi[i]) { exit=-1; break; } }
            else {
                float a=(lo[i]-prev[i])/d,b=(hi[i]-prev[i])/d,wall=lo[i]-.001f;
                if(a>b) { float t=a;a=b;b=t;wall=hi[i]+.001f; }
                if(a>=enter) { enter=a;face=i;side=wall; }
                exit=fminf(exit,b);
            }
        }
        if(face>=0 && enter>=0 && enter<=1 && enter<=exit) {
            // Move tangentially freely rather than sticking the wrist to one point.
            int within=1;for(int i=0;i<3;i++) if(i!=face && (p[i]<lo[i] || p[i]>hi[i])) within=0;
            if(within) { out[face]=side;return 1; }
        }
    }
    if(!inside) return 0;
    int nearest=0;float distance=INFINITY,wall=0;
    for(int i=0;i<3;i++) {
        float a=p[i]-lo[i],b=hi[i]-p[i];
        if(a<distance) { distance=a;nearest=i;wall=lo[i]-.001f; }
        if(b<distance) { distance=b;nearest=i;wall=hi[i]+.001f; }
    }
    out[nearest]=wall;return 1;
}
