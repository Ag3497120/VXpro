// SPDX-License-Identifier: MIT
#include "../vr/room_view.h"
#include "../vr/weapon_contact.h"
#include <assert.h>
#include <stdio.h>
static void close3(const float a[3],const float b[3]) { for(int i=0;i<3;i++) assert(fabsf(a[i]-b[i])<1e-5); }
int main(void) {
    float head[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,1.6,0,1},view[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1},o[3];
    vx_room_view s={0};vx_room_view_update(&s,head,1,0,1);
    head[12]=.2;head[13]+= .1;head[14]=-.3;vx_room_view_update(&s,head,1,0,1);
    vx_room_view_offset(&s,view,o);close3(o,(float[3]){-.2,-.1,.3});
    // Current view rotation, not Euler pitch or a game-camera velocity, controls the basis.
    view[0]=view[10]=0;view[2]=-1;view[8]=1;vx_room_view_offset(&s,view,o);close3(o,(float[3]){.3,-.1,.2});
    float anchor[3];memcpy(anchor,s.anchor,sizeof anchor);
    for(int i=0;i<30;i++) vx_room_view_update(&s,head,1,0,1);
    close3(anchor,s.anchor); // not reset on every captured game frame
    head[12]=9;vx_room_view_update(&s,head,0,0,1);close3(anchor,s.anchor);
    vx_room_view_update(&s,head,1,0,1);vx_room_view_offset(&s,view,o);close3(o,(float[3]){0});
    head[12]+=.1;vx_room_view_update(&s,head,1,0,2);vx_room_view_offset(&s,view,o);close3(o,(float[3]){0});
    head[14]+=.2;vx_room_view_update(&s,head,1,1,2);vx_room_view_offset(&s,view,o);close3(o,(float[3]){0});
    float lo[3]={-.1,-.1,-.1},hi[3]={.1,.1,.1};
    assert(!vx_weapon_box_contact(NULL,(float[3]){.2,0,0},lo,hi,o));close3(o,(float[3]){.2,0,0});
    assert(vx_weapon_box_contact((float[3]){-.2,0,0},(float[3]){.2,0,0},lo,hi,o));assert(o[0]<-.1);
    assert(vx_weapon_box_contact((float[3]){.2,0,0},(float[3]){-.2,0,0},lo,hi,o));assert(o[0]>.1);
    assert(vx_weapon_box_contact((float[3]){0,0,.2},(float[3]){0,0,0},lo,hi,o));assert(o[2]>.1);
    assert(!vx_weapon_box_contact((float[3]){.2,.2,0},(float[3]){-.2,.2,0},lo,hi,o));
    assert(vx_weapon_box_contact(NULL,(float[3]){0,.09,0},lo,hi,o));assert(o[1]>.1);
    assert(!vx_weapon_box_contact((float[3]){.101,0,0},(float[3]){.3,0,0},lo,hi,o));
    puts("room view: metre displacement, rotation, hold, recenter, seated transition; weapon contact: sweep, tangential release: ok");
}
