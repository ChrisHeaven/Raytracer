#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
constant int   SCREEN_WIDTH  = 450;
constant int   SCREEN_HEIGHT = 450;
constant int   MAX_TRIANGLES = 30;

// Front-plane test vertices (world space)
constant float3 FRONT_V0 = float3(-0.76f, -0.87f, -1.0f);
constant float3 FRONT_V1 = float3(-0.76f,  1.0f,  -1.0f);
constant float3 FRONT_V2 = float3( 1.31f,  1.0f,  -1.0f);

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------
struct GPUTriangle {
    float4 v0;      // w unused
    float4 v1;
    float4 v2;
    float4 normal;
    float4 color;
};

struct RenderUniforms {
    float4 camera_pos;
    float4 light_pos;
    float4 light_colour;
    float4 indirect_light;
    float4 front_v0;
    float4 front_v1;
    float4 front_v2;
    float  focal;
    float  f;
    float  yaw;
    int    triangle_count;
    int    screen_width;
    int    screen_height;
    float  _pad[2];
};

struct GPUIntersection {
    float3 position;
    float  distance;
    int    triangle_index;
    float3 colour;
    bool   is_mirror;
};

// ---------------------------------------------------------------------------
// LCG random number generator
// ---------------------------------------------------------------------------
inline uint lcg_rand(thread uint& seed) {
    seed = seed * 1664525u + 1013904223u;
    return seed;
}

inline float rand_float(thread uint& seed) {
    return float(lcg_rand(seed)) / 4294967295.0f;
}

// ---------------------------------------------------------------------------
// Möller–Trumbore ray-triangle intersection
// Returns true and writes t if the ray hits the triangle.
// ---------------------------------------------------------------------------
inline bool ray_triangle_intersect(float3 orig,
                                   float3 dir,
                                   float3 v0,
                                   float3 v1,
                                   float3 v2,
                                   thread float& t)
{
    const float epsilon = 1e-6f;

    float3 e1 = v1 - v0;
    float3 e2 = v2 - v0;

    float3 pvec = cross(dir, e2);
    float  det  = dot(e1, pvec);

    if (abs(det) < epsilon) return false;

    float  invDet = 1.0f / det;
    float3 tvec   = orig - v0;

    float u = dot(tvec, pvec) * invDet;
    if (u < 0.0f || u > 1.0f) return false;

    float3 qvec = cross(tvec, e1);
    float  v    = dot(dir, qvec) * invDet;
    if (v < 0.0f || u + v > 1.0f) return false;

    t = dot(e2, qvec) * invDet;
    return t > 0.0f;
}

// ---------------------------------------------------------------------------
// mirror_intersect_gpu
// Scans all triangles and returns the closest hit (t > 0.03).
// ---------------------------------------------------------------------------
inline GPUIntersection mirror_intersect_gpu(float3 orig,
                                            float3 dir,
                                            constant GPUTriangle* triangles,
                                            int triangle_count)
{
    GPUIntersection result;
    result.distance       = 1e30f;
    result.triangle_index = -1;
    result.colour         = float3(0.0f);
    result.is_mirror      = false;
    result.position       = float3(0.0f);

    for (int i = 0; i < triangle_count; ++i) {
        float t = 0.0f;
        if (ray_triangle_intersect(orig, dir,
                                   triangles[i].v0.xyz,
                                   triangles[i].v1.xyz,
                                   triangles[i].v2.xyz,
                                   t))
        {
            if (t > 0.03f && t < result.distance) {
                result.distance       = t;
                result.triangle_index = i;
                result.position       = orig + dir * t;
                result.colour         = triangles[i].color.xyz;
            }
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// shadow_intersect_gpu
// Tests a narrow band of triangles around `id` for any occlusion.
// ---------------------------------------------------------------------------
inline bool shadow_intersect_gpu(float3 orig,
                                 float3 dir,
                                 int    id,
                                 constant GPUTriangle* triangles,
                                 int triangle_count)
{
    int lo = max(0,              id - 2);
    int hi = min(triangle_count, id + 3);

    for (int i = lo; i < hi; ++i) {
        float t = 0.0f;
        if (ray_triangle_intersect(orig, dir,
                                   triangles[i].v0.xyz,
                                   triangles[i].v1.xyz,
                                   triangles[i].v2.xyz,
                                   t))
        {
            if (t > 0.0f) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// closest_intersect_gpu
// ---------------------------------------------------------------------------
inline GPUIntersection closest_intersect_gpu(float3 orig,
                                             float3 dir,
                                             constant GPUTriangle* triangles,
                                             int triangle_count,
                                             int light,              // 0 = normal, 1 = shadow ray
                                             constant RenderUniforms& uni)
{
    GPUIntersection result;
    result.distance       = 1e30f;
    result.triangle_index = -1;
    result.colour         = float3(0.0f);
    result.is_mirror      = false;
    result.position       = float3(0.0f);

    // --- Front-plane test ---
    int ignore = 1; // default: ignore front-plane (only render up to tri 9)
    {
        float t = 0.0f;
        if (ray_triangle_intersect(orig, dir,
                                   uni.front_v0.xyz,
                                   uni.front_v1.xyz,
                                   uni.front_v2.xyz,
                                   t))
        {
            ignore = 0; // ray passed through the opening — see full scene
        }
    }

    // --- Triangle loop ---
    int loop_count = triangle_count;
    if (ignore == 1 && light == 0) {
        loop_count = min(10, triangle_count); // only first 10 triangles
    }

    for (int i = 0; i < loop_count; ++i) {
        float t = 0.0f;
        if (ray_triangle_intersect(orig, dir,
                                   triangles[i].v0.xyz,
                                   triangles[i].v1.xyz,
                                   triangles[i].v2.xyz,
                                   t))
        {
            if (t > 0.03f && t < result.distance) {
                result.distance       = t;
                result.triangle_index = i;
                result.position       = orig + dir * t;
            }
        }
    }

    // --- Post-process hit ---
    if (result.triangle_index >= 0) {
        int idx = result.triangle_index;

        if (idx == 4 || idx == 5) {
            // Mirror surface: reflect and re-trace
            float3 reflect_dir = float3(-dir.x, dir.y, dir.z);
            GPUIntersection mirror_hit = mirror_intersect_gpu(result.position,
                                                              reflect_dir,
                                                              triangles,
                                                              triangle_count);
            result.colour    = mirror_hit.colour;
            result.is_mirror = true;
        } else {
            result.colour    = triangles[idx].color.xyz;
            result.is_mirror = false;
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// direct_light_gpu
// ---------------------------------------------------------------------------
inline float3 direct_light_gpu(GPUIntersection        point,
                                constant GPUTriangle*  triangles,
                                int                    triangle_count,
                                constant RenderUniforms& uni,
                                thread uint&           seed)
{
    int    idx           = point.triangle_index;
    float3 surface_light = uni.light_pos.xyz - point.position;
    float  r             = length(surface_light);

    float  result_dot    = dot(surface_light, triangles[idx].normal.xyz);
    float  area_divisor  = 4.0f * M_PI_F * r * r;

    float3 light_area;
    if (result_dot > 0.0f) {
        light_area = (result_dot / area_divisor) * uni.light_colour.xyz;
    } else {
        light_area = float3(0.0f);
    }

    // --- Shadow branch ---
    bool do_shadow_check = true;
    if (uni.light_pos.y < -0.20f) {
        // Only cast shadow rays from surfaces above the threshold
        do_shadow_check = (point.position.y >= -0.20f);
    }

    if (do_shadow_check) {
        GPUIntersection occluder = closest_intersect_gpu(point.position,
                                                         surface_light,
                                                         triangles,
                                                         triangle_count,
                                                         1,  // light ray
                                                         uni);

        // CPU checks: r > length(dis) where dis = t * surface_light
        // → r > t * r → 1.0 > t
        // i.e. occluder parameter t must be < 1.0 to be between surface and light
        bool blocked = (occluder.triangle_index >= 0) &&
                       (occluder.distance < 1.0f)     &&
                       (result_dot > 0.0f)             &&
                       (occluder.triangle_index != idx);

        if (blocked) {
            light_area = float3(0.0f);

            // Soft shadow: 10 jittered samples
            // Use occluder.triangle_index (not idx) to search around the occluder,
            // matching CPU: shadow_intersection(point.position, direction, inter.triangle_index, ...)
            int occluder_idx = occluder.triangle_index;
            float3 soft = float3(0.0f);
            for (int s = 0; s < 10; ++s) {
                float jx = rand_float(seed) * 2.0f - 1.0f;
                float jy = rand_float(seed) * 2.0f - 1.0f;
                float jz = rand_float(seed) * 2.0f - 1.0f;

                float3 jitter_dir = surface_light + float3(0.03f * jx,
                                                           0.03f * jy,
                                                           0.03f * jz);
                if (shadow_intersect_gpu(point.position, jitter_dir,
                                         occluder_idx, triangles, triangle_count)) {
                    // fully in shadow — add nothing
                } else {
                    soft += triangles[idx].color.xyz;
                }
            }
            light_area += soft / 10.0f;
        }
    }

    return light_area;
}

// ---------------------------------------------------------------------------
// Kernel
// ---------------------------------------------------------------------------
kernel void raytracer_kernel(
    uint3                          gid            [[thread_position_in_grid]],
    constant GPUTriangle*          triangles      [[buffer(0)]],
    constant RenderUniforms&       uni            [[buffer(1)]],
    device   float4*               output_buffer  [[buffer(2)]])
{
    uint x          = gid.x;
    uint y          = gid.y;
    uint sample_idx = gid.z;

    int sw = uni.screen_width;
    int sh = uni.screen_height;

    if (x >= (uint)sw || y >= (uint)sh || sample_idx >= 9u) return;

    // --- Seed ---
    uint seed = (x * 1000u + y) * 9u + sample_idx + 1u;

    // --- Rotation matrix (yaw around Y axis) ---
    // GLM mat3 col-major: col0=(cos,0,-sin), col1=(0,1,0), col2=(sin,0,cos)
    // R*d = float3(cos*d.x + sin*d.z,  d.y,  -sin*d.x + cos*d.z)
    float yaw     = uni.yaw;
    float cos_yaw = cos(yaw);
    float sin_yaw = sin(yaw);

    // --- Primary ray focal point ---
    float sw_f = float(sw);
    float sh_f = float(sh);

    float focal_x = (-0.5f + 0.5f / sw_f + float(x) / sw_f)
                    * (uni.focal - uni.camera_pos.z) / uni.f;
    float focal_y = (-0.5f + 0.5f / sh_f + float(y) / sh_f)
                    * (uni.focal - uni.camera_pos.z) / uni.f;

    // --- Anti-aliasing sub-sample grid (3×3, stratified jitter) ---
    // Divide [-8, 8] into 3 equal strata of width 16/3 each.
    // Each sample falls uniformly within its stratum — no gaps, no overlap.
    // Total spread stays ±8 pixels so depth-of-field effect is unchanged.
    int a_idx = int(sample_idx) / 3;   // 0, 1, 2
    int b_idx = int(sample_idx) % 3;   // 0, 1, 2

    float x_ = -8.0f + (float(b_idx) + rand_float(seed)) * (16.0f / 3.0f);
    float y_ = -8.0f + (float(a_idx) + rand_float(seed)) * (16.0f / 3.0f);

    // --- Sub-pixel position ---
    float3 sub_pixel = float3(
        -0.5f + 0.5f / sw_f + (float(x) + x_) / sw_f,
        -0.5f + 0.5f / sh_f + (float(y) + y_) / sh_f,
        -2.0f
    );

    // --- Ray direction (before rotation) ---
    float3 d_local = float3(focal_x - sub_pixel.x,
                            focal_y - sub_pixel.y,
                            uni.focal - sub_pixel.z);

    // Apply Y-axis rotation: R*d
    float3 d = float3(
         cos_yaw * d_local.x + sin_yaw * d_local.z,
         d_local.y,
        -sin_yaw * d_local.x + cos_yaw * d_local.z
    );

    // --- Trace primary ray ---
    // Ray origin is sub_pixel (lens sample point at z=-2), NOT camera_pos (z=-3)
    // This matches the CPU code: closest_intersection(sub_pixel, d, ...)
    GPUIntersection intersection = closest_intersect_gpu(
        sub_pixel, d,
        triangles, uni.triangle_count,
        0, uni);

    float3 pixel_colour = float3(0.0f);

    if (intersection.triangle_index >= 0) {
        float3 light_area = direct_light_gpu(intersection,
                                             triangles,
                                             uni.triangle_count,
                                             uni,
                                             seed);

        if (intersection.is_mirror) {
            // Mirror: also light the reflected surface and blend
            int mirror_idx = intersection.triangle_index;

            // Build a temporary intersection at the mirror hit to light it
            // We already have the reflected colour in intersection.colour,
            // but we need a GPUIntersection pointing at the reflected surface.
            // Re-trace the reflected ray to get the proper surface intersection.
            float3 reflect_dir = float3(-d.x, d.y, d.z);
            GPUIntersection mirror_isec = mirror_intersect_gpu(
                intersection.position, reflect_dir,
                triangles, uni.triangle_count);

            float3 mirror_shadow = float3(0.0f);
            if (mirror_isec.triangle_index >= 0) {
                mirror_shadow = direct_light_gpu(mirror_isec,
                                                 triangles,
                                                 uni.triangle_count,
                                                 uni,
                                                 seed);
            }

            light_area = 0.5f * (uni.indirect_light.xyz +
                                 (light_area + mirror_shadow) / 2.0f);
        } else {
            light_area = 0.5f * (uni.indirect_light.xyz + light_area);
        }

        pixel_colour = light_area * intersection.colour;
    }

    // --- Write output ---
    uint out_idx = (y * uint(sw) + x) * 9u + sample_idx;
    output_buffer[out_idx] = float4(pixel_colour, 1.0f);
}
