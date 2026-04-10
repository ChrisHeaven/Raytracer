#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <simd/simd.h>
#include <cstring>
#include <cstdio>
#include <algorithm>
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
    int frame_number;
    float aperture_radius;
    int accum_count;
    float accum_weight_new;
    int samples_per_pixel;
};

// ---------------------------------------------------------------------------
// Helper: convert glm::vec3 -> simd_float4 (w = 0)
// ---------------------------------------------------------------------------
static inline simd_float4 toFloat4(const glm::vec3& v) {
    return simd_make_float4(v.x, v.y, v.z, 0.0f);
}

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------
MetalRenderer::MetalRenderer(int width, int height, int spp)
    : _device(nullptr), _commandQueue(nullptr),
      _raytracePipeline(nullptr), _accumPipeline(nullptr),
      _triangleBuffer(nullptr), _uniformsBuffer(nullptr),
      _sampleBuffer(nullptr), _accumGPUBuffer(nullptr), _outputBuffer(nullptr),
      _width(width), _height(height), _spp(spp)
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
            NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
            NSString* candidate = [NSString stringWithFormat:@"%@/raytracer.metallib", cwd];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                path = candidate;
            }
        }

        if (!path) {
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

        // 4. Get compute kernels
        id<MTLFunction> rtFn = [library newFunctionWithName:@"raytracer_kernel"];
        if (!rtFn) {
            fprintf(stderr, "[MetalRenderer] Function 'raytracer_kernel' not found.\n");
            return;
        }
        id<MTLFunction> accFn = [library newFunctionWithName:@"accumulate_kernel"];
        if (!accFn) {
            fprintf(stderr, "[MetalRenderer] Function 'accumulate_kernel' not found.\n");
            return;
        }

        // 5. Build compute pipelines
        id<MTLComputePipelineState> rtPipeline =
            [device newComputePipelineStateWithFunction:rtFn error:&err];
        if (!rtPipeline) {
            fprintf(stderr, "[MetalRenderer] Failed to create raytrace pipeline: %s\n",
                    [[err localizedDescription] UTF8String]);
            return;
        }
        id<MTLComputePipelineState> accPipeline =
            [device newComputePipelineStateWithFunction:accFn error:&err];
        if (!accPipeline) {
            fprintf(stderr, "[MetalRenderer] Failed to create accumulate pipeline: %s\n",
                    [[err localizedDescription] UTF8String]);
            return;
        }

        // 6. Allocate persistent buffers
        id<MTLBuffer> uniformsBuf =
            [device newBufferWithLength:sizeof(RenderUniforms)
                                options:MTLResourceStorageModeShared];

        // Per-sample buffer: W * H * SPP * float4
        NSUInteger sampleBytes = (NSUInteger)width * height * spp * sizeof(simd_float4);
        id<MTLBuffer> sampleBuf =
            [device newBufferWithLength:sampleBytes
                                options:MTLResourceStorageModeShared];

        // Accumulation buffer: W * H * float4
        NSUInteger pixelBytes = (NSUInteger)width * height * sizeof(simd_float4);
        id<MTLBuffer> accumBuf =
            [device newBufferWithLength:pixelBytes
                                options:MTLResourceStorageModeShared];

        // Output buffer: W * H * float4
        id<MTLBuffer> outputBuf =
            [device newBufferWithLength:pixelBytes
                                options:MTLResourceStorageModeShared];

        // 7. Store as void* (ARC bridge)
        _device          = (__bridge_retained void*)device;
        _commandQueue    = (__bridge_retained void*)queue;
        _raytracePipeline = (__bridge_retained void*)rtPipeline;
        _accumPipeline   = (__bridge_retained void*)accPipeline;
        _uniformsBuffer  = (__bridge_retained void*)uniformsBuf;
        _sampleBuffer    = (__bridge_retained void*)sampleBuf;
        _accumGPUBuffer  = (__bridge_retained void*)accumBuf;
        _outputBuffer    = (__bridge_retained void*)outputBuf;

        NSLog(@"Metal GPU renderer initialized: %@ (%d spp)", device.name, spp);
    }
}

// ---------------------------------------------------------------------------
// Destructor
// ---------------------------------------------------------------------------
MetalRenderer::~MetalRenderer()
{
    @autoreleasepool {
        if (_outputBuffer)    { (void)(__bridge_transfer id<MTLBuffer>)_outputBuffer; }
        if (_accumGPUBuffer)  { (void)(__bridge_transfer id<MTLBuffer>)_accumGPUBuffer; }
        if (_sampleBuffer)    { (void)(__bridge_transfer id<MTLBuffer>)_sampleBuffer; }
        if (_uniformsBuffer)  { (void)(__bridge_transfer id<MTLBuffer>)_uniformsBuffer; }
        if (_triangleBuffer)  { (void)(__bridge_transfer id<MTLBuffer>)_triangleBuffer; }
        if (_accumPipeline)   { (void)(__bridge_transfer id<MTLComputePipelineState>)_accumPipeline; }
        if (_raytracePipeline) { (void)(__bridge_transfer id<MTLComputePipelineState>)_raytracePipeline; }
        if (_commandQueue)    { (void)(__bridge_transfer id<MTLCommandQueue>)_commandQueue; }
        if (_device)          { (void)(__bridge_transfer id<MTLDevice>)_device; }
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

        if (_triangleBuffer) {
            (void)(__bridge_transfer id<MTLBuffer>)_triangleBuffer;
        }
        _triangleBuffer = (__bridge_retained void*)buf;
    }
}

// ---------------------------------------------------------------------------
// resetAccumulation
// ---------------------------------------------------------------------------
void MetalRenderer::resetAccumulation()
{
    _accumCount = 0;
}

// ---------------------------------------------------------------------------
// render
// ---------------------------------------------------------------------------
void MetalRenderer::render(const RenderParams& params, std::vector<glm::vec3>& pixels)
{
    @autoreleasepool {
        id<MTLDevice>               device     = (__bridge id<MTLDevice>)_device;
        id<MTLCommandQueue>         queue      = (__bridge id<MTLCommandQueue>)_commandQueue;
        id<MTLComputePipelineState> rtPipeline = (__bridge id<MTLComputePipelineState>)_raytracePipeline;
        id<MTLComputePipelineState> accPipeline = (__bridge id<MTLComputePipelineState>)_accumPipeline;
        id<MTLBuffer>               triBuf     = (__bridge id<MTLBuffer>)_triangleBuffer;
        id<MTLBuffer>               uniBuf     = (__bridge id<MTLBuffer>)_uniformsBuffer;
        id<MTLBuffer>               smpBuf     = (__bridge id<MTLBuffer>)_sampleBuffer;
        id<MTLBuffer>               accBuf     = (__bridge id<MTLBuffer>)_accumGPUBuffer;
        id<MTLBuffer>               outBuf     = (__bridge id<MTLBuffer>)_outputBuffer;

        if (!device || !rtPipeline || !triBuf) {
            fprintf(stderr, "[MetalRenderer] render() called before init or uploadTriangles().\n");
            return;
        }

        // Detect parameter changes -> reset accumulation
        if (params.camera_pos != _prevCameraPos ||
            params.light_pos != _prevLightPos ||
            params.yaw != _prevYaw) {
            _accumCount = 0;
            _prevCameraPos = params.camera_pos;
            _prevLightPos = params.light_pos;
            _prevYaw = params.yaw;
        }

        _frameNumber++;
        _accumCount++;
        int cap = std::min(_accumCount, 256);

        // 1. Fill uniforms
        RenderUniforms uni;
        uni.camera_pos      = toFloat4(params.camera_pos);
        uni.light_pos       = toFloat4(params.light_pos);
        uni.light_colour    = toFloat4(params.light_colour);
        uni.indirect_light  = toFloat4(params.indirect_light);
        uni.light_corner    = toFloat4(params.light_corner);
        uni.light_edge_u    = toFloat4(params.light_edge_u);
        uni.light_edge_v    = toFloat4(params.light_edge_v);
        uni.light_normal    = toFloat4(params.light_normal);
        uni.focal           = params.focal;
        uni.f               = params.f;
        uni.yaw             = params.yaw;
        uni.light_area_val  = params.light_area;
        uni.triangle_count  = (int)(triBuf.length / sizeof(GPUTriangle));
        uni.light_tri_start = params.light_tri_start;
        uni.screen_width    = params.screen_width;
        uni.screen_height   = params.screen_height;
        uni.frame_number    = _frameNumber;
        uni.aperture_radius = params.aperture_radius;
        uni.accum_count     = cap;
        uni.accum_weight_new = 1.0f / float(cap);
        uni.samples_per_pixel = _spp;

        memcpy(uniBuf.contents, &uni, sizeof(RenderUniforms));

        // 2. Encode raytrace pass — 3D dispatch: W x H x SPP
        id<MTLCommandBuffer>         cmdBuf  = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];

        [encoder setComputePipelineState:rtPipeline];
        [encoder setBuffer:triBuf offset:0 atIndex:0];
        [encoder setBuffer:uniBuf offset:0 atIndex:1];
        [encoder setBuffer:smpBuf offset:0 atIndex:2];
        [encoder setBuffer:accBuf offset:0 atIndex:3];

        MTLSize rtGrid = MTLSizeMake((NSUInteger)_width,
                                      (NSUInteger)_height,
                                      (NSUInteger)_spp);
        MTLSize rtGroup = MTLSizeMake(8, 8, 1);
        [encoder dispatchThreads:rtGrid threadsPerThreadgroup:rtGroup];

        [encoder endEncoding];

        // 3. Encode accumulation pass — 2D dispatch: W x H
        id<MTLComputeCommandEncoder> accEncoder = [cmdBuf computeCommandEncoder];

        [accEncoder setComputePipelineState:accPipeline];
        [accEncoder setBuffer:uniBuf offset:0 atIndex:0];
        [accEncoder setBuffer:smpBuf offset:0 atIndex:1];
        [accEncoder setBuffer:accBuf offset:0 atIndex:2];
        [accEncoder setBuffer:outBuf offset:0 atIndex:3];

        MTLSize accGrid  = MTLSizeMake((NSUInteger)_width, (NSUInteger)_height, 1);
        MTLSize accGroup = MTLSizeMake(16, 16, 1);
        [accEncoder dispatchThreads:accGrid threadsPerThreadgroup:accGroup];

        [accEncoder endEncoding];

        // 4. Submit and wait
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        // 5. Read back: 1 float4 per pixel
        const simd_float4* buf = reinterpret_cast<const simd_float4*>(outBuf.contents);

        size_t npixels = (size_t)_width * _height;
        pixels.resize(npixels);

        for (size_t i = 0; i < npixels; ++i) {
            pixels[i] = glm::vec3(buf[i].x, buf[i].y, buf[i].z);
        }
    }
}
