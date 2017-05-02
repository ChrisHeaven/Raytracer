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

#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>

using namespace std;
using glm::vec3;
using glm::mat3;

/* ----------------------------------------------------------------------------*/
/* GLOBAL VARIABLES                                                            */
const int SCREEN_WIDTH = 400;
const int SCREEN_HEIGHT = 400;
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
static vec3 anti_aliasing[SCREEN_WIDTH / 2][SCREEN_HEIGHT / 2][4];
std::vector<Triangle> triangles;
static vec3 map[101][101][101];

struct Intersection
{
    vec3 position;
    float distance;
    int triangle_index;
    vec3 colour;
};
std::vector<Intersection> shadowIntersection;


/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */

void Update();
void Draw();
bool closest_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection, int light);
bool shadow_intersection(vec3 start, vec3 dir, int triangle_index, Intersection& cloestIntersection);
bool mirror_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection);
vec3 direct_light(const Intersection& intersection_point);
void* img_thread(void *arg);
int round_double(float number);



int main(int argc, char* argv[])
{
    screen = InitializeSDL(SCREEN_WIDTH, SCREEN_HEIGHT);
    t = SDL_GetTicks(); // Set start value for timer.
    // memset(map, -1.0f, sizeof(map));
    // printf("%f\n", map[10][10][10][0]);

    while (NoQuitMessageSDL())
    {
        for (int i = 0; i < 101; i++)
        {
            for (int j = 0; j < 101; j++)
            {
                for (int k = 0; k < 101; k++)
                {
                    map[i][j][k] = vec3(-1.0f, -1.0f, -1.0f);
                }
            }
        }

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
    SDL_FillRect(screen, 0, 0);
    if (SDL_MUSTLOCK(screen))
        SDL_LockSurface(screen);

    LoadTestModel(triangles);

    pthread_t tid[4];
    int area_id[4];

    for (int i = 0; i < 4; i++)
    {
        area_id[i] = i;
        pthread_create(&tid[i], NULL, img_thread, &area_id[i]);
    }

    for (int i = 0; i < 4; i++)
        pthread_join(tid[i], NULL);

    if (SDL_MUSTLOCK(screen))
        SDL_UnlockSurface(screen);

    SDL_UpdateRect(screen, 0, 0, 0, 0);
}


void *img_thread(void *arg)
{
    int area = *(int*)arg;

    vec3 black(0.0f, 0.0f, 0.0f);
    Intersection intersection, mirror_intersec;
    vec3 d, light_area, intersection_pos, sum_colour, pixel_colour, sub_pixel;
    mat3 R(cos(yaw), 0, sin(yaw), 0, 1, 0, -sin(yaw), 0, cos(yaw));
    float x, y, focal_x, focal_y;
    int height = 0;
    float srceen_width = SCREEN_WIDTH;
    float screen_height = SCREEN_HEIGHT;
    vec3 original_img[10][10];
    int x_value, y_value;

    switch (area)
    {
    case 0:
        x_value = 0;
        y_value = 0;
        break;

    case 1:
        x_value = SCREEN_WIDTH / 2;
        y_value = 0;
        break;

    case 2:
        x_value = 0;
        y_value = SCREEN_HEIGHT / 2;
        break;

    case 3:
        x_value = SCREEN_WIDTH / 2;
        y_value = SCREEN_HEIGHT / 2;
        break;

    default:
        printf("ERROR!\n");
        break;
    }

    for (int i = 0; i < SCREEN_HEIGHT / 2; i++)
    {
        for (int j = 0; j < SCREEN_WIDTH / 2; j++)
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
                    float x_ = b - b / 2 + b / 2 * (rand() / float(RAND_MAX));
                    float y_ = a - a / 2 + a / 2 * (rand() / float(RAND_MAX));
                    sub_pixel = vec3 ((-0.5 + 0.5 / srceen_width + (x + x_) * 1.0 / srceen_width), (-0.5 + 0.5 / screen_height + (y + y_) * 1.0 / screen_height), -2.0f);
                    d = vec3(focal_x - sub_pixel[0], focal_y - sub_pixel[1], focal - sub_pixel[2]);
                    d = R * d;

                    if (closest_intersection(sub_pixel, d, triangles, intersection, 0))
                    {
                        // intersection_pos = camera_pos + intersection.distance * d;
                        light_area = direct_light(intersection);
                        light_area = 0.5f * (indirect_light + light_area);
                        // pixel_colour = light_area * triangles[intersection.triangle_index].color;
                        pixel_colour = light_area * intersection.colour;

                        original_img[width][height] = pixel_colour;
                    }
                    else
                        original_img[width][height] = black;

                    anti_aliasing[j][i][area] = anti_aliasing[j][i][area] + original_img[width][height];
                    // if (area >= 2)
                    // {
                    //     mirror_intersection(sub_pixel, d, triangles, mirror_intersec);

                    // }
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

bool closest_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection, int light)
{
    // printf("aaa\n");
    bool flag = false;
    float min = 0.0;
    int triangle_index, ignore = 1;
    vec3 v0, v1, v2, e1, e2, b, x, intersection_pos, e1_, e2_, b_;
    vec3 reflect_position, reflect_dir;
    mat3 A;
    vec3 front_triangle_v0, front_triangle_v1, front_triangle_v2;
    front_triangle_v0 = vec3(-0.76f, -0.87f, -1.0f);
    front_triangle_v1 = vec3(-0.76f, 1.0f, -1.0f);
    front_triangle_v2 = vec3(1.31f, 1.0f, -1.0f);
    Intersection reflect_intersec;

    e1_ = front_triangle_v1 - front_triangle_v0;
    e2_ = front_triangle_v2 - front_triangle_v0;
    b_ = start - front_triangle_v0;
    A = mat3(-dir, e1_, e2_);
    x = glm::inverse(A) * b_;
    if (x[1] >= 0 && x[2] >= 0 && (x[1] + x[2]) <= 1 && x[0] > 0)
        ignore = 0;

    for (size_t i = 0; i < triangles.size(); i++)
    {
        v0 = triangles[i].v0;
        v1 = triangles[i].v1;
        v2 = triangles[i].v2;

        e1 = v1 - v0;
        e2 = v2 - v0;
        b = start - v0;

        if (ignore == 1 && light == 0)
        {
            if (i <= 9)
            {
                A = mat3(-dir, e1, e2);
                x = glm::inverse(A) * b;
                if (x[1] >= 0 && x[2] >= 0 && (x[1] + x[2]) <= 1 && x[0] > 0.03f)
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

                    if (i == 4 || i == 5)
                    {
                        reflect_position = start + min * dir;
                        reflect_dir = vec3(-dir[0], dir[1], dir[2]);
                        if (mirror_intersection(reflect_position, reflect_dir, triangles, reflect_intersec))
                        {
                            // triangle_index = reflect_intersec.triangle_index;
                            // cloestIntersection.position = reflect_intersec.position;
                            cloestIntersection.colour = reflect_intersec.colour;
                            min = x[0];
                        }
                    }
                }
            }
        }
        else if (ignore == 0 || light == 1)
        {
            A = mat3(-dir, e1, e2);
            x = glm::inverse(A) * b;
            if (x[1] >= 0 && x[2] >= 0 && (x[1] + x[2]) <= 1 && x[0] > 0.03f)
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

                if (i == 4 || i == 5)
                {
                    reflect_position = start + min * dir;
                    reflect_dir = vec3(-dir[0], dir[1], dir[2]);
                    if (mirror_intersection(reflect_position, reflect_dir, triangles, reflect_intersec))
                    {
                        // triangle_index = reflect_intersec.triangle_index;
                        // cloestIntersection.position = reflect_intersec.position;
                        cloestIntersection.colour = reflect_intersec.colour;
                        // printf("%f\n", cloestIntersection.colour[0]);
                        min = x[0];
                    }
                }
            }
        }
    }

    if (flag)
    {
        cloestIntersection.position = start + min * dir;
        cloestIntersection.distance = min;
        cloestIntersection.triangle_index = triangle_index;
        if (triangle_index != 4 && triangle_index != 5)
            cloestIntersection.colour = triangles[triangle_index].color;
        return true;
    }
    else
        return false;
}

vec3 direct_light(const Intersection &point)
{
    vec3 surface_light, dis, light_area, shadow_colour;
    float r;
    Intersection inter, shadow_inter;

    surface_light = light_pos - point.position;
    r = glm::length(surface_light);
    float result = surface_light[0] * triangles[point.triangle_index].normal[0] + surface_light[1] * triangles[point.triangle_index].normal[1] + surface_light[2] * triangles[point.triangle_index].normal[2];
    float camera_pos = 4.0 * 3.1415926 * r * r;
    if (result > 0.0)
        light_area = result / camera_pos * light_colour;
    else
        light_area = vec3(0.0, 0.0, 0.0);

    if (closest_intersection(point.position, surface_light, triangles, inter, 1))
    {
        dis = inter.position - point.position;
        if (r > glm::length(dis) && result > 0.0 && point.triangle_index != inter.triangle_index)
        {
            light_area = vec3(0.0, 0.0, 0.0);
            for (int i = 0; i < 10; i++)
            {
                vec3 direction = surface_light + vec3(0.03f * (((rand() / float(RAND_MAX)) - 0.5f) * 2.0f), 0.03f * (((rand() / float(RAND_MAX)) - 0.5f) * 2.0f), 0.03f * (((rand() / float(RAND_MAX)) - 0.5f) * 2.0f));
                if (shadow_intersection(point.position, direction, inter.triangle_index, shadow_inter))
                    shadow_colour = vec3(0.0, 0.0, 0.0);
                else
                    shadow_colour = triangles[point.triangle_index].color;
                // shadow_colour = vec3(1.0f, 1.0f, 1.0f);

                light_area = light_area + shadow_colour;
            }
            light_area = light_area / vec3(10.0f, 10.0f, 10.0f);
            // printf("Assign value to map\n");
            map[round_double(point.position[0])]
            [round_double(point.position[1])]
            [round_double(point.position[2])] = light_area;
        }
    }

    return light_area;
}

int round_double(float number)
{
    // printf("original %f\n", number);
    number = ((number  + 1.0f) * 100.0f / 2.0f);
    number = floor(number + 0.5);
    // printf("final %f\n", number);
    return number;
}

bool shadow_intersection(vec3 start, vec3 dir, int triangle_id, Intersection& cloestIntersection)
{
    bool flag = false;
    vec3 v0, v1, v2, e1, e2, b, x, intersection_pos, e1_, e2_, b_;
    mat3 A;

    for (int i = triangle_id - 2; i < triangle_id + 3; i++)
    {
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
            flag = true;
            break;
        }
    }

    if (flag)
        return true;
    else
        return false;
}

bool mirror_intersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection)
{
    bool flag = false;
    float min = 0.0;
    int triangle_index;
    vec3 v0, v1, v2, e1, e2, b, x, intersection_pos, e1_, e2_, b_, shadow_colour;
    mat3 A;

    for (size_t i = 0; i < triangles.size(); i++)
    {
        v0 = triangles[i].v0;
        v1 = triangles[i].v1;
        v2 = triangles[i].v2;

        e1 = v1 - v0;
        e2 = v2 - v0;
        b = start - v0;

        A = mat3(-dir, e1, e2);
        x = glm::inverse(A) * b;
        if (x[1] >= 0 && x[2] >= 0 && (x[1] + x[2]) <= 1 && x[0] > 0.03f)
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

    cloestIntersection.position = start + min * dir;

    if (map[round_double(cloestIntersection.position[0])]
            [round_double(cloestIntersection.position[1])]
            [round_double(cloestIntersection.position[2])][0] != -1.0f)
    {
        shadow_colour = map[round_double(cloestIntersection.position[0])]
                        [round_double(cloestIntersection.position[1])]
                        [round_double(cloestIntersection.position[2])];
        // printf("%f\n", shadow_colour[0]);
    }

    if (flag)
    {
        cloestIntersection.position = start + min * dir;
        cloestIntersection.distance = min;
        cloestIntersection.triangle_index = triangle_index;
        if (map[round_double(cloestIntersection.position[0])]
                [round_double(cloestIntersection.position[1])]
                [round_double(cloestIntersection.position[2])][0] == -1.0f)
            cloestIntersection.colour = triangles[triangle_index].color;
        else
            cloestIntersection.colour = triangles[triangle_index].color * 0.5f * (indirect_light + shadow_colour);
        return true;
    }
    else
        return false;
}