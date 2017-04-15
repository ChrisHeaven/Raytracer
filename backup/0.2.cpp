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

/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */

void Update();
void Draw();
void Interpolate( vec3 a, vec3 b, vector<vec3>& result );

int main( int argc, char* argv[] )
{
    screen = InitializeSDL( SCREEN_WIDTH, SCREEN_HEIGHT );
    t = SDL_GetTicks(); // Set start value for timer.

    for ( size_t s = 0; s < stars.size(); s++ )
    {
        float x = (2 * float(rand()) / float(RAND_MAX)) - 1;
        float y = (2 * float(rand()) / float(RAND_MAX)) - 1;
        float z = float(rand()) / float(RAND_MAX);
        while (!z)
        {
            z = float(rand()) / float(RAND_MAX);
        }
        //cout << x << endl;
        //float u = x / z * f;
        //float v = y / z * f;
        stars[s].x = x;
        stars[s].y = y;
        stars[s].z = z;
        //cout << stars[0].x << endl;
    }
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

    for ( size_t s = 0; s < stars.size(); s++ )
    {
        //cout << stars[0].x << endl;
        stars[s].x = stars[s].x;
        stars[s].y = stars[s].y;
        stars[s].z = stars[s].z - 0.001 * dt;

        if ( stars[s].z <= 0 )
            stars[s].z += 1;
        if ( stars[s].z > 1 )
            stars[s].z -= 1;

        float u = stars[s].x / stars[s].z * f + SCREEN_WIDTH / 2;
        float v = stars[s].y / stars[s].z * f + SCREEN_HEIGHT / 2;
        x_direction[s] = u;
        y_direction[s] = v;
        //cout << stars[s].z << endl;
    }
}

void Draw()
{
    SDL_FillRect( screen, 0, 0 );
    if ( SDL_MUSTLOCK(screen) )
        SDL_LockSurface(screen);

    for ( size_t s = 0; s < stars.size(); s++ )
    {
        vec3 color = 0.3f * vec3(1.0, 1.0, 1.0) / (stars[s].z * stars[s].z);
        PutPixelSDL( screen, x_direction[s], y_direction[s], color );
    }

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