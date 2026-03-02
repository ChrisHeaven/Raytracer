// Minimal SDL snake in this repo (refactored for readability)

#include <SDL/SDL.h>
#include <deque>
#include <cstdlib>
#include <ctime>

#include <glm/glm.hpp>

#include "SDLauxiliary.h"

using glm::vec3;

// Grid configuration
constexpr int kGridWidth  = 25;
constexpr int kGridHeight = 25;
constexpr int kCellSize   = 15;

// Game state
SDL_Surface* screen = nullptr;

using Cell = std::pair<int, int>;

std::deque<Cell> snake;
Cell food;

int directionX = 1;
int directionY = 0;
bool isAlive   = true;

void SpawnFood()
{
    food = Cell(rand() % kGridWidth, rand() % kGridHeight);
}

void DrawCell(int gridX, int gridY, const vec3& color)
{
    const int baseX = gridX * kCellSize;
    const int baseY = gridY * kCellSize;

    for (int dx = 0; dx < kCellSize; ++dx)
    {
        for (int dy = 0; dy < kCellSize; ++dy)
        {
            PutPixelSDL(screen, baseX + dx, baseY + dy, color);
        }
    }
}

void UpdateSnake()
{
    Cell head = snake.front();
    head.first  += directionX;
    head.second += directionY;

    const bool hitWall =
        head.first < 0 || head.first >= kGridWidth ||
        head.second < 0 || head.second >= kGridHeight;

    if (hitWall)
    {
        isAlive = false;
        return;
    }

    // Self-collision
    for (const Cell& segment : snake)
    {
        if (segment == head)
        {
            isAlive = false;
            return;
        }
    }

    snake.push_front(head);

    if (head == food)
    {
        SpawnFood();
    }
    else
    {
        snake.pop_back();
    }
}

void HandleInput()
{
    SDL_Event event;

    while (SDL_PollEvent(&event))
    {
        if (event.type == SDL_QUIT)
        {
            isAlive = false;
            continue;
        }

        if (event.type != SDL_KEYDOWN)
        {
            continue;
        }

        SDLKey key = event.key.keysym.sym;

        if (key == SDLK_ESCAPE)
        {
            isAlive = false;
        }
        else if (key == SDLK_UP && directionY == 0)
        {
            directionX = 0;
            directionY = -1;
        }
        else if (key == SDLK_DOWN && directionY == 0)
        {
            directionX = 0;
            directionY = 1;
        }
        else if (key == SDLK_LEFT && directionX == 0)
        {
            directionX = -1;
            directionY = 0;
        }
        else if (key == SDLK_RIGHT && directionX == 0)
        {
            directionX = 1;
            directionY = 0;
        }
    }
}

void Render()
{
    SDL_FillRect(screen, nullptr, 0);

    if (SDL_MUSTLOCK(screen))
    {
        SDL_LockSurface(screen);
    }

    // Draw snake body (green)
    for (const Cell& segment : snake)
    {
        DrawCell(segment.first, segment.second, vec3(0.0f, 1.0f, 0.0f));
    }

    // Draw food (red)
    DrawCell(food.first, food.second, vec3(1.0f, 0.0f, 0.0f));

    if (SDL_MUSTLOCK(screen))
    {
        SDL_UnlockSurface(screen);
    }

    SDL_UpdateRect(screen, 0, 0, 0, 0);
}

int main(int /*argc*/, char** /*argv*/)
{
    srand(static_cast<unsigned int>(time(nullptr)));

    screen = InitializeSDL(kGridWidth * kCellSize, kGridHeight * kCellSize);

    snake.clear();
    snake.push_back(Cell(kGridWidth / 2, kGridHeight / 2));

    SpawnFood();

    Uint32 lastUpdateTime = SDL_GetTicks();

    while (isAlive)
    {
        HandleInput();

        Uint32 now = SDL_GetTicks();
        if (now - lastUpdateTime > 120)
        {
            UpdateSnake();
            lastUpdateTime = now;
        }

        Render();
        SDL_Delay(10);
    }

    return 0;
}

