# HalilShaders pipeline contract

This file is the single source of truth for how the built-in pack's passes talk to each other.
Read it before adding a feature that lights, shadows, tints or outlines the scene. Keeping to
these rules is what stops features (for example shadows and edge glow) from fighting each other.

Pack files: `common/src/main/resources/halilshaders/shaders/`

## Pass order

1. **gbuffers_*** (terrain, entities, textured_lit): write geometry data (below). No lighting.
2. **deferred**: the only place directional light is applied, and the only place light
   visibility (shadows) is computed. Writes visibility to `colortex3`.
3. **composite**: effects that add or remove light-colored detail (edge glow), then fog.
4. **final**: grading only (pastel). Works on the finished picture, reads no geometry data.

## Buffers

| Buffer | r | g | b | a |
|---|---|---|---|---|
| colortex0 | scene color (albedo, then lit, then glow and fog) | | | |
| colortex1 | view-space normal * 0.5 + 0.5 | | | sky light level 0..1 |
| colortex2 | vanilla lightmap color | | | 1 = an opaque gbuffer program wrote here (clears to 0) |
| colortex3 | block light level 0..1 | edge glow allowed (1/0) | sun visibility 0..1 | block light visibility 0..1 |

- `colortex3` clears to 0, so a pixel no gbuffer program wrote to may not glow.
- Gbuffer programs write `b = 1` and `a = 1` (unshadowed). `deferred.fsh` replaces them.
- `deferred.fsh` reads and writes `colortex3`. It copies the pixel through unchanged when it skips
  lighting (sky, or `colortex2.a == 0`).
- Translucent entities write `colortex3 = (0, 0, 0, 1)`: no glow under them.
- New data goes in a new channel here first. Do not reuse a channel for a second meaning.

## Light visibility (shadows)

- Computed once, in `lib/lighting.glsl`: `sunVisibility()` and `blockLightVisibility()`. Today both
  return 1.0. Phase 7 fills in the first, Phase 8 the second.
- Value is continuous 0..1 (1 = fully lit) and does not include N.L.
- Consumers use `colortex3.b` and `colortex3.a`. Nothing outside `deferred.fsh` samples the
  shadow map.

## Sky and fog (atmosphere)

- `lib/atmosphere.glsl` is the only place that decides sky and fog color: `atmosphereColor(viewDir)`
  for the sky dome (`gbuffers_skybasic`) and `fogColorAt(viewDir)` for terrain fog (`composite`).
  Both use the same function, so far terrain fades into the sky behind it without a seam.
- The base is the game's `fogColor` (horizon) and `skyColor` (zenith); these are already biome, time,
  weather, dimension and underwater aware. The pack adds a biome tint (smoothed `hsWarmth` and
  `hsHumidity` custom uniforms from `shaders.properties`) and a sun glow near the horizon.
- How much fog there is (`envFog`, `rdFog`) is decided in `composite.fsh`; the atmosphere only gives
  its color. Underwater, in lava, and under blindness or darkness the game's fog color is used as is.
- The file declares its own uniforms. A program that includes it must not declare `fogColor`,
  `skyColor`, `upPosition`, `sunPosition`, `rainStrength`, `isEyeInWater`, `blindness`,
  `darknessFactor`, `hsWarmth` or `hsHumidity` again.

## Light list (colored block light)

- The fork, not the pack, finds light sources: `net.irisshaders.iris.lights.LightSourceBuffer` scans
  the chunk sections within the player's **render distance** (and 6 sections, 96 blocks, up and down
  from the camera) for emitters and writes them into a shader storage buffer at **binding 7**. Iris
  itself gives shaders no light positions.
- Scanning works on 16 x 16 x 16 sections. A section whose block palette has no emitting state is
  skipped without reading a block; sections with emitters are read block by block and their lights
  remembered per section. Each frame a few chunk columns around the camera are rescanned (a placed
  torch shows up in about half a second) plus as many outer columns as fit in half a millisecond,
  walking outward and starting over. The lists below are rebuilt only when the remembered lights
  really changed (at most every 10 frames) or when the camera leaves the middle of the grid.
- The buffer holds two views of the same lights:
  - a **grid** of world-aligned cells of 16 blocks, `(2 * renderChunks + 6)` cells wide in x and z and
    20 cells (320 blocks) tall, so it always covers at least the render distance around the camera.
    Each cell lists up to 15 lights that reach it. `coloredLightAt` (surface lighting in `deferred`)
    reads only the surface's own cell, so a torch 100 blocks away still colors the wall next to it.
    Choosing lights per surface, not per camera, is the point: the old "32 most influential to the
    camera" list ran out in cave areas and far lights fell back to vanilla.
  - a **halo list** of the 64 lights most influential to the camera, used by `lightHalos`, because
    halos are drawn along view rays and not on surfaces.
- Layout (std430): `ivec4 header` (x = halo count), `ivec4 gridDims` (grid size in cells, x y z),
  `vec4 gridOrigin` (grid corner minus camera), `Light haloLights[64]`, `Light candidates[32768]`,
  then a runtime-sized `int grid[]` (per cell: count, then indices into `candidates`; cell index =
  `(x * dimsY + y) * dimsZ + z`). `Light` is `{ vec4 posRadius; vec4 colorIntensity; }`. `posRadius.xyz`
  is the light center minus a reference point, in world axes (not view space): the camera for the halo
  list, the grid corner for the candidates (so candidates stay valid while the camera moves), and
  `w` is the reach in blocks. Only the header and halo list are uploaded every frame. The layout
  lives in two places that must match: the header comment and constants of `LightSourceBuffer.java`
  and `lib/lights.glsl`.
- Limits: the render distance is capped at 32 chunks for this list, only chunks the client has loaded
  are seen, and the 32768 lights closest to the camera are kept.
- Colors are chosen by block name in `LightSourceBuffer.resolveColor` (soul = blue, lava = orange...).
- Binding 7 is reserved. A pack buffer defined with `bufferObject.7` would collide with it.
- Only programs at `#version 430` or newer can include `lib/lights.glsl`. Today that is `deferred`
  and `composite`.
- The halo list is culled on the CPU, so lights that cannot show a halo cost nothing per pixel and
  take no slot from a light that can. Lights outside the camera's view (widened by about 20 degrees
  and by the glow size) are left out. A light is also left out when it is hidden: rays from the
  camera to its middle and to 8 points on a ring the size of its glow must ALL be stopped by an
  opaque full block (`canOcclude` and a full collision cube; glass, leaves, fences and slabs never
  stop a ray) more than 1.3 blocks before the point. A light behind a one block pole therefore stays:
  the ring points beside the pole are not blocked. Tests are limited to 12 lights per frame, kept for
  8 frames, and lights fade in and out (`Light.visibility`, multiplied into the color the shader
  sees). A light that was never tested counts as visible; lights nearer than 4 or farther than 96
  blocks are never tested. The surface lighting grid is not culled this way, because it only runs for
  pixels that are on screen and a light behind a wall still lights its own side of the wall.
- Until lights have real shadows, whether a light reaches a surface is guessed from vanilla's block
  light level (`coloredLightAt` in `lights.glsl`). That guess is replaced, not extended, by shadows.
- Two passes read the buffer: `deferred` (colored light on surfaces, from the grid) and `composite`
  (light halos, `lightHalos` in `lights.glsl`, from the halo list). Both are `#version 430`, and so
  are their vertex shaders.

## First-person hand

- The hand is drawn before `deferred` with its depth squeezed to 1/8 (`HandRenderer.DEPTH`), so the
  world's `gbufferProjectionInverse` puts every hand pixel about 0.1 block from the camera. Anything
  in the pack that reads depth is therefore wrong for hand pixels. `gbuffers_hand` writes the same
  buffers as other opaque programs but with the edge glow flag off (`HS_NO_EDGE_GLOW`), because the
  depth jump between hand and world would read as a huge silhouette and draw a rim around the hand.
- `blend.gbuffers_hand=off` in `shaders.properties`: the game draws the arm with a blended render
  type, and blending is applied to all four buffers at once. The alpha of colortex1 is the sky light,
  which would then act as a blend factor.
- `gbuffers_hand_water` is the translucent hand (a held glass block, say). It is a separate program.

## Keeping colors inside 0..1

- The color buffers are 8 bit, so values above 1.0 are cut off per channel, which flattens texture
  and shifts hue. `lib/range.glsl` has `fitToRange()`: it divides by the brightest channel when that
  is above 1.0 and returns the color unchanged otherwise. `deferred` and `composite` call it after
  they add light.
- The sun boost in `deferred.fsh` is scaled by headroom (`1 - peak`), so near-white surfaces (snow,
  white wool, quartz) are not pushed past 1.0 by the sun.
- The pastel grade in `final.fsh` fades its palette tint out on strongly colored pixels
  (`PASTEL_TINT_PROTECT*` in settings). A night sky tint is blue, and blue added to red-orange light
  (lava) turns it pink. The lava light color itself is in `LightSourceBuffer.resolveColor`.
- Colored block light is bounded so a cluster of lights (a lava lake: every lava block is a light,
  up to 15 per cell) cannot overexpose a surface. `coloredLightAt` soft-limits the luma of the summed
  light to `COLORED_LIGHT_MAX` and keeps its hue. `deferred.fsh` scales the new light color so its
  brightest channel equals the brightest channel of vanilla's light (not its luma: a luma-matched
  lava color has a red channel of 2 or more, `fitToRange` then divided it away and a white block and
  a stone block ended up the same flat orange). The extra glow (`COLORED_LIGHT_EXTRA`) is added to the
  surface color, so it keeps the surface's own brightness differences.

## Level of detail (LOD)

- Work nobody can see is skipped or done more cheaply. "Can anybody see it" is one number: how many
  screen pixels a block covers at a distance, `viewHeight / (2 * distance * tan(fov / 2))`
  (`lodPixelsPerBlock` in `lib/lod.glsl`; `tan(fov / 2)` is `gbufferProjectionInverse[1][1]`). It
  follows the window height and the field of view, so a small window loses detail sooner. Settings
  are in the "Level of detail" part of `lib/settings.glsl`; `LOD_ENABLED = false` turns it all off.
- **Edge glow** (`composite.fsh`): below `LOD_EDGE_MIN_PIXELS_PER_BLOCK` there is no glow and nothing
  is read (lines a pixel or two apart would merge into bands); it is at full strength from
  `LOD_EDGE_FULL_PIXELS_PER_BLOCK`. The thin-step filter (steps of 1-2 texels) is skipped where such
  a step is shorter than `LOD_THIN_STEP_MIN_PIXELS`.
- **Colored light** (`deferred.fsh`, `coloredLightAt`): far surfaces use only the strongest
  `LOD_COLORED_LIGHTS_MIN` lights of their cell, all of them from `LOD_LIGHT_FULL_PIXELS_PER_BLOCK`
  up, with a smooth change in between (the last light used is faded). This needs each cell sorted
  strongest first, which `LightSourceBuffer.buildGrid` does. Surfaces with no block light at all skip
  the light loop completely; that one loses nothing, because the result is multiplied by the block
  light share, which is 0 there.
- **Halos** (`LightSourceBuffer.java`): a light whose visible glow is smaller than `HALO_MIN_PIXELS`
  (1.5) on screen is left out of the halo list, and it fades in up to `HALO_FULL_PIXELS` (3). The
  numbers are in the Java file; `HALO_RADIUS_BLOCKS` there must match `HALO_RADIUS` in settings.
- Not covered: terrain, textures and mipmaps are the game's, not the pack's. Sky, fog and the
  pastel grade cost the same everywhere and have no detail to drop.

## Math helpers and per-frame values

- `lib/fastmath.glsl` has the shared helpers: `rcp` (GLSL has none, it is `1.0 / x`; use it by writing
  a divisor once and multiplying), `fastNormalize` and `fastLength` (`inversesqrt` based, a zero
  vector gives 0 instead of NaN), `fastCosAngle` (angle between two non-unit vectors with one
  `inversesqrt`) and `fastPow` (`exp2(log2(x) * b)` for non-negative x). New shader code uses these
  instead of `/`, `normalize`, `length` and `pow` in per-pixel code.
- Branches stay where they skip real work (the light loop, neighbour texture reads, the thin-step
  walk, out-of-grid buffer reads, which must never run). Cheap choices between two values are
  written with `step`, `mix` and `max`, for example `fitToRange` is `c * rcp(max(peak, 1.0))`.
- Anything that depends only on uniforms is computed in the vertex shader and passed as a `flat`
  varying, not per pixel. `final.vsh` does this for the pastel grade: the amount for the time of day
  and the two palette tints (each one is an OKLab conversion with pow calls). OKLab is in
  `lib/oklab.glsl`, shared by `final.vsh` and `final.fsh`.
- Work that two parts of one pass both need is done once: `composite.fsh` computes the view position,
  distance and direction once for halos and fog.

## Glass and water glint

- `gbuffers_water` (glass, ice, water: the translucent terrain layer) adds a stylized sun sheen from
  `lib/glint.glsl`. Its vertex shader defines `HS_GLINT`, which adds `viewPosition` and
  `isWaterSurface` (from `mc_Entity`, id 10002 in `block.properties`).
- Plain glass and glass panes are moved to the translucent layer by `layer.translucent` in
  `block.properties`, because cutout glass never draws its transparent texels.
- The glint is computed before the transparent-texel discard in `gbuffer_forward_lit.glsl`, so a pane
  shows the sheen across its whole surface.
- `glint.glsl` and `lights.glsl` both declare `gbufferModelViewInverse`: never include both in one
  program. Sun shadows (Phase 7) will multiply the glint by the stored sun visibility.

## Rules for features

1. **Shadows remove light, they never add color.** Applied in `deferred.fsh` as a factor on the
   directional term (`direct`).
2. **Anything that adds light-colored detail after deferred (edge glow, specular, god rays) must
   multiply by the stored visibility.** Otherwise it shows up inside shadows. Edge glow does this
   through `sunBudget` and `blockBudget` in `composite.fsh`.
3. **Surface orientation and visibility are separate factors**: `facing * exposure * visibility`.
   Do not fold N.L into the visibility, or it is counted twice.
4. **Geometry detection (edges) reads geometry buffers only**, never the shadow map. Shadow acne
   or filtering noise cannot then create fake edges.
5. **Order matters in `composite`**: glow, then fog, so distant glow fades with the haze. Grading
   stays in `final` so it treats glow and shadows alike.
6. **Mask what must not glow in the gbuffer stage** (`colortex3.g`), not in composite.
7. **Never write a second sky or fog color.** Anything that colors the sky or the distance (clouds,
   Phase 6 effects, a Nether or End look) goes through `lib/atmosphere.glsl`, or the sky and the
   fog will stop matching.
8. **Include guards and uniforms:** a `lib/` file that can be included twice in one program
   (`settings.glsl`, `atmosphere.glsl`) has an include guard (`#ifndef`), because Iris does not add
   one. A lib that declares uniforms says so in its header.
9. **No trailing comment on an `#include` line.** Iris cannot resolve `#include "/lib/x.glsl" // note`
   and the whole pack fails to load (the game then falls back to vanilla). Put the comment on its
   own line above the include.

## Edge glow in one paragraph

Edges come from geometry (1/z second difference for silhouettes, normal difference for creases).
A crease glows on the side that faces the light more than its neighbour, in proportion to the
difference in N.L, so equally lit faces (roof steps) barely glow. Silhouettes glow at a fraction of
that and only where the surface faces the light. Strength is multiplied by sky exposure, rain,
light visibility, a distance fade and a brightness factor. Settings are in `lib/settings.glsl`.
