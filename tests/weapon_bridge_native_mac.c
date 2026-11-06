// SPDX-License-Identifier: MIT
// Optional local integration test against the player's header-only macOS copy
// of the 2.5.0 image. Never calls its entry point or opens a save/game session.
#include "../app/Sources/weapon_bridge.c"
#include <assert.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

static const char *string_text(const vm_string *s) {
    const char *p = (const char *)s->text;
    if (s->size_flags >> 30) memcpy(&p, s->text, sizeof p);
    return p;
}

static void literal_operand(void *object, void *frame, void *result, const void *type) {
    (void)object; (void)type;
    const unsigned char **pc = frame;
    memcpy(result, *pc, 4);
    *pc += 4;
}

static void call(script_opcode handler, int value, const char *expected) {
    unsigned char code[6] = {0x06,0,0,0,0,0x26}, frame[0x70] = {0};
    memcpy(code + 1, &value, 4);
    *(const unsigned char **)frame = code;
    vm_string result;
    string_init(&result, "previous result");
    handler(NULL, frame, &result, NULL);
    assert(*(const unsigned char **)frame == code + 6 && frame[0x62] == 1);
    assert(!strcmp(string_text(&result), expected));
    printf("native VM returned: %s\n", string_text(&result));
    string_free(&result);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(dlopen(argv[1], RTLD_NOW | RTLD_LOCAL));
    const struct mach_header *image = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (!strcmp(_dyld_get_image_name(i), argv[1])) image = _dyld_get_image_header(i);
    assert(image);
    setenv("VXMAC_WEAPON_BRIDGE", "1", 1);
    setenv("VXMAC_WEAPON_COMMANDS", "1", 1);
    vx_weapon_bridge_prepare(image);
    const unsigned char *base = atomic_load(&game_base);
    assert(base);
    script_opcode *dispatch = (script_opcode *)(base + VM_DISPATCH);
    // The game initializes VM opcodes after its entry point. Supply just the
    // literal operand fixture; string construction/assignment use real game code.
    script_opcode previous = dispatch[0x06];
    dispatch[0x06] = literal_operand;
    call(original_poll, 42, "42");
    call(poll_handler, 42, "42");
    call(poll_handler, POLL_LITERAL, "VXH2|idle");
    pthread_mutex_lock(&snapshot_lock);
    equipped = (vx_weapon_snapshot){ .known = 1, .ranged = 1, .entity = 9, .record = 42, .generation = 1 };
    pending.serial = 1; pending.entity = 9; pending.record = 42;
    pending.generation = 1; pending.kind = VX_WEAPON_INSERT; pending.sent_at = bridge_now();
    pthread_mutex_unlock(&snapshot_lock);
    call(poll_handler, POLL_LITERAL, "VXH2|9|42|1|2");
    // Real entity/record tokens exceed the small-string inline buffer.
    pending.entity = UINT64_MAX; pending.record = UINT64_C(4294967297);
    pending.serial = UINT64_C(123456789012345);
    call(poll_handler, POLL_LITERAL, "VXH2|18446744073709551615|4294967297|123456789012345|2");
    dispatch[0x06] = previous;
    puts("native handler/string ABI with a fixture operand decoder: ok");
}
