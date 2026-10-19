# Pour video

The 10 second clip for announcing Pour: an empty mail draft, the bar glows while someone talks, they let go and the sentence lands. 1080×1350 at 60 fps, no audio.

The bar, its aurora, the rim light, the springs and the timings are ported from `Pour/PourHUD.swift`, `Pour/PourSession.swift` and `Pour/PourTheme.swift`. The glow follows `src/envelope.json`, the loudness per frame of the sentence spoken by macOS `say`. Nobody hears that recording, it only drives the light.

## Render

Needs macOS, for Apple's system fonts, and Node.

```bash
npm install
npm run fonts
npm run render
```

The MP4 is written to `out/pour.mp4`. `npm run studio` opens the Remotion preview.

`npm run fonts` copies SF Pro and New York from `/System/Library/Fonts` into `public/fonts`, which git ignores.
