// SPDX-License-Identifier: MIT
#pragma once
// One toggle per hold, including two separately connected Joy-Cons. Both
// buttons must be released before another toggle. Defer single-button menu
// actions until release, so the first half of a chord cannot open a menu.
typedef struct { double since; int held,fired; unsigned seen,previous,taps; int combined; } vx_control_chord;
static inline int vx_control_chord_update(vx_control_chord *s,int plus,int minus,double now) {
    unsigned down=(plus?1u:0)|(minus?2u:0);
    s->taps=0;s->seen|=down;
    if(down==3)s->combined=1;
    if(!down) {
        if(!s->combined)s->taps=s->seen;
        s->since=0;s->held=s->fired=s->combined=0;s->seen=s->previous=0;return 0;
    }
    s->previous=down;
    if(!(plus && minus)) {s->held=0;s->since=0;return 0;}
    if(!s->held) {s->held=1;s->since=now;}
    if(!s->fired && now>=s->since && now-s->since>=1) {s->fired=1;return 1;}
    return 0;
}
