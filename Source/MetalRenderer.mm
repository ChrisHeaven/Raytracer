#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <simd/simd.h>
#include <cstring>
#include <cstdio>
#include "MetalRenderer.h"

// ---------------------------------------------------------------------------
// GPU structs – must match raytracer.metal exactly
// ---------------------------------------------------------------------------
struct GPUTriangle {
    simd_float4 v0, v1, v2, normal, color;
};

struct RenderUniforms {
    simd_float4 camera_pos;
    simd_float4 light_pos;
    simd_float4 light_colour;
    simd_float4 indirect_light;
    simd_float4 light_corner;
    simd_float4 light_edge_u;
    simd_float4 light_edge_v;
    simd_float4 light_normal;
    float focal;
    float f;
    float yaw;
    float light_area_val;
    int triangle_count;
    int light_tri_start;
    int screen_width;
    int screen_height;
};

// ---------------------------------------------------------------------------
// Helper: convert glm::vec3 → simd_float4 (w = 0)
// ---------------------------------------------------------------------------
static inline simd_float4 toFloat4(const glm::vec3& v) {
    return simd_make_float4(v.x, v.y, v.z, 0.0f);
}

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------
MetalRenderer::MetalRenderer(int width, int height)
    : _device(nullptr), _commandQueue(nullptr), _pipelineState(nullptr),
      _triangleBuffer(nullptr), _uniformsBuffer(nullptr), _outputBuffer(nullptr),
      _width(width), _height(height)
{
    @autoreleasepool {
        // 1. Create device & command queue
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[MetalRenderer] No Metal-capable GPU found.\n");
            return;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        // 2. Locate raytracer.metallib
        NSString* path = [[NSBundle mainBundle] pathForResource:@"raytracer" ofType:@"metallib"];

        if (!path) {
            // Try current working directory (running from Build/)
            NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
            NSString* candidate = [NSString stringWithFormat:@"%@/raytracer.metallib", cwd];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                path = candidate;
            }
        }

        if (!path) {
            // Try directory containing the executable
            NSString* execPath = [[NSProcessInfo processInfo] arguments][0];
            NSString* execDir  = [execPath stringByDeletingLastPathComponent];
            NSString* candidate = [execDir stringByAppendingPathComponent:@"raytracer.metallib"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                path = candidate;
            }
        }

        if (!path) {
            fprintf(stderr, "[MetalRenderer] Could not find raytracer.metallib.\n");
            return;
        }

        // 3. Load library
        NSError* err = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:path]
                                                     error:&err];
        if (!library) {
            fprintf(stderr, "[MetalRenderer] Failed to load metallib: %s\n",
                    [[err localizedDescription] UTF8String]);
            return;
        }

        // 4. Get compute kernel
        id<MTLFunction> fn = [library newFunctionWithName:@"raytracer_kernel"];
        if (!fn) {
            fprintf(stderr, "[MetalRenderer] Function 'raytracer_kernel' not found in metallib.\n");
            return;
        }

        // 5. Build compute pipeline
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:fn error:&err];
        if (!pipeline) {
            fprintf(stderr, "[MetalRenderer] Failed to create pipeline: %s\n",
                    [[err localizedDescription] UTF8String]);
            return;
        }

        // 6. Allocate persistent buffers
        id<MTLBuffer> uniformsBuf =
            [device newBufferWithLength:sizeof(RenderUniforms)
                                options:MTLResourceStorageModeShared];

        // 9 samples per pixel, each sample is a float4
        NSUInteger outputBytes = (NSUInteger)width * height * 9 * sizeof(simd_float4);
        id<MTLBuffer> outputBuf =
            [device newBufferWithLength:outputBytes
                                options:MTLResourceStorageModeShared];

        // 7. Store as void* (ARC bridge – we own the references)
        _device        = (__bridge_retained void*)device;
        _commandQueue  = (__bridge_retained void*)queue;
        _pipelineState = (__bridge_retained void*)pipeline;
        _uniformsBuffer = (__bridge_retained void*)uniformsBuf;
        _outputBuffer   = (__bridge_retained void*)outputBuf;

        NSLog(@"Metal GPU renderer initialized: %@", device.name);
    }
}

// ---------------------------------------------------------------------------
// Destructor
// ---------------------------------------------------------------------------
MetalRenderer::~MetalRenderer()
{
    @autoreleasepool {
        if (_outputBuffer)   { (void)(__bridge_transfer id<MTLBuffer>)_outputBuffer; }
        if (_uniformsBuffer) { (void)(__bridge_transfer id<MTLBuffer>)_uniformsBuffer; }
        if (_triangleBuffer) { (void)(__bridge_transfer id<MTLBuffer>)_triangleBuffer; }
        if (_pipelineState)  { (void)(__bridge_transfer id<MTLComputePipelineState>)_pipelineState; }
        if (_commandQueue)   { (void)(__bridge_transfer id<MTLCommandQueue>)_commandQueue; }
        if (_device)         { (void)(__bridge_transfer id<MTLDevice>)_device; }
    }
}

// ---------------------------------------------------------------------------
// uploadTriangles
// ---------------------------------------------------------------------------
void MetalRenderer::uploadTriangles(const std::vector<Triangle>& tris)
{
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)_device;
        if (!device) return;

        std::vector<GPUTriangle> gpuTris(tris.size());
        for (size_t i = 0; i < tris.size(); ++i) {
            gpuTris[i].v0     = toFloat4(tris[i].v0);
            gpuTris[i].v1     = toFloat4(tris[i].v1);
            gpuTris[i].v2     = toFloat4(tris[i].v2);
            gpuTris[i].normal = toFloat4(tris[i].normal);
            gpuTris[i].color  = toFloat4(tris[i].color);
        }

        NSUInteger bytes = gpuTris.size() * sizeof(GPUTriangle);
        id<MTLBuffer> buf = [device newBufferWithBytes:gpuTris.data()
                                                length:bytes
                                               options:MTLResourceStorageModeShared];

        // Release old buffer if present
        if (_triangleBuffer) {
            (void)(__bridge_transfer id<MTLBuffer>)_triangleBuffer;
        }
        _triangleBuffer = (__bridge_retained void*)buf;
    }
}

// ---------------------------------------------------------------------------
// render
// ---------------------------------------------------------------------------
void MetalRenderer::render(const RenderParams& params, std::vector<glm::vec3>& pixels)
{
    @autoreleasepool {
        id<MTLDevice>                  device   = (__bridge id<MTLDevice>)_device;
        id<MTLCommandQueue>            queue    = (__bridge id<MTLCommandQueue>)_commandQueue;
        id<MTLComputePipelineState>    pipeline = (__bridge id<MTLComputePipelineState>)_pipelineState;
        id<MTLBuffer>                  triBuf   = (__bridge id<MTLBuffer>)_triangleBuffer;
        id<MTLBuffer>                  uniBuf   = (__bridge id<MTLBuffer>)_uniformsBuffer;
        id<MTLBuffer>                  outBuf   = (__bridge id<MTLBuffer>)_outputBuffer;

        if (!device || !pipeline || !triBuf) {
            fprintf(stderr, "[MetalRenderer] render() called before initialisation or uploadTriangles().\n");
            return;
        }

        // 1. Fill uniforms
        RenderUniforms uni;
        uni.camera_pos     = toFloat4(params.camera_pos);
        uni.light_pos      = toFloat4(params.light_pos);
        uni.light_colour   = toFloat4(params.light_colour);
        uni.indirect_light = toFloat4(params.indirect_light);
        uni.light_corner   = toFloat4(params.light_corner);
        uni.light_edge_u   = toFloat4(params.light_edge_u);
        uni.light_edge_v   = toFloat4(params.light_edge_v);
        uni.light_normal   = toFloat4(params.light_normal);
        uni.focal          = params.focal;
        uni.f              = params.f;
        uni.yaw            = params.yaw;
        uni.light_area_val = params.light_area;
        uni.triangle_count = (int)(triBuf.length / sizeof(GPUTriangle));
        uni.light_tri_start = params.light_tri_start;
        uni.screen_width   = params.screen_width;
        uni.screen_height  = params.screen_height;

        // 2. Copy uniforms into shared buffer
        memcpy(uniBuf.contents, &uni, sizeof(RenderUniforms));

        // 3. Encode compute pass
        id<MTLCommandBuffer>         cmdBuf  = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];

        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:triBuf offset:0 atIndex:0];
        [encoder setBuffer:uniBuf offset:0 atIndex:1];
        [encoder setBuffer:outBuf offset:0 atIndex:2];

        // 4. Dispatch – one thread per (x, y, sample)
        MTLSize threadsPerGrid      = MTLSizeMake((NSUInteger)_width,
                                                   (NSUInteger)_height,
                                                   9);
        MTLSize threadsPerThreadgroup = MTLSizeMake(8, 8, 1);
        [encoder dispatchThreads:threadsPerGrid
           threadsPerThreadgroup:threadsPerThreadgroup];

        [encoder endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        // 5. Read back: layout is [pixelIndex * 9 + sampleIndex] → simd_float4
        const simd_float4* buf = reinterpret_cast<const simd_float4*>(outBuf.contents);

        pixels.resize((size_t)_width * _height);
        for (int y = 0; y < _height; ++y) {
            for (int x = 0; x < _width; ++x) {
                int pixelIdx = y * _width + x;
                float r = 0.0f, g = 0.0f, b = 0.0f;
                for (int s = 0; s < 9; ++s) {
                    const simd_float4& sample = buf[pixelIdx * 9 + s];
                    r += sample.x;
                    g += sample.y;
                    b += sample.z;
                }
                pixels[pixelIdx] = glm::vec3(r / 9.0f, g / 9.0f, b / 9.0f);
            }
        }
    }
}
