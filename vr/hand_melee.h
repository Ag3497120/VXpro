// SPDX-License-Identifier: MIT
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint64_t weapon;
    int sampled,fast,latched;
    double at,slow_at,fired_at;
    float previous[3],travel;
} hand_melee;

// Recognise a deliberate stroke, not a single tracking jump or the wearer
// walking/leaning. The caller gates this with the game's equipped melee item.
static inline int hand_melee_update(hand_melee *s,uint64_t weapon,int active,
                                     const float palm[3],const float head[3],double now) {
    if(!active || !weapon || !isfinite(now)) {memset(s,0,sizeof *s);return 0;}
    float point[3];for(int i=0;i<3;i++) {
        point[i]=palm[i]-head[i];
        if(!isfinite(point[i])) {memset(s,0,sizeof *s);return 0;}
    }
    double dt=now-s->at;
    if(!s->sampled || s->weapon!=weapon || dt<=0 || dt>.10) {
        *s=(hand_melee){.weapon=weapon,.sampled=1,.at=now,.slow_at=now};
        memcpy(s->previous,point,sizeof point);return 0;
    }
    float length=0;for(int i=0;i<3;i++)length+=(point[i]-s->previous[i])*(point[i]-s->previous[i]);
    length=sqrtf(length);float speed=length/(float)dt;
    memcpy(s->previous,point,sizeof point);s->at=now;
    if(speed>8.f || length>.30f) {s->fast=0;s->travel=0;s->latched=1;s->slow_at=0;return 0;}
    if(speed<.45f) {
        if(!s->slow_at)s->slow_at=now;
        if(now-s->slow_at>=.10) {s->latched=0;s->fast=0;s->travel=0;}
    } else s->slow_at=0;
    if(speed<1.1f) {s->fast=0;s->travel=0;return 0;}
    s->travel+=length;s->fast++;
    if(!s->latched && s->fast>=2 && s->travel>=.10f && (!s->fired_at || now-s->fired_at>=.45)) {
        s->latched=1;s->fired_at=now;return 1;
    }
    return 0;
}
