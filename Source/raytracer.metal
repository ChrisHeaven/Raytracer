#include <metal_stdlib>
using namespace metal;

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
    float4 light_corner;
    float4 light_edge_u;
    float4 light_edge_v;
    float4 light_normal;
    float  focal;
    float  f;
    float  yaw;
    float  light_area_val;
    int    triangle_count;
    int    light_tri_start;
    int    screen_width;
    int    screen_height;
    int    frame_number;       // for temporal seed variation
    float  aperture_radius;    // thin-lens DOF (0 = pinhole)
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
// Sample a random point on the rectangular area light (stratified 2×2)
// ---------------------------------------------------------------------------
inline float3 sample_area_light(constant RenderUniforms& uni,
                                 thread uint& seed,
                                 int stratum_u, int stratum_v)
{
    // Stratified: divide [0,1]² into 2×2 cells
    float u = (float(stratum_u) + rand_float(seed)) * 0.5f;
    float v = (float(stratum_v) + rand_float(seed)) * 0.5f;
    return uni.light_corner.xyz + u * uni.light_edge_u.xyz + v * uni.light_edge_v.xyz;
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
// Tests ALL triangles for any occlusion.
// ---------------------------------------------------------------------------
inline bool shadow_intersect_gpu(float3 orig,
                                 float3 dir,
                                 int    id,
                                 constant GPUTriangle* triangles,
                                 int triangle_count)
{
    for (int i = 0; i < triangle_count; ++i) {
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

        if (idx == 20 || idx == 21) {
            // Mirror surface on tall block front face
            float3 n = triangles[idx].normal.xyz;
            float3 reflect_dir = dir - 2.0f * dot(dir, n) * n;
            GPUIntersection mirror_hit = simple_intersect_gpu(result.position,
                                                               reflect_dir,
                                                               triangles,
                                                               triangle_count);
            if (mirror_hit.triangle_index >= 0) {
                result.colour = mirror_hit.colour;
            } else {
                result.colour = float3(0.05f); // dark if reflection misses
            }
            result.is_mirror = true;
        } else {
            result.colour    = triangles[idx].color.xyz;
            result.is_mirror = false;
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// direct_light_gpu — area light sampling with Blinn-Phong specular
// ---------------------------------------------------------------------------
constant int N_LIGHT_SAMPLES = 8;

inline float3 direct_light_gpu(GPUIntersection        point,
                                constant GPUTriangle*  triangles,
                                int                    triangle_count,
                                constant RenderUniforms& uni,
                                thread uint&           seed,
                                float3                 view_dir)
{
    int    idx    = point.triangle_index;
    float3 normal = triangles[idx].normal.xyz;
    float3 light_n = uni.light_normal.xyz;

    float3 diffuse_accum  = float3(0.0f);
    float3 specular_accum = float3(0.0f);

    // Specular parameters (Blinn-Phong)
    float shininess = 32.0f;
    float spec_strength = 0.15f;
    float3 V = normalize(-view_dir);  // direction toward camera

    for (int s = 0; s < N_LIGHT_SAMPLES; ++s) {
        int su = int(rand_float(seed) * 2.0f);
        int sv = int(rand_float(seed) * 2.0f);
        su = min(su, 1); sv = min(sv, 1);
        float3 sample_pos = sample_area_light(uni, seed, su, sv);
        float3 dir = sample_pos - point.position;
        float  r   = length(dir);
        float3 dir_n = dir / r;

        // Cosine at surface
        float cos_surface = dot(dir_n, normal);
        if (cos_surface <= 0.0f) continue;

        // Cosine at light (light normal points into scene = +y)
        float cos_light = dot(-dir_n, light_n);
        if (cos_light <= 0.0f) continue;

        // Shadow test: trace from surface to light sample point
        GPUIntersection shadow = simple_intersect_gpu(point.position, dir,
                                                       triangles, triangle_count);

        // Skip light geometry itself in shadow test
        bool blocked = (shadow.triangle_index >= 0) &&
                       (shadow.distance < 1.0f) &&
                       (shadow.triangle_index != idx) &&
                       (shadow.triangle_index < uni.light_tri_start);

        if (blocked) continue;

        // Area light contribution:
        // L = Le * cos_surface * cos_light * A / (N * π * r²)
        float geom = cos_surface * cos_light * uni.light_area_val /
                     (float(N_LIGHT_SAMPLES) * M_PI_F * r * r);
        diffuse_accum += geom * uni.light_colour.xyz;

        // Blinn-Phong specular: half-vector between view and light
        float3 H = normalize(V + dir_n);
        float NdotH = max(dot(normal, H), 0.0f);
        float spec = pow(NdotH, shininess);
        specular_accum += spec * geom * uni.light_colour.xyz;
    }

    return diffuse_accum + spec_strength * specular_accum;
}

// ---------------------------------------------------------------------------
// indirect_light_one_bounce — 1-bounce global illumination
// Shoots N_BOUNCES random cosine-weighted rays from the surface and averages.
// ---------------------------------------------------------------------------
constant int N_BOUNCES = 5;

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
    float ao_radius = 0.4f; // AO sampling radius

    for (int b = 0; b < N_BOUNCES; ++b) {
        float3 bounce_dir = cosine_weighted_hemisphere(normal, seed);

        GPUIntersection bounce_hit = simple_intersect_gpu(point.position, bounce_dir,
                                                           triangles, triangle_count);

        // AO: if hit is close, this point is occluded
        if (bounce_hit.triangle_index >= 0 && bounce_hit.distance < ao_radius) {
            ao_accum += 1.0f - (bounce_hit.distance / ao_radius);
        }

        if (bounce_hit.triangle_index < 0) continue;

        // Skip if bounce hit the light itself
        int bounce_idx = bounce_hit.triangle_index;
        if (bounce_idx >= uni.light_tri_start) continue;

        float3 bounce_normal = triangles[bounce_idx].normal.xyz;

        // Sample 1 random point on the area light for bounce illumination
        int su = int(rand_float(seed) * 2.0f);
        int sv = int(rand_float(seed) * 2.0f);
        su = min(su, 1); sv = min(sv, 1);
        float3 light_sample = sample_area_light(uni, seed, su, sv);
        float3 bounce_to_light = light_sample - bounce_hit.position;
        float bounce_r = length(bounce_to_light);
        float3 bounce_dir_n = bounce_to_light / bounce_r;

        float bounce_cos_surface = dot(bounce_dir_n, bounce_normal);
        if (bounce_cos_surface <= 0.0f) continue;

        float bounce_cos_light = dot(-bounce_dir_n, uni.light_normal.xyz);
        if (bounce_cos_light <= 0.0f) continue;

        GPUIntersection shadow_test = simple_intersect_gpu(bounce_hit.position,
                                                            bounce_to_light,
                                                            triangles, triangle_count);
        if (shadow_test.triangle_index >= 0 &&
            shadow_test.distance < 1.0f &&
            shadow_test.triangle_index != bounce_idx &&
            shadow_test.triangle_index < uni.light_tri_start)
            continue;

        // Area light formula for single sample
        float bounce_geom = bounce_cos_surface * bounce_cos_light * uni.light_area_val /
                            (M_PI_F * bounce_r * bounce_r);
        float3 bounce_direct = bounce_geom * uni.light_colour.xyz;

        accum += triangles[bounce_idx].color.xyz * bounce_direct;
    }

    // AO: 0 = fully occluded, 1 = fully open
    ao_factor = clamp(1.0f - 0.5f * ao_accum / float(N_BOUNCES), 0.35f, 1.0f);

    // Clamp indirect to prevent fireflies
    float3 result = accum / float(N_BOUNCES);
    result = min(result, float3(1.5f));
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

    // --- Seed --- use multiple PCG rounds with golden-ratio scrambling for better spatial decorrelation
    uint frame_seed = pcg_hash(uint(uni.frame_number) * 1664525u + 1013904223u);
    uint seed = pcg_hash(pcg_hash(x * 1973u + y * 9277u + sample_idx * 26699u) + frame_seed);

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

    // --- Sub-pixel position (pinhole origin on image plane) ---
    float3 sub_pixel = float3(
        -0.5f + 0.5f / sw_f + (float(x) + x_) / sw_f,
        -0.5f + 0.5f / sh_f + (float(y) + y_) / sh_f,
        -2.0f
    );

    // --- Focal point (where this ray converges regardless of lens jitter) ---
    float3 focal_point = float3(focal_x, focal_y, uni.focal);

    // --- Thin-lens DOF: jitter ray origin on the lens disk ---
    float3 ray_origin = sub_pixel;
    if (uni.aperture_radius > 0.0f) {
        // Uniform disk sampling via concentric mapping
        float r1 = rand_float(seed);
        float r2 = rand_float(seed);
        float angle = 2.0f * M_PI_F * r1;
        float radius = uni.aperture_radius * sqrt(r2);
        float lens_dx = radius * cos(angle);
        float lens_dy = radius * sin(angle);
        ray_origin.x += lens_dx;
        ray_origin.y += lens_dy;
    }

    // --- Ray direction (before rotation) ---
    float3 d_local = float3(focal_point.x - ray_origin.x,
                            focal_point.y - ray_origin.y,
                            focal_point.z - ray_origin.z);

    // Apply Y-axis rotation: R*d
    float3 d = float3(
         cos_yaw * d_local.x + sin_yaw * d_local.z,
         d_local.y,
        -sin_yaw * d_local.x + cos_yaw * d_local.z
    );

    // --- Trace primary ray ---
    GPUIntersection intersection = closest_intersect_gpu(
        ray_origin, d,
        triangles, uni.triangle_count,
        0, uni);

    float3 pixel_colour = float3(0.0f);

    if (intersection.triangle_index >= 0) {
        // If we hit a light source triangle, render emissive with glow
        if (intersection.triangle_index >= uni.light_tri_start) {
            // Light source center (in post-transform space)
            float3 light_center = uni.light_corner.xyz
                                + 0.5f * uni.light_edge_u.xyz
                                + 0.5f * uni.light_edge_v.xyz;
            float3 to_center = intersection.position - light_center;
            // Normalize distance by half-diagonal of the light rectangle
            float half_diag = 0.5f * length(uni.light_edge_u.xyz + uni.light_edge_v.xyz);
            float d_norm = length(to_center) / half_diag;

            // Core emission: brighter in the center, slight falloff at edges
            float core = 1.0f - 0.25f * d_norm * d_norm;
            // Warm tint: center is slightly warm white
            float3 warm_white = float3(1.0f, 0.97f, 0.92f);
            pixel_colour = core * warm_white;
        } else {
        float3 light_area = direct_light_gpu(intersection,
                                             triangles,
                                             uni.triangle_count,
                                             uni,
                                             seed,
                                             d);

        if (intersection.is_mirror) {
            // Mirror: re-trace reflected ray, light the reflected surface
            float3 mir_n = triangles[intersection.triangle_index].normal.xyz;
            float3 reflect_dir = d - 2.0f * dot(d, mir_n) * mir_n;
            GPUIntersection mirror_isec = simple_intersect_gpu(
                intersection.position, reflect_dir,
                triangles, uni.triangle_count);

            float3 mirror_light = float3(0.0f);
            if (mirror_isec.triangle_index >= 0) {
                mirror_light = direct_light_gpu(mirror_isec,
                                                triangles,
                                                uni.triangle_count,
                                                uni, seed, reflect_dir);
                float mirror_ao;
                float3 mirror_indirect = indirect_light_one_bounce(
                    mirror_isec, triangles, uni.triangle_count, uni, seed, mirror_ao);
                mirror_light = 0.12f * uni.indirect_light.xyz + mirror_light
                             + 1.0f * mirror_indirect;
                mirror_light *= mirror_ao;
            }
            light_area = mirror_light;
        } else {
            light_area = 0.12f * uni.indirect_light.xyz + light_area;

            // Add 1-bounce indirect illumination (global illumination / colour bleeding)
            float ao;
            float3 indirect = indirect_light_one_bounce(
                intersection, triangles, uni.triangle_count, uni, seed, ao);
            light_area += 1.0f * indirect;

            // Apply ambient occlusion
            light_area *= ao;
        }

        pixel_colour = light_area * intersection.colour;

        // Artificial ceiling glow removed — GI bounce now handles
        // natural light spill around the area light panel.

        } // end non-light-triangle branch
    }

    // --- Exposure adjustment + Tone mapping: ACES Filmic (Narkowicz 2015) + gamma ---
    pixel_colour *= 1.2f;  // exposure boost for brighter scene
    {
        float3 x = pixel_colour;
        float a = 2.51f;
        float b = 0.03f;
        float c = 2.43f;
        float dd = 0.59f;
        float e = 0.14f;
        pixel_colour = clamp((x * (a * x + b)) / (x * (c * x + dd) + e), 0.0f, 1.0f);
    }
    pixel_colour = pow(pixel_colour, 1.0f / 2.2f);

    // --- Write output ---
    uint out_idx = (y * uint(sw) + x) * 9u + sample_idx;
    output_buffer[out_idx] = float4(pixel_colour, 1.0f);
}
