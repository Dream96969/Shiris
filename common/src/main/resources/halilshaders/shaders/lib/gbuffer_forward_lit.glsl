// Translucent geometry drawn after the deferred pass: lit here with the vanilla lightmap.
//
// Optional, chosen by the including program:
//   HS_CLEAR_EDGE_FLAG = also write colortex3 = "no edge glow" (translucent entities)
//   HS_GLINT           = add the sun glint (glass, ice, water). The including fragment shader must
//                        include "/lib/glint.glsl" before this file, and the vertex shader must define
//                        HS_GLINT too, for viewPosition and isWaterSurface. (Iris inlines includes before
//                        evaluating conditions, so the glint library cannot be included from here.)

uniform sampler2D gtexture;
uniform sampler2D lightmap;
uniform vec4 entityColor;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
#ifdef HS_GLINT
in vec3 viewNormal;
in vec3 viewPosition;
in float isWaterSurface;
#endif

void main() {
	vec4 color = texture(gtexture, texcoord) * glcolor;

#ifdef HS_GLINT
	// The glint is computed before the transparent-texel discard: a glass pane is mostly
	// transparent texture, and the sheen must still show across all of it.
	vec4 glint = vec4(0.0);
	if (GLINT_ENABLED) {
		float skyLevel = clamp((lmcoord.y - 0.03125) * 1.0666667, 0.0, 1.0);
		glint = sunGlint(viewPosition, normalize(viewNormal), skyLevel);
		glint.a *= GLINT_STRENGTH * mix(1.0, GLINT_WATER_FACTOR, isWaterSurface);
	}
	if (color.a < 0.01 && glint.a < 0.01) discard;
#else
	if (color.a < 0.01) discard;
#endif

	color.rgb = mix(color.rgb, entityColor.rgb, entityColor.a);
	color.rgb *= texture(lightmap, lmcoord).rgb;

#ifdef HS_GLINT
	// Lay the glint over the lit surface (the usual "over" blend of two layers).
	float outAlpha = glint.a + color.a * (1.0 - glint.a);
	color.rgb = (glint.rgb * glint.a + color.rgb * color.a * (1.0 - glint.a)) / max(outAlpha, 0.0001);
	color.a = outAlpha;
#endif

	gl_FragData[0] = color;
#ifdef HS_CLEAR_EDGE_FLAG
	// Opaque alpha, so blending replaces colortex3 with "no edge glow" under this surface.
	gl_FragData[1] = vec4(0.0, 0.0, 0.0, 1.0);
#endif
}
