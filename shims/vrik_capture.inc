// SPDX-License-Identifier: MIT
// Opt-in numeric replay capture. Never copy geometry or full GPU arenas, and
// never write a source matrix. At most 16 files and one serialization in flight.
static NSArray *vrik_capture_floats(const float *values, unsigned count) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned i=0;i<count;i++) {
        if (!isfinite(values[i])) return nil;
        [result addObject:@(values[i])];
    }
    return result;
}

static NSDictionary *vrik_capture_snapshot(void) {
    NSMutableArray *palettes = [NSMutableArray array];
    for (int i=0;i<g_vk.npals && palettes.count<24;i++) {
        const vrik_pal *p=&g_vk.pals[i];
        if (p->frame!=g_vk.capture_frame || p->L==-2 || !p->nb || p->nb>128 || p->nb>p->cap_b) continue;
        aff view=aff_mul(p->view,p->obj);
        if (v3len((float[3]){view.m[3],view.m[7],view.m[11]})>2.f) continue;
        NSArray *original=vrik_capture_floats(p->orig[0].m,p->nb*12);
        NSArray *posed=vrik_capture_floats(p->posed[0].m,p->nb*12);
        if (!original || !posed) continue;
        [palettes addObject:@{@"indices":@(p->count),@"list":@(p->L),@"rig":@(p->rig),
            @"bones":@(p->nb),@"asset":@(p->asset ? p->asset->asset : 0),@"applied":@(p->applied),
            @"object":vrik_capture_floats(p->obj.m,12),@"view":vrik_capture_floats(p->view.m,12),
            @"original":original,@"posed":posed}];
    }
    return @{@"schema":@1,@"frame":@(g_vk.capture_frame),@"epoch":@(g_vk.held.epoch),
        @"owner":@(g_vk.held.owner),@"buttons":@((unsigned)g_vk.weap[5]),
        @"support":@(vrik_support_requested()),@"support_locked":@(g_vk.support_pose.locked),
        @"hand_points":@[@(g_vk.hand_shape[0].count),@(g_vk.hand_shape[1].count)],
        @"trigger_ready":@(g_vk.trigger_source.valid),@"asset_binding":@(g_vk.asset_grip.valid),
        @"frame_uses_asset":@(g_vk.weapon_frame.asset),@"catalog_count":@(VRIK_ASSET_COUNT),
        @"native_grip":vrik_capture_floats(g_vk.native_item_grip.at,9),
        @"support_local":vrik_capture_floats(g_vk.support_local.at,9),
        @"tracked_grip":vrik_capture_floats(g_vk.held.right_grip_view.m,12),@"palettes":palettes};
}

static void vrik_capture_replay(void) {
    if (!vrik_replay_enabled() || g_vk.held.owner!=1 || !g_vk.capture_body || !g_vk.have_h[1] ||
        !g_vk.held.right_grip_valid || g_vk.solve_frame!=g_vk.capture_frame) return;
    static unsigned epoch,mask,records,frame,first_call;
    static double started;
    static _Atomic int pending;
    if (epoch!=g_vk.held.epoch) { epoch=g_vk.held.epoch;mask=0;started=g_vk.held.at; }
    if (frame!=g_vk.capture_frame) { frame=g_vk.capture_frame;first_call=g_vk.call_seq; }
    unsigned bit=vrik_support_requested()?2:1;
    if ((mask&bit) || records>=16 || atomic_load(&pending) || g_vk.held.at-started<1.0 ||
        g_vk.call_seq-first_call<24) return;
    NSDictionary *snapshot=vrik_capture_snapshot();
    if (![snapshot[@"palettes"] count]) return;
    atomic_store(&pending,1);mask|=bit;records++;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
        NSError *error=nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:&error];
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *dir=[docs stringByAppendingPathComponent:@"vx_pose_capture"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error];
        NSString *file=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"e%@-s%@.json",snapshot[@"epoch"],snapshot[@"support"]]];
        BOOL ok=data.length<=1024*1024 && [data writeToFile:file options:NSDataWritingAtomic error:&error];
        vxmac_log("VRIK replay: %s epoch=%u support=%u bytes=%lu",ok?"saved":"failed",
                  [snapshot[@"epoch"] unsignedIntValue],[snapshot[@"support"] unsignedIntValue],(unsigned long)data.length);
        atomic_store(&pending,0);
    }});
}
