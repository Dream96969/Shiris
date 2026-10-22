#version 330 compatibility

/* DRAWBUFFERS:0 */

// Glass, ice and water: lit like other translucent geometry, plus the sun glint.
#define HS_GLINT
#include "/lib/glint.glsl"
#include "/lib/gbuffer_forward_lit.glsl"
