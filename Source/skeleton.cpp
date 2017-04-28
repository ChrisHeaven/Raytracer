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

using namespace std;
using glm::vec3;
using glm::mat3;

/* ----------------------------------------------------------------------------*/
/* GLOBAL VARIABLES                                                            */

const int SCREEN_WIDTH = 200;
const int SCREEN_HEIGHT = 200;
SDL_Surface* screen;
int t;
float f = 1.0;
float zz = 3.0;
float yaw = 0.0f * 3.1415926 / 180;
vec3 camera_pos(0, 0, -zz);
vec3 light_pos(0, -0.5, -0.7);
vec3 light_colour = 14.f * vec3(1, 1, 1);
vec3 indirect_light = 0.5f * vec3( 1, 1, 1 );
std::vector<Triangle> triangles;

struct Intersection
{
    vec3 position;
    float distance;
    int triangle_index;
    // int anti_aliasing[6];
};

/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */

void Update();
void Draw();
vec3 intersection_point(Triangle triangle, vec3 d, vec3 camera_pos);
bool closest_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection);
vec3 direct_light(const Intersection& intersection_point);

int main(int argc, char* argv[])
{
    screen = InitializeSDL(SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2);
    t = SDL_GetTicks(); // Set start value for timer.

    //int i = 0;
    while (NoQuitMessageSDL())
    {
        Update();
        Draw();
    }

    SDL_SaveBMP( screen, "screenshot.bmp" );
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
    vec3 black(0.0, 0.0, 0.0);
    SDL_FillRect(screen, 0, 0);
    if (SDL_MUSTLOCK(screen))
        SDL_LockSurface(screen);

    LoadTestModel(triangles);
    Intersection intersection;
    vec3 d, light_area, intersection_pos, sum_colour, pixel_colour;
    mat3 R(cos(yaw), 0, sin(yaw), 0, 1, 0, -sin(yaw), 0, cos(yaw));
    static vec3 map[SCREEN_WIDTH][SCREEN_HEIGHT];
    static vec3 anti_aliasing[SCREEN_WIDTH / 2][SCREEN_HEIGHT / 2];

    for (int i = 0; i < SCREEN_HEIGHT; i++)
    {
        for (int j = 0; j < SCREEN_WIDTH; j++)
        {
            float x = j;
            float y = i;
            float srceen_width = SCREEN_WIDTH;
            float screen_height = SCREEN_HEIGHT;

            d = vec3((-0.5 + 0.5 / srceen_width + x * 1.0 / srceen_width), (-0.5 + 0.5 / screen_height + y * 1.0 / screen_height), f);
            d = R * d;

            if (closest_intersection(camera_pos, d, triangles, intersection))
            {
                // intersection_pos = camera_pos + intersection.distance * d;
                light_area = direct_light(intersection);
                light_area = 0.5f * (indirect_light + light_area);
                pixel_colour = light_area * triangles[intersection.triangle_index].color;
                map[j][i] = pixel_colour;
                // PutPixelSDL( screen, j, i, pixel_colour);
            }
            else
                map[j][i] = black;
            // PutPixelSDL( screen, j, i, black);
        }
    }

    int height = 0;
    for (int i = 0; i < SCREEN_HEIGHT; i = i + 2)
    {
        int width = 0;
        for (int j = 0; j < SCREEN_WIDTH; j = j + 2)
        {
            anti_aliasing[width][height] = (map[j][i] + map[j + 1][i] + map[j][i + 1] + map[j + 1][i + 1]) / vec3(4.0f, 4.0f, 4.0f);
            // printf("%d\n", width);
            PutPixelSDL(screen, width, height, anti_aliasing[width][height]);
            width++;
        }
        height++;
    }

    if (SDL_MUSTLOCK(screen))
        SDL_UnlockSurface(screen);

    SDL_UpdateRect(screen, 0, 0, 0, 0);
}

bool closest_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection)
{
    bool flag = false;
    float min = 0.0;
    int triangle_index;
    vec3 v0, v1, v2, e1, e2, b, x, intersection_pos;
    mat3 A;

    for (size_t i = 0; i < triangles.size(); i++)
    {
        //printf("b\n");
        v0 = triangles[i].v0;
        v1 = triangles[i].v1;
        v2 = triangles[i].v2;

        e1 = v1 - v0;
        e2 = v2 - v0;
        b = start - v0;

        A = mat3(-dir, e1, e2);
        x = glm::inverse(A) * b;
        if (x[1] >= 0 && x[2] >= 0 && (x[1] + x[2]) <= 1 && x[0] > 0)
        {
            if (!flag)
            {
                min = x[0];
                triangle_index = i;
            }
            flag = true;
            if (min > x[0])
            {
                min = x[0];
                triangle_index = i;
            }
        }
    }

    if (flag)
    {
        cloestIntersection.position = start + min * dir;
        cloestIntersection.distance = min;
        cloestIntersection.triangle_index = triangle_index;
        return true;
    }
    else
        return false;
}

vec3 direct_light(const Intersection &point)
{
    vec3 surface_light, dis, light_area;
    float r;
    Intersection inter;

    surface_light = light_pos - point.position;
    r = glm::length(surface_light);
    float result = surface_light[0] * triangles[point.triangle_index].normal[0] + surface_light[1] * triangles[point.triangle_index].normal[1] + surface_light[2] * triangles[point.triangle_index].normal[2];
    float camera_pos = 4.0 * 3.1415926 * r * r;
    if (result > 0.0)
        light_area = result / camera_pos * light_colour;
    else
        light_area = vec3(0.0, 0.0, 0.0);

    if (closest_intersection(point.position, surface_light, triangles, inter))
    {
        dis = inter.position - point.position;
        if (r > glm::length(dis) && result > 0.0 && point.triangle_index != inter.triangle_index)
            light_area = vec3(0.0, 0.0, 0.0);
    }

    return light_area;
}