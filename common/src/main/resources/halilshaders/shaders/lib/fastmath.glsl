#ifndef HS_FASTMATH_GLSL
#define HS_FASTMATH_GLSL

// Small math helpers for the hot passes. No uniforms are declared here, so this file can be
// included anywhere.
//
// What they replace, and why:
//   a / b           ->  a * rcp(b)           one reciprocal, shared when the same divisor is used again
//   1.0 / a         ->  rcp(a)
//   sqrt(a)         ->  a * inversesqrt(a)   inversesqrt is a native GPU instruction, sqrt is built on it
//   normalize(v)    ->  v * inversesqrt(dot(v, v))
//   pow(a, b)       ->  exp2(log2(a) * b)    which is what pow does inside anyway
//
// GLSL has no rcp(): it is plain 1.0 / x here. The gain comes from writing a divisor once and
// reusing it, not from the function itself. The zero-input guards below cost one max() and keep a
// zero vector from turning into NaN (a NaN written to a color buffer spreads to its neighbours
// through later passes).

float rcp(float x) { return 1.0 / x; }
vec2 rcp(vec2 x) { return 1.0 / x; }
vec3 rcp(vec3 x) { return 1.0 / x; }
vec4 rcp(vec4 x) { return 1.0 / x; }

// Length as d * inversesqrt(d), where d = dot(v, v). Zero vector gives 0.
float fastLength(vec2 v) {
	float d = dot(v, v);
	return d * inversesqrt(max(d, 1.0e-20));
}

float fastLength(vec3 v) {
	float d = dot(v, v);
	return d * inversesqrt(max(d, 1.0e-20));
}

// Unit vector without a sqrt and a divide. Zero vector gives the zero vector.
vec2 fastNormalize(vec2 v) {
	return v * inversesqrt(max(dot(v, v), 1.0e-20));
}

vec3 fastNormalize(vec3 v) {
	return v * inversesqrt(max(dot(v, v), 1.0e-20));
}

// Cosine of the angle between two vectors that are not unit length: one inversesqrt instead of
// two normalizes.
float fastCosAngle(vec3 a, vec3 b) {
	return dot(a, b) * inversesqrt(max(dot(a, a) * dot(b, b), 1.0e-20));
}

// pow for non-negative input. The base is kept above 1e-12 because log2 of 0 is not defined in
// GLSL. An input of 0 then gives about 0 for exponents of 1 or more, 4e-6 for 1 / 2.2 and 1e-4 for a
// cube root: all far below what an 8 bit buffer can show.
float fastPow(float a, float b) {
	return exp2(log2(max(a, 1.0e-12)) * b);
}

vec3 fastPow(vec3 a, float b) {
	return exp2(log2(max(a, vec3(1.0e-12))) * b);
}

#endif
