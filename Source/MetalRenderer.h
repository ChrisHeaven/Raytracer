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
};

class MetalRenderer {
public:
    MetalRenderer(int width, int height);
    ~MetalRenderer();
    void uploadTriangles(const std::vector<Triangle>& tris);
    // Renders and fills pixels (size = width*height, row-major)
    void render(const RenderParams& params, std::vector<glm::vec3>& pixels);
private:
    void* _device;
    void* _commandQueue;
    void* _pipelineState;
    void* _triangleBuffer;
    void* _uniformsBuffer;
    void* _outputBuffer;
    int _width, _height;
};
