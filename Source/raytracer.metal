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
// PCG-based random number generator (much better than LCG for spatial seeds)
// ---------------------------------------------------------------------------
inline uint pcg_hash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

inline uint lcg_rand(thread uint& seed) {
    seed = pcg_hash(seed);
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
// Cosine-weighted hemisphere sampling for diffuse bounce
// ---------------------------------------------------------------------------
inline float3 cosine_weighted_hemisphere(float3 normal, thread uint& seed) {
    float r1 = rand_float(seed);
    float r2 = rand_float(seed);
    float phi = 2.0f * M_PI_F * r1;
    float cos_theta = sqrt(1.0f - r2);
    float sin_theta = sqrt(r2);

    // Build orthonormal basis (TBN) from normal
    float3 w = normal;
    float3 helper = abs(w.x) > 0.9f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 u = normalize(cross(helper, w));
    float3 v = cross(w, u);

    return u * (cos(phi) * sin_theta) + v * (sin(phi) * sin_theta) + w * cos_theta;
}

// ---------------------------------------------------------------------------
// simple_intersect_gpu — lightweight closest-hit, no mirror logic
// Used for bounce rays and bounce shadow rays.
// ---------------------------------------------------------------------------
inline GPUIntersection simple_intersect_gpu(float3 orig,
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
            if (t > 0.001f && t < result.distance) {
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
            if (t > 0.001f && t < result.distance) {
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

    // --- Triangle loop ---
    // Always test all triangles for primary and shadow rays.
    // The original CPU front-plane test caused seam blurring: AA jitter made
    // some sub-samples hit the front plane (ignore=0, all 30 tris) and others
    // miss it (ignore=1, only 10 tris), giving inconsistent results per pixel.
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

            // Soft shadow: 24 jittered samples
            // Use occluder.triangle_index (not idx) to search around the occluder,
            // matching CPU: shadow_intersection(point.position, direction, inter.triangle_index, ...)
            int occluder_idx = occluder.triangle_index;
            float3 soft = float3(0.0f);
            for (int s = 0; s < 16; ++s) {
                float jx = rand_float(seed) * 2.0f - 1.0f;
                float jy = rand_float(seed) * 2.0f - 1.0f;
                float jz = rand_float(seed) * 2.0f - 1.0f;

                float3 jitter_dir = surface_light + float3(0.05f * jx,
                                                           0.05f * jy,
                                                           0.05f * jz);
                if (shadow_intersect_gpu(point.position, jitter_dir,
                                         occluder_idx, triangles, triangle_count)) {
                    // fully in shadow — add nothing
                } else {
                    soft += triangles[idx].color.xyz;
                }
            }
            light_area += soft / 16.0f;
        }
    }

    return light_area;
}

// ---------------------------------------------------------------------------
// indirect_light_one_bounce — 1-bounce global illumination
// Shoots N_BOUNCES random cosine-weighted rays from the surface and averages.
// ---------------------------------------------------------------------------
constant int N_BOUNCES = 4;

inline float3 indirect_light_one_bounce(GPUIntersection point,
                                         constant GPUTriangle* triangles,
                                         int triangle_count,
                                         constant RenderUniforms& uni,
                                         thread uint& seed,
                                         thread float& ao_factor)
{
    int idx = point.triangle_index;
    if (idx < 0) { ao_factor = 1.0f; return float3(0.0f); }

    float3 normal = triangles[idx].normal.xyz;
    float3 accum = float3(0.0f);
    float ao_accum = 0.0f;
    float ao_radius = 0.6f; // AO sampling radius

    for (int b = 0; b < N_BOUNCES; ++b) {
        float3 bounce_dir = cosine_weighted_hemisphere(normal, seed);

        GPUIntersection bounce_hit = simple_intersect_gpu(point.position, bounce_dir,
                                                           triangles, triangle_count);

        // AO: if hit is close, this point is occluded
        if (bounce_hit.triangle_index >= 0 && bounce_hit.distance < ao_radius) {
            ao_accum += 1.0f - (bounce_hit.distance / ao_radius);
        }

        if (bounce_hit.triangle_index < 0) continue;

        int bounce_idx = bounce_hit.triangle_index;
        float3 bounce_normal = triangles[bounce_idx].normal.xyz;
        float3 bounce_to_light = uni.light_pos.xyz - bounce_hit.position;
        float bounce_r = length(bounce_to_light);
        float bounce_dot = dot(bounce_to_light, bounce_normal);

        if (bounce_dot <= 0.0f) continue;

        GPUIntersection shadow_test = simple_intersect_gpu(bounce_hit.position,
                                                            bounce_to_light,
                                                            triangles, triangle_count);
        if (shadow_test.triangle_index >= 0 &&
            shadow_test.distance < 1.0f &&
            shadow_test.triangle_index != bounce_idx)
            continue;

        float bounce_area = 4.0f * M_PI_F * bounce_r * bounce_r;
        float3 bounce_direct = (bounce_dot / bounce_area) * uni.light_colour.xyz;

        accum += triangles[bounce_idx].color.xyz * bounce_direct;
    }

    // AO: 0 = fully occluded, 1 = fully open
    ao_factor = clamp(1.0f - 0.8f * ao_accum / float(N_BOUNCES), 0.30f, 1.0f);

    // Clamp indirect to prevent fireflies
    float3 result = accum / float(N_BOUNCES);
    result = min(result, float3(0.35f));
    return result;
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

    // --- Seed --- use multiple PCG rounds for better decorrelation
    uint seed = pcg_hash(x + pcg_hash(y + pcg_hash(sample_idx + 1u)));

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

            light_area = 0.22f * uni.indirect_light.xyz +
                                 (light_area + mirror_shadow) / 2.0f;

            // Add indirect GI for the reflected surface
            if (mirror_isec.triangle_index >= 0) {
                float mirror_ao;
                float3 mirror_indirect = indirect_light_one_bounce(
                    mirror_isec, triangles, uni.triangle_count, uni, seed, mirror_ao);
                light_area += 0.35f * mirror_indirect;
            }
        } else {
            light_area = 0.22f * uni.indirect_light.xyz + light_area;

            // Add 1-bounce indirect illumination (global illumination / colour bleeding)
            float ao;
            float3 indirect = indirect_light_one_bounce(
                intersection, triangles, uni.triangle_count, uni, seed, ao);
            light_area += 0.35f * indirect;

            // Apply ambient occlusion
            light_area *= ao;
        }

        pixel_colour = light_area * intersection.colour;
    }

    // --- Tone mapping (extended Reinhard with white point) + gamma correction ---
    float Lw = 2.0f; // white point — values above this compress to near-white
    pixel_colour = pixel_colour * (1.0f + pixel_colour / (Lw * Lw)) / (1.0f + pixel_colour);
    pixel_colour = pow(clamp(pixel_colour, 0.0f, 1.0f), 1.0f / 2.2f);

    // --- Write output ---
    uint out_idx = (y * uint(sw) + x) * 9u + sample_idx;
    output_buffer[out_idx] = float4(pixel_colour, 1.0f);
}
