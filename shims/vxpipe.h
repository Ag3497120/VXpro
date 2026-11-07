// SPDX-License-Identifier: MIT
#pragma once

// Startup only, after host arguments and before client GPU threads. Does not reinstall hooks.
void vxpipe_configure_startup(void);
