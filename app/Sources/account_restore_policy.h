// SPDX-License-Identifier: MIT
#ifndef VXMAC_ACCOUNT_RESTORE_POLICY_H
#define VXMAC_ACCOUNT_RESTORE_POLICY_H
typedef struct { int finished,attempted,begun;double started,attempt_time; } VXAccountRestore;
enum { VX_ACCOUNT_WAIT,VX_ACCOUNT_REQUEST,VX_ACCOUNT_ALREADY_SIGNED_IN,VX_ACCOUNT_COMPLETE,VX_ACCOUNT_GIVE_UP };
static inline int vx_account_restore_step(VXAccountRestore *s,double now,int ready,int signed_in) {
    if(s->finished)return VX_ACCOUNT_WAIT;
    if(!s->begun){s->begun=1;s->started=now;}
    if(signed_in) { s->finished=1;return s->attempted?VX_ACCOUNT_COMPLETE:VX_ACCOUNT_ALREADY_SIGNED_IN; }
    if(now-s->started>60 || (s->attempted && now-s->attempt_time>30)) {s->finished=1;return VX_ACCOUNT_GIVE_UP;}
    if(!ready || now-s->started<5 || s->attempted)return VX_ACCOUNT_WAIT;
    s->attempted=1;s->attempt_time=now;return VX_ACCOUNT_REQUEST;
}
#endif
