/* SPDX-License-Identifier: MIT
 * Offline pilot rasterizer. Original implementation; no game/runtime linkage.
 * Perspective-correct local surface coordinates identify temporal matches.
 * Near-plane crossings are refused by omission; pilot scenes stay in front.
 */
#include <math.h>
#include <stdint.h>

void teacher_render(int w, int h, int count, float focal,
                    const float *camera, const float *local, const int32_t *ids,
                    const float *colours, const float *light,
                    float *rgb, float *depth, float *points, int32_t *object)
{
    for (int p = 0; p < w*h; ++p) {
        depth[p] = 64.0f; object[p] = -1;
        for (int k = 0; k < 3; ++k) {
            rgb[p*3+k] = 0.07f + 0.02f*k; points[p*3+k] = 0;
        }
    }
    for (int t = 0; t < count; ++t) {
        const float *v = camera+t*9, *l = local+t*9;
        float x[3], y[3];
        if (v[2] <= .1f || v[5] <= .1f || v[8] <= .1f) continue;
        for (int i = 0; i < 3; ++i) {
            x[i] = focal*v[i*3]/v[i*3+2]+w*.5f;
            y[i] = focal*v[i*3+1]/v[i*3+2]+h*.5f;
        }
        float det = (y[1]-y[2])*(x[0]-x[2])+(x[2]-x[1])*(y[0]-y[2]);
        if (!isfinite(det) || fabsf(det) < 1e-8f) continue;
        int xa = (int)fmaxf(0, floorf(fminf(x[0], fminf(x[1], x[2]))));
        int xb = (int)fminf(w-1, ceilf(fmaxf(x[0], fmaxf(x[1], x[2]))));
        int ya = (int)fmaxf(0, floorf(fminf(y[0], fminf(y[1], y[2]))));
        int yb = (int)fminf(h-1, ceilf(fmaxf(y[0], fmaxf(y[1], y[2]))));
        float a[3], b[3], n[3];
        for (int k=0;k<3;++k) { a[k]=v[3+k]-v[k]; b[k]=v[6+k]-v[k]; }
        n[0]=a[1]*b[2]-a[2]*b[1]; n[1]=a[2]*b[0]-a[0]*b[2]; n[2]=a[0]*b[1]-a[1]*b[0];
        float norm=sqrtf(n[0]*n[0]+n[1]*n[1]+n[2]*n[2])+1e-12f;
        float shade=.3f+.7f*fabsf((n[0]*light[0]+n[1]*light[1]+n[2]*light[2])/norm);
        for (int py=ya;py<=yb;++py) for (int px=xa;px<=xb;++px) {
            float u=((y[1]-y[2])*(px+.5f-x[2])+(x[2]-x[1])*(py+.5f-y[2]))/det;
            float q=((y[2]-y[0])*(px+.5f-x[2])+(x[0]-x[2])*(py+.5f-y[2]))/det;
            float r=1-u-q;
            if (u < -1e-6f || q < -1e-6f || r < -1e-6f) continue;
            float z=1/(u/v[2]+q/v[5]+r/v[8]);
            int p=py*w+px;
            if (z >= depth[p]) continue;
            depth[p]=z; object[p]=ids[t];
            float uv[3]={u*z/v[2],q*z/v[5],r*z/v[8]};
            for (int k=0;k<3;++k)
                points[p*3+k]=uv[0]*l[k]+uv[1]*l[3+k]+uv[2]*l[6+k];
            int check=(int)floorf(points[p*3]*9)+(int)floorf(points[p*3+1]*9)+(int)floorf(points[p*3+2]*9);
            float pattern=(check&1) ? .7f : 1;
            for (int k=0;k<3;++k) rgb[p*3+k]=colours[t*3+k]*shade*pattern;
        }
    }
}
