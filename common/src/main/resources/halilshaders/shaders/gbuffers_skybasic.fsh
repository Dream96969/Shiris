#version 330 compatibility

/* DRAWBUFFERS:0 */

// fogColor, skyColor, upPosition and the other atmosphere uniforms are declared by this include.
#include "/lib/atmosphere.glsl"

uniform mat4 gbufferProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;
uniform int renderStage;

in vec4 glcolor;

void main() {
	// Stars and the sunrise/sunset glow keep their vanilla vertex colors.
	if (renderStage == MC_RENDER_STAGE_STARS || renderStage == MC_RENDER_STAGE_SUNSET) {
		gl_FragData[0] = glcolor;
		return;
	}

	// Sky dome. The color comes from the shared atmosphere function, the same one the fog on
	// terrain uses, so far terrain fades into the sky without a seam.
	vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
	vec4 p = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 viewDir = normalize(p.xyz / p.w);

	gl_FragData[0] = vec4(atmosphereColor(viewDir), 1.0);
}
