// Minimal SDL snake in this repo (refactored for readability)

#include <SDL/SDL.h>
#include <deque>
#include <cstdlib>
#include <ctime>
#include <cstring>

#include <glm/glm.hpp>

#include "SDLauxiliary.h"

using glm::vec3;

const vec3 kSnakeColor(0.0f, 1.0f, 0.0f);
const vec3 kFoodColor (1.0f, 0.0f, 0.0f);

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
    SDL_Rect rect;
    rect.x = gridX * kCellSize;
    rect.y = gridY * kCellSize;
    rect.w = kCellSize;
    rect.h = kCellSize;

    const float rClamped = glm::clamp(color.r, 0.0f, 1.0f);
    const float gClamped = glm::clamp(color.g, 0.0f, 1.0f);
    const float bClamped = glm::clamp(color.b, 0.0f, 1.0f);

    const Uint8 r = static_cast<Uint8>(rClamped * 255.0f);
    const Uint8 g = static_cast<Uint8>(gClamped * 255.0f);
    const Uint8 b = static_cast<Uint8>(bClamped * 255.0f);

    const Uint32 mapped = SDL_MapRGB(screen->format, r, g, b);
    SDL_FillRect(screen, &rect, mapped);
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
        DrawCell(segment.first, segment.second, kSnakeColor);
    }

    // Draw food (red)
    DrawCell(food.first, food.second, kFoodColor);

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
    std::memset(occupied, 0, sizeof(occupied));

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

