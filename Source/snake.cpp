// Minimal SDL snake in this repo (refactored for readability)

#include <SDL/SDL.h>
#include <deque>
#include <vector>
#include <random>
#include <cstring>
#include <algorithm>

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

// Occupancy grid for O(1) collision detection
bool occupied[kGridHeight][kGridWidth];

// Free-cell list for O(1) food spawning.
// Each cell stores the index of its own slot so removal is O(1)
// via swap-with-back.
std::vector<Cell> freeCells;
int freeCellIndex[kGridHeight][kGridWidth];  // freeCellIndex[y][x] = index in freeCells

// C++11 PRNG — seeded once at startup
std::mt19937 rng;

int directionX = 1;
int directionY = 0;
bool isAlive   = true;

// Remove a cell from freeCells in O(1) using swap-with-back.
void RemoveFreeCell(int x, int y)
{
    const int idx  = freeCellIndex[y][x];
    const int last = static_cast<int>(freeCells.size()) - 1;

    if (idx != last)
    {
        // Overwrite the slot being removed with the last element.
        freeCells[idx] = freeCells[last];
        freeCellIndex[freeCells[idx].second][freeCells[idx].first] = idx;
    }

    freeCells.pop_back();
    // Mark the index as invalid so accidental look-ups are detectable.
    freeCellIndex[y][x] = -1;
}

// Add a cell back to freeCells in O(1).
void AddFreeCell(int x, int y)
{
    freeCellIndex[y][x] = static_cast<int>(freeCells.size());
    freeCells.push_back(Cell(x, y));
}

void SpawnFood()
{
    // Win condition: no free cells left means the snake fills the entire grid.
    if (freeCells.empty())
    {
        isAlive = false;
        return;
    }

    // Pick a random free cell in O(1).
    std::uniform_int_distribution<int> dist(0, static_cast<int>(freeCells.size()) - 1);
    const int idx = dist(rng);
    food = freeCells[idx];

    // The food cell is still technically free (not occupied by the snake),
    // so we do NOT remove it from freeCells here.  It will be removed from
    // freeCells when the snake's head moves into it (i.e. it becomes occupied).
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
        AddFreeCell(tail.first, tail.second);
        snake.pop_back();
    }

    // Self-collision check using occupancy grid (O(1)).
    if (occupied[newY][newX])
    {
        isAlive = false;
        return;
    }

    // The new head cell is currently free; claim it.
    RemoveFreeCell(newX, newY);
    snake.push_front(Cell(newX, newY));
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
    // Seed the PRNG with a non-deterministic source.
    rng.seed(std::random_device{}());

    screen = InitializeSDL(kGridWidth * kCellSize, kGridHeight * kCellSize);

    // Reset occupancy grid and free-cell structures.
    std::memset(occupied,       0,  sizeof(occupied));
    std::memset(freeCellIndex, -1, sizeof(freeCellIndex));

    freeCells.reserve(kGridWidth * kGridHeight);
    for (int y = 0; y < kGridHeight; ++y)
    {
        for (int x = 0; x < kGridWidth; ++x)
        {
            freeCellIndex[y][x] = static_cast<int>(freeCells.size());
            freeCells.push_back(Cell(x, y));
        }
    }

    // Place the initial snake head at the grid centre.
    const int startX = kGridWidth  / 2;
    const int startY = kGridHeight / 2;

    snake.push_back(Cell(startX, startY));
    occupied[startY][startX] = true;
    RemoveFreeCell(startX, startY);

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
