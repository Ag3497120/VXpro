// SPDX-License-Identifier: MIT
#include "../vr/hand_melee.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    hand_melee s={0};float h[3]={0,1.7f,0},p[3]={.2f,1.3f,-.4f};double t=1;
    assert(!hand_melee_update(&s,42,1,p,h,t));
    for(int i=0;i<120;i++) {t+=1./60;h[0]+=.015f;p[0]+=.015f;assert(!hand_melee_update(&s,42,1,p,h,t));}
    int hits=0;for(int i=0;i<10;i++) {t+=1./60;p[2]-=.04f;hits+=hand_melee_update(&s,42,1,p,h,t);}
    assert(hits==1);
    for(int i=0;i<60;i++){t+=1./60;assert(!hand_melee_update(&s,42,1,p,h,t));}
    hits=0;for(int i=0;i<10;i++){t+=1./60;p[2]+=.04f;hits+=hand_melee_update(&s,42,1,p,h,t);}assert(hits==1);
    p[0]+=1;t+=1./60;assert(!hand_melee_update(&s,42,1,p,h,t));
    t+=.3;assert(!hand_melee_update(&s,42,1,p,h,t));
    p[0]+=.05;t+=1./60;assert(!hand_melee_update(&s,43,1,p,h,t));
    assert(!hand_melee_update(&s,43,0,p,h,t) && !s.sampled);
    assert(!hand_melee_update(&s,0,1,p,h,t));
    puts("melee strokes: one attack per swing, rearm, head translation rejection, jumps/loss/equip/menu/mode reset: ok");
}
