# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ray tracer coursework for Computer Graphics @ University of Bristol. Implements the Cornell Box scene with multiple rendering backends: C++ CPU (multithreaded), C++ GPU (Apple Metal), and Python (vectorized numpy).

## Build Commands

```bash
make          # Build the C++ raytracer (outputs to Build/skeleton)
make clean    # Clean build artifacts
```

The build compiles `Source/skeleton.cpp` with Metal GPU support enabled via `-DUSE_METAL`. Requires SDL and GLM (via Homebrew at `/opt/homebrew/include`), plus Apple Metal/Foundation/CoreGraphics frameworks.

To run:
```bash
./Build/skeleton
```

To run the Python version:
```bash
python3 Source/skeleton.py
```

## Architecture

### C++ CPU Renderer (`Source/skeleton.cpp`)
- Entry point: `main()` spawns 9 pthreads for parallel rendering
- Each thread renders a horizontal band of pixels
- 3×3 anti-aliasing (stratified sampling), soft shadows (10 samples), mirror reflections
- Ray–triangle intersection via Möller–Trumbore algorithm
- Scene geometry defined in `Source/TestModel.h` (Cornell Box, 30 triangles)
- SDL window for display; `Source/SDLauxiliary.h` wraps SDL boilerplate

### Metal GPU Renderer (`Source/MetalRenderer.mm` / `Source/raytracer.metal`)
- `MetalRenderer` class (declared in `Source/MetalRenderer.h`) uploads triangle data to GPU, dispatches a Metal compute kernel, and returns averaged pixel colors
- Metal shader in `Source/raytracer.metal` performs per-pixel ray tracing with 3×3 anti-aliasing
- Built into `Build/default.metallib` via `xcrun metal` + `xcrun metallib`
- Activated at runtime when `USE_METAL` is defined

### Python Renderer (`Source/skeleton.py`)
- Row-vectorized batch ray casting using NumPy
- `multiprocessing.Pool` with 4 workers (each handles a row range)
- 4×4 anti-aliasing (16 spp), 32 soft-shadow samples, thin-lens depth-of-field

## Key Parameters

| Parameter | C++ | Python |
|-----------|-----|--------|
| Resolution | 600×600 | 600×600 |
| AA samples | 3×3 | 4×4 |
| Shadow samples | 10 | 32 |
| Threads/workers | 9 (pthreads) | 4 (processes) |

## Interactive Controls (C++ version)

- **Arrow keys**: Rotate/move camera
- **W/A/S/D/Q/E**: Move light source
- **ESC**: Quit; saves `screenshot.bmp`
