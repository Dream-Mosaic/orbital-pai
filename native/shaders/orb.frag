#version 460 core
#include <flutter/runtime_effect.glsl>

// ---------------------------------------------------------------------------
// Uniforms. DECLARATION ORDER IS THE CONTRACT with orb_uniforms.dart's OrbU —
// vec2 is two slots, vec4 is four. Reordering here without reordering there
// compiles and runs, and silently shades with the wrong numbers.
// ---------------------------------------------------------------------------
uniform vec2  uOrigin;       // 0,1   paint rect origin, in SURFACE coords
uniform vec2  uSize;         // 2,3
uniform float uT;            // 4
uniform float uLevel;        // 5
uniform float uPunch;        // 6
uniform float uOff;          // 7     1.0 when powered down
uniform vec4  uGlow;         // 8..11
uniform vec4  uHi;           // 12..15
uniform vec4  uLo;           // 16..19
uniform vec4  uRim;          // 20..23
uniform float uPunchSpread;  // 24    from orb_tuning.dart
uniform float uPunchGlow;    // 25    from orb_tuning.dart

out vec4 fragColor;

// ---------------------------------------------------------------------------
// Glass tuning. These are the GLASS-ONLY knobs. The PUNCH constants
// (uPunchSpread, uPunchGlow) ride as uniforms above, so those two cannot
// drift from orb_painter.dart. The GEOMETRY constants below (kBreathe,
// kHalos, kGlowGain) are duplicated by hand from orb_painter.dart — they are
// NOT guaranteed to stay in step, and a change to one side must be mirrored
// on the other manually.
// Edit here, rebuild, look at it.
// ---------------------------------------------------------------------------
const float kIor         = 1.45;  // index of refraction; higher bends more
const float kDispersion  = 0.012; // R/G/B IOR spread — the rainbow at the rim
const float kHaloSigma   = 0.055; // ring softness (was MaskFilter.blur)
const float kSpecHardExp = 110.0; // primary highlight: small, hard, bright
const float kSpecSoftExp = 12.0;  // secondary: wide, dim
const float kSpecHardAmp = 0.26;
const float kSpecSoftAmp = 0.13;
const float kFresnelAmp  = 0.9;   // grazing-angle rim brightness
/// How much of the palette the highlights carry. Pure white highlights on a
/// strongly tinted sphere read as a blown-out lamp rather than as light in
/// glass — the sphere is green, so its reflections should be too.
const float kSpecTint    = 0.45;
/// Floor under the internal environment's dark end.
///
/// The environment ran all the way down to uLo, so the sphere's limb fell to
/// very nearly black and met the background with a hard edge — the "intense
/// black to sphere transition" at the top. Real glass never gets there: it is
/// picking up light from every direction, not just the key.
const float kEnvFloor    = 0.16;
const float kCausticAmp  = 0.55;  // the focused spot low INSIDE the sphere
const float kEnvAmp      = 0.85;  // how much refracted environment shows
const vec3  kLightDir    = vec3(-0.45, -0.60, 0.66); // fixed upper-left

// Geometry carried over from orb_painter.dart so the two agree in layout.
const float kBreathe  = 1.05;
const float kSphereR  = 0.60; // r0 = min(w,h)*0.3 over a half-extent of min/2
const int   kHalos    = 3;
const float kGlowGain = 1.10; // (0.5 + kGlow*0.5) with kGlow = 1.2

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// Three concentric rings as TRUE Gaussians. Canvas could only approximate this
// with a blur pass per ring; here it is three exp() calls.
float haloField(float rn) {
  float acc = 0.0;
  for (int i = 0; i < kHalos; i++) {
    float fi = float(i) / float(kHalos - 1);
    float spread = 1.06 + float(i) * 0.17 + uLevel * 0.05 + uPunch * uPunchSpread;
    float rr = spread + sin(uT * 1.3 + float(i) * 1.4) * 0.025 * kBreathe * (1.0 + uLevel);
    float a = (0.42 - fi * 0.3) * (0.6 + uLevel * 0.6) * kGlowGain
            * (1.0 + uPunch * uPunchGlow);
    float d = (rn - rr) / kHaloSigma;
    acc += a * exp(-0.5 * d * d);
  }
  return acc;
}

// The internal environment the refracted ray samples.
//
// This exists because the orb sits on near-black: refracting "the scene behind
// it" would refract nothing, and the sphere would stay a filled circle. A
// procedural studio field gives the refraction something to find.
vec3 environment(vec3 dir) {
  float v = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
  // Floored, not run down to uLo: see kEnvFloor.
  vec3 base = mix(mix(uLo.rgb, uHi.rgb, kEnvFloor), uHi.rgb,
                  smoothstep(0.10, 0.95, v));
  float bx = (dir.y - 0.35) / 0.20; // signed — hence bx*bx, not pow(bx, 2.0)
  float band = exp(-bx * bx); // a window reflection
  return base + uHi.rgb * band * 0.35;
}

void main() {
  vec2 frag = FlutterFragCoord().xy - uOrigin;
  vec2 uv = frag / max(uSize, vec2(1.0));
  vec2 p = (uv - 0.5) * 2.0;   // -1..1
  float r = length(p);

  bool off = uOff > 0.5;
  vec3 L = normalize(kLightDir);
  vec3 V = vec3(0.0, 0.0, 1.0);

  float breathe = off ? 0.0 : kBreathe * (0.015 * sin(uT * 1.6) + uLevel * 0.04);
  float R = kSphereR * (1.0 + breathe);
  float rn = r / R;            // 1.0 exactly on the sphere's edge

  // Everything past the outermost ring is transparent by construction; ~30% of
  // the drawn rect is corner pixels that would otherwise do full glass work to
  // produce alpha 0.
  //
  // 1.6 does NOT clear it: the outermost ring (i == kHalos-1) has
  // spread = 1.06 + 2*0.17 + uLevel*0.05 + uPunch*uPunchSpread, which alone
  // reaches 1.55 at uLevel == uPunch == 1.0 (uPunchSpread = 0.10), and its
  // `rr` adds a further +/-0.025*kBreathe*(1+uLevel) wobble (~+-0.0525 at
  // uLevel == 1), so the ring's PEAK can sit at rn ~= 1.6025 -- already past
  // 1.6 before counting any of the Gaussian's own sigma. 1.9 clears the peak
  // by ~5.4*kHaloSigma (kHaloSigma = 0.055), i.e. exp(-0.5*5.4^2) ~= 4e-7 of
  // the ring's already-small peak amplitude: nothing visible is cut.
  if (rn > 1.9) {
    fragColor = vec4(0.0);
    return;
  }

  vec3 col = vec3(0.0);
  float alpha = 0.0;

  // --- halos + contact glow, outside the sphere ---
  if (!off) {
    float h = haloField(rn);
    col += uGlow.rgb * h;
    alpha += h;

    // x*x, never pow(x, 2.0): GLSL pow is UNDEFINED for a negative base, and
    // (rn - 1.0) is negative everywhere inside the sphere. The symptom would
    // be NaN pixels on some drivers and not others.
    float gx = (rn - 1.0) / (0.70 + uLevel * 0.35 + uPunch * 0.25);
    float g = exp(-gx * gx);
    // Wider and brighter than before. The silhouette used to meet the
    // background almost dead, so the gap between the glass edge and the first
    // ring read as a hard dark moat rather than as air around a lit object.
    col += uGlow.rgb * g * 0.20;
    alpha += g * 0.20;
  }

  // --- the glass body ---
  if (rn <= 1.0) {
    // A REAL hemisphere normal. Everything below is derived from it, which is
    // exactly what the stacked-gradient version could not do.
    float z = sqrt(max(0.0, 1.0 - rn * rn));
    vec3 N = normalize(vec3(p / R, z));

    float fres = pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 5.0);

    // Refraction, sampled per channel so the rim splits into colour.
    vec3 rd = refract(-V, N, 1.0 / (kIor - kDispersion));
    vec3 gd = refract(-V, N, 1.0 / kIor);
    vec3 bd = refract(-V, N, 1.0 / (kIor + kDispersion));
    vec3 env = vec3(environment(rd).r, environment(gd).g, environment(bd).b);

    // The halos are INSIDE this shader, so the refracted ray can find them —
    // that is what makes the rings visibly bend through the glass, and the
    // reason they are not left as Canvas ops behind the sphere.
    //
    // MINUS, not plus: with I = -V and N the outward hemisphere normal,
    // `refract`'s coefficient (eta*z - sqrt(k)) is negative for every point on
    // the hemisphere (about -0.31 at the centre, -0.72 at the rim), so gd.xy
    // already points INWARD. Adding it samples toward the centre — nowhere
    // near the rings, which sit out around rn ~= 1.06+ — so subtracting is
    // what moves the sample outward into ring territory. Get the sign wrong
    // here again and `bent` silently goes back to sampling empty space near
    // the centre for every fragment, with no visible symptom short of the
    // rings failing to bend through the glass.
    float bent = haloField(length((p - gd.xy * 0.35) / R));
    vec3 body = env * kEnvAmp + uGlow.rgb * bent * 0.25;

    // Caustic: light entering the top focuses low inside the sphere. The old
    // Canvas shadowRect did the opposite — a subtractive darkening.
    vec2 focus = vec2(0.16, 0.42);
    float cd = length(p / R - focus);
    float cx2 = cd / (0.34 - uLevel * 0.10);
    float caustic = exp(-cx2 * cx2);
    body += uHi.rgb * caustic * kCausticAmp;

    // Dual specular.
    vec3 H = normalize(L + V);
    float ndh = clamp(dot(N, H), 0.0, 1.0);
    vec3 specTint = mix(vec3(1.0), uHi.rgb, kSpecTint);
    body += specTint * pow(ndh, kSpecHardExp) * kSpecHardAmp;
    body += specTint * pow(ndh, kSpecSoftExp) * kSpecSoftAmp;

    // Fresnel rim, replacing the uniform 1.5px stroke.
    body += uRim.rgb * fres * kFresnelAmp * (off ? 0.4 : 1.0);

    if (off) body = mix(uLo.rgb * 0.9, body, 0.35);

    // One pixel's worth of rn, derived rather than taken from fwidth().
    // fwidth() is a derivative instruction that SkSL's runtime-effect subset
    // does not implement, so using it makes the whole shader fail to load on
    // the Skia backend — the app would silently fall back to the old Canvas
    // orb with no indication why. rn = length(p)/R and p spans -1..1 across
    // uSize.x pixels, so one pixel is exactly 2/(uSize.x*R) here.
    float px = 2.0 / (max(uSize.x, 1.0) * R);
    float edge = 1.0 - smoothstep(1.0 - px * 1.5, 1.0, rn);
    col = mix(col, body, edge);
    alpha = mix(alpha, 1.0, edge);
  }

  alpha = clamp(alpha, 0.0, 1.0);
  // Dither. An 8-bit radial ramp across ~500px always bands; a sub-LSB of
  // noise is the standard cure and is free here.
  col += (hash12(frag) - 0.5) / 255.0;
  col = clamp(col, 0.0, 1.0);

  // `col` is accumulated ALREADY PREMULTIPLIED — every term added to it
  // above is colour scaled by its own coverage (the halo/glow terms by `h`/
  // `g`, the glass body by `mix(col, body, edge)`, whose `body` operand has
  // implicit alpha 1). Scaling by `alpha` again here would double-apply that
  // coverage: harmless where alpha == 1 (inside the sphere), but outside it
  // the rings would come out roughly alpha^2 dim and the dither would lose
  // the same way. Flutter still wants premultiplied output — that
  // requirement is just already satisfied, so pass `col` through unscaled.
  fragColor = vec4(col, alpha);
}
