#version 430 compatibility

/* DRAWBUFFERS:0 */

#include "/lib/settings.glsl"
// The atmosphere include also declares fogColor, sunPosition, upPosition and rainStrength.
// Keep comments off the include lines themselves: Iris cannot resolve an include with a trailing comment.
#include "/lib/atmosphere.glsl"
#include "/lib/fastmath.glsl"
// Keeps glow and halo additions inside 0..1 without changing the hue.
#include "/lib/range.glsl"
// Level of detail: skips work that cannot be seen at this window size and distance.
#include "/lib/lod.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex3;
// Light halos, drawn at half size by composite.fsh (see the notes there).
uniform sampler2D colortex4;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform mat4 gbufferProjectionInverse;
uniform float fogStart;
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;
// Per-frame values from composite1.vsh (see the notes there).
flat in vec3 atmoUp;
flat in vec3 atmoSunDir;
flat in vec3 atmoBiome;
flat in vec3 atmoGlow;
flat in vec3 toLightDir;
flat in vec4 frameA;
flat in vec2 frameB;

// Neighbours whose 1/z differs by more than this fraction are different surfaces. Their normals
// are not compared, because the depth test already reports that edge.
const float EDGE_NORMAL_DEPTH_MASK = 0.15;

// 1 / view-space distance along z. For a perspective projection this is a straight line across
// the screen for any flat surface, at any angle, so its second difference is zero on flat
// surfaces and large only where depth really jumps. x and y do not affect z in the inverse
// projection, so they are left at 0.
float inverseViewDepth(float depth) {
	vec4 p = gbufferProjectionInverse * vec4(0.0, 0.0, depth * 2.0 - 1.0, 1.0);
	return -p.w * rcp(p.z);
}

// colortex3 (see docs/shader-pipeline.md):
// r = block light level, g = 1 when the surface may glow, b = sun visibility,
// a = block light visibility. It clears to 0, so pixels nothing wrote to may not glow.
bool mayGlow(vec4 aux) {
	return aux.g > 0.5;
}

vec3 viewPosAt(vec2 uv, float depth) {
	vec4 p = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
	return p.xyz * rcp(p.w);
}

// True when what lies a few pixels further along dirUv (one pixel per unit) is the same kind of
// surface as this one, offset from this surface's plane by no more than EDGE_MIN_STEP_HEIGHT.
// What lies between is then a thin ledge, like the 1/16 block step between a path block and a
// grass block, and it must not glow.
//
// The distance to look is the screen size of EDGE_MIN_STEP_HEIGHT at this depth, so the test is
// in blocks, not pixels: it behaves the same up close and far away. A taller step or a block
// corner keeps the sample on the side face (a different normal) or puts it far from the plane.
bool isThinStep(vec2 uv, vec2 dirUv, vec3 posC, vec3 nc, float pixelsPerBlock) {
	float kPx = clamp(ceil(EDGE_MIN_STEP_HEIGHT * pixelsPerBlock) + 2.0, 3.0, 160.0);
	vec2 farUv = uv + dirUv * kPx;
	float farDepth = texture(depthtex1, farUv).r;
	if (farDepth >= 1.0) return false;

	vec3 nf = fastNormalize(texture(colortex1, farUv).rgb * 2.0 - 1.0);
	float offPlane = abs(dot(viewPosAt(farUv, farDepth) - posC, nc));
	return dot(nf, nc) > 0.9 && offPlane <= EDGE_MIN_STEP_HEIGHT * 1.25;
}

// 0..1 edge strength for a solid (non-sky) pixel.
//
// Two kinds of edge, each weighted by how much light reaches the surface:
//  - crease: two faces of one surface meet. Glows on the side that faces the light more than its
//    neighbour, in proportion to that difference.
//  - silhouette: this pixel is nearer than what is next to it. Glows weaker, and only on
//    surfaces that face the light.
// Light reaching the surface = exposure (sky light, rain, light visibility) * facing.
// Light visibility comes from colortex3, never from the shadow map, so shadows and glow
// cannot disagree.
//
// The early returns and the texture reads behind an if stay branches on purpose: each of them skips
// real work (neighbour reads, the thin-step walk). Only cheap value choices are written as arithmetic.
float edgeAmount(vec2 uv, float depth) {
	vec4 aux = texture(colortex3, uv);
	if (!mayGlow(aux)) return 0.0;

	// ic is 1 / distance, so dist is its reciprocal and 1 / ic below is dist again.
	float ic = inverseViewDepth(depth);
	float dist = rcp(ic);

	// Far away the glow fades out. Skipping the neighbour reads there is also the cheap path.
	float fade = 1.0 - smoothstep(EDGE_FADE_START, EDGE_FADE_END, dist);
	if (fade <= 0.0) return 0.0;

	// Level of detail. Where a block covers only a few screen pixels the lines would be a pixel or two
	// apart and merge into bands, so the glow thins out and then is not computed at all. The same
	// number tells whether the thin-step filter below could change anything.
	float pixelsPerBlock = lodPixelsPerBlock(dist, viewHeight, gbufferProjectionInverse[1][1]);
	float detail = lodEdgeDetail(pixelsPerBlock);
	if (detail <= 0.0) return 0.0;
	bool checkThinSteps = !LOD_ENABLED || EDGE_MIN_STEP_HEIGHT * pixelsPerBlock >= LOD_THIN_STEP_MIN_PIXELS;

	vec4 geometry = texture(colortex1, uv);
	vec3 nc = fastNormalize(geometry.rgb * 2.0 - 1.0);

	// Sun by day, moon by night: toLightDir points at whichever is up, and frameA.x is the glow
	// strength of that light (both worked out once per frame in composite1.vsh).
	vec3 toLight = toLightDir;
	float lightPower = frameA.x;
	float sunFacing = max(dot(nc, toLight), 0.0);

	// Same sky exposure and rain dimming as the directional light in deferred.fsh. A surface that
	// does not face the light gets 0 from the step, so no branch is needed.
	float sunBudget = step(1.0e-6, sunFacing)
		* geometry.a * geometry.a * (1.0 - 0.8 * rainStrength) * lightPower * EDGE_SUN_STRENGTH * aux.b;
	float blockBudget = smoothstep(EDGE_BLOCKLIGHT_MIN, 1.0, aux.r) * EDGE_BLOCKLIGHT_STRENGTH * aux.a;

	// Shaded surfaces, caves without lights, nights without torches: nothing can glow here.
	if (max(sunBudget, blockBudget) <= 0.001) return 0.0;

	// Lines are EDGE_GLOW_WIDTH pixels wide up close and thin to 1 pixel with distance.
	float width = mix(EDGE_GLOW_WIDTH, 1.0, smoothstep(0.0, EDGE_FADE_END, dist));
	vec2 px = width * rcp(vec2(viewWidth, viewHeight));
	float invWidth = rcp(width);
	vec2 offsets[4] = vec2[4](vec2(px.x, 0.0), vec2(-px.x, 0.0), vec2(0.0, px.y), vec2(0.0, -px.y));

	float inv[4];
	float creaseAny = 0.0; // strongest crease next to this pixel, regardless of light direction
	float creaseSun = 0.0; // the same, weighted by how much more this side faces the sun
	vec3 posC = viewPosAt(uv, depth);
	for (int k = 0; k < 4; k++) {
		vec2 nuv = uv + offsets[k];
		inv[k] = inverseViewDepth(texture(depthtex1, nuv).r);

		// Compare normals only against neighbours that are the same surface and may glow too.
		// This keeps foliage and entities from creating lines on the ground next to them.
		if (abs(inv[k] - ic) < ic * EDGE_NORMAL_DEPTH_MASK && mayGlow(texture(colortex3, nuv))) {
			vec3 nn = fastNormalize(texture(colortex1, nuv).rgb * 2.0 - 1.0);
			float crease = smoothstep(EDGE_NORMAL_THRESHOLD, EDGE_NORMAL_THRESHOLD * 2.0, 1.0 - dot(nc, nn));

			// Steps of a texel or two (path next to grass, carpet, slabs of thin trim) do not glow.
			if (crease > 0.0 && checkThinSteps && isThinStep(uv, offsets[k] * invWidth, posC, nc, pixelsPerBlock)) {
				crease = 0.0;
			}

			float bevel = clamp((sunFacing - max(dot(nn, toLight), 0.0)) * (1.0 / EDGE_BEVEL_FULL), 0.0, 1.0);
			creaseAny = max(creaseAny, crease);
			creaseSun = max(creaseSun, crease * bevel);
		}
	}

	// Positive only when this pixel is nearer than its neighbours (the near side of a silhouette
	// or the ridge of a convex corner), so the rim sits on the object, not on what is behind it.
	float depthEdge = max(2.0 * ic - inv[0] - inv[1], 2.0 * ic - inv[2] - inv[3]) * dist;
	float silhouette = smoothstep(EDGE_DEPTH_THRESHOLD, EDGE_DEPTH_THRESHOLD * 2.0, depthEdge) * EDGE_SILHOUETTE_FACTOR;

	float sunEdge = max(creaseSun, silhouette * smoothstep(EDGE_LIGHT_FACING_MIN, 1.0, sunFacing));
	float blockEdge = max(creaseAny, silhouette);

	return clamp(max(sunBudget * sunEdge, blockBudget * blockEdge), 0.0, 1.0) * fade * detail;
}

void main() {
	vec4 scene = texture(colortex0, texcoord);
	float depth = texture(depthtex0, texcoord).r;

	// Where this pixel is: view-space position, distance and view direction, for the fog. For sky
	// pixels this is a point on the far plane, which still gives the right direction.
	vec3 viewPos = viewPosAt(texcoord, depth);
	float dist = fastLength(viewPos);
	vec3 viewDir = viewPos * rcp(dist);

	// Edge glow runs before fog so distant rims fade out with the haze. Sky has no edges, and the
	// branch skips every neighbour read.
	if (EDGE_GLOW_ENABLED) {
		float solidDepth = texture(depthtex1, texcoord).r;
		if (solidDepth < 1.0) {
			float edge = edgeAmount(texcoord, solidDepth);

			// Rim color: the light's color mixed with the surface's own hue at full brightness.
			// A rim reflects light, so it is stronger on bright surfaces than on dark ones.
			float peak = max(max(scene.r, scene.g), scene.b);
			vec3 hue = scene.rgb * rcp(max(peak, 0.001));
			vec3 rim = mix(EDGE_GLOW_LIGHT_TINT, hue, EDGE_GLOW_COLOR_INFLUENCE);
			scene.rgb += rim * edge * EDGE_GLOW_STRENGTH * (0.4 + 0.6 * peak);
		}
	}

	// Light halos: a soft glow around torches, lava, glowstone and the like, before fog so that
	// distant halos fade with the haze. composite.fsh drew them at half size into the lower left
	// quarter of colortex4, already multiplied by their strength for the time of day. By day they are
	// almost gone: when that strength is below what an 8 bit color can show, there is nothing to read.
	if (HALO_ENABLED && frameA.y > 0.002) {
		// Half a pixel of the half size picture in from each side of its quarter, so that bilinear
		// filtering never blends in the unused rest of the buffer.
		vec2 halfTexel = 0.5 * rcp(vec2(viewWidth, viewHeight));
		vec2 haloUV = clamp(texcoord * 0.5, halfTexel, vec2(0.5) - halfTexel);
		scene.rgb += texture(colortex4, haloUV).rgb;
	}

	// Rim and halo light is added on top of the lit scene. Fit the sum into 0..1 before fog so a
	// bright surface does not clip per channel.
	scene.rgb = fitToRange(scene.rgb);

	// Sky pixels already have the atmosphere color, so the fog work is skipped for them.
	if (depth < 1.0) {
		// Environmental fog (haze, underwater, lava, blindness) as reported by the game; the length
		// of its range is already inverted in frameB.x, and 0 there when the game reports no range.
		float envFog = clamp((dist - fogStart) * frameB.x, 0.0, 1.0);

		// Render distance fog hides the edge of the loaded world (start and 1 / length: frameA.zw).
		float rdFog = clamp((dist - frameA.z) * frameA.w, 0.0, 1.0);

		// How much fog is decided above; its color comes from the shared atmosphere, the same
		// function the sky uses, so distant terrain fades into the sky behind it.
		scene.rgb = mix(scene.rgb, fogColorFrom(viewDir, atmoUp, atmoSunDir, atmoBiome, atmoGlow, frameB.y), max(envFog, rdFog));
	}

	gl_FragData[0] = scene;
}
