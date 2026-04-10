#pragma once
#include <vector>
#include <glm/glm.hpp>
#include "TestModel.h"

struct RenderParams {
    glm::vec3 camera_pos;
    glm::vec3 light_pos;       // center of area light (for compatibility)
    glm::vec3 light_colour;
    glm::vec3 indirect_light;
    glm::vec3 light_corner;    // area light corner
    glm::vec3 light_edge_u;    // area light edge vector u
    glm::vec3 light_edge_v;    // area light edge vector v
    glm::vec3 light_normal;    // area light normal
    float light_area;          // area light surface area
    int   light_tri_start;     // first triangle index of light geometry
    float focal;
    float f;
    float yaw;
    int screen_width;
    int screen_height;
    float aperture_radius = 0.0f;  // thin-lens DOF radius (0 = pinhole)
    int samples_per_pixel = 16;    // AA samples per pixel
};

class MetalRenderer {
public:
    MetalRenderer(int width, int height, int spp = 16);
    ~MetalRenderer();
    void uploadTriangles(const std::vector<Triangle>& tris);
    void render(const RenderParams& params, std::vector<glm::vec3>& pixels);
    void resetAccumulation();
private:
    void* _device;
    void* _commandQueue;
    void* _raytracePipeline;   // raytracer_kernel
    void* _accumPipeline;      // accumulate_kernel
    void* _triangleBuffer;
    void* _uniformsBuffer;
    void* _sampleBuffer;      // per-sample results (W*H*SPP float4)
    void* _accumGPUBuffer;    // GPU-side accumulation buffer
    void* _outputBuffer;      // final output (W*H float4)
    int _width, _height, _spp;
    int _frameNumber = 0;
    int _accumCount = 0;
    float _prevYaw = 0.0f;
    glm::vec3 _prevCameraPos{0};
    glm::vec3 _prevLightPos{0};
};
