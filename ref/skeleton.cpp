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
const vec3 startpoint(SCREEN_WIDTH / 2 , SCREEN_HEIGHT / 2, SCREEN_HEIGHT / 2);
struct Intersection {
	vec3 position;
	float distance;
	int triangleIndex;
};
SDL_Surface* screen;
int t;

/* ----------------------------------------------------------------------------*/
/* FUNCTIONS                                                                   */

void Update();
void Draw();
bool ClosestIntersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection);

int main( int argc, char* argv[] )
{
	screen = InitializeSDL( SCREEN_WIDTH, SCREEN_HEIGHT );
	t = SDL_GetTicks();	// Set start value for timer.

	while ( NoQuitMessageSDL() )
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
}

void Draw()
{
	vector<Triangle> triangles;
	LoadTestModel(triangles);
	Intersection intersection;
	if ( SDL_MUSTLOCK(screen) )
		SDL_LockSurface(screen);

	for ( int y = 0; y < SCREEN_HEIGHT; ++y )
	{
		for ( int x = 0; x < SCREEN_WIDTH; ++x )
		{
			vec3 d(x - startpoint[0], y - startpoint[1], startpoint[2]);
			ClosestIntersection(startpoint, d, triangles, intersection);
			vec3 color( 1.0, 0.0, 0.0 );
			PutPixelSDL( screen, x, y, triangles[intersection.triangleIndex].color);
		}
	}
	// for(int i = 0; i < triangles.size(); ++i){
	// 	vector<vec3> vertices(3);

	// 	vertices[0] = triangles[i].v0;
	// 	vertices[1] = triangles[i].v1;
	// 	vertices[2] = triangles[i].v2;

	// 	for(int v = 0; v < 3; ++v){
	// 		glm::ivec2 projPos;
	// 		VertexShader(vertices[v], projPos);
	// 		vec3 color(1,1,1);
	// 		PutPixelSDL(screen, projPos.x, projPos.y, color);
	// 	}
	// }

	if ( SDL_MUSTLOCK(screen) )
		SDL_UnlockSurface(screen);

	SDL_UpdateRect( screen, 0, 0, 0, 0 );
}


bool ClosestIntersection(vec3 start, vec3 dir, const vector<Triangle>& triangles, Intersection& cloestIntersection) {
	bool flag = false;
	float min = 0.0;
	int triangleIndex;
	for (int i = 0; i < triangles.size(); i++) {
		vec3 v0 = triangles[i].v0;
		vec3 v1 = triangles[i].v1;
		vec3 v2 = triangles[i].v2;

		vec3 e1 = v1 - v0;
		vec3 e2 = v2 - v0;
		vec3 b = start - v0;

		mat3 A(-dir, e1, e2);
		vec3 x = glm::inverse(A) * b;

		if (x[1] > 0 && x[2] > 0 && (x[1] + x[2]) < 1 && x[0] > 0) {
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
}