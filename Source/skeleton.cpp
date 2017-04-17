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

#define max(a,b) (((a)>(b)) ? (a):(b))

using namespace std;
using glm::vec3;
using glm::mat3;

/* ----------------------------------------------------------------------------*/
/* GLOBAL VARIABLES                                                            */

const int SCREEN_WIDTH = 300;
const int SCREEN_HEIGHT = 300;
SDL_Surface* screen;
int t;
// vector<vec3> stars(1000);
// vector<float> x_direction(1000);
// vector<float> y_direction(1000);
// vector<float> z_direction(1000);
//vec3 color(1.0, 1.0, 1.0);
float f = 1.0;
float zz = 3.0;
float yaw = 0.0f * 3.1415926 / 180;
vec3 s(0, 0, -zz);
vec3 light_pos(0, -0.5, -0.7);
vec3 light_colour = 14.f * vec3(1, 1, 1);

std::vector<Triangle> triangles;

struct Intersection
{
    vec3 position;
    float distance;
    int triangleIndex;
};

/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */

void Update();
void Draw();
vec3 intersection_point(Triangle triangle, vec3 d, vec3 s);
bool closest_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection);
vec3 direct_light(const Intersection& intersection_point);

int main(int argc, char* argv[])
{
    screen = InitializeSDL(SCREEN_WIDTH, SCREEN_HEIGHT);
    t = SDL_GetTicks(); // Set start value for timer.

    //int i = 0;
    while (NoQuitMessageSDL())
    {
        //cout << stars[10].x << endl;
        Update();
        Draw();
    }

    SDL_SaveBMP( screen, "screenshot.bmp" );
    return 0;
}

void Update()
{
    //cout << stars[2].x << endl;
    // Compute frame time:
    int t2 = SDL_GetTicks();
    float dt = float(t2 - t);
    t = t2;
    cout << "Render time: " << dt << " ms." << endl;

    Uint8* keystate = SDL_GetKeyState(0);
    if (keystate[SDLK_UP])
    {
        // Move camera forward
        s.z += 0.1f;
    }
    if (keystate[SDLK_DOWN])
    {
        // Move camera backward
        s.z -= 0.1f;
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
}

void Draw()
{
    vec3 black(0.0, 0.0, 0.0);
    SDL_FillRect(screen, 0, 0);
    if (SDL_MUSTLOCK(screen))
        SDL_LockSurface(screen);

    LoadTestModel(triangles);
    Intersection intersection;
    vec3 d;
    vec3 light_area, intersection_pos;
    mat3 R(cos(yaw), 0, sin(yaw), 0, 1, 0, -sin(yaw), 0, cos(yaw));

    for (int i = 0; i < SCREEN_HEIGHT; ++i)
    {
        for (int j = 0; j < SCREEN_WIDTH; ++j)
        {
            float x = j;
            float y = i;
            float srceen_width = SCREEN_WIDTH;
            float screen_height = SCREEN_HEIGHT;
            //vec3 d(j - SCREEN_WIDTH / 2, i - SCREEN_HEIGHT / 2, f);
            //float hhhh = -0.5 + j * 1 / SCREEN_WIDTH;
            d = vec3((-0.5 + x * 1.0 / srceen_width), (-0.5 + y * 1.0 / screen_height), f);
            d = R * d;

            if (closest_intersection(s, d, triangles, intersection))
            {
                // intersection_pos = s + intersection.distance * d;
                light_area = direct_light(intersection);
                // PutPixelSDL( screen, j, i, triangles[intersection.triangleIndex].color);
                PutPixelSDL( screen, j, i, light_area);
            }
            else
                PutPixelSDL( screen, j, i, black);

            // float m = std::numeric_limits<float>::max();
            // printf("%f\n", m);

        }
    }

    if (SDL_MUSTLOCK(screen))
        SDL_UnlockSurface(screen);

    SDL_UpdateRect(screen, 0, 0, 0, 0);
}

bool closest_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection)
{
    bool flag = false;
    float min = 0.0;
    int triangleIndex;
    vec3 v0, v1, v2, e1, e2, b, x, intersection_pos;
    mat3 A;

    for (size_t i = 0; i < triangles.size(); i++) {
        //printf("b\n");
        v0 = triangles[i].v0;
        v1 = triangles[i].v1;
        v2 = triangles[i].v2;

        e1 = v1 - v0;
        e2 = v2 - v0;
        b = start - v0;

        A = mat3(-dir, e1, e2);
        //cout << A[0][1] << endl;
        //printf("a\n");
        x = glm::inverse(A) * b;
        //printf("%f %f %f\n", x[0], x[1], x[2]);
        if (x[1] >= 0 && x[2] >= 0 && (x[1] + x[2]) <= 1 && x[0] > 0) {
            //printf("c\n");
            if (!flag) {
                min = x[0];
                triangleIndex = i;
            }
            flag = true;
            if (min > x[0]) {
                min = x[0];
                triangleIndex = i;
            }
        }
    }

    if (flag)
    {
        cloestIntersection.position = start + min * dir;
        cloestIntersection.distance = min;
        cloestIntersection.triangleIndex = triangleIndex;
        return true;
    }
    else
        return false;
}

vec3 direct_light(const Intersection& point)
{
    vec3 surface_light;
    float r;
    vec3 light_area;

    surface_light = light_pos - point.position;
    r = glm::length(surface_light);
    // r = sqrt(surface_light[0] * surface_light[0] + surface_light[1] * surface_light[1] + surface_light[2] * surface_light[2]);

    float result = surface_light[0] * triangles[point.triangleIndex].normal[0] + surface_light[1] * triangles[point.triangleIndex].normal[1] + surface_light[2] * triangles[point.triangleIndex].normal[2];
    float s = 4.0 * 3.1415926 * r * r;
    if (result > 0.0)
        light_area = result / s * light_colour;
    else
        light_area = vec3(0.0, 0.0, 0.0);

    return light_area;
}

// void Interpolate( vec3 a, vec3 b, vector<vec3>& result )
// {
//     for (size_t i = 0;  i < result.size(); i++)
//     {
//         result[i].x = (a.x + (b.x - a.x) / result.size() * i);
//         result[i].y = (a.y + (b.y - a.y) / result.size() * i);
//         result[i].z = (a.z + (b.z - a.z) / result.size() * i);
//     }

// }
