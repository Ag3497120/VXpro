# Installing VXpro (Cyberpunk 2077) on Apple Vision Pro

VXpro plays the Mac App Store edition of Cyberpunk 2077 in stereo VR on Apple Vision Pro: your Mac prepares, signs and installs your own copy, and the headset then runs it with no streaming.

The full guide is [docs/VISION_PRO_CYBERPUNK_MAC.md](docs/VISION_PRO_CYBERPUNK_MAC.md): what each step does, recommended graphics settings, controls, options and troubleshooting. The [README](README.md) has the short version.

## Requirements

- An Apple-silicon Mac with Xcode 26 or later and the visionOS SDK, `xcodegen` (`brew install xcodegen`) and Python 3
- Apple Vision Pro in Developer Mode, paired with Xcode, with about 85 GB free (game 2.5.0) or 160 GB (2.3.2 with all voice packs)
- An Apple Developer Program team signed in to Xcode. The tested setup is a paid team (Increased Memory Limit and Extended Virtual Addressing); a free Personal Team hasn't been verified
- Your own Mac App Store copy of Cyberpunk 2077, installed on the Mac (builds 2.5.0 and 2.3.2 tested; Steam and GOG copies are untested)
- A Joy-Con pair for the tracked-hand controls, or a game controller

## Game files

You need to supply your own game files. This repository contains none. The tools read the game from where the Mac App Store installed it (usually `/Applications/Cyberpunk2077.app`), and `doctor` checks it.

## Build and install

From a checkout of this repository, with your game path and your Apple Developer team ID:

```sh
game="/Applications/Cyberpunk2077.app"
python3 tools/vxmac_cyberpunk.py doctor --game "$game"
python3 tools/vxmac_cyberpunk.py prepare --game "$game" --team YOUR_TEAM_ID
python3 tools/vxmac_cyberpunk.py build
python3 tools/vxmac_cyberpunk.py install
python3 tools/vxmac_cyberpunk.py copy
python3 tools/vxmac_cyberpunk.py launch
```

Keep the headset awake until `copy` finishes the first game-data transfer, and start with the **1280×720 native** graphics profile. To update later, keep the same bundle ID and team: deleting the VX Mac Host app also deletes its saves and copied game data.
