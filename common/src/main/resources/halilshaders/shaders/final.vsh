#version 330 compatibility

// The pastel grade's palette and strength depend only on uniforms (sky color, sun position), so they
// are worked out here, four vertices per frame, and not again for every pixel in final.fsh. Each
// one costs several OKLab conversions, which are full of pow calls.
//
// skyColor, sunPosition, upPosition and sunLightColor() come from the atmosphere include.
// Keep comments off the include lines themselves: Iris cannot resolve an include with a trailing comment.
#include "/lib/settings.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/oklab.glsl"

out vec2 texcoord;

// xy = shadow tint, zw = highlight tint (OKLab a and b shifts), and the amount of grade 0..1.
flat out vec4 gradeTints;
flat out float gradeAmount;

// A sky or light color with at least this much OKLab chroma gets the full tint.
// Less colorful ones (gray rain sky, noon sun) get proportionally less.
const float TINT_FULL_CHROMA = 0.10;

// The hue direction of a color as an OKLab (a, b) shift, scaled by how colorful it is.
vec2 tintFrom(vec3 encoded) {
	vec2 ab = toOklab(encoded).yz;
	float len = fastLength(ab);
	return fastNormalize(ab) * (clamp(len * (1.0 / TINT_FULL_CHROMA), 0.0, 1.0) * PASTEL_TINT_CHROMA);
}

void main() {
	gl_Position = ftransform();
	texcoord = gl_MultiTexCoord0.xy;

	// Sun elevation: 1 = overhead, 0 = horizon, -1 = straight below.
	float e = fastCosAngle(sunPosition, upPosition);

	// Time of day weights, always adding up to 1. Dusk is sunrise and sunset.
	float day = smoothstep(0.05, 0.40, e);
	float night = 1.0 - smoothstep(-0.25, 0.0, e);
	float dusk = 1.0 - day - night;
	gradeAmount = day * PASTEL_AMOUNT_DAY + dusk * PASTEL_AMOUNT_DUSK + night * PASTEL_AMOUNT_NIGHT;

	gradeTints = vec4(tintFrom(skyColor), tintFrom(sunLightColor(e)));
}
