/*
No recorded activity before January 30, 2017
*/

#include <cstddef>
#include <iostream>
#include <glm/glm.hpp>
#include <SDL/SDL.h>
#include "SDLauxiliary.h"
#include "TestModel.h"
#include "limits.h"
#include <algorithm>

#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>

#ifdef USE_METAL
#include "MetalRenderer.h"
#endif

using namespace std;
using glm::vec3;
using glm::mat3;

/* ----------------------------------------------------------------------------*/
/* GLOBAL VARIABLES                                                            */
const int SCREEN_WIDTH = 450;
const int SCREEN_HEIGHT = 450;
SDL_Surface* screen;
int t;
float f = 1.0;
float focal = -0.5;
float zz = 3.0;
float yaw = 0.0f * 3.1415926 / 180;
vec3 camera_pos(0, 0, -zz);
vec3 light_pos(0, -0.5, -0.7);
float light_radi = 0.3f;
vec3 light_colour = 14.f * vec3(1, 1, 1);
vec3 indirect_light = 0.5f * vec3( 1, 1, 1 );
static vec3 anti_aliasing[SCREEN_WIDTH / 3][SCREEN_HEIGHT / 3][9];
std::vector<Triangle> triangles;

#ifdef USE_METAL
MetalRenderer* g_metal_renderer = nullptr;
#endif

struct Intersection
{
    vec3 position;
    float distance;
    int triangle_index;
    vec3 colour;
    bool is_mirror;
};

static const vec3 FRONT_V0(-0.76f, -0.87f, -1.0f);
static const vec3 FRONT_V1(-0.76f,  1.0f,  -1.0f);
static const vec3 FRONT_V2( 1.31f,  1.0f,  -1.0f);

/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */
void Update();
void Draw();
bool closest_intersection(const vec3& start, const vec3& dir, const vector<Triangle>& triangles, Intersection& cloestIntersection, Intersection& mirIntersection, int light);
bool shadow_intersection(const vec3& start, const vec3& dir, int triangle_index, Intersection& cloestIntersection);
bool mirror_intersection(const vec3& start, const vec3& dir, const vector<Triangle>& triangles, Intersection& cloestIntersection);
vec3 direct_light(const Intersection& intersection_point, unsigned int& seed);
void* img_thread(void *arg);

inline bool RayTriangleIntersection(const vec3& orig,
                                    const vec3& dir,
                                    const vec3& v0,
                                    const vec3& v1,
                                    const vec3& v2,
                                    float& t,
                                    float& u,
                                    float& v)
{
    const float EPSILON = 1e-6f;
    vec3 e1 = v1 - v0;
    vec3 e2 = v2 - v0;
    vec3 pvec = glm::cross(dir, e2);
    float det = glm::dot(e1, pvec);
    if (fabs(det) < EPSILON)
        return false;

    float invDet = 1.0f / det;
    vec3 tvec = orig - v0;
    u = glm::dot(tvec, pvec) * invDet;
    if (u < 0.0f || u > 1.0f)
        return false;

    vec3 qvec = glm::cross(tvec, e1);
    v = glm::dot(dir, qvec) * invDet;
    if (v < 0.0f || u + v > 1.0f)
        return false;

    t = glm::dot(e2, qvec) * invDet;
    return t > 0.0f;
}


int main(int argc, char* argv[])
{
    screen = InitializeSDL(SCREEN_WIDTH, SCREEN_HEIGHT);
    t = SDL_GetTicks(); // Set start value for timer.

    LoadTestModel(triangles);

#ifdef USE_METAL
    g_metal_renderer = new MetalRenderer(SCREEN_WIDTH, SCREEN_HEIGHT);
    g_metal_renderer->uploadTriangles(triangles);
    cout << "Using Metal GPU renderer" << endl;
#endif

    while (NoQuitMessageSDL())
    {
        Update();
        Draw();
    }

    SDL_SaveBMP( screen, "screenshot.bmp" );

#ifdef USE_METAL
    delete g_metal_renderer;
#endif

    return 0;
}

void Update()
{
    // Compute frame time:
    int t2 = SDL_GetTicks();
    float dt = float(t2 - t);
    t = t2;
    cout << "Render time: " << dt << " ms." << endl;

    Uint8* keystate = SDL_GetKeyState(0);
    if (keystate[SDLK_UP])
    {
        // Move camera forward
        camera_pos.z += 0.1f;
    }
    if (keystate[SDLK_DOWN])
    {
        // Move camera backward
        camera_pos.z -= 0.1f;
    }
    if (keystate[SDLK_LEFT])
    {
        // Rotate the camera along the y axis
        yaw += 0.1f;
    }
    if (keystate[SDLK_RIGHT])
    {
        // Rotate the camera along the y axis
        yaw -= 0.1f;
    }
    if (keystate[SDLK_w])
    {
        // Move lightsource forward
        light_pos.z += 0.1f;
    }
    if (keystate[SDLK_s])
    {
        // Move lightsource backward
        light_pos.z -= 0.1f;
    }
    if (keystate[SDLK_a])
    {
        // Move lightsource left
        light_pos.x -= 0.1f;
    }
    if (keystate[SDLK_d])
    {
        // Move lightsource right
        light_pos.x += 0.1f;
    }
    if (keystate[SDLK_q])
    {
        // Move lightsource up
        light_pos.y -= 0.1f;
    }
    if (keystate[SDLK_e])
    {
        // Move lightsource down
        light_pos.y += 0.1f;
    }
}

void Draw()
{
    SDL_FillRect(screen, 0, 0);
    if (SDL_MUSTLOCK(screen))
        SDL_LockSurface(screen);

#ifdef USE_METAL
    RenderParams params;
    params.camera_pos   = camera_pos;
    params.light_pos    = light_pos;
    params.light_colour = light_colour;
    params.indirect_light = indirect_light;
    params.focal        = focal;
    params.f            = f;
    params.yaw          = yaw;
    params.screen_width  = SCREEN_WIDTH;
    params.screen_height = SCREEN_HEIGHT;

    std::vector<glm::vec3> pixels(SCREEN_WIDTH * SCREEN_HEIGHT);
    g_metal_renderer->render(params, pixels);

    for (int y = 0; y < SCREEN_HEIGHT; y++)
        for (int x = 0; x < SCREEN_WIDTH; x++)
            PutPixelSDL(screen, x, y, pixels[y * SCREEN_WIDTH + x]);
#else
    pthread_t tid[9];
    int area_id[9];

    for (int i = 0; i < 9; i++)
    {
        area_id[i] = i;
        pthread_create(&tid[i], NULL, img_thread, &area_id[i]);
    }

    for (int i = 0; i < 9; i++)
        pthread_join(tid[i], NULL);
#endif

    if (SDL_MUSTLOCK(screen))
        SDL_UnlockSurface(screen);

    SDL_UpdateRect(screen, 0, 0, 0, 0);
}


void *img_thread(void *arg)
{
    int area = *(int*)arg;
    unsigned int seed = (unsigned int)(area + 1) * 12345;

    vec3 black(0.0f, 0.0f, 0.0f);
    Intersection intersection, mirror_intersec;
    vec3 d, light_area, mirror_shadow, intersection_pos, sum_colour, pixel_colour, sub_pixel;
    mat3 R(cos(yaw), 0, sin(yaw), 0, 1, 0, -sin(yaw), 0, cos(yaw));
    float x, y, focal_x, focal_y;
    int height = 0;
    float srceen_width = SCREEN_WIDTH;
    float screen_height = SCREEN_HEIGHT;
    vec3 original_img[10][10];
    int x_value, y_value;

    switch (area)
    {
    case 0: x_value = 0;                y_value = 0;                break;
    case 1: x_value = SCREEN_WIDTH / 3; y_value = 0;                break;
    case 2: x_value = SCREEN_WIDTH / 3 * 2; y_value = 0;           break;
    case 3: x_value = 0;                y_value = SCREEN_HEIGHT / 3; break;
    case 4: x_value = SCREEN_WIDTH / 3; y_value = SCREEN_HEIGHT / 3; break;
    case 5: x_value = SCREEN_WIDTH / 3 * 2; y_value = SCREEN_HEIGHT / 3; break;
    case 6: x_value = 0;                y_value = SCREEN_HEIGHT / 3 * 2; break;
    case 7: x_value = SCREEN_WIDTH / 3; y_value = SCREEN_HEIGHT / 3 * 2; break;
    case 8: x_value = SCREEN_WIDTH / 3 * 2; y_value = SCREEN_HEIGHT / 3 * 2; break;
    default:
        printf("ERROR!\n");
        break;
    }

    for (int i = 0; i < SCREEN_HEIGHT / 3; i++)
    {
        for (int j = 0; j < SCREEN_WIDTH / 3; j++)
        {
            x = j + x_value;
            y = i + y_value;

            focal_x = (-0.5 + 0.5 / srceen_width + x * 1.0 / srceen_width) * (focal - camera_pos[2]) / f;
            focal_y = (-0.5 + 0.5 / screen_height + y * 1.0 / screen_height) * (focal - camera_pos[2]) / f;
            height = 0;

            for (int a = -8; a < 9; a = a + 8)
            {
                int width = 0;
                for (int b = -8; b < 9; b = b + 8)
                {
                    float x_ = b - b / 2 + b / 2 * (rand_r(&seed) / float(RAND_MAX));
                    float y_ = a - a / 2 + a / 2 * (rand_r(&seed) / float(RAND_MAX));
                    sub_pixel = vec3 ((-0.5 + 0.5 / srceen_width + (x + x_) * 1.0 / srceen_width), (-0.5 + 0.5 / screen_height + (y + y_) * 1.0 / screen_height), -2.0f);
                    d = vec3(focal_x - sub_pixel[0], focal_y - sub_pixel[1], focal - sub_pixel[2]);
                    d = R * d;

                    if (closest_intersection(sub_pixel, d, triangles, intersection, mirror_intersec, 0))
                    {
                        light_area = direct_light(intersection, seed);
                        if (intersection.is_mirror)
                        {
                            mirror_shadow = direct_light(mirror_intersec, seed);
                            light_area = 0.5f * (indirect_light + (light_area + mirror_shadow) / 2.0f);
                        }
                        else
                        {
                            light_area = 0.5f * (indirect_light + light_area);
                        }
                        pixel_colour = light_area * intersection.colour;

                        original_img[width][height] = pixel_colour;
                    }
                    else
                        original_img[width][height] = black;

                    anti_aliasing[j][i][area] = anti_aliasing[j][i][area] + original_img[width][height];
                    width++;
                }
                height++;
            }

            anti_aliasing[j][i][area] = anti_aliasing[j][i][area] / vec3(9.0f, 9.0f, 9.0f);


            PutPixelSDL(screen, x, y, anti_aliasing[j][i][area]);
            anti_aliasing[j][i][area] = black;
        }
    }
    return NULL;
}

bool closest_intersection(const vec3& start, const vec3& dir, const vector<Triangle>& triangles, Intersection& cloestIntersection, Intersection& mirIntersection, int light)
{

    bool flag = false;
    float min = 0.0;
    int triangle_index, ignore = 1;
    vec3 v0, v1, v2;
    vec3 reflect_position, reflect_dir;
    Intersection reflect_intersec;

    float t_front, u_front, v_front;
    if (RayTriangleIntersection(start, dir, FRONT_V0, FRONT_V1, FRONT_V2, t_front, u_front, v_front))
        ignore = 0;

    for (size_t i = 0; i < triangles.size(); i++)
    {
        v0 = triangles[i].v0;
        v1 = triangles[i].v1;
        v2 = triangles[i].v2;

        if (ignore == 1 && light == 0)
        {
            if (i <= 9)
            {
                float t_hit, u_hit, v_hit;
                if (RayTriangleIntersection(start, dir, v0, v1, v2, t_hit, u_hit, v_hit) && t_hit > 0.03f)
                {
                    if (!flag)
                    {
                        min = t_hit;
                        triangle_index = i;
                    }
                    flag = true;
                    if (min > t_hit)
                    {
                        min = t_hit;
                        triangle_index = i;
                    }
                }
            }
        }
        else if (ignore == 0 || light == 1)
        {
            float t_hit, u_hit, v_hit;
            if (RayTriangleIntersection(start, dir, v0, v1, v2, t_hit, u_hit, v_hit) && t_hit > 0.03f)
            {
                if (!flag)
                {
                    min = t_hit;
                    triangle_index = i;
                }
                flag = true;
                if (min > t_hit)
                {
                    min = t_hit;
                    triangle_index = i;
                }
            }
        }
    }

    if (flag)
    {
        cloestIntersection.position = start + min * dir;
        cloestIntersection.distance = min;
        cloestIntersection.triangle_index = triangle_index;
        if (triangle_index == 4 || triangle_index == 5)
        {
            reflect_position = start + min * dir;
            reflect_dir = vec3(-dir[0], dir[1], dir[2]);
            if (mirror_intersection(reflect_position, reflect_dir, triangles, reflect_intersec))
            {
                cloestIntersection.colour = reflect_intersec.colour;

                mirIntersection.triangle_index = reflect_intersec.triangle_index;
                mirIntersection.position = reflect_intersec.position;
                mirIntersection.distance = reflect_intersec.distance;
            }
            cloestIntersection.is_mirror = true;
        }
        else
        {
            mirIntersection.triangle_index = triangle_index;
            mirIntersection.position = start + min * dir;
            mirIntersection.distance = min;
            cloestIntersection.colour = triangles[triangle_index].color;
            cloestIntersection.is_mirror = false;
        }
        return true;
    }
    else
        return false;
}

vec3 direct_light(const Intersection &point, unsigned int& seed)
{
    vec3 surface_light, dis, light_area, shadow_colour;
    float r;
    Intersection inter, shadow_inter, mirIntersection;

    surface_light = light_pos - point.position;
    r = glm::length(surface_light);
    float result = surface_light[0] * triangles[point.triangle_index].normal[0] + surface_light[1] * triangles[point.triangle_index].normal[1] + surface_light[2] * triangles[point.triangle_index].normal[2];
    float area_divisor = 4.0 * 3.1415926 * r * r;
    if (result > 0.0)
        light_area = result / area_divisor * light_colour;
    else
        light_area = vec3(0.0, 0.0, 0.0);

    if (light_pos[1] < -0.20f)
    {
        if (point.position[1] >= -0.20f)
        {
            if (closest_intersection(point.position, surface_light, triangles, inter, mirIntersection, 1))
            {
                dis = inter.position - point.position;
                if (r > glm::length(dis) && result > 0.0 && point.triangle_index != inter.triangle_index)
                {
                    light_area = vec3(0.0, 0.0, 0.0);
                    for (int i = 0; i < 10; i++)
                    {
                        vec3 direction = surface_light + vec3(0.03f * (((rand_r(&seed) / float(RAND_MAX)) - 0.5f) * 2.0f), 0.03f * (((rand_r(&seed) / float(RAND_MAX)) - 0.5f) * 2.0f), 0.03f * (((rand_r(&seed) / float(RAND_MAX)) - 0.5f) * 2.0f));
                        if (shadow_intersection(point.position, direction, inter.triangle_index, shadow_inter))
                            shadow_colour = vec3(0.0, 0.0, 0.0);
                        else
                            shadow_colour = triangles[point.triangle_index].color;

                        light_area = light_area + shadow_colour;
                    }
                    light_area = light_area / vec3(10.0f, 10.0f, 10.0f);
                }
            }
        }
    }
    else
    {
        if (closest_intersection(point.position, surface_light, triangles, inter, mirIntersection, 1))
        {
            dis = inter.position - point.position;
            if (r > glm::length(dis) && result > 0.0 && point.triangle_index != inter.triangle_index)
            {
                light_area = vec3(0.0, 0.0, 0.0);
                for (int i = 0; i < 10; i++)
                {
                    vec3 direction = surface_light + vec3(0.03f * (((rand_r(&seed) / float(RAND_MAX)) - 0.5f) * 2.0f), 0.03f * (((rand_r(&seed) / float(RAND_MAX)) - 0.5f) * 2.0f), 0.03f * (((rand_r(&seed) / float(RAND_MAX)) - 0.5f) * 2.0f));
                    if (shadow_intersection(point.position, direction, inter.triangle_index, shadow_inter))
                        shadow_colour = vec3(0.0, 0.0, 0.0);
                    else
                        shadow_colour = triangles[point.triangle_index].color;

                    light_area = light_area + shadow_colour;
                }
                light_area = light_area / vec3(10.0f, 10.0f, 10.0f);
            }
        }
    }

    return light_area;
}

bool shadow_intersection(const vec3& start, const vec3& dir, int triangle_id, Intersection& cloestIntersection)
{
    bool flag = false;
    float t_hit, u_hit, v_hit;

    int i_start = std::max(0, triangle_id - 2);
    int i_end = std::min((int)triangles.size(), triangle_id + 3);

    for (int i = i_start; i < i_end; i++)
    {
        vec3 v0 = triangles[i].v0;
        vec3 v1 = triangles[i].v1;
        vec3 v2 = triangles[i].v2;

        if (RayTriangleIntersection(start, dir, v0, v1, v2, t_hit, u_hit, v_hit) && t_hit > 0.0f)
        {
            flag = true;
            break;
        }
    }

    if (flag)
        return true;
    else
        return false;
}

bool mirror_intersection(const vec3& start, const vec3& dir, const vector<Triangle>& triangles, Intersection& cloestIntersection)
{
    bool flag = false;
    float min = 0.0;
    int triangle_index;
    vec3 v0, v1, v2;

    for (size_t i = 0; i < triangles.size(); i++)
    {
        v0 = triangles[i].v0;
        v1 = triangles[i].v1;
        v2 = triangles[i].v2;

        float t_hit, u_hit, v_hit;
        if (RayTriangleIntersection(start, dir, v0, v1, v2, t_hit, u_hit, v_hit) && t_hit > 0.03f)
        {
            if (!flag)
            {
                min = t_hit;
                triangle_index = i;
            }
            flag = true;
            if (min > t_hit)
            {
                min = t_hit;
                triangle_index = i;
            }
        }
    }

    if (flag)
    {
        cloestIntersection.position = start + min * dir;
        cloestIntersection.distance = min;
        cloestIntersection.triangle_index = triangle_index;
        cloestIntersection.colour = triangles[triangle_index].color;
        return true;
    }
    else
        return false;
}
