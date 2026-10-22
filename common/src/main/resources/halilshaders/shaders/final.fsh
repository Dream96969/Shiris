#version 330 compatibility

// Only the pastel settings are needed here. The palette (skyColor and sun based tints) and the
// amount of grade are computed once per frame in final.vsh and arrive as flat varyings.
// Keep comments off the include lines themselves: Iris cannot resolve an include with a trailing comment.
#include "/lib/settings.glsl"
#include "/lib/oklab.glsl"

uniform sampler2D colortex0;

in vec2 texcoord;
flat in vec4 gradeTints;
flat in float gradeAmount;

// Pastel look, applied in the game's native color space (no gamma conversion outside this file).
vec3 pastelGrade(vec3 c, vec2 shadowTint, vec2 lightTint) {
	vec3 lab = toOklab(c);

	// 1. Chroma squeeze: the more colorful a pixel, the more it is pulled in. Muted colors
	//    (wood, stone) barely change, neon ones calm down.
	float chroma = fastLength(lab.yz);
	lab.yz *= mix(1.0, rcp(1.0 + chroma * (1.0 / PASTEL_CHROMA_KNEE)), PASTEL_CHROMA_COMPRESS);

	// 2. Milky shadows: lift strongest at black, none at white, so mid tones keep their contrast.
	float dark = 1.0 - lab.x;
	lab.x += PASTEL_LIFT * dark * dark;

	// 3. Palette: shadows take the sky's tint, highlights take the sun's. Strongly colored pixels
	//    (lava glow, torch light) keep their own hue, so the tint is faded out as chroma rises.
	float shadowWeight = 1.0 - smoothstep(0.35, 0.80, lab.x);
	float lightWeight = smoothstep(0.55, 0.95, lab.x);
	float tintKeep = 1.0 - PASTEL_TINT_PROTECT * smoothstep(PASTEL_TINT_PROTECT_START, PASTEL_TINT_PROTECT_END, chroma);
	lab.yz += (shadowTint * shadowWeight + lightTint * lightWeight) * tintKeep;

	return fromOklab(lab);
}

void main() {
	vec4 scene = texture(colortex0, texcoord);

	if (PASTEL_ENABLED) {
		vec3 graded = pastelGrade(scene.rgb, gradeTints.xy, gradeTints.zw);
		scene.rgb = mix(scene.rgb, graded, gradeAmount);
	}

	gl_FragData[0] = scene;
}
