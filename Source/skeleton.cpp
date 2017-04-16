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
// vector<vec3> stars(1000);
// vector<float> x_direction(1000);
// vector<float> y_direction(1000);
// vector<float> z_direction(1000);
//vec3 color(1.0, 1.0, 1.0);
float f = 1.0;
float zz = 3.0;
vec3 s(0, 0, -zz);

std::vector<Triangle> triangles;
struct Intersection {
    vec3 position;
    float distance;
    int triangleIndex;
};

/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */

void Update();
void Draw();
vec3 intersection_point(Triangle triangle, vec3 d, vec3 s);
bool ClosestIntersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection);
// void Interpolate( vec3 a, vec3 b, vector<vec3>& result );

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
        //i++;
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

}

void Draw()
{
    SDL_FillRect(screen, 0, 0);
    if (SDL_MUSTLOCK(screen))
        SDL_LockSurface(screen);

    LoadTestModel(triangles);
    Intersection intersection;
    vec3 d;
    for (int i = 0; i < SCREEN_HEIGHT; i++)
    {
        for (int j = 0; j < SCREEN_WIDTH; j++)
        {
            //vec3 d(j - SCREEN_WIDTH / 2, i - SCREEN_HEIGHT / 2, f);
            d = vec3(-0.5 + j * 1 / SCREEN_WIDTH, -0.5 + i * 1 / SCREEN_HEIGHT, f);
            // for (int num; num < triangles.size(); num++)
            // {
            //     intersection_point(triangles[num], d, s);
            // }
            ClosestIntersection(s, d, triangles, intersection);
            //vec3 color( 1.0, 0.0, 0.0 );
            PutPixelSDL( screen, j, i, triangles[intersection.triangleIndex].color);
            // float m = std::numeric_limits<float>::max();
            // printf("%f\n", m);

        }
    }

    if (SDL_MUSTLOCK(screen))
        SDL_UnlockSurface(screen);

    SDL_UpdateRect(screen, 0, 0, 0, 0);
}

// vec3 intersection_point(Triangle triangle, vec3 d, vec3 s)
// {
//     vec3 v0 = triangle.v0;
//     vec3 v1 = triangle.v1;
//     vec3 v2 = triangle.v2;
//     vec3 e1 = v1 - v0;
//     vec3 e2 = v2 - v0;
//     vec3 b = s - v0;
//     mat3 A( -d, e1, e2 );
//     vec3 x = glm::inverse(A) * b;
//     return x;
// }

bool ClosestIntersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection)
{
    bool flag = false;
    float min = 0.0;
    int triangleIndex;
    vec3 v0, v1, v2, e1, e2, b, x;
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
        //printf("a\n");
        x = glm::inverse(A) * b;
        printf("%f %f %f\n", x[0], x[1], x[2]);
        if (x[1] > 0 && x[2] > 0 && (x[1] + x[2]) < 1 && x[0] > 0) {
            printf("c\n");
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

    cloestIntersection.position = dir;
    cloestIntersection.distance = min;
    cloestIntersection.triangleIndex = triangleIndex;
    return true;
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
