// SPDX-License-Identifier: MIT
#include "../app/Sources/weapon_bridge.c"
#include <assert.h>
#include <sys/mman.h>

static void report(const char *s) { read_report(s, strlen(s)); }

int main(void) {
    // Allocate the data pages sparsely and exercise the real version and slot checks.
    size_t size = REPORT_FUNCTION + 4096;
    void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(memory != MAP_FAILED);
    unsigned char *base = memory;
    struct mach_header_64 *header = memory;
    header->magic = MH_MAGIC_64;
    header->ncmds = 1;
    header->sizeofcmds = sizeof(struct uuid_command);
    struct uuid_command *uuid = (struct uuid_command *)(header + 1);
    uuid->cmd = LC_UUID;
    uuid->cmdsize = sizeof *uuid;
    assert(!setenv("VXMAC_WEAPON_BRIDGE", "1", 1));
    vx_weapon_bridge_prepare((struct mach_header *)header);
    vx_weapon_bridge_poll();
    assert(!atomic_load(&game_base) && !atomic_load(&attached));

    memcpy(uuid->uuid, game_uuid, sizeof game_uuid);
    vx_weapon_bridge_prepare((struct mach_header *)header);
    vx_weapon_bridge_poll();
    assert(!atomic_load(&attached));
    base[REPORT_GUARD] = 1;
    *(uint32_t *)(base + REPORT_FUNCTION + REPORT_INDEX) = FIRST_NATIVE + 2;
    *(uint32_t *)(base + VM_NATIVE_COUNT) = 3;
    script_opcode *slot = (script_opcode *)(base + VM_DISPATCH) + FIRST_NATIVE + 2;
    vx_weapon_bridge_poll();
    assert(!atomic_load(&attached) && !*slot);
    *slot = (script_opcode)(base + REPORT_HANDLER);
    vx_weapon_bridge_poll();
    assert(*slot == report_handler && atomic_load(&attached));

    report("other debug report");
    report("VXW1|E|1|42|1|junk");
    report("VXW1|S|1|42|1|2|3|0|0|nan");
    assert(!vx_weapon_bridge_snapshot().known);
    report("VXW1|E|18446744073709551615|4294967297|1");
    vx_weapon_snapshot a = vx_weapon_bridge_snapshot();
    assert(a.known && a.generation == 1 && a.entity == UINT64_MAX && a.record == UINT64_C(4294967297));
    report("VXW1|S|18446744073709551615|4294967297|1|2|3|0|-1|0");
    a = vx_weapon_bridge_snapshot();
    assert(a.generation == 1 && a.shot_count == 1 && a.muzzle[2] == 3.f && a.forward[1] == -1.f);
    report("VXW1|K|18446744073709551615|4294967297|2");
    a = vx_weapon_bridge_snapshot();
    assert(a.type_known && !a.handgun && !a.reload_known);
    report("VXW1|K|18446744073709551615|4294967297|1|");
    report("VXW1|K|18446744073709551615|4294967297|3");
    assert(!vx_weapon_bridge_snapshot().handgun && vx_weapon_bridge_snapshot().revolver);
    report("VXW1|K|18446744073709551615|4294967297|4");
    assert(vx_weapon_bridge_snapshot().revolver);
    report("VXW1|R|18446744073709551615|4294967297|3|1|0|6|1");
    a=vx_weapon_bridge_snapshot();
    assert(a.revolver && !a.handgun && a.reload_phase==1 && a.capacity==6);
    report("VXW1|R|18446744073709551615|4294967297|2|7|0|30|4");
    a = vx_weapon_bridge_snapshot();
    assert(a.reload_known && !a.handgun && !a.revolver && a.reload_phase == 7 && a.ammo == 0 && a.capacity == 30);
    uint64_t before = a.reload_report;
    report("VXW1|R|18446744073709551615|4294967297|2|0|31|30|4");
    report("VXW1|R|18446744073709551615|4294967297|2|0|30|30|4|");
    report("VXW1|R|18446744073709551615|4294967297|2|9|30|30|4");
    assert(vx_weapon_bridge_snapshot().reload_report == before);
    report("VXW1|R|18446744073709551615|4294967297|2|0|30|30|4");
    a = vx_weapon_bridge_snapshot();
    assert(a.reload_report == before + 1 && a.ammo == 30 && a.reload_phase == 0);
    report("VXW1|R|18446744073709551615|4294967297|1|5|12|12|5");
    a = vx_weapon_bridge_snapshot();
    assert(a.handgun && a.reload_phase == 5 && a.ammo == 12);
    report("VXW1|E|8|11|0");
    assert(vx_weapon_bridge_snapshot().generation == 2 && vx_weapon_bridge_snapshot().shot_count == 0);
    report("VXW1|U");
    assert(vx_weapon_bridge_snapshot().generation == 3 && !vx_weapon_bridge_snapshot().entity);

    // A root context records only its image-relative vtable. Fake entries are
    // deliberately non-functions: this read-only probe must never call them.
    struct segment_command_64 *segment = (void *)((char *)uuid + sizeof *uuid);
    header->ncmds = 2; header->sizeofcmds += sizeof *segment;
    segment->cmd = LC_SEGMENT_64; segment->cmdsize = sizeof *segment;
    segment->vmaddr = UINT64_C(0x100000000); segment->vmsize = size;
    segment->initprot = 5;
    void **vtable = (void **)(base + 0x1000);
    for (int i = 0; i < 8; i++) vtable[i] = base + 0x2000 + i*4;
    void *context = vtable;
    setenv("VXMAC_NATIVE_POSE_PROBE", "1", 1);
    const char *marker = "VXW2|P|player-root";
    pose_context_probe(&context, marker, strlen(marker));
    pose_context_probe((void *)1, "unrecognized", 12);
    vx_weapon_bridge_diagnostic d = vx_weapon_bridge_diagnostics();
    assert(d.attached && !d.commands_ready && d.pose_vtable[2] == 0x1000 && d.pose_observations[2] == 1);
    assert(!d.pose_observations[0] && !d.pose_observations[1] && !d.pose_observations[3]);
    char status[768]; vx_weapon_bridge_status_json(status, sizeof status);
    assert(strstr(status, "\"pose_seen\":[0,0,1,0]") && strstr(status, "\"ready\":0"));
    assert(!munmap(memory, size));
    puts("weapon bridge: refuses other images and native slots; exact equipment identity and shot snapshot: ok");
    return 0;
}
