// SPDX-License-Identifier: MIT
#include "../vr/frame_pipeline.h"
#include <assert.h>
#include <stdio.h>

static vxfp_ticket ready(vxfp_pipeline *p,uint64_t seq,double t) {
    vxfp_ticket w;assert(vxfp_acquire(p,seq,t,&w));assert(vxfp_process(p,w));
    assert(vxfp_complete(p,w,t+.001,1));return w;
}
int main(void) {
    assert(VXFP_SLOTS==3 || VXFP_SLOTS==4);
    vxfp_pipeline p;vxfp_ticket shown,a,b,c,d;vxfp_reason why;
    size_t bytes=0,need=100*VXFP_SLOTS+128;
    assert(!vxfp_memory_plan(100,64,2,need-1,&bytes));
    assert(vxfp_memory_plan(100,64,2,need,&bytes) && bytes==need);
    assert(!vxfp_memory_plan(SIZE_MAX/VXFP_SLOTS,100,2,SIZE_MAX,&bytes));
    assert(vxfp_init(&p,0,.5));a=ready(&p,1,1);
    assert(vxfp_select(&p,1.01,0,&shown,&why) && shown.sequence==1);
    b=ready(&p,2,1.02); // Latest complete image must remain available while the display still reads #1.
    assert(vxfp_acquire(&p,3,1.03,&c));assert(vxfp_process(&p,c));
    int fourth=vxfp_acquire(&p,4,1.04,&d);
    assert(fourth==(VXFP_SLOTS==4));
    if(fourth) assert(vxfp_process(&p,d));
    else assert(p.capacity_drops==1 && p.capacity_busy_drops==0);
    assert(p.slots[a.slot].readers==1 && p.slots[a.slot].sequence==1);
    assert(p.slots[b.slot].state==VXFP_READY && p.slots[b.slot].sequence==2);
    vxfp_ticket newer;
    assert(vxfp_select(&p,1.045,0,&newer,&why) && newer.sequence==2);
    assert(vxfp_release(&p,newer));
    assert(vxfp_release(&p,shown));assert(!vxfp_release(&p,shown));
    if(fourth) { assert(vxfp_complete(&p,d,1.05,1));assert(vxfp_select(&p,1.051,0,&newer,&why) && newer.sequence==4);assert(vxfp_release(&p,newer)); }
    assert(vxfp_complete(&p,c,1.06,1));
    assert(vxfp_select(&p,1.07,0,&newer,&why) && newer.sequence==(fourth ? 4 : 3));
    assert(vxfp_release(&p,newer));

    // Delayed GPU readers, failures and reverse completion order must never expose an unfinished or replaced image.
    assert(vxfp_init(&p,0,.5));
    vxfp_ticket leases[VXFP_READERS]={0};unsigned born[VXFP_READERS]={0};
    uint64_t seq=0,displayed=0;unsigned checked=0;
    for(unsigned tick=1;tick<=100000;tick++) {
        double now=tick*.001;
        for(int i=0;i<VXFP_READERS;i++) if(leases[i].reader && tick-born[i]>=3) {
            assert(vxfp_release(&p,leases[i]));leases[i].reader=0;
        }
        for(int i=VXFP_SLOTS-1;i>=0;i--) {
            vxfp_slot *s=&p.slots[i];
            if(s->state==VXFP_PROCESSING && now-s->content_time>=.003+(s->sequence%7)*.001) {
                vxfp_ticket t={.slot=i,.sequence=s->sequence,.generation=s->generation};
                assert(vxfp_complete(&p,t,now,s->sequence%23!=0));
            }
        }
        if(!(tick%2)) {
            vxfp_slot previous[VXFP_SLOTS];for(int i=0;i<VXFP_SLOTS;i++) previous[i]=p.slots[i];
            vxfp_ticket w;if(vxfp_acquire(&p,++seq,now,&w)) assert(vxfp_process(&p,w));
            for(int i=0;i<VXFP_SLOTS;i++) if(previous[i].readers) {
                assert(p.slots[i].state==VXFP_READY && p.slots[i].generation==previous[i].generation && p.slots[i].sequence==previous[i].sequence);
            }
        }
        int free=-1;for(int i=0;i<VXFP_READERS;i++) if(!leases[i].reader) {free=i;break;}
        assert(free>=0);
        if(vxfp_select(&p,now,0,&shown,&why)) {
            assert(shown.sequence>=displayed && p.slots[shown.slot].state==VXFP_READY);
            assert(p.slots[shown.slot].ready_time<=now && p.slots[shown.slot].content_time<=now);
            displayed=shown.sequence;leases[free]=shown;born[free]=tick;checked++;
        }
    }
    assert(checked>99000 && p.failed && p.capacity_busy_drops<=p.capacity_drops);
    for(int i=0;i<VXFP_READERS;i++) if(leases[i].reader) assert(vxfp_release(&p,leases[i]));
    printf("slots=%d: two producers plus displayed/latest handoff; %u monotonic selections, no live-reader overwrite; synthetic drops=%llu busy=%llu\n",
        VXFP_SLOTS,checked,(unsigned long long)p.capacity_drops,(unsigned long long)p.capacity_busy_drops);
    return 0;
}
