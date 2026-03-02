// Minimal SDL snake in this repo (refactored for readability)

#include <SDL/SDL.h>
#include <deque>
#include <cstdlib>
#include <ctime>

#include <glm/glm.hpp>

#include "SDLauxiliary.h"

using glm::vec3;

// Grid configuration
constexpr int kGridWidth  = 20;
constexpr int kGridHeight = 20;
constexpr int kCellSize   = 15;

// Game state
SDL_Surface* screen = nullptr;

using Cell = std::pair<int, int>;

std::deque<Cell> snake;
Cell food;

// Occupancy grid to accelerate collision checks
bool occupied[kGridHeight][kGridWidth];

int directionX = 1;
int directionY = 0;
bool isAlive   = true;

void SpawnFood()
{
    int x, y;

    // Ensure food never spawns on the snake body
    do
    {
        x = rand() % kGridWidth;
        y = rand() % kGridHeight;
    }
    while (occupied[y][x]);

    food = Cell(x, y);
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
    const Cell& head = snake.front();
    const int newX   = head.first  + directionX;
    const int newY   = head.second + directionY;

    const bool hitWall =
        newX < 0 || newX >= kGridWidth ||
        newY < 0 || newY >= kGridHeight;

    if (hitWall)
    {
        isAlive = false;
        return;
    }

    const bool willGrow = (newX == food.first && newY == food.second);

    // If we're not growing, free the tail cell so moving into the old tail
    // position is allowed in the same step.
    if (!willGrow)
    {
        const Cell& tail = snake.back();
        occupied[tail.second][tail.first] = false;
        snake.pop_back();
    }

    // Self-collision check using occupancy grid (O(1))
    if (occupied[newY][newX])
    {
        isAlive = false;
        return;
    }

    const Cell newHead(newX, newY);
    snake.push_front(newHead);
    occupied[newY][newX] = true;

    if (willGrow)
    {
        SpawnFood();
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

    // Reset occupancy grid
    for (int y = 0; y < kGridHeight; ++y)
    {
        for (int x = 0; x < kGridWidth; ++x)
        {
            occupied[y][x] = false;
        }
    }

    snake.push_back(Cell(kGridWidth / 2, kGridHeight / 2));
    occupied[snake.front().second][snake.front().first] = true;

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

