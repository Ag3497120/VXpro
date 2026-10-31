# Third-party notices

All code in this repository was written for VXpro / VeRantyx and is under the MIT licence ([LICENSE](LICENSE)).
It contains no third-party source code, headers, models or data:

- the shims (`shims/`) are written from Apple's public documentation; no code from Wine, ReactOS, GNUstep, Darling or
  any other reimplementation of Apple or Microsoft APIs;
- the immersive presenter (`vr/`) comes from VeRantyx's own `VXRuntime/src` (MIT, same author);
- the foveated super-resolution model is not shipped: `tools/fsr_model.py` builds it on your Mac from fixed filters
  (no learned weights, no third-party model);
- no code or text from other Vision Pro ports of the game is used.

Not part of this repository (you install or already have them):

| what | used for | licence |
|---|---|---|
| Apple's SDKs (UIKit, SwiftUI, CompositorServices, ARKit, Metal, MetalFX, QuartzCore, CoreText, GameController, CoreVideo, Vision, CoreML) | building the app | Apple's Xcode and SDK terms |
| the macOS libcurl and libbz2 | the Mac test program (`testapp/`) | system libraries |
| xcodegen | generating the Xcode project | MIT |
| coremltools, numpy | building the SR model (`tools/fsr_model.py`, optional) | BSD-3-Clause |
| Pillow | regenerating the app icon (`tools/app_icon.py`, optional; the icon in `app/Assets.xcassets` is its output) | MIT-CMU (HPND) |
| Python 3 | the tools | PSF |
| Cyberpunk 2077 (Mac App Store) | your own purchased copy | CD PROJEKT RED's terms |
