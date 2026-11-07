// SPDX-License-Identifier: MIT
#include "../shims/vxframe_pace.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void near(double a, double b) { assert(fabs(a-b) < 1e-8); }
int main(void) {
    vxfp_clock c = {0};
    double now=10;
    near(vxfp_clock_reserve(&c,now,45),now);
    // Fast producers get one deadline per image, independent of CB count.
    for(int i=1;i<=10000;i++) {
        double due=vxfp_clock_reserve(&c,now+.001,45);
        near(due,10+i/45.0);now=due;
    }
    // A slower game adds no wait, and idle time never creates catch-up credits.
    for(int i=0;i<10000;i++) {
        now+=1.0/30;near(vxfp_clock_reserve(&c,now,45),now);
    }
    now+=100;near(vxfp_clock_reserve(&c,now,45),now);
    near(vxfp_clock_reserve(&c,now,45),now+1.0/45);
    // Disable, rate changes and clock resets cannot inherit a stale deadline.
    near(vxfp_clock_reserve(&c,now,0),now);
    near(vxfp_clock_reserve(&c,now,45),now);
    near(vxfp_clock_reserve(&c,now,30),now);
    near(vxfp_clock_reserve(&c,1,30),1);
    vxfp_clock before=c;
    near(vxfp_clock_reserve(&c,NAN,45),0);
    near(vxfp_clock_reserve(&c,-1,45),0);
    assert(c.next==before.next && c.last_now==before.last_now);
    const char *invalid[]={"", "bad", "-1", "14.99", "90.1", "nan", "inf", "1e-999", "1e999", "30junk"};
    near(vxfp_clock_limit(NULL),45);
    for(unsigned i=0;i<sizeof invalid/sizeof *invalid;i++) near(vxfp_clock_limit(invalid[i]),45);
    near(vxfp_clock_limit("0"),0);near(vxfp_clock_limit("15"),15);
    near(vxfp_clock_limit("45"),45);near(vxfp_clock_limit("90"),90);
    puts("frame clock: 20000 deadlines, idle/resume, reset, disabled and invalid settings passed");
}
