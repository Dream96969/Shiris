// Opaque geometry: write data for the deferred pass and the edge glow.
//   colortex0 = albedo
//   colortex1 = view-space normal (rgb), sky light level (a)
//   colortex2 = vanilla lightmap color (rgb), 1.0 (a)
//   colortex3 = block light level (r), edge glow allowed flag (g), sun visibility (b),
//               block light visibility (a)
//
// colortex2.a: the buffer clears to 0 and this file writes 1, so 0 means "no opaque program
// wrote here" (deferred.fsh skips lighting those pixels).
// colortex3: clears to 0, so pixels nothing wrote to may not glow. g = 1 lets a surface glow,
// g = 0 (written by entities and foliage, and by translucent entities) keeps it from glowing.
// b and a are written as 1 (unshadowed) here; deferred.fsh replaces them with the real
// visibility from lib/lighting.glsl. The full buffer contract is in docs/shader-pipeline.md.
//
// Where the glow flag comes from, chosen by the including program:
//   HS_TERRAIN        = per-vertex edgeMask from gbuffers_vertex.glsl (foliage detection)
//   HS_NO_EDGE_GLOW   = never glows (entities)
//   neither           = glows
#if defined(HS_TERRAIN)
in float edgeMask;
#elif defined(HS_NO_EDGE_GLOW)
const float edgeMask = 0.0;
#else
const float edgeMask = 1.0;
#endif

uniform sampler2D gtexture;
uniform sampler2D lightmap;
uniform vec4 entityColor;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 viewNormal;

void main() {
	vec4 albedo = texture(gtexture, texcoord) * glcolor;
	if (albedo.a < 0.1) discard;
	albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);

	// Raw lightmap coordinates span 1/32 .. 31/32; remap both channels to 0..1.
	float blockLevel = clamp((lmcoord.x - 0.03125) * 1.0666667, 0.0, 1.0);
	float skyLevel = clamp((lmcoord.y - 0.03125) * 1.0666667, 0.0, 1.0);

	gl_FragData[0] = vec4(albedo.rgb, 1.0);
	gl_FragData[1] = vec4(viewNormal * 0.5 + 0.5, skyLevel);
	gl_FragData[2] = vec4(texture(lightmap, lmcoord).rgb, 1.0);
	gl_FragData[3] = vec4(blockLevel, edgeMask > 0.5 ? 1.0 : 0.0, 1.0, 1.0);
}
