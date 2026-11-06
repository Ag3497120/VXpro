// SPDX-License-Identifier: MIT
#include "../app/Sources/weapon_bridge.c"
#include <assert.h>
#include <sys/mman.h>

static char answer[128];
static int delegated;
static void init_string(vm_string *s, const char *value) {
    memset(s, 0, sizeof *s);
    strcpy(answer, value);
}
static void assign_string(vm_string *a, const vm_string *b) { (void)a; (void)b; }
static void free_string(vm_string *s) { (void)s; }
static void ordinary(void *o, void *f, void *r, const void *t) {
    (void)o; (void)f; (void)r; (void)t; delegated++;
}
static void report(const char *s) { read_report(s, strlen(s)); }
static void poll_packet(void) {
    unsigned char frame[0x70] = {0}, bytes[6] = {0x06,0,0,0,0,0x26};
    uint32_t literal = POLL_LITERAL;
    memcpy(bytes + 1, &literal, 4);
    *(const unsigned char **)frame = bytes;
    memset(frame + 0x30, 0xff, 16);
    vm_string result = {0};
    poll_handler(NULL, frame, &result, NULL);
    assert(*(const unsigned char **)frame == bytes + 6 && frame[0x62] == 1);
    for (int i = 0x30; i < 0x40; i++) assert(!frame[i]);
}
static void ack(uint64_t serial, int kind, int rejected) {
    char text[128];
    snprintf(text, sizeof text, "VXW2|A|9|42|%llu|%d|%d", (unsigned long long)serial, kind, rejected);
    report(text);
}

int main(void) {
    size_t size = POLL_FUNCTION + 4096;
    unsigned char *base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(base != MAP_FAILED);
    struct mach_header_64 *header = (void *)base;
    header->magic = MH_MAGIC_64; header->ncmds = 1; header->sizeofcmds = sizeof(struct uuid_command);
    struct uuid_command *uuid = (void *)(header + 1);
    uuid->cmd = LC_UUID; uuid->cmdsize = sizeof *uuid;
    assert(!setenv("VXMAC_WEAPON_BRIDGE", "1", 1));
    assert(!setenv("VXMAC_WEAPON_COMMANDS", "1", 1));
    vx_weapon_bridge_prepare((void *)header);
    assert(!vx_weapon_bridge_commands_enabled());
    memcpy(uuid->uuid, game_uuid, sizeof game_uuid);
    vx_weapon_bridge_prepare((void *)header);
    assert(vx_weapon_bridge_commands_enabled() && !vx_weapon_bridge_commands_ready());
    base[REPORT_GUARD] = base[POLL_GUARD] = 1;
    *(uint32_t *)(base + REPORT_FUNCTION + REPORT_INDEX) = FIRST_NATIVE + 1;
    *(uint32_t *)(base + POLL_FUNCTION + POLL_INDEX) = FIRST_NATIVE + 2;
    *(uint32_t *)(base + VM_NATIVE_COUNT) = 3;
    script_opcode *slots = (void *)(base + VM_DISPATCH);
    slots[FIRST_NATIVE + 1] = (script_opcode)(base + REPORT_HANDLER);
    slots[FIRST_NATIVE + 2] = ordinary;
    vx_weapon_bridge_poll();
    assert(atomic_load(&attached) && !atomic_load(&poll_attached));
    assert(slots[FIRST_NATIVE + 2] == ordinary);
    slots[FIRST_NATIVE + 2] = (script_opcode)(base + POLL_HANDLER);
    vx_weapon_bridge_poll();
    assert(slots[FIRST_NATIVE + 2] == poll_handler && atomic_load(&poll_attached));

    original_poll = ordinary;
    string_init = init_string; string_assign = assign_string; string_free = free_string;
    // Ordinary argument expressions must be passed on, without executing or advancing them here.
    unsigned char regular[6] = {0x06,42,0,0,0,0x26}, frame[0x70] = {0};
    *(const unsigned char **)frame = regular;
    poll_handler(NULL, frame, NULL, NULL);
    assert(delegated == 1 && *(const unsigned char **)frame == regular && frame[0x62] == 0);
    uint32_t literal = POLL_LITERAL;
    memcpy(regular + 1, &literal, 4); regular[5] = 0x25;
    poll_handler(NULL, frame, NULL, NULL);
    assert(delegated == 2 && *(const unsigned char **)frame == regular);
    poll_packet(); assert(!strcmp(answer, "VXH2|idle"));
    assert(!vx_weapon_bridge_commands_ready());
    report("VXW1|R|9|42|1|0|12|12|0");
    assert(vx_weapon_bridge_commands_ready());
    uint64_t a = vx_weapon_bridge_command(VX_WEAPON_EJECT);
    assert(a && !vx_weapon_bridge_command(VX_WEAPON_INSERT));
    poll_packet();
    char first[128]; strcpy(first, answer);
    poll_packet(); assert(!strcmp(first, answer));
    assert(vx_weapon_bridge_snapshot().ammo == 12); // Sending never changes the real weapon state.
    report("VXW2|A|8|42|1|1|0");
    report("VXW2|A|9|41|1|1|0");
    ack(a + 1, VX_WEAPON_EJECT, 0); ack(a, VX_WEAPON_INSERT, 0);
    report("VXW2|A|9|42|1|1|0|");
    assert(vx_weapon_bridge_snapshot().command_status == VX_COMMAND_PENDING);
    ack(a, VX_WEAPON_EJECT, 0);
    assert(vx_weapon_bridge_snapshot().command_status == VX_COMMAND_ACCEPTED);
    assert(vx_weapon_bridge_snapshot().ammo == 12 && vx_weapon_bridge_snapshot().reload_phase == 0);
    report("VXW1|R|9|42|1|1|0|12|1");
    uint64_t b = vx_weapon_bridge_command(VX_WEAPON_INSERT);
    assert(b > a);
    ack(a, VX_WEAPON_EJECT, 1); // A delayed old reply cannot reject the next request.
    assert(vx_weapon_bridge_snapshot().command_status == VX_COMMAND_PENDING);
    ack(b, VX_WEAPON_INSERT, 1);
    assert(vx_weapon_bridge_snapshot().command_status == VX_COMMAND_REJECTED);

    uint64_t c = vx_weapon_bridge_command(VX_WEAPON_INSERT);
    assert(c > b);
    report("VXW1|R|10|43|1|0|8|8|0");
    ack(c, VX_WEAPON_INSERT, 0);
    assert(vx_weapon_bridge_snapshot().entity == 10 && vx_weapon_bridge_snapshot().command_status == 0);
    poll_packet(); assert(!strcmp(answer, "VXH2|idle"));
    assert(vx_weapon_bridge_command(VX_WEAPON_EJECT));
    pending.sent_at -= 3;
    assert(vx_weapon_bridge_snapshot().command_status == VX_COMMAND_TIMEOUT);
    poll_packet(); assert(!strcmp(answer, "VXH2|idle"));
    poll_seen -= 1;
    assert(!vx_weapon_bridge_commands_ready() && !vx_weapon_bridge_command(VX_WEAPON_EJECT));
    report("VXW1|U"); poll_packet();
    assert(!vx_weapon_bridge_commands_ready());
    munmap(base, size);
    puts("weapon commands: VM forwarding, retries, acknowledgement, weapon switch and timeout: ok");
}
