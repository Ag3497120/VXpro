// SPDX-License-Identifier: MIT
#pragma once

// Track only a CPU submission permit, never GPU resource ownership. Call before commit.
// Completion always releases the permit if scheduling did not. release runs at most once.
void vxwg_track(void *command_buffer, int release_when_scheduled, void (^release)(void));
