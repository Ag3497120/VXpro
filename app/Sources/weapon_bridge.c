// SPDX-License-Identifier: MIT
#include "weapon_bridge.h"
#include <errno.h>
#include <mach-o/loader.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Verified against the local 2.5.0 ARM64 image. The shipping debug report
// handler reads one red::String and discards it. Its dispatch slot is in
// writable game data, so the bridge needs neither a code patch nor a trampoline.
static const unsigned char game_uuid[16] = {
    0x03, 0x8b, 0x50, 0xeb, 0xa6, 0x7e, 0x37, 0x5a, 0xb0, 0x7b, 0x95, 0xf0, 0xc0, 0x46, 0x35, 0x30
};
enum {
    REPORT_GUARD = 0x887b670, REPORT_FUNCTION = 0x887b760,
    REPORT_INDEX = 0xf8, REPORT_HANDLER = 0x1586070,
    VM_DISPATCH = 0x7f5b820, VM_NATIVE_COUNT = 0x7edb818, FIRST_NATIVE = 255,
    STRING_INIT = 0x2cd2c, STRING_FREE = 0x291cc, STRING_ASSIGN = 0x2aaf4,
    REPORT_DEFAULT = 0x74f86a3,
    POLL_GUARD = 0x889d930, POLL_FUNCTION = 0x889f4d8, POLL_INDEX = 0xf0,
    POLL_HANDLER = 0x16771b4, POLL_LITERAL = 0x56584832, MODE_LITERAL = 0x56584d32
};

typedef void (*script_opcode)(void *, void *, void *, const void *);
// Long strings store a pointer in the inline buffer. Use memcpy to read it
// without changing the native alignment of the size field.
typedef struct {
    unsigned char text[20];
    uint32_t size_flags;
    uintptr_t allocator;
} vm_string;
_Static_assert(sizeof(vm_string) == 32 && __builtin_offsetof(vm_string, size_flags) == 20,
               "2.5.0 red::String ABI");

static _Atomic(const unsigned char *) game_base;
static atomic_bool attached;
static atomic_bool commands_enabled, poll_attached;
static atomic_bool tracking_enabled = 1;
static pthread_mutex_t snapshot_lock = PTHREAD_MUTEX_INITIALIZER;
static vx_weapon_snapshot equipped;
static vx_game_context game_context;
static vx_weapon_bridge_diagnostic diagnostic;
static struct {
    uint64_t serial, entity, record, generation;
    int kind;
    double sent_at;
} pending;
static uint64_t next_serial;
static double poll_seen;
static pthread_mutex_t hands_lock = PTHREAD_MUTEX_INITIALIZER;
static vx_weapon_hand_frame hand_frame;
static script_opcode original_poll;
static void (*string_init)(vm_string *, const char *);
static void (*string_assign)(vm_string *, const vm_string *);
static void (*string_free)(vm_string *);

static double bridge_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

vx_game_context vx_weapon_bridge_context(void) {
    pthread_mutex_lock(&snapshot_lock);
    vx_game_context c = game_context;
    pthread_mutex_unlock(&snapshot_lock);
    double age = bridge_now() - c.received_at;
    c.known = c.known && age >= 0 && age < 1.0;
    age=bridge_now()-c.camera_received_at;
    c.camera_known=c.camera_known && c.known && age>=0 && age<1.0;
    return c;
}

void vx_weapon_bridge_publish_hands(const float head[16], const float wrists[20],
                                    unsigned buttons, double sampled_at) {
    if (!vx_weapon_bridge_commands_enabled()) return;
    vx_weapon_hand_frame next = { .sampled_at = sampled_at, .received_at = bridge_now(),
                                  .buttons = buttons, .valid = isfinite(sampled_at) && sampled_at >= 0 };
    memcpy(next.head, head, sizeof next.head);
    memcpy(next.wrists, wrists, sizeof next.wrists);
    for (int i = 0; i < 16; i++) if (!isfinite(head[i])) next.valid = 0;
    for (int h = 0; h < 2; h++)
        for (int i = 0; i < 10; i++) if (!isfinite(wrists[10*h+i])) next.wrists[10*h] = 0;
    pthread_mutex_lock(&hands_lock);
    next.sequence = hand_frame.sequence + 1;
    hand_frame = next;
    pthread_mutex_unlock(&hands_lock);
}

vx_weapon_hand_frame vx_weapon_bridge_hands(void) {
    pthread_mutex_lock(&hands_lock);
    vx_weapon_hand_frame frame = hand_frame;
    pthread_mutex_unlock(&hands_lock);
    double age = bridge_now() - frame.received_at;
    frame.valid = frame.valid && age >= 0 && age < .25;
    if (!frame.valid) frame.wrists[0] = frame.wrists[10] = 0;
    return frame;
}

int vx_weapon_bridge_commands_enabled(void) { return atomic_load(&commands_enabled); }
int vx_weapon_bridge_tracking(void) { return atomic_load(&tracking_enabled); }
void vx_weapon_bridge_set_tracking(int enabled) {
    pthread_mutex_lock(&snapshot_lock);
    atomic_store(&tracking_enabled,enabled!=0);
    if(!enabled && pending.serial) { pending.serial=0;equipped.command_status=VX_COMMAND_REJECTED; }
    pthread_mutex_unlock(&snapshot_lock);
    if(!enabled) { pthread_mutex_lock(&hands_lock);hand_frame.valid=0;pthread_mutex_unlock(&hands_lock); }
}


static int commands_ready_locked(double now) {
    return atomic_load(&attached) && atomic_load(&poll_attached) &&
           poll_seen > 0 && now >= poll_seen && now - poll_seen < .25 &&
           equipped.known && equipped.entity && equipped.reload_known && equipped.ranged;
}

int vx_weapon_bridge_commands_ready(void) {
    if (!vx_weapon_bridge_commands_enabled()) return 0;
    pthread_mutex_lock(&snapshot_lock);
    int ready = commands_ready_locked(bridge_now());
    pthread_mutex_unlock(&snapshot_lock);
    return ready;
}

vx_weapon_bridge_diagnostic vx_weapon_bridge_diagnostics(void) {
    pthread_mutex_lock(&snapshot_lock);
    vx_weapon_bridge_diagnostic value = diagnostic;
    value.attached = atomic_load(&attached);
    value.commands_ready = commands_ready_locked(bridge_now());
    pthread_mutex_unlock(&snapshot_lock);
    return value;
}

static void expire_command_locked(double now) {
    if (pending.serial && now - pending.sent_at > 2.0) {
        equipped.command_status = VX_COMMAND_TIMEOUT;
        pending.serial = 0;
    }
}

uint64_t vx_weapon_bridge_command(int kind) {
    if (!vx_weapon_bridge_tracking() || !vx_weapon_bridge_commands_enabled() || kind < VX_WEAPON_EJECT || kind > VX_WEAPON_CHAMBER) return 0;
    pthread_mutex_lock(&snapshot_lock);
    double now = bridge_now();
    expire_command_locked(now);
    uint64_t serial = 0;
    if (!pending.serial && commands_ready_locked(now)) {
        serial = ++next_serial;
        pending.serial = serial;
        pending.entity = equipped.entity;
        pending.record = equipped.record;
        pending.generation = equipped.generation;
        pending.kind = kind;
        pending.sent_at = now;
        equipped.command_serial = serial;
        equipped.command_kind = kind;
        equipped.command_status = VX_COMMAND_PENDING;
    }
    pthread_mutex_unlock(&snapshot_lock);
    return serial;
}

static void command_packet(char *out, size_t size) {
    pthread_mutex_lock(&snapshot_lock);
    double now = bridge_now();
    poll_seen = now;
    expire_command_locked(now);
    if (pending.serial && pending.generation == equipped.generation) {
        snprintf(out, size, "VXH2|%llu|%llu|%llu|%d", (unsigned long long)pending.entity,
                 (unsigned long long)pending.record, (unsigned long long)pending.serial, pending.kind);
    } else snprintf(out, size, "VXH2|idle");
    pthread_mutex_unlock(&snapshot_lock);
}

vx_weapon_snapshot vx_weapon_bridge_snapshot(void) {
    if (!atomic_load(&attached)) return (vx_weapon_snapshot){0};
    pthread_mutex_lock(&snapshot_lock);
    expire_command_locked(bridge_now());
    vx_weapon_snapshot copy = equipped;
    pthread_mutex_unlock(&snapshot_lock);
    return copy;
}

void vx_weapon_bridge_status_json(char *out, unsigned size) {
    vx_weapon_snapshot weapon = vx_weapon_bridge_snapshot();
    vx_weapon_bridge_diagnostic status = vx_weapon_bridge_diagnostics();
    vx_weapon_hand_frame hands = vx_weapon_bridge_hands();
    vx_game_context context=vx_weapon_bridge_context();
    snprintf(out, size, "\"weapon_bridge\":{\"attached\":%d,\"ready\":%d,\"entity\":%llu,\"record\":%llu,"
             "\"generation\":%llu,\"phase\":%d,\"ammo\":%u,\"capacity\":%u,\"command\":%llu,\"command_status\":%d,"
             "\"hands\":%llu,\"hands_valid\":%d,\"pose_vtable\":[%llu,%llu,%llu,%llu],\"pose_seen\":[%llu,%llu,%llu,%llu],"
             "\"context\":{\"known\":%d,\"sequence\":%llu,\"mounted\":%d,\"vehicle\":%d,\"scene\":%d,\"menu_known\":%d,\"menu\":%d,\"script_revision\":%u,"
             "\"camera_known\":%d,\"perspective\":%d,\"pitch_ready\":%d,\"fov_owned\":%d,\"native_fov\":%.2f,\"foot_fov\":%.2f}}",
             status.attached, status.commands_ready, (unsigned long long)weapon.entity, (unsigned long long)weapon.record,
             (unsigned long long)weapon.generation, weapon.reload_phase, weapon.ammo, weapon.capacity,
             (unsigned long long)weapon.command_serial, weapon.command_status, (unsigned long long)hands.sequence, hands.valid,
             (unsigned long long)status.pose_vtable[0], (unsigned long long)status.pose_vtable[1],
             (unsigned long long)status.pose_vtable[2], (unsigned long long)status.pose_vtable[3],
             (unsigned long long)status.pose_observations[0], (unsigned long long)status.pose_observations[1],
             (unsigned long long)status.pose_observations[2], (unsigned long long)status.pose_observations[3],
             context.known,(unsigned long long)context.sequence,context.mounted,context.vehicle_mode,
             context.scene_tier,context.menu_known,context.menu_open,context.script_revision,
             context.camera_known,context.vehicle_perspective,context.vehicle_pitch_ready,context.vehicle_fov_owned,context.native_fov,context.foot_fov);
}

static int next_uint(char **cursor, uint64_t *value) {
    if (**cursor < '0' || **cursor > '9') return 0;
    char *end;
    errno = 0;
    *value = strtoull(*cursor, &end, 10);
    if (errno || (*end && *end != '|')) return 0;
    *cursor = *end ? end + 1 : end;
    return 1;
}

static int next_float(char **cursor, float *value, int last) {
    if (!**cursor) return 0;
    char *end;
    errno = 0;
    *value = strtof(*cursor, &end);
    if (errno || end == *cursor || !isfinite(*value) || (last ? *end != 0 : *end != '|')) return 0;
    *cursor = last ? end : end + 1;
    return 1;
}

static void read_report(const char *message, size_t length) {
    if (length > 7 && length < 160 && !memcmp(message, "VXW2|A|", 7) && !memchr(message, 0, length)) {
        char text[160]; memcpy(text, message, length); text[length] = 0;
        char *cursor = text + 7;
        uint64_t values[5];
        for (int i = 0; i < 5; i++) {
            if (i == 4 && strchr(cursor, '|')) return;
            if (!next_uint(&cursor, &values[i])) return;
        }
        if (*cursor || values[4] > 1) return;
        pthread_mutex_lock(&snapshot_lock);
        expire_command_locked(bridge_now());
        if (pending.serial && values[0] == pending.entity && values[1] == pending.record &&
            values[2] == pending.serial && values[3] == (uint64_t)pending.kind &&
            pending.generation == equipped.generation) {
            equipped.command_status = values[4] ? VX_COMMAND_REJECTED : VX_COMMAND_ACCEPTED;
            fprintf(stderr, "vxmac: weapon command serial=%llu kind=%d %s\n",
                    (unsigned long long)pending.serial, pending.kind, values[4] ? "rejected" : "accepted");
            pending.serial = 0;
        }
        pthread_mutex_unlock(&snapshot_lock);
        return;
    }
    if (length < 6 || length >= 256 || memcmp(message, "VXW1|", 5) || memchr(message, 0, length)) return;
    if (message[5] == 'R' || message[5] == 'T')
        fprintf(stderr, "vxmac: script report %.*s\n", (int)length, message);
    static const char ready[] = "VXW1|B|equipment-and-shot";
    if (length == sizeof ready - 1 && !memcmp(message, ready, length)) {
        fprintf(stderr, "vxmac: weapon bridge received the menu handshake\n");
        return;
    }
    char text[256];
    memcpy(text, message, length);
    text[length] = 0;
    char kind = text[5], *cursor = text + 7;
    if (kind == 'V') {
        uint64_t revision;
        if (text[6]!='|' || strchr(cursor,'|') || !next_uint(&cursor,&revision) || *cursor || revision<1 || revision>100) return;
        pthread_mutex_lock(&snapshot_lock);game_context.script_revision=(unsigned)revision;pthread_mutex_unlock(&snapshot_lock);
        return;
    }
    if(kind=='D') {
        uint64_t mode;
        if(text[6]!='|' || strchr(cursor,'|') || !next_uint(&cursor,&mode) || *cursor || mode>1)return;
        pthread_mutex_lock(&snapshot_lock);game_context.control_known=1;game_context.control_tracking=(int)mode;pthread_mutex_unlock(&snapshot_lock);
        return;
    }
    if (kind == 'M') {
        uint64_t open;
        if (text[6] != '|' || strchr(cursor,'|') || !next_uint(&cursor,&open) || *cursor || open>1) return;
        pthread_mutex_lock(&snapshot_lock);
        game_context.menu_known=1; game_context.menu_open=(int)open;
        pthread_mutex_unlock(&snapshot_lock);
        return;
    }
    if(kind=='J') {
        uint64_t v[3];float f[2];
        if(text[6]!='|')return;
        for(int i=0;i<3;i++)if(!next_uint(&cursor,&v[i]))return;
        for(int i=0;i<2;i++)if(!next_float(&cursor,&f[i],i==1))return;
        if(*cursor || v[0]>7 || v[1]>1 || v[2]>1 || f[0]<0 || f[0]>=180 || f[1]<0 || f[1]>=180)return;
        pthread_mutex_lock(&snapshot_lock);
        game_context.camera_known=1;game_context.vehicle_perspective=(int)v[0];
        game_context.vehicle_pitch_ready=(int)v[1];game_context.vehicle_fov_owned=(int)v[2];
        game_context.native_fov=f[0];game_context.foot_fov=f[1];game_context.camera_received_at=bridge_now();
        pthread_mutex_unlock(&snapshot_lock);return;
    }
    if (kind == 'C') {
        uint64_t v[3];
        if (text[6] != '|') return;
        for (int i=0; i<3; i++) if (!next_uint(&cursor,&v[i])) return;
        if (*cursor || v[0]>1 || v[1]>7 || v[2]>6) return;
        pthread_mutex_lock(&snapshot_lock);
        if(game_context.mounted!=(int)v[0] || game_context.vehicle_mode!=(int)v[1])game_context.camera_known=0;
        game_context.known=1; game_context.mounted=(int)v[0]; game_context.vehicle_mode=(int)v[1];
        game_context.scene_tier=(int)v[2]; game_context.sequence++; game_context.received_at=bridge_now();
        pthread_mutex_unlock(&snapshot_lock);
        return;
    }
    uint64_t entity = 0, record = 0, ranged = 0, reload[5] = {0};
    float shot[6] = {0};
    if (kind == 'U') {
        if (length != 6) return;
    } else {
        if ((kind != 'E' && kind != 'S' && kind != 'R' && kind != 'K') || text[6] != '|' ||
            !next_uint(&cursor, &entity) || !entity || !next_uint(&cursor, &record) || !record) return;
        if (kind == 'E') {
            if ((cursor[0] != '0' && cursor[0] != '1') || cursor[1]) return;
            ranged = cursor[0] == '1';
        } else if (kind == 'K') {
            if (strchr(cursor, '|') || !next_uint(&cursor, &reload[0]) || *cursor || reload[0] > 3) return;
            ranged = reload[0] != 0;
        } else if (kind == 'R') {
            for (int i = 0; i < 5; i++) {
                if (i == 4 && strchr(cursor, '|')) return;
                if (!next_uint(&cursor, &reload[i])) return;
            }
            if (*cursor || reload[0] > 3 || reload[1] > 8 || reload[2] > reload[3] || reload[3] > 65535) return;
            ranged = reload[0] != 0;
        } else {
            for (int i = 0; i < 6; i++) if (!next_float(&cursor, &shot[i], i == 5)) return;
            float norm = hypotf(hypotf(shot[3], shot[4]), shot[5]);
            if (norm < .95f || norm > 1.05f) return;
            ranged = 1;
        }
    }

    pthread_mutex_lock(&snapshot_lock);
    int changed = !equipped.known || entity != equipped.entity || record != equipped.record;
    if (changed) {
        pending.serial = 0;
        equipped = (vx_weapon_snapshot){ .entity = entity, .record = record, .known = 1,
                                         .generation = equipped.generation + 1, .ranged = (int)ranged };
        fprintf(stderr, "vxmac: weapon bridge equip entity=%llu record=%llu generation=%llu ranged=%d\n",
                (unsigned long long)entity, (unsigned long long)record,
                (unsigned long long)equipped.generation, equipped.ranged);
    }
    if (kind == 'S') {
        memcpy(equipped.muzzle, shot, sizeof equipped.muzzle);
        memcpy(equipped.forward, shot + 3, sizeof equipped.forward);
        if (++equipped.shot_count == 1)
            fprintf(stderr, "vxmac: weapon bridge shot entity=%llu muzzle=(%.3f %.3f %.3f) forward=(%.3f %.3f %.3f)\n",
                    (unsigned long long)entity, shot[0], shot[1], shot[2], shot[3], shot[4], shot[5]);
    }
    if (kind == 'R') {
        equipped.type_known = 1;
        equipped.reload_known = 1;
        equipped.handgun = reload[0] == 1;
        equipped.revolver = reload[0] == 3;
        equipped.reload_phase = (int)reload[1];
        equipped.ammo = (uint32_t)reload[2];
        equipped.capacity = (uint32_t)reload[3];
        equipped.reload_report++;
        fprintf(stderr, "vxmac: weapon reload entity=%llu phase=%d ammo=%u/%u handgun=%d sequence=%llu\n",
                (unsigned long long)entity, equipped.reload_phase, equipped.ammo, equipped.capacity,
                equipped.handgun, (unsigned long long)reload[4]);
    }
    if (kind == 'K') {
        equipped.type_known = 1;
        equipped.handgun = reload[0] == 1;
        equipped.revolver = reload[0] == 3;
        fprintf(stderr, "vxmac: weapon type entity=%llu handgun=%d ranged=%d\n",
                (unsigned long long)entity, equipped.handgun, equipped.ranged);
    }
    pthread_mutex_unlock(&snapshot_lock);
}

// IntToString's ordinary calls go to the untouched shipping handler. Only one
// literal argument, followed immediately by ParamEnd, is the private mailbox.
// Inspecting bytecode avoids evaluating ordinary argument expressions twice.
static void poll_handler(void *object, void *frame, void *result, const void *type) {
    unsigned char *stack = frame;
    const unsigned char **pc = (const unsigned char **)stack;
    uint32_t literal = 0;
    if (**pc == 0x06) memcpy(&literal, *pc + 1, sizeof literal);
    if ((literal != POLL_LITERAL && literal != MODE_LITERAL) || (*pc)[5] != 0x26) {
        original_poll(object, frame, result, type);
        return;
    }
    memset(stack + 0x30, 0, 16);
    stack[0x62]++;
    *pc += 6;
    char packet[128];
    if(literal==MODE_LITERAL) snprintf(packet,sizeof packet,"%d",vx_weapon_bridge_tracking());
    else command_packet(packet, sizeof packet);
    if (result) {
        vm_string value;
        string_init(&value, packet);
        string_assign(result, &value);
        string_free(&value);
    }
}

static int image_contains(const void *pointer, size_t size, int executable) {
    const unsigned char *base = atomic_load(&game_base);
    uintptr_t address = (uintptr_t)pointer;
    if (!base || !address || address + size < address) return 0;
    const struct mach_header_64 *header = (const void *)base;
    const unsigned char *command = (const unsigned char *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const void *)command;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            uintptr_t start = (uintptr_t)base + segment->vmaddr - UINT64_C(0x100000000);
            int protection = executable ? 4 : 1;
            if ((segment->initprot & protection) && address >= start &&
                address + size <= start + segment->vmsize) return 1;
        }
        command += lc->cmdsize;
    }
    return 0;
}

// A game-thread observation only. Never call an unverified virtual method: the
// Mac vtable order has not been established and a guessed slot may be a destructor.
// Record image-relative entries for offline inspection; retain no object pointer.
static void pose_context_probe(void *context, const char *message, size_t length) {
    const char *option = getenv("VXMAC_NATIVE_POSE_PROBE");
    if (!option || strcmp(option, "1")) return;
    static const char *markers[] = { "VXW2|P|player-controller", "VXW2|P|weapon-controller",
                                     "VXW2|P|player-root", "VXW2|P|weapon-root" };
    int binding = -1;
    for (int i = 0; i < 4; i++)
        if (length == strlen(markers[i]) && !memcmp(message, markers[i], length)) binding = i;
    if (binding < 0) return;
    const char *owner = markers[binding] + 7;
    if (!context) { fprintf(stderr, "vxmac: native pose %s: no VM context\n", owner); return; }
    void **vtable; memcpy(&vtable, context, sizeof vtable);
    if (!image_contains(vtable, 8 * sizeof(void *), 0)) {
        fprintf(stderr, "vxmac: native pose %s: unrecognized context vtable\n", owner); return;
    }
    vx_weapon_hand_frame sample = vx_weapon_bridge_hands();
    const unsigned char *base = atomic_load(&game_base);
    pthread_mutex_lock(&snapshot_lock);
    diagnostic.pose_vtable[binding] = (uintptr_t)vtable - (uintptr_t)base;
    diagnostic.pose_observations[binding]++;
    pthread_mutex_unlock(&snapshot_lock);
    fprintf(stderr, "vxmac: native pose %s vtable=+%lx hands=%llu valid=%d tracked=%.0f/%.0f entries=",
            owner, (unsigned long)((uintptr_t)vtable - (uintptr_t)base),
            (unsigned long long)sample.sequence, sample.valid, sample.wrists[0], sample.wrists[10]);
    for (int i = 0; i < 8; i++) {
        if (image_contains(vtable[i], 4, 1))
            fprintf(stderr, "%s+%lx", i ? "," : "", (unsigned long)((uintptr_t)vtable[i] - (uintptr_t)base));
        else fprintf(stderr, "%soutside-image", i ? "," : "");
    }
    fprintf(stderr, " (read-only; no virtual calls)\n");
}

static void report_handler(void *object, void *frame, void *result, const void *type) {
    (void)object; (void)result; (void)type;
    const unsigned char *base = atomic_load(&game_base);
    unsigned char *stack = frame;
    script_opcode *dispatch = (script_opcode *)(base + VM_DISPATCH);
    vm_string name;
    ((void (*)(vm_string *, const char *))(base + STRING_INIT))(&name, (const char *)base + REPORT_DEFAULT);
    memset(stack + 0x30, 0, 16);
    stack[0x62]++;
    const unsigned char **pc = (const unsigned char **)stack;
    unsigned opcode = *(*pc)++;
    dispatch[opcode](*(void **)(stack + 0x40), frame, &name, NULL);
    (*pc)++;
    size_t length = name.size_flags & 0x3fffffff;
    const char *message = (const char *)name.text;
    if (name.size_flags >> 30) memcpy(&message, name.text, sizeof message);
    if (message && (name.size_flags >> 30 || length < sizeof name.text))
        read_report(message, length);
    if (message && (name.size_flags >> 30 || length < sizeof name.text))
        pose_context_probe(*(void **)(stack + 0x40), message, length);
    ((void (*)(vm_string *))(base + STRING_FREE))(&name);
}

void vx_weapon_bridge_prepare(const struct mach_header *image) {
    const char *option = getenv("VXMAC_WEAPON_BRIDGE");
    if (!option || strcmp(option, "1") || !image || image->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *header = (const struct mach_header_64 *)image;
    const unsigned char *command = (const unsigned char *)(header + 1);
    const unsigned char *limit = command + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && (size_t)(limit - command) >= sizeof(struct load_command); i++) {
        const struct load_command *lc = (const struct load_command *)command;
        if (lc->cmdsize < sizeof *lc || lc->cmdsize > (size_t)(limit - command)) break;
        if (lc->cmd == LC_UUID && lc->cmdsize == sizeof(struct uuid_command) &&
            !memcmp(((const struct uuid_command *)lc)->uuid, game_uuid, sizeof game_uuid)) {
            original_poll = (script_opcode)((const unsigned char *)image + POLL_HANDLER);
            string_init = (void (*)(vm_string *, const char *))((const unsigned char *)image + STRING_INIT);
            string_assign = (void (*)(vm_string *, const vm_string *))((const unsigned char *)image + STRING_ASSIGN);
            string_free = (void (*)(vm_string *))((const unsigned char *)image + STRING_FREE);
            const char *commands = getenv("VXMAC_WEAPON_COMMANDS");
            atomic_store(&commands_enabled, commands && !strcmp(commands, "1"));
            atomic_store(&game_base, (const unsigned char *)image);
            return;
        }
        command += lc->cmdsize;
    }
    fprintf(stderr, "vxmac: weapon bridge skipped for unrecognized game image\n");
}

void vx_weapon_bridge_poll(void) {
    const unsigned char *base = atomic_load(&game_base);
    if (!base) return;
    uint32_t count = __atomic_load_n((const uint32_t *)(base + VM_NATIVE_COUNT), __ATOMIC_RELAXED);
    if (!atomic_load(&attached) && __atomic_load_n(base + REPORT_GUARD, __ATOMIC_ACQUIRE)) {
        uint32_t index = __atomic_load_n((const uint32_t *)(base + REPORT_FUNCTION + REPORT_INDEX), __ATOMIC_RELAXED);
        if (index >= FIRST_NATIVE && index < 65536 && index - FIRST_NATIVE < count) {
            script_opcode *slot = (script_opcode *)(base + VM_DISPATCH) + index;
            script_opcode expected = (script_opcode)(base + REPORT_HANDLER);
            if (__atomic_compare_exchange_n(slot, &expected, report_handler, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
                atomic_store(&attached, 1);
                fprintf(stderr, "vxmac: weapon bridge attached to 2.5.0 report handler\n");
            }
        }
    }
    if (atomic_load(&attached) && vx_weapon_bridge_commands_enabled() && !atomic_load(&poll_attached) &&
        __atomic_load_n(base + POLL_GUARD, __ATOMIC_ACQUIRE)) {
        uint32_t index = __atomic_load_n((const uint32_t *)(base + POLL_FUNCTION + POLL_INDEX), __ATOMIC_RELAXED);
        if (index >= FIRST_NATIVE && index < 65536 && index - FIRST_NATIVE < count) {
            script_opcode *slot = (script_opcode *)(base + VM_DISPATCH) + index;
            script_opcode expected = (script_opcode)(base + POLL_HANDLER);
            if (__atomic_compare_exchange_n(slot, &expected, poll_handler, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
                atomic_store(&poll_attached, 1);
                fprintf(stderr, "vxmac: game-thread weapon mailbox attached (experimental)\n");
            }
        }
    }
}
