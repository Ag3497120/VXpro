// SPDX-License-Identifier: MIT
#define main old_hand_suite
#include "hand_weapon_mac.c"
#undef main
#include <assert.h>
int main(void) {
    for(int wrong=0;wrong<2;wrong++) {
        reset(0,0);w.manual_mag=1;w.state=HW_HOLD_NEW;w.well_contact_model=3;
        w.magazine_grab_model=wrong ? 4:3;
        memcpy(w.well_contact,WELL,sizeof WELL);memcpy(H[off_h].palm,WELL,sizeof WELL);
        H[off_h].palm[0]+=.17f;hand_weapon_set_controller(&w,HW_BTN_L_TRIG,t);
        step();
        assert(w.state==(wrong?HW_HOLD_NEW:HW_IN_NO_ROUND));
        assert(seen[2]==(wrong?0:1) && !seen[4]);
    }
    puts("magnet capture: 17 cm from actual well seats held magazine, rejects wrong model, leaves pistol unchambered: ok");
}
