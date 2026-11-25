#version 460 core
#include <flutter/runtime_effect.glsl>

// Sara aurora: soft flowing colour light (brand crimson, rose, warm amber,
// plum and a cool indigo note) that rises from the composer, gathers around
// Sara while she thinks and flows along her reply while it streams.
// Same uniform layout as before (SaraAmbientPainter writes them in order).
uniform float u_time;
uniform vec2 u_resolution;
// Normalized center.xy, half-extents.zw, in scene-local coordinates.
uniform vec4 u_avatar;
uniform vec4 u_input;
uniform vec4 u_user;
uniform vec4 u_reply;
uniform float u_typingAmp;
uniform float u_sendImpulse;
uniform float u_thinkingFocus;
uniform float u_respondFlow;
uniform float u_revealPulse;
uniform float u_completedBalance;
uniform float u_theme;
uniform float u_business;
uniform float u_flow;
uniform float u_sendProgress;
out vec4 fragColor;

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x),
             mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}
// Two octaves only: silk, not smoke.
float silk(vec2 p) {
  return noise(p) * 0.65 + noise(p * 2.1 + vec2(7.3, 1.9)) * 0.35;
}
float glow(vec2 d, vec2 r) {
  vec2 q = d / max(r, vec2(0.02));
  return exp(-dot(q, q));
}
float region(vec2 uv, vec4 box, vec2 spread) {
  vec2 d = (uv - box.xy) / max(box.zw + spread, vec2(0.04));
  return exp(-dot(d, d) * 1.4);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_resolution;
  float aspect = u_resolution.x / u_resolution.y;
  // Integrated clock: continuous through every phase handoff.
  float t = u_flow * 7.0;

  // Palette. Light theme uses lighter, airier tints of the same hues.
  vec3 crimson = vec3(0.627, 0.082, 0.188);
  vec3 rose = vec3(0.902, 0.329, 0.427);
  vec3 amber = vec3(0.969, 0.639, 0.408);
  vec3 plum = vec3(0.471, 0.200, 0.478);
  vec3 indigo = vec3(0.345, 0.388, 0.871);
  // Business leans a little cooler (indigo), Personal a little warmer.
  amber = mix(amber, vec3(0.949, 0.553, 0.584), u_business * 0.45);
  plum = mix(plum, indigo, u_business * 0.35);
  float light = 1.0 - u_theme;
  crimson = mix(crimson, vec3(0.86, 0.33, 0.43), light * 0.35);
  plum = mix(plum, vec3(0.68, 0.52, 0.86), light * 0.40);

  // Gentle domain warp so the bands drift like silk.
  vec2 w = vec2(silk(uv * vec2(2.2 * aspect, 2.6) + vec2(t * 0.22, -t * 0.12)),
                silk(uv * vec2(1.8 * aspect, 2.2) + vec2(-t * 0.16, t * 0.19))) - 0.5;
  vec2 p = uv + w * (0.085 + 0.05 * u_typingAmp);

  // ── Composer aurora: lives at the bottom, rises while typing/sending.
  float baseY = clamp(u_input.y, 0.55, 1.0);
  float rise = 0.15 + 0.08 * u_typingAmp + 0.08 * u_sendImpulse + 0.04 * u_respondFlow;
  vec2 c1 = vec2(0.18 + 0.10 * sin(t * 0.50), baseY + 0.07);
  vec2 c2 = vec2(0.52 + 0.12 * sin(t * 0.37 + 1.7), baseY + 0.10);
  vec2 c3 = vec2(0.86 + 0.09 * sin(t * 0.43 + 3.1), baseY + 0.06);
  vec2 r = vec2(0.34, rise);
  float a1 = glow(p - c1, r * vec2(1.0, 1.05));
  float a2 = glow(p - c2, r * vec2(1.15, 1.20));
  float a3 = glow(p - c3, r * vec2(0.95, 0.95));
  vec3 bottom = (crimson * a1 + mix(rose, amber, 0.5 + 0.5 * sin(t * 0.3)) * a2 + plum * a3) /
                max(a1 + a2 + a3, 1e-3);
  float bottomA = clamp(a1 + a2 + a3, 0.0, 1.0);
  bottomA *= 0.60 + 0.30 * u_typingAmp + 0.15 * u_respondFlow;

  // ── Send: one bright band travels from the composer to the top, once.
  float waveY = mix(baseY, -0.15, u_sendProgress);
  float sendD = (p.y - waveY) / 0.075;
  float sendBand = exp(-sendD * sendD) * u_sendImpulse * 0.75;
  vec3 sendColor = mix(rose, amber, smoothstep(0.0, 1.0, uv.x));

  // ── Thinking: a slow rotating halo of colour around Sara's portrait,
  // plus a soft veil under the header.
  vec2 av = vec2(u_avatar.x, max(u_avatar.y, 0.0));
  vec2 da = (p - av) * vec2(aspect, 1.0);
  float halo = glow(da, vec2(0.40, 0.28)) * u_thinkingFocus * 0.85;
  // Colours travel around the halo (no angle seam): a slowly turning axis.
  vec2 axis = vec2(cos(t * 0.8), sin(t * 0.8));
  float side = dot(normalize(da + vec2(1e-4)), axis) * smoothstep(0.0, 0.18, length(da));
  vec3 haloColor = mix(mix(crimson, indigo, 0.5 + 0.5 * side), amber,
                       0.20 + 0.20 * sin(t * 0.6 + da.x * 4.0));
  float veil = smoothstep(0.30, 0.0, p.y) * u_thinkingFocus *
               (0.55 + 0.45 * sin(p.x * 5.0 + t * 1.3));

  // ── Responding: light flows along the reply as words arrive.
  float replyFlow = region(p, u_reply, vec2(0.20, 0.14)) * u_respondFlow;
  vec3 replyColor = mix(plum, rose, 0.5 + 0.5 * sin(uv.y * 6.0 - t * 1.2));
  float replyA = replyFlow * (0.35 + 0.65 * u_revealPulse);

  // ── The user's last message warms briefly as it is sent.
  float userA = region(uv, u_user, vec2(0.16)) * u_sendImpulse * 0.45;

  // ── Idle: a faint wash in the top corner so the page is never flat.
  float wash = glow((p - vec2(0.95, -0.06)) * vec2(aspect, 1.0), vec2(0.42, 0.22)) * 0.16;

  vec3 color = bottom * bottomA + haloColor * halo + crimson * veil * 0.6 +
               sendColor * sendBand + replyColor * replyA + crimson * userA + plum * wash;
  float alpha = bottomA + halo + veil * 0.6 + sendBand + replyA + userA + wash;
  color /= max(alpha, 1e-3);

  // Calm after an answer completes.
  alpha *= 1.0 - 0.10 * u_completedBalance;
  // Light theme: airy pastel; dark theme: richer light.
  float cap = mix(0.40, 0.58, u_theme);
  alpha = clamp(alpha * mix(0.62, 0.78, u_theme), 0.0, cap);
  // Fades into the header instead of ending in a hard line.
  alpha *= smoothstep(0.0, 0.03, uv.y);
  fragColor = vec4(color * alpha, alpha);
}
