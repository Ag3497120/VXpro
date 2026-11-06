// SPDX-License-Identifier: MIT
#include "warp_core.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void identity(float m[16], float x, float y, float z) {
    memset(m, 0, 16 * sizeof(float));
    m[0] = m[5] = m[10] = m[15] = 1;
    m[12] = x; m[13] = y; m[14] = z;
}

static void near(float a, float b) { assert(fabsf(a - b) < .000001f); }

int main(void) {
    float left[16], right[16], offsets[2][3];
    identity(left, -.029f, .05f, -.04f);
    identity(right, .029f, .05f, -.04f);
    assert(vxw_stereo_eye_offsets(left, right, offsets));
    near(offsets[0][0], .029f);
    near(offsets[1][0], -.029f);
    for (int h = 0; h < 2; h++) {
        near(offsets[h][1], 0);
        near(offsets[h][2], 0);
    }
    // Asymmetric anchors share one centre instead of giving the two eyes
    // different convergence distances.
    right[12] = .035f; right[13] += .002f; right[14] += .004f;
    assert(vxw_stereo_eye_offsets(left, right, offsets));
    near(offsets[0][0], .032f);
    near(offsets[0][1], .001f);
    near(offsets[0][2], .002f);
    for (int i = 0; i < 3; i++) near(offsets[0][i], -offsets[1][i]);
    // A canted eye receives the baseline in its own rotated coordinates.
    float angle = .1f;
    left[0] = left[10] = cosf(angle);
    left[2] = -sinf(angle); left[8] = sinf(angle);
    assert(vxw_stereo_eye_offsets(left, right, offsets));
    near(offsets[0][0], .032f*cosf(angle) - .002f*sinf(angle));
    near(offsets[0][2], .032f*sinf(angle) + .002f*cosf(angle));
    float saved[2][3];
    memcpy(saved, offsets, sizeof saved);
    assert(!vxw_stereo_eye_offsets(NULL, right, offsets));
    assert(!vxw_stereo_eye_offsets(right, left, offsets));
    right[12] = 10;
    assert(!vxw_stereo_eye_offsets(left, right, offsets));
    right[12] = .035f; right[0] = 0;
    assert(!vxw_stereo_eye_offsets(left, right, offsets));
    identity(right, .035f, .052f, -.036f);
    right[0] = NAN;
    assert(!vxw_stereo_eye_offsets(left, right, offsets));
    identity(right, .035f, .052f, -.036f);
    right[0] = -1;
    assert(!vxw_stereo_eye_offsets(left, right, offsets));
    assert(!memcmp(saved, offsets, sizeof saved));
    puts("stereo eyes: measured baseline, common centre, cant and invalid-pair fallback: ok");
    return 0;
}
