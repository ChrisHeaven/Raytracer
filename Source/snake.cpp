// Minimal SDL snake in this repo
#include <SDL/SDL.h>
#include <deque>
#include <cstdlib>
#include <ctime>
#include <glm/glm.hpp>
#include "SDLauxiliary.h"
using namespace std;using glm::vec3;
const int CW=25,CH=25,SZ=15;
SDL_Surface* screen;deque<pair<int,int>> snake;pair<int,int> food;int dx=1,dy=0;bool alive=true;
void newFood(){food={rand()%CW,rand()%CH};}
void drawCell(int x,int y,vec3 c){for(int i=0;i<SZ;i++)for(int j=0;j<SZ;j++)PutPixelSDL(screen,x*SZ+i,y*SZ+j,c);}
void step(){auto h=snake.front();h.first+=dx;h.second+=dy;if(h.first<0||h.first>=CW||h.second<0||h.second>=CH)alive=false;for(auto &p:snake)if(p==h)alive=false;snake.push_front(h);if(h==food)newFood();else snake.pop_back();}
void handleInput(){SDL_Event e;while(SDL_PollEvent(&e)){if(e.type==SDL_QUIT)alive=false;if(e.type==SDL_KEYDOWN){SDLKey k=e.key.keysym.sym;if(k==SDLK_ESCAPE)alive=false;else if(k==SDLK_UP&&dy==0){dx=0;dy=-1;}else if(k==SDLK_DOWN&&dy==0){dx=0;dy=1;}else if(k==SDLK_LEFT&&dx==0){dx=-1;dy=0;}else if(k==SDLK_RIGHT&&dx==0){dx=1;dy=0;}}}}
void draw(){SDL_FillRect(screen,0,0);if(SDL_MUSTLOCK(screen))SDL_LockSurface(screen);for(auto &p:snake)drawCell(p.first,p.second,vec3(0,1,0));drawCell(food.first,food.second,vec3(1,0,0));if(SDL_MUSTLOCK(screen))SDL_UnlockSurface(screen);SDL_UpdateRect(screen,0,0,0,0);}
int main(){srand((unsigned)time(0));screen=InitializeSDL(CW*SZ,CH*SZ);snake.push_back({CW/2,CH/2});newFood();Uint32 last=SDL_GetTicks();while(alive){handleInput();Uint32 now=SDL_GetTicks();if(now-last>120){step();last=now;}draw();SDL_Delay(10);}return 0;}

