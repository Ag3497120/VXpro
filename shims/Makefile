# The VX Mac shims (see vxmac.h, docs/DESIGN.md): one dylib per macOS library a prepared image names
# (tools/macho_prepare.py SHIMMED). make            -> ../build/xros/*.dylib (visionOS device)
#                                     make mac        -> ../build/macshim/libvxmtl.dylib, libvxmtlfx.dylib (Mac tests)
SDK := $(shell xcrun --sdk xros --show-sdk-path)
MSDK := $(shell xcrun --sdk macosx --show-sdk-path)
OUT := ../build/xros
MOUT := ../build/macshim
CC := xcrun --sdk xros clang
MCC := xcrun --sdk macosx clang
CFLAGS := -target arm64-apple-xros26.0 -isysroot $(SDK) -O2 -Wall -Wno-unused-parameter -fobjc-arc -fvisibility=default
MCFLAGS := -target arm64-apple-macos15.0 -isysroot $(MSDK) -O2 -Wall -Wno-unused-parameter -fobjc-arc
DY = -dynamiclib -install_name @rpath/$(notdir $@) -Wl,-headerpad_max_install_names

FXLINK := -Wl,-reexport_framework,MetalFX
LIBS := libvxkit libvxcocoa libvxcarbon libvxcg libvxiokit libvxsec libvxgk libvxcurl libvxmtl libvxmtlfx libvxsystem libvxaudiounit
all: $(addprefix $(OUT)/,$(addsuffix .dylib,$(LIBS)))

$(OUT):
	mkdir -p $@
$(OUT)/libvxkit.dylib: vxkit.m vxmac.h | $(OUT)
	$(CC) $(CFLAGS) $(DY) vxkit.m -o $@ -framework Foundation -framework QuartzCore -framework CoreGraphics
$(OUT)/libvxcocoa.dylib: vxempty.c $(OUT)/libvxkit.dylib
	$(CC) $(CFLAGS) $(DY) vxempty.c -o $@ -Wl,-reexport_library,$(OUT)/libvxkit.dylib -Wl,-reexport_framework,Foundation
$(OUT)/libvxaudiounit.dylib: vxempty.c | $(OUT)
	$(CC) $(CFLAGS) $(DY) vxempty.c -o $@ -Wl,-reexport_framework,AudioToolbox
$(OUT)/libvxcarbon.dylib: vxempty.c | $(OUT)
	$(CC) $(CFLAGS) $(DY) vxempty.c -o $@
$(OUT)/libvxcg.dylib: vxcg.c $(OUT)/libvxkit.dylib
	$(CC) $(CFLAGS) $(DY) vxcg.c -o $@ -Wl,-reexport_framework,CoreGraphics -framework CoreFoundation $(OUT)/libvxkit.dylib
$(OUT)/libvxiokit.dylib: vxiokit.c | $(OUT)
	$(CC) $(CFLAGS) $(DY) vxiokit.c -o $@ -Wl,-reexport_framework,IOKit -framework CoreFoundation
$(OUT)/libvxsec.dylib: vxsec.c | $(OUT)
	$(CC) $(CFLAGS) $(DY) vxsec.c -o $@ -Wl,-reexport_framework,Security -framework CoreFoundation
$(OUT)/libvxgk.dylib: vxgk.m | $(OUT)
	$(CC) $(CFLAGS) $(DY) vxgk.m -o $@ -Wl,-reexport_framework,GameKit -framework Foundation
$(OUT)/libvxcurl.dylib: vxcurl.c $(OUT)/libvxkit.dylib
	$(CC) $(CFLAGS) $(DY) vxcurl.c -o $@ $(OUT)/libvxkit.dylib
$(OUT)/libvxmtl.dylib: vxmtl.m vxpipe.m $(OUT)/libvxkit.dylib
	$(CC) $(CFLAGS) $(DY) vxmtl.m vxpipe.m -o $@ -Wl,-reexport_framework,Metal -framework Foundation -framework QuartzCore $(OUT)/libvxkit.dylib
$(OUT)/libvxmtlfx.dylib: vxmtlfx.m $(OUT)/libvxkit.dylib
	$(CC) $(CFLAGS) $(DY) vxmtlfx.m -o $@ $(FXLINK) -framework Foundation -framework Metal -framework QuartzCore $(OUT)/libvxkit.dylib
$(OUT)/libvxsystem.dylib: vxsystem.c | $(OUT)
	$(CC) $(CFLAGS) $(DY) vxsystem.c -o $@ -Wl,-reexport-lSystem

# (Mac tests of the Metal / MetalFX parts with DYLD_INSERT_LIBRARIES: they need vxmac_log, from a small log unit)
mac: $(MOUT)/libvxmtl.dylib $(MOUT)/libvxmtlfx.dylib
$(MOUT):
	mkdir -p $@
$(MOUT)/libvxlog.dylib: vxlog_mac.c | $(MOUT)
	$(MCC) $(MCFLAGS) $(DY) vxlog_mac.c -o $@
$(MOUT)/libvxmtl.dylib: vxmtl.m vxpipe.m $(MOUT)/libvxlog.dylib
	$(MCC) $(MCFLAGS) $(DY) vxmtl.m vxpipe.m -o $@ -framework Foundation -framework Metal -framework QuartzCore $(MOUT)/libvxlog.dylib -Wl,-rpath,@loader_path
$(MOUT)/libvxmtlfx.dylib: vxmtlfx.m $(MOUT)/libvxlog.dylib
	$(MCC) $(MCFLAGS) $(DY) vxmtlfx.m -o $@ -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore $(MOUT)/libvxlog.dylib -Wl,-rpath,@loader_path

# (the visionOS simulator: make sim -> ../build/xrsim; a Mac run of the whole route. The simulator has no MetalFX:
#  libvxmtlfx re-exports nothing there and the program's by-name lookups find no MetalFX classes)
sim:
	$(MAKE) FXLINK= OUT=../build/xrsim SDK=$$(xcrun --sdk xrsimulator --show-sdk-path) CC="xcrun --sdk xrsimulator clang" \
	  CFLAGS="-target arm64-apple-xros26.0-simulator -isysroot $$(xcrun --sdk xrsimulator --show-sdk-path) -O2 -Wall -Wno-unused-parameter -fobjc-arc -fvisibility=default" all

clean:
	rm -rf $(OUT) $(MOUT) ../build/xrsim
.PHONY: all mac sim clean
