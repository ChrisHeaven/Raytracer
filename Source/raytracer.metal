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
};

// ---------------------------------------------------------------------------
// PCG-based random number generator
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

    float3 w = normal;
    float3 helper = abs(w.x) > 0.9f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 u = normalize(cross(helper, w));
    float3 v = cross(w, u);

    return u * (cos(phi) * sin_theta) + v * (sin(phi) * sin_theta) + w * cos_theta;
}

// ---------------------------------------------------------------------------
// Sample a random point on the rectangular area light
// ---------------------------------------------------------------------------
inline float3 sample_area_light_uniform(constant RenderUniforms& uni,
                                         thread uint& seed)
{
    float u = rand_float(seed);
    float v = rand_float(seed);
    return uni.light_corner.xyz + u * uni.light_edge_u.xyz + v * uni.light_edge_v.xyz;
}

// ---------------------------------------------------------------------------
// trace_ray — find closest hit among all triangles
// ---------------------------------------------------------------------------
inline GPUIntersection trace_ray(float3 orig,
                                  float3 dir,
                                  constant GPUTriangle* triangles,
                                  int triangle_count)
{
    GPUIntersection result;
    result.distance       = 1e30f;
    result.triangle_index = -1;
    result.colour         = float3(0.0f);
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
// shadow_test — any-hit test (returns true if blocked)
// ---------------------------------------------------------------------------
inline bool shadow_test(float3 orig,
                         float3 dir,
                         float  max_dist,
                         int    exclude_idx,
                         int    light_tri_start,
                         constant GPUTriangle* triangles,
                         int triangle_count)
{
    for (int i = 0; i < triangle_count; ++i) {
        if (i >= light_tri_start) continue;  // skip light geometry
        if (i == exclude_idx) continue;
        float t = 0.0f;
        if (ray_triangle_intersect(orig, dir,
                                   triangles[i].v0.xyz,
                                   triangles[i].v1.xyz,
                                   triangles[i].v2.xyz,
                                   t))
        {
            if (t > 0.001f && t < max_dist) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Path Tracing with Next Event Estimation (NEE)
//
// Each call traces ONE complete light path from the given ray origin/direction,
// bouncing up to MAX_DEPTH times. At each bounce:
//   1. NEE: sample a point on the area light, compute direct illumination
//   2. Sample a random bounce direction (cosine-weighted for diffuse,
//      perfect reflection for mirror surfaces)
//   3. Russian Roulette after depth >= 3
// ---------------------------------------------------------------------------
constant int MAX_DEPTH = 8;

inline float3 path_trace(float3 ray_origin,
                           float3 ray_dir,
                           constant GPUTriangle* triangles,
                           int triangle_count,
                           constant RenderUniforms& uni,
                           thread uint& seed)
{
    float3 radiance   = float3(0.0f);
    float3 throughput = float3(1.0f);

    float3 cur_origin = ray_origin;
    float3 cur_dir    = ray_dir;

    for (int depth = 0; depth < MAX_DEPTH; ++depth) {

        // --- Trace ray ---
        GPUIntersection hit = trace_ray(cur_origin, cur_dir, triangles, triangle_count);

        // Miss → black background
        if (hit.triangle_index < 0) break;

        int    idx    = hit.triangle_index;
        float3 normal = triangles[idx].normal.xyz;
        float3 albedo = triangles[idx].color.xyz;

        // --- Hit light source → add emission and stop ---
        if (idx >= uni.light_tri_start) {
            // Only count direct light hit on depth 0 (NEE handles the rest)
            if (depth == 0) {
                float3 warm_white = float3(1.0f, 0.97f, 0.92f);
                radiance += throughput * warm_white;
            }
            break;
        }

        // --- Mirror surface (tall block front face) ---
        if (idx == 20 || idx == 21) {
            float3 n = triangles[idx].normal.xyz;
            cur_dir = cur_dir - 2.0f * dot(cur_dir, n) * n;
            cur_origin = hit.position;
            // Mirror doesn't attenuate throughput, just reflects
            continue;
        }

        // --- Make sure normal faces the incoming ray ---
        if (dot(normal, cur_dir) > 0.0f) {
            normal = -normal;
        }

        // --- Next Event Estimation (NEE): sample area light directly ---
        {
            float3 light_sample = sample_area_light_uniform(uni, seed);
            float3 to_light = light_sample - hit.position;
            float  dist     = length(to_light);
            float3 to_light_n = to_light / dist;

            float cos_surface = dot(to_light_n, normal);
            float cos_light   = dot(-to_light_n, uni.light_normal.xyz);

            if (cos_surface > 0.0f && cos_light > 0.0f) {
                // Shadow test
                bool blocked = shadow_test(hit.position, to_light, 0.999f,
                                            idx, uni.light_tri_start,
                                            triangles, triangle_count);
                if (!blocked) {
                    // Area light PDF = 1/A, geometry term
                    float geom = cos_surface * cos_light / (dist * dist);
                    float3 Le = uni.light_colour.xyz;
                    float  A  = uni.light_area_val;
                    radiance += throughput * albedo * Le * geom * A / M_PI_F;
                }
            }
        }

        // --- Sample next bounce direction (cosine-weighted diffuse) ---
        float3 bounce_dir = cosine_weighted_hemisphere(normal, seed);

        // Cosine-weighted PDF = cos(theta) / pi
        // BRDF for Lambertian = albedo / pi
        // throughput *= (albedo / pi) * cos(theta) / (cos(theta) / pi) = albedo
        throughput *= albedo;

        // --- Russian Roulette (after depth 3) ---
        if (depth >= 3) {
            float p = max(max(throughput.x, throughput.y), throughput.z);
            p = clamp(p, 0.05f, 0.95f);
            if (rand_float(seed) > p) break;
            throughput /= p;  // compensate for termination probability
        }

        // --- Advance ray ---
        cur_origin = hit.position;
        cur_dir    = bounce_dir;
    }

    return radiance;
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
    uint frame_seed = pcg_hash(uint(uni.frame_number) * 1664525u + 1013904223u);
    uint seed = pcg_hash(pcg_hash(x * 1973u + y * 9277u + sample_idx * 26699u) + frame_seed);

    // --- Rotation matrix (yaw around Y axis) ---
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
    int a_idx = int(sample_idx) / 3;
    int b_idx = int(sample_idx) % 3;

    float x_ = -8.0f + (float(b_idx) + rand_float(seed)) * (16.0f / 3.0f);
    float y_ = -8.0f + (float(a_idx) + rand_float(seed)) * (16.0f / 3.0f);

    // --- Sub-pixel position ---
    float3 sub_pixel = float3(
        -0.5f + 0.5f / sw_f + (float(x) + x_) / sw_f,
        -0.5f + 0.5f / sh_f + (float(y) + y_) / sh_f,
        -2.0f
    );

    // --- Focal point ---
    float3 focal_point = float3(focal_x, focal_y, uni.focal);

    // --- Thin-lens DOF ---
    float3 ray_origin = sub_pixel;
    if (uni.aperture_radius > 0.0f) {
        float r1 = rand_float(seed);
        float r2 = rand_float(seed);
        float angle = 2.0f * M_PI_F * r1;
        float radius = uni.aperture_radius * sqrt(r2);
        ray_origin.x += radius * cos(angle);
        ray_origin.y += radius * sin(angle);
    }

    // --- Ray direction ---
    float3 d_local = focal_point - ray_origin;
    float3 d = float3(
         cos_yaw * d_local.x + sin_yaw * d_local.z,
         d_local.y,
        -sin_yaw * d_local.x + cos_yaw * d_local.z
    );

    // --- Path trace ---
    float3 pixel_colour = path_trace(ray_origin, d,
                                      triangles, uni.triangle_count,
                                      uni, seed);

    // --- Exposure + ACES Filmic tone mapping + gamma ---
    pixel_colour *= 1.2f;
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
