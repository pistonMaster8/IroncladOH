#pragma once
#include "Types.hpp"
#include <cmath>

// Use Apple's SIMD library when available, fall back to scalar otherwise.
#if defined(__APPLE__)
#  include <simd/simd.h>
   using Vec2 = simd_float2;
   using Vec3 = simd_float3;
   using Vec4 = simd_float4;
   using Mat4 = simd_float4x4;
   using Quat = simd_quatf;

   inline Vec2 Vec2Make(f32 x, f32 y)              { return simd_make_float2(x, y); }
   inline Vec3 Vec3Make(f32 x, f32 y, f32 z)       { return simd_make_float3(x, y, z); }
   inline Vec4 Vec4Make(f32 x, f32 y, f32 z, f32 w){ return simd_make_float4(x, y, z, w); }

   inline f32  Vec3Dot(Vec3 a, Vec3 b)  { return simd_dot(a, b); }
   inline Vec3 Vec3Cross(Vec3 a, Vec3 b){ return simd_cross(a, b); }
   inline f32  Vec3Len(Vec3 v)          { return simd_length(v); }
   inline Vec3 Vec3Norm(Vec3 v)         { return simd_normalize(v); }
   inline Vec3 Vec3Lerp(Vec3 a, Vec3 b, f32 t){ return simd_mix(a, b, simd_make_float3(t,t,t)); }

   inline Mat4 Mat4Identity()           { return matrix_identity_float4x4; }

   inline Mat4 Mat4Perspective(f32 fovY, f32 aspect, f32 near, f32 far) {
       f32 ys = 1.0f / tanf(fovY * 0.5f);
       f32 xs = ys / aspect;
       f32 zs = far / (near - far);
       return (Mat4){ .columns = {
           { xs,   0,  0,  0 },
           {  0,  ys,  0,  0 },
           {  0,   0, zs, -1 },
           {  0,   0, zs * near, 0 }
       }};
   }

   inline Mat4 Mat4Ortho(f32 left, f32 right, f32 bottom, f32 top, f32 near, f32 far) {
       return (Mat4){ .columns = {
           { 2.0f/(right-left),         0,                      0,                 0 },
           { 0,                         2.0f/(top-bottom),      0,                 0 },
           { 0,                         0,                      1.0f/(near-far),   0 },
           { (left+right)/(left-right), (top+bottom)/(bottom-top), near/(near-far), 1 }
       }};
   }

   inline Mat4 Mat4LookAt(Vec3 eye, Vec3 center, Vec3 up) {
       Vec3 z = Vec3Norm(eye - center);
       Vec3 x = Vec3Norm(Vec3Cross(up, z));
       Vec3 y = Vec3Cross(z, x);
       return (Mat4){ .columns = {
           { x.x, y.x, z.x, 0 },
           { x.y, y.y, z.y, 0 },
           { x.z, y.z, z.z, 0 },
           { -simd_dot(x,eye), -simd_dot(y,eye), -simd_dot(z,eye), 1 }
       }};
   }

   inline Mat4 Mat4Translation(Vec3 t) {
       Mat4 m = Mat4Identity();
       m.columns[3] = Vec4Make(t.x, t.y, t.z, 1.0f);
       return m;
   }

   inline Mat4 Mat4Scale(Vec3 s) {
       Mat4 m = Mat4Identity();
       m.columns[0].x = s.x;
       m.columns[1].y = s.y;
       m.columns[2].z = s.z;
       return m;
   }

   inline Mat4 Mat4Mul(Mat4 a, Mat4 b) { return simd_mul(a, b); }

#else
// ─── Scalar fallback (Windows / Linux build) ─────────────────────────────────
#  include <array>
   struct Vec2 { f32 x, y; };
   struct Vec3 { f32 x, y, z; };
   struct Vec4 { f32 x, y, z, w; };
   struct Mat4 { f32 m[4][4]; };
   struct Quat { f32 x, y, z, w; };

   inline Vec2 Vec2Make(f32 x, f32 y)              { return {x, y}; }
   inline Vec3 Vec3Make(f32 x, f32 y, f32 z)       { return {x, y, z}; }
   inline Vec4 Vec4Make(f32 x, f32 y, f32 z, f32 w){ return {x, y, z, w}; }

   inline f32 Vec3Dot(Vec3 a, Vec3 b)  { return a.x*b.x + a.y*b.y + a.z*b.z; }
   inline Vec3 Vec3Cross(Vec3 a, Vec3 b) {
       return { a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x };
   }
   inline f32  Vec3Len(Vec3 v)  { return sqrtf(Vec3Dot(v, v)); }
   inline Vec3 Vec3Norm(Vec3 v) { f32 l = Vec3Len(v); return l>0?Vec3{v.x/l,v.y/l,v.z/l}:v; }
   inline Vec3 Vec3Lerp(Vec3 a, Vec3 b, f32 t) {
       return { a.x + (b.x-a.x)*t, a.y + (b.y-a.y)*t, a.z + (b.z-a.z)*t };
   }
   inline Mat4 Mat4Identity() { return {{{1,0,0,0},{0,1,0,0},{0,0,1,0},{0,0,0,1}}}; }
   inline Mat4 Mat4Mul(Mat4 a, Mat4 b) {
       Mat4 r{};
       for(int i=0;i<4;++i) for(int j=0;j<4;++j) for(int k=0;k<4;++k) r.m[i][j]+=a.m[i][k]*b.m[k][j];
       return r;
   }
#endif

// ─── Common math ─────────────────────────────────────────────────────────────
constexpr f32 kPi    = 3.14159265358979323846f;
constexpr f32 kTwoPi = 2.0f * kPi;

inline f32 Deg2Rad(f32 d) { return d * (kPi / 180.0f); }
inline f32 Rad2Deg(f32 r) { return r * (180.0f / kPi); }
inline f32 Clamp(f32 v, f32 lo, f32 hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline f32 Saturate(f32 v) { return Clamp(v, 0.0f, 1.0f); }
inline f32 Lerp(f32 a, f32 b, f32 t) { return a + (b - a) * t; }
