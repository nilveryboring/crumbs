# Launch video

`index.html` is the whole video: seven scenes driven by `render(t)`, so every
frame is deterministic. `render.mjs` steps through it with Playwright and ffmpeg
stitches the frames.

```sh
npm i --no-save playwright && npx playwright install chromium
node render.mjs stills 3.8,14.5,28.8     # spot-check frames
node render.mjs video                    # frames/00000.jpg …
ffmpeg -framerate 30 -i frames/%05d.jpg -c:v libx264 -preset slow -crf 18 \
  -pix_fmt yuv420p -movflags +faststart crumbs-launch.mp4
```

Screenshots in `shots/` come from the app's debug demo mode
(`CRUMBS_DEMO=1` / `CRUMBS_DEMO=trashed` with `CRUMBS_SNAPSHOT_DIR`), so no real
project names appear.
