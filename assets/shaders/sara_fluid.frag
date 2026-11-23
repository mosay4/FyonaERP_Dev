#version 460 core
#include <flutter/runtime_effect.glsl>

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
float fbm(vec2 p) {
  float n = 0.0, a = 0.533333;
  mat2 rotate = mat2(0.8, -0.6, 0.6, 0.8);
  // Fixed four octaves: no unbounded loops, textures, or offscreen passes.
  for (int i = 0; i < 4; i++) {
    n += a * noise(p);
    p = rotate * p * 2.03 + vec2(13.7, 9.2);
    a *= 0.5;
  }
  return n;
}
float region(vec2 uv, vec4 box, vec2 spread) {
  vec2 d = (uv - box.xy) / max(box.zw + spread, vec2(0.04));
  return exp(-dot(d, d) * 1.4);
}
void main() {
  vec2 uv = FlutterFragCoord().xy / u_resolution;
  float aspect = u_resolution.x / u_resolution.y;
  vec2 p = uv * vec2(aspect, 1.0) * 3.8;
  // Integrated advection keeps position continuous through phase handoffs.
  p.y += u_flow;
  p.x += 0.035 * sin(u_time * 0.12);
  float inputWave = region(uv, vec4(u_input.xy - vec2(0, 0.12), u_input.zw), vec2(0.3, 0.25));
  p.y += inputWave * u_typingAmp * 0.16 * sin(p.x * 3.0 - u_flow * 4.0);
  float avatarFocus = region(uv, u_avatar, vec2(0.32, 0.25)) * u_thinkingFocus;
  p += (u_avatar.xy - uv) * avatarFocus * 0.7;
  float replyFlow = region(uv, u_reply, vec2(0.18, 0.12)) * u_respondFlow;
  p.x += replyFlow * 0.16 * sin(u_flow * 2.0 + uv.y * 4.0);
  float waveY = mix(u_input.y, -0.12, u_sendProgress);
  float sendWave = exp(-pow((uv.y - waveY) / 0.12, 2.0)) * u_sendImpulse;
  p.y += sendWave * 0.25;
  // Double domain warping: q feeds itself, then r warps by q.
  vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
  q = vec2(fbm(p + q + vec2(1.7, 9.2)), fbm(p + q + vec2(8.3, 2.8)));
  vec2 r = vec2(fbm(p + q * 2.0 + vec2(1.1, 3.4)),
                fbm(p + q * 2.0 + vec2(6.7, 4.1)));
  float smoke = fbm(p + r * 2.5);
  float density = smoothstep(0.15, 0.87, smoke);
  vec3 burgundy = mix(vec3(0.490, 0.106, 0.212), vec3(0.557, 0.137, 0.251), u_theme);
  vec3 pale = mix(vec3(0.914, 0.878, 0.808), vec3(0.83, 0.84, 0.86), u_theme);
  vec3 ink = mix(vec3(0.075, 0.055, 0.065), vec3(0.52, 0.54, 0.58), u_theme);
  burgundy = mix(burgundy, burgundy * vec3(0.90, 0.96, 1.07), u_business * 0.45);
  vec3 color = mix(ink, burgundy, smoothstep(0.22, 0.70, r.x));
  color = mix(color, pale, smoothstep(0.40, 0.76, q.y) * 0.85);
  float presence = 0.21 + 0.14 * density;
  presence += sendWave * 0.16 + avatarFocus * density * 0.08;
  presence += replyFlow * u_revealPulse * 0.10 + inputWave * u_typingAmp * 0.07;
  presence *= 1.0 - 0.04 * u_completedBalance;
  // Continuous coverage; only the outermost 2.5% reaches transparent.
  float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
  float alpha = clamp(presence, 0.0, 0.62) * smoothstep(0.0, 0.025, edge);
  // User geometry subtly biases the color, without introducing a new pass.
  color = mix(color, burgundy, region(uv, u_user, vec2(0.16)) * u_sendImpulse * 0.12);
  fragColor = vec4(color * alpha, alpha);
}
