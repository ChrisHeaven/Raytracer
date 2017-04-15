/*
1.0.cpp
Last week
Y
You uploaded an item
Jan 30
C++
1.0.cpp
No recorded activity before January 30, 2017
*/

#include <iostream>
#include <glm/glm.hpp>
#include <SDL/SDL.h>
#include "SDLauxiliary.h"
#include "TestModel.h"

using namespace std;
using glm::vec3;
using glm::mat3;

/* ----------------------------------------------------------------------------*/
/* GLOBAL VARIABLES                                                            */

const int SCREEN_WIDTH = 500;
const int SCREEN_HEIGHT = 500;
SDL_Surface* screen;
int t;
vector<vec3> stars( 1000 );
vector<float> x_direction(1000);
vector<float> y_direction(1000);
vector<float> z_direction(1000);
//vec3 color(1.0, 1.0, 1.0);
float f = SCREEN_HEIGHT / 2;

std::vector<Triangle> triangles;


/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */

void Update();
void Draw();
void Interpolate( vec3 a, vec3 b, vector<vec3>& result );

int main( int argc, char* argv[] )
{
    screen = InitializeSDL( SCREEN_WIDTH, SCREEN_HEIGHT );
    t = SDL_GetTicks(); // Set start value for timer.

    //int i = 0;
    while ( NoQuitMessageSDL() )
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
    SDL_FillRect( screen, 0, 0 );
    if ( SDL_MUSTLOCK(screen) )
        SDL_LockSurface(screen);

    LoadTestModel(triangles);

    if ( SDL_MUSTLOCK(screen) )
        SDL_UnlockSurface(screen);

    SDL_UpdateRect( screen, 0, 0, 0, 0 );
}

void Interpolate( vec3 a, vec3 b, vector<vec3>& result )
{
    for (size_t i = 0;  i < result.size(); i++)
    {
        result[i].x = (a.x + (b.x - a.x) / result.size() * i);
        result[i].y = (a.y + (b.y - a.y) / result.size() * i);
        result[i].z = (a.z + (b.z - a.z) / result.size() * i);
    }

}
