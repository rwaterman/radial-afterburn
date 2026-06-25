# Task 7 Report: Billboard Sprites for Player and Enemies

## Build
`swift build` — clean, 0 warnings. Commit `e0081c4 feat: billboard sprites for player and enemies`.

## Screenshot
Command: `.build/debug/RadialAfterburn --screenshot /tmp/nv-task7.png --frames 60 --width 1100 --height 760`

**What the standard screenshot shows:** textured/wireframe tunnel with a glowing cyan player arrow sprite at the near rim (bottom-right, lane 3, depth=0.04). Enemies at 60 frames are at depth >0.98 (distance ~15.7, fog factor ~97%) — rendering correctly but effectively invisible due to fog.

**Extended verification (700 frames, firing disabled temporarily):** pixel analysis of `/tmp/nv-task7-final.png` confirmed vivid pink pixels at the exact expected screen position of enemy 1 (lane=15, depth=0.12, pixel ~(467,564): R=242, G=31, B=46) and pale-pink additive glow pixels across the billboard area. Enemy sprites render correctly with perspective scaling and partial depth-test occlusion by the tunnel wall surface.

**No-walls test** (`/tmp/nv-nowalls.png`): confirmed all three debug test sprites visible at depths 0.15, 0.30, 0.50 with correct perspective (smaller/foggier the farther they are). Player arrow large and bright at near rim.

## Tests
`swift test`: 19/19 pass.

## Concern: Brief/Harness Mismatch

The brief expects "several enemy sprites (pink diamond/orange winged/blue hex) at various depths" at frames 60–90. This is not achievable with the scripted harness: spikes don't appear until wave 1 (frame ~48), flippers until wave 2 (frame ~676), tankers until wave 4. The scripted scene fires every 9 frames and keeps enemies at depth >0.65 throughout wave 1 (97%+ fogged). The implementation is correct; the Screenshot.swift scripted scene was not designed to showcase enemy sprites. Recommend improving the scripted scene for future checkpoints (e.g., reduced fire rate, or a seeded scenario that puts one enemy of each kind at depth 0.2–0.5 before the snapshot).

## Screenshot Paths
- Standard (60 frames): `/tmp/nv-task7.png`
- Extended no-fire verification (700 frames): `/tmp/nv-task7-final.png`
- No-walls confirmation: `/tmp/nv-nowalls.png`

## Report Path
`/Users/rick/git/github/rwaterman/radial-afterburn/docs/superpowers/sdd/task-7-report.md`
