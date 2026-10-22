#ifndef HS_SETTINGS_GLSL
#define HS_SETTINGS_GLSL

// HalilShaders settings.
// Plain GLSL constants, edited here until the config screen arrives in Phase 9.
// Rebuild (or reload resources) after changing a value.

// ---- Phase 3: pastel grading (final pass) ----
//
// The grade works in OKLab (a perceptual color space), so the same numbers look the same on
// every color. Its palette follows the world: shadows lean toward the sky color, highlights
// toward the color of the sun (neutral at noon, warm at sunset, cool by moonlight).

// Master switch. false = final pass copies the scene unchanged.
const bool  PASTEL_ENABLED         = true;

// How much of the grade is applied, by time of day. 0.0 = vanilla colors, 1.0 = full grade.
// Dusk covers sunrise and sunset. Day is kept close to dusk and night so the look stays the
// same all day; a high day value makes bright scenes look hazy.
const float PASTEL_AMOUNT_DAY      = 0.50;
const float PASTEL_AMOUNT_DUSK     = 0.50;
const float PASTEL_AMOUNT_NIGHT    = 0.60;

// Saturated colors are squeezed harder than muted ones. COMPRESS is how strongly (0 = off),
// KNEE is the chroma (OKLab, roughly 0..0.3) where squeezing is half-way.
const float PASTEL_CHROMA_COMPRESS = 0.50;
const float PASTEL_CHROMA_KNEE     = 0.12;

// Milky shadows: raises the darkest values by this much (OKLab lightness) and fades out
// toward white. Mid tones and highlights are not flattened.
const float PASTEL_LIFT            = 0.10;

// Largest tint shift (OKLab chroma). 0.0 = no tint. 0.03 is subtle, 0.06 is obvious.
const float PASTEL_TINT_CHROMA     = 0.03;

// Strongly colored pixels (lava glow, torch light) keep their own hue: the palette tint is faded out
// as a pixel's chroma (OKLab, before the squeeze) rises from START to END. Without this the blue of
// a night sky shifts red-orange light toward pink. PROTECT is how much of the tint is removed at
// END: 1.0 = all of it, 0.0 = off (the old behaviour). Muted colors (stone, wood) are not affected.
const float PASTEL_TINT_PROTECT       = 1.0;
const float PASTEL_TINT_PROTECT_START = 0.10;
const float PASTEL_TINT_PROTECT_END   = 0.20;

// ---- Phase 4: edge glow (composite pass) ----

// Master switch.
const bool  EDGE_GLOW_ENABLED         = true;

// How bright the rim is. 0.0 = invisible.
const float EDGE_GLOW_STRENGTH        = 0.35;

// Rim color: 0.0 = pure light color (pale, like a highlight), 1.0 = the surface's own hue
// at full brightness (saturated, like neon).
const float EDGE_GLOW_COLOR_INFLUENCE = 0.50;
// The light color the rim leans toward. Warm white for sunlight.
const vec3  EDGE_GLOW_LIGHT_TINT      = vec3(1.00, 0.96, 0.88);

// Line thickness in pixels up close. It thins toward 1 pixel (the minimum) with distance.
// Values above 1.0 only matter near the player.
const float EDGE_GLOW_WIDTH           = 1.0;

// Distance fade, in blocks. The glow is at full strength up to START and gone at END.
// Past END the edge is not even computed.
const float EDGE_FADE_START           = 24.0;
const float EDGE_FADE_END             = 96.0;

// Silhouette sensitivity: relative depth jump needed to start glowing (0.15 = about 18% distance step).
// Lower finds more edges, higher keeps only strong silhouettes.
const float EDGE_DEPTH_THRESHOLD      = 0.15;

// Crease sensitivity: 1 - dot(normal, neighbour normal). 0.3 is about 45 degrees, a cube edge is 1.0.
const float EDGE_NORMAL_THRESHOLD     = 0.30;

// Steps up to this tall (in blocks) never glow. 1/16 is one texel of a block texture, so 0.125
// ignores steps of 1 or 2 texels, like a path block next to grass. A 3 texel step (0.1875) glows.
// 0.0 turns the filter off.
const float EDGE_MIN_STEP_HEIGHT      = 0.125;

// Which edges glow: only those where a surface catches light.
//
// Creases between two faces glow on the side that faces the light MORE than the other side.
// The glow is proportional to that difference, so a crease between two equally lit faces
// (the steps of a roof, for example) barely glows, while a lit face next to a darker one
// glows fully. EDGE_BEVEL_FULL is the difference in N.L that gives full glow.
const float EDGE_BEVEL_FULL           = 0.50;

// Silhouettes (an object against what is behind it) glow at this fraction of a crease glow,
// and only where the surface faces the light.
const float EDGE_SILHOUETTE_FACTOR    = 0.50;

// Silhouette facing: N.L at which the silhouette glow starts (0.3 = about 70 degrees off the light).
const float EDGE_LIGHT_FACING_MIN     = 0.30;
const float EDGE_SUN_STRENGTH         = 1.0;
// Moonlight glow relative to sunlight.
const float EDGE_MOON_FACTOR          = 0.40;

// Block lights (torches, lava, glowstone...): the surface must be lit by them at least this much
// (0..1 of the vanilla block light level). Higher = only edges very close to a light glow.
// Block light has no direction yet, so every crease and silhouette near a light glows equally;
// real per-light facing arrives with the Phase 8 light data.
const float EDGE_BLOCKLIGHT_MIN       = 0.60;
const float EDGE_BLOCKLIGHT_STRENGTH  = 1.0;

// ---- Phase 5: colored fog and sky (lib/atmosphere.glsl) ----
//
// Sky and fog share one color function, so far terrain always fades into the sky behind it.
// The base is the game's own sky and fog color (already biome, time and weather aware); the
// settings below add a biome tint and a sun glow on top.

// How strongly the biome climate tints the haze. 0.0 = off, 1.0 = as written below.
const float FOG_BIOME_STRENGTH = 1.0;

// Tint added to the haze per climate (RGB shift, 0.05 is subtle, 0.10 is obvious).
const vec3  FOG_BIOME_HOT_DRY  = vec3( 0.07,  0.03, -0.05); // desert, badlands, savanna: sandy haze
const vec3  FOG_BIOME_HOT_WET  = vec3(-0.02,  0.04, -0.01); // jungle: green
const vec3  FOG_BIOME_COLD     = vec3(-0.03,  0.00,  0.06); // snowy and cold biomes: icy blue
const vec3  FOG_BIOME_WET      = vec3(-0.01,  0.02,  0.00); // forest, swamp, taiga: faint green

// Glow of the haze toward the sun, in the sun's color (white at noon, orange when low).
// Only near the horizon, only by day. POWER is how tight it is around the sun (higher = tighter).
const float FOG_SUN_STRENGTH   = 0.30;
const float FOG_SUN_POWER      = 8.0;

// ---- Phase 6: colored block light (lib/lights.glsl, deferred pass) ----
//
// The fork finds light-emitting blocks and gives the pack the 32 most influential ones (position,
// color, strength) in a shader storage buffer. Each light has a color: torches are warm, soul
// torches blue, lava orange, sea lanterns aqua, and so on (the table is in LightSourceBuffer.java).
// There are no shadows from these lights yet; until then, vanilla's block light level is used to
// tell whether a light can actually reach a surface (see lights.glsl).

// Master switch. false = vanilla block light only.
const bool  COLORED_LIGHT_ENABLED   = true;

// How much of vanilla's fixed warm block light is replaced by the real colors of nearby lights.
// The new light color keeps vanilla's peak brightness, so a saturated light (lava) filters the
// surface instead of overexposing it. 0.0 = vanilla hue, 1.0 = fully the lights' hue.
const float COLORED_LIGHT_TINT      = 0.85;

// Extra colored light added on top near a light source, as a fraction of the surface color.
// 0.0 = none. Higher gives a stronger colored glow on nearby blocks.
const float COLORED_LIGHT_EXTRA     = 0.20;

// Ceiling for the brightness (luma) of all colored light that reaches one surface, however many
// lights there are. Every lava block is a light, so a lava lake gives a surface a dozen of them; with
// no ceiling that is several times one light and the surface turns flat saturated orange. The sum is
// soft-limited (a single nearby light keeps about 85%) and keeps its hue. Lower = calmer lava and
// glowstone clusters, higher = closer to the old unlimited sum.
const float COLORED_LIGHT_MAX       = 1.20;

// How strongly a surface must face a light to receive it. 0.0 = every face gets the same light
// (flat), 1.0 = faces turned away get none. Without shadows, a moderate value looks best.
const float COLORED_LIGHT_FACING    = 0.55;

// Occlusion guess: a light is ignored where vanilla's block light is this many levels below what
// the light would give with nothing in the way. Smaller = stricter (less leaking through walls,
// but more flicker at corners). Replaced by real shadows in a later phase.
const float COLORED_LIGHT_OCCLUSION_SLACK = 3.0;

// ---- Phase 6b: light halos (lib/lights.glsl, composite pass) ----
//
// A soft glow around every listed light, in the light's color. It shows only where the scene behind
// the pixel is farther than the light, so a wall in front of a torch hides the torch's glow.

// Master switch.
const bool  HALO_ENABLED            = true;

// Glow brightness. 0.0 = invisible. The glow is soft-limited, so this is also the most it can add.
const float HALO_STRENGTH           = 0.30;

// Glow size in blocks for an average light. Brighter lights get a larger glow.
const float HALO_RADIUS             = 0.60;

// A light's own surface sits this much in front of its center. The glow must still show on it.
const float HALO_FRONT_BIAS         = 0.7;

// Lights closer to the camera than START give no glow, fully back at END (in blocks). Without
// this a light next to the player would cover the whole screen.
const float HALO_NEAR_FADE_START    = 0.8;
const float HALO_NEAR_FADE_END      = 3.0;

// Strength by full daylight, as a fraction of HALO_STRENGTH. Halos belong to the dark.
const float HALO_DAY_FACTOR         = 0.15;

// ---- Phase 6c: sun glint on glass and water (lib/glint.glsl, gbuffers_water) ----
//
// Surfaces that face the sun get a soft sheen, brighter at the mirror angle, with a few sparkles.
// Deliberately not a real reflection. Plain glass is moved to the translucent layer in
// block.properties so that the whole pane, not just its frame, can show the sheen.

// Master switch.
const bool  GLINT_ENABLED           = true;

// Overall opacity of the sheen over the glass. 0.0 = invisible.
const float GLINT_STRENGTH          = 0.55;

// N.L at which a surface starts to catch the light (0.25 = about 75 degrees off the sun).
const float GLINT_FACING_MIN        = 0.25;

// Sheen that does not depend on the view angle, and the extra at the mirror angle.
const float GLINT_SHEEN             = 0.30;
const float GLINT_SPECULAR          = 0.70;
// How tight the mirror-angle highlight is. Higher = smaller.
const float GLINT_SHARPNESS         = 16.0;

// Sparkles: cells per block, share of cells that twinkle, brightness and speed.
const float GLINT_SPARKLE_DENSITY   = 6.0;
const float GLINT_SPARKLE_AMOUNT    = 0.18;
const float GLINT_SPARKLE           = 0.60;
const float GLINT_TWINKLE_SPEED     = 2.5;

// Moonlight sheen as a fraction of sunlight, and the share of the effect water gets.
const float GLINT_MOON_FACTOR       = 0.35;
const float GLINT_WATER_FACTOR      = 0.50;

// ---- Phase 7: sun and moon shadows (lib/shadows.glsl, shadow.vsh, deferred pass) ----
//
// The game draws the scene once from the sun (or moon) into a shadow map; the deferred pass looks each
// surface up in it. The look is soft and light on purpose: shadows only take part of the sun's light
// away, in a slightly cool color, and the edge is filtered over a fraction of a block.
//
// The first four constants below are read by the game itself (Iris finds them in the shader source),
// not by the pack, so keep them as plain "const type name = value;" lines.

// Shadow map size in texels. 2048 is a good balance, 1024 is faster and blurrier, 4096 is sharper.
const int   shadowMapResolution = 2048;

// Half the width of the area the shadow map covers around the player, in blocks. Beyond it there
// are no shadows (they fade out over the last part). Smaller = sharper shadows near the player.
const float shadowDistance      = 128.0;

// Read the shadow map with nearest filtering. The pack filters it itself, so this must stay true.
const bool  shadowtex1Nearest   = true;

// Tilt of the sun's path, in degrees. 0 puts the sun straight overhead at noon (shadows fall
// straight down); a tilt gives shadows a direction at every hour. Also tilts the moon.
const float sunPathRotation     = 20.0;

// Master switch for the shadow lookup. false = no sun shadows. The shadow map is still drawn, so
// this saves the per-pixel work, not the map.
const bool  SHADOW_ENABLED      = true;

// How much light a fully shadowed surface keeps, per channel. 1.0 = no shadow at all. A little bluer
// than red so shadows read as cool and soft. The pastel grade in the final pass lifts them further.
const vec3  SHADOW_COLOR        = vec3(0.62, 0.66, 0.78);

// Scales the whole effect. 0.0 = no shadows, 1.0 = as written above.
const float SHADOW_STRENGTH     = 1.0;

// Moonlight shadows as a fraction of sunlight shadows.
const float SHADOW_MOON_FACTOR  = 0.35;

// How much rain removes of the shadows (1.0 = none left in full rain).
const float SHADOW_RAIN_REDUCTION = 0.75;

// Shadows fade out as the light sinks to the horizon, where they would be endless and the map is
// stretched thin. These are the sine of the light's height: 0.04 is about 2 degrees, 0.22 about 13.
const float SHADOW_HORIZON_START = 0.04;
const float SHADOW_HORIZON_END   = 0.22;

// Softness: the width of the filtered edge in blocks, and the most it may grow in map texels (far
// shadows, where a texel is large, are blurred by whole texels and not by this width). Samples is the
// number of map reads per pixel; fewer is faster but grainier.
const float SHADOW_SOFTNESS          = 0.20;
const float SHADOW_BLUR_MAX_TEXELS   = 4.0;
const int   SHADOW_SAMPLES           = 12;

// The map is stretched so that texels near the player are smaller. 0.0 = even, 0.85 = strong. Used by
// shadow.vsh and the lookup, so both always agree.
const float SHADOW_DISTORTION        = 0.85;

// Self-shadowing control. The surface is moved along its normal by this many texels before the
// lookup, plus a small depth offset in blocks and in texels. Raise them if surfaces show stripes
// or dots; lower them if shadows detach from the objects that cast them.
const float SHADOW_NORMAL_OFFSET     = 1.5;
const float SHADOW_BIAS_BLOCKS       = 0.02;
const float SHADOW_BIAS_TEXELS       = 0.5;

// Where the shadow area's edge starts to fade, as a fraction of its half width.
const float SHADOW_EDGE_FADE_START   = 0.80;

// ---- Level of detail (lib/lod.glsl, and the halo list in LightSourceBuffer.java) ----
//
// Work nobody can see is skipped or done more cheaply. What counts as visible is judged by how many
// screen pixels one block covers at a given distance. That depends on the window height and the
// field of view, so a small window loses detail sooner than a tall one.
// Rough guide at a 70 degree field of view: pixels per block = window height / (1.4 * distance),
// so at 1080 pixels high a block covers about 12 pixels at 64 blocks and 6 pixels at 128 blocks.

// Master switch. false = everything always at full detail.
const bool  LOD_ENABLED                    = true;

// Edge glow: below MIN pixels per block there is no glow (its lines would sit so close together
// that they merge into bands), and nothing is computed. It is at full strength from FULL.
const float LOD_EDGE_MIN_PIXELS_PER_BLOCK  = 2.5;
const float LOD_EDGE_FULL_PIXELS_PER_BLOCK = 6.0;

// The filter that ignores 1 or 2 texel steps (EDGE_MIN_STEP_HEIGHT) is skipped where such a step is
// shorter than this many pixels on screen, because it could not be seen anyway.
const float LOD_THIN_STEP_MIN_PIXELS       = 1.5;

// Colored light: at FULL pixels per block and above, every light of a surface's cell is used. At MIN
// and below only the strongest LOD_COLORED_LIGHTS_MIN of them are, with a smooth change in between.
const float LOD_LIGHT_MIN_PIXELS_PER_BLOCK  = 3.0;
const float LOD_LIGHT_FULL_PIXELS_PER_BLOCK = 10.0;
const int   LOD_COLORED_LIGHTS_MIN          = 4;

#endif
