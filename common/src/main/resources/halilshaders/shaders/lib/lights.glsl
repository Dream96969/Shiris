#ifndef HS_LIGHTS_GLSL
#define HS_LIGHTS_GLSL

// Light list from the fork: net.irisshaders.iris.lights.LightSourceBuffer finds light-emitting
// blocks on the CPU (every loaded chunk within the render distance) and writes them into a shader
// storage buffer.
//
// Two views of the same lights are in the buffer:
//  - a grid of 16 block cells holding, per cell, the lights that reach it. Its size is in the buffer
//    header (it follows the render distance). A surface reads only its own cell, so it gets the
//    lights close to IT, however far it is from the camera. coloredLightAt uses this.
//  - a short halo list: the lights most influential to the CAMERA. Halos are drawn along view rays,
//    not on surfaces, so lightHalos uses this.
//
// Needs #version 430 or newer in the including program (shader storage buffers).
// Declares its own uniforms (gbufferModelViewInverse through viewmatrix.glsl, plus everything
// atmosphere.glsl declares).
// The buffer layout must match the header comment of LightSourceBuffer.java.

#include "/lib/settings.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/fastmath.glsl"
#include "/lib/viewmatrix.glsl"

struct HsLight {
	vec4 posRadius;      // xyz = light center minus a reference point, in world axes (the camera for
	                     // the halo list, the grid corner for the candidates). w = reach in blocks
	vec4 colorIntensity; // rgb = color, a = emission level / 15
};

// Sizes below must match LightSourceBuffer.java (MAX_LIGHTS, MAX_CANDIDATES, CELL_SIZE,
// CELL_STRIDE_INTS). The grid size is not a constant: it is read from hsGridDims.
const int HS_HALO_CAPACITY = 64;
const int HS_CANDIDATE_CAPACITY = 32768;
const int HS_GRID_STRIDE = 16;
const float HS_CELL_SIZE = 16.0;

// Luma weights, used to limit the brightness of a summed light while keeping its hue.
const vec3 HS_LIGHT_LUMA = vec3(0.2126, 0.7152, 0.0722);

// 1 / ln(2): exp(x) is exp2(x * HS_INV_LN2).
const float HS_INV_LN2 = 1.4426950409;

layout(std430, binding = 7) readonly buffer HsLightBuffer {
	ivec4 hsLightHeader;  // x = number of lights in the halo list
	ivec4 hsGridDims;     // xyz = grid size in cells; all zero until the first grid is built
	vec4 hsGridOrigin;    // xyz = corner of the grid's first cell, minus camera, in world axes
	HsLight hsLights[64];          // halo list (HS_HALO_CAPACITY), positions relative to the camera
	HsLight hsCandidates[32768];   // every known light (HS_CANDIDATE_CAPACITY), positions relative to the grid corner
	int hsGrid[];                  // cells of 16 ints each: [count, light indices...]
};

// Colored light arriving at a surface from the lights in its grid cell.
//   viewPos, viewNormal: view-space position and unit normal of the surface.
//   blockLevel: vanilla block light at the surface, 0..1.
//   detail: 0..1 level of detail (lib/lod.glsl). 1 = use every light of the cell. Lower values use only
//   the strongest few, because the fork lists each cell strongest first.
// Returns rgb = summed light color and a = coverage 0..1, how much of the surface's block light the
// listed lights explain.
//
// The brightness of rgb is soft-limited: its luma (brightness) never goes above COLORED_LIGHT_MAX,
// whatever the number of lights, and its hue is kept. Every lava block is a light, and a cell lists
// up to 15 of them, so beside a lava lake the plain sum was several times what one light gives and
// drowned the surface color in saturated orange. One nearby light keeps about 85% of its sum, three
// or four keep about half, a lava lake saturates at the ceiling.
vec4 coloredLightAt(vec3 viewPos, vec3 viewNormal, float blockLevel, float detail) {
	// Candidate light positions are relative to the grid corner. Work in that frame: gridPos is the
	// surface position with the grid corner as the origin.
	vec3 worldPos = viewToFeetPosition(viewPos);
	vec3 worldNormal = viewToFeetDirection(viewNormal);
	vec3 gridPos = worldPos - hsGridOrigin.xyz;

	// Which grid cell the surface is in. Outside the grid (beyond the render distance) there is no
	// data. This check stays a branch: reading the buffer out of bounds is not allowed.
	ivec3 cell = ivec3(floor(gridPos * (1.0 / HS_CELL_SIZE)));
	if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, hsGridDims.xyz))) {
		return vec4(0.0);
	}
	int cellBase = ((cell.x * hsGridDims.y + cell.y) * hsGridDims.z + cell.z) * HS_GRID_STRIDE;
	int count = min(hsGrid[cellBase], HS_GRID_STRIDE - 1);

	// Level of detail: use the first few lights of the cell (the strongest), more as detail rises. The
	// last light used is faded in with the fractional part, so nothing pops as the distance changes.
	float allowed = mix(float(min(count, LOD_COLORED_LIGHTS_MIN)), float(count), detail);
	count = min(count, int(ceil(allowed)));

	// Center of the air block in front of the surface: that is where vanilla measured its light.
	vec3 airPos = gridPos + worldNormal * 0.5;
	float actualLevel = blockLevel * 15.0;

	vec3 sum = vec3(0.0);
	float coverage = 0.0;

	for (int i = 0; i < count; i++) {
		float lodWeight = clamp(allowed - float(i), 0.0, 1.0);
		int lightIndex = clamp(hsGrid[cellBase + 1 + i], 0, HS_CANDIDATE_CAPACITY - 1);
		HsLight light = hsCandidates[lightIndex];
		vec4 posRadius = light.posRadius;

		// Distance as a square first: a light out of reach is skipped before any sqrt is spent on it.
		// These early exits stay branches because everything below them is real work.
		vec3 toLight = posRadius.xyz - gridPos;
		float distSq = dot(toLight, toLight);
		if (distSq >= posRadius.w * posRadius.w) continue;

		// One inversesqrt gives both the distance and the direction to the light.
		float invDist = inversesqrt(max(distSq, 1.0e-8));
		float atten = 1.0 - distSq * invDist * rcp(posRadius.w);
		atten *= atten;

		// Occlusion guess, until lights have real shadows. Vanilla block light drops by one per
		// block of walking distance (Manhattan), and a wall in the way makes the walk longer. So
		// if the surface is much darker than "emission minus walking distance" says it should be,
		// something is blocking this light.
		vec3 walk = abs(posRadius.xyz - airPos);
		float expectedLevel = posRadius.w - (walk.x + walk.y + walk.z);
		float visible = clamp((actualLevel - expectedLevel + COLORED_LIGHT_OCCLUSION_SLACK) * (1.0 / COLORED_LIGHT_OCCLUSION_SLACK), 0.0, 1.0);
		// Blocked by a wall: nothing more to compute for this light.
		if (visible <= 0.0) continue;

		// Faces turned toward the light get more.
		float facing = mix(1.0 - COLORED_LIGHT_FACING, 1.0, clamp(dot(worldNormal, toLight * invDist), 0.0, 1.0));

		float weight = atten * visible * lodWeight;
		sum += light.colorIntensity.rgb * (weight * facing);
		coverage += weight;
	}

	// Soft limit on the brightness of the sum, hue untouched. x -> MAX * (1 - exp(-x / MAX)) is
	// almost x for small x and never passes MAX. The luma floor only guards the division: for an
	// empty sum, limited is 0 as well.
	float lum = dot(sum, HS_LIGHT_LUMA);
	float limited = COLORED_LIGHT_MAX * (1.0 - exp2(-lum * (HS_INV_LN2 / COLORED_LIGHT_MAX)));
	sum *= limited * rcp(max(lum, 0.0001));

	return vec4(sum, min(coverage, 1.0));
}

// Soft glow around the halo-list lights, in each light's color, for a pixel that looks along viewDir
// (unit, view space) at a scene sceneDist blocks away (use a huge value for sky pixels).
//
// The glow is a Gaussian in the angle between the pixel's ray and the direction to the light, so it
// has a fixed size in blocks and looks smaller farther away. It is visible only where the scene is
// behind the light: a wall in front of a torch hides the torch's glow, and the wall behind it
// receives it.
//
// Three things keep it from misbehaving:
//  - the angular size is capped, so the glow is already invisible where the ray turns 90 degrees
//    away from the light (a cut there would leave a hard straight line across the screen);
//  - lights right next to the camera fade out instead of flooding the view;
//  - the sum is soft-limited, so overlapping lights add up to a bright glow, never to a white blowout.
vec3 lightHalos(vec3 viewDir, float sceneDist) {
	vec3 worldDir = viewToFeetDirection(viewDir);

	vec3 sum = vec3(0.0);
	int count = min(hsLightHeader.x, HS_HALO_CAPACITY);
	for (int i = 0; i < count; i++) {
		// The fork scales a halo light's color by how visible it is (0 when culled or fading out).
		if (dot(hsLights[i].colorIntensity.rgb, vec3(1.0)) <= 0.0001) continue;

		vec3 toLight = hsLights[i].posRadius.xyz;
		float distSq = dot(toLight, toLight);
		float invDist = inversesqrt(max(distSq, 1.0e-8));
		float lightDist = distSq * invDist;

		float nearFade = smoothstep(HALO_NEAR_FADE_START, HALO_NEAR_FADE_END, lightDist);
		if (nearFade <= 0.0) continue;

		float cosAngle = dot(worldDir, toLight * invDist);
		if (cosAngle <= 0.0) continue;

		// Brighter lights glow wider. 1 - cos is about half the angle squared, so q is
		// (angle / angular radius) squared. With the radius capped at 0.5 rad, q is at least 8 at
		// cos = 0, where exp(-q) is far below visibility.
		float radius = HALO_RADIUS * (0.5 + hsLights[i].colorIntensity.a);
		float angular = min(radius * invDist, 0.5);
		float q = 2.0 * (1.0 - cosAngle) * rcp(angular * angular);
		if (q > 9.0) continue;

		// The light's own surface is in front of its center, so allow for that before hiding.
		float visible = smoothstep(lightDist - HALO_FRONT_BIAS - 0.5, lightDist - HALO_FRONT_BIAS + 0.5, sceneDist);

		sum += hsLights[i].colorIntensity.rgb * (exp2(-q * HS_INV_LN2) * visible * nearFade);
	}

	// Soft limit: close to linear for faint glow, never above 1.
	return 1.0 - exp2(-sum * HS_INV_LN2);
}

#endif
