import random
import time
import tkinter as tk
from collections import deque
from dataclasses import dataclass
from typing import Deque, List, Tuple
from tkinter import TclError, messagebox


Cell = Tuple[int, int]


@dataclass(frozen=True)
class GridConfig:
    width: int = 20
    height: int = 20
    cell_size: int = 15


class SnakeGame:
    def __init__(self, root: tk.Tk, config: GridConfig) -> None:
        self.root = root
        self.config = config

        self.canvas = tk.Canvas(
            root,
            width=self.config.width * self.config.cell_size,
            height=self.config.height * self.config.cell_size,
            highlightthickness=0,
            bg="black",
        )
        self.canvas.pack()

        self.snake: Deque[Cell] = deque()
        self.food: Cell = (0, 0)
        self.occupied: List[List[bool]] = [
            [False for _ in range(self.config.width)] for _ in range(self.config.height)
        ]

        self.direction_x = 1
        self.direction_y = 0
        self.is_alive = True

        self.last_update_ms = self._now_ms()

        self.root.bind("<Up>", self._on_key)
        self.root.bind("<Down>", self._on_key)
        self.root.bind("<Left>", self._on_key)
        self.root.bind("<Right>", self._on_key)
        self.root.bind("<Escape>", self._on_key)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        self._reset()

    def _now_ms(self) -> int:
        return int(time.monotonic() * 1000)

    def _reset(self) -> None:
        self.snake.clear()
        for y in range(self.config.height):
            for x in range(self.config.width):
                self.occupied[y][x] = False

        start = (self.config.width // 2, self.config.height // 2)
        self.snake.appendleft(start)
        self.occupied[start[1]][start[0]] = True

        self.direction_x = 1
        self.direction_y = 0
        self.is_alive = True

        self._spawn_food()
        self._render()

    def _spawn_food(self) -> None:
        empties: List[Cell] = []
        for y in range(self.config.height):
            for x in range(self.config.width):
                if not self.occupied[y][x]:
                    empties.append((x, y))

        if not empties:
            self.is_alive = False
            try:
                messagebox.showinfo("Snake", "You win! The grid is full.")
            except TclError:
                pass
            self.root.after(0, self.root.destroy)
            return

        self.food = random.choice(empties)

    def _on_close(self) -> None:
        self.is_alive = False
        self.root.after(0, self.root.destroy)

    def _on_key(self, event: tk.Event) -> None:
        if not self.is_alive:
            return

        key = event.keysym
        if key == "Escape":
            self.is_alive = False
            self.root.after(0, self.root.destroy)
            return

        if key == "Up" and self.direction_y == 0:
            self.direction_x = 0
            self.direction_y = -1
        elif key == "Down" and self.direction_y == 0:
            self.direction_x = 0
            self.direction_y = 1
        elif key == "Left" and self.direction_x == 0:
            self.direction_x = -1
            self.direction_y = 0
        elif key == "Right" and self.direction_x == 0:
            self.direction_x = 1
            self.direction_y = 0

    def _update_snake(self) -> None:
        head_x, head_y = self.snake[0]
        new_x = head_x + self.direction_x
        new_y = head_y + self.direction_y

        hit_wall = (
            new_x < 0
            or new_x >= self.config.width
            or new_y < 0
            or new_y >= self.config.height
        )
        if hit_wall:
            self.is_alive = False
            return

        will_grow = (new_x, new_y) == self.food

        if not will_grow:
            tail_x, tail_y = self.snake.pop()
            self.occupied[tail_y][tail_x] = False

        if self.occupied[new_y][new_x]:
            self.is_alive = False
            return

        self.snake.appendleft((new_x, new_y))
        self.occupied[new_y][new_x] = True

        if will_grow:
            self._spawn_food()

    def _render(self) -> None:
        cs = self.config.cell_size
        self.canvas.delete("all")

        fx, fy = self.food
        self.canvas.create_rectangle(
            fx * cs,
            fy * cs,
            fx * cs + cs,
            fy * cs + cs,
            fill="red",
            outline="",
        )

        for x, y in self.snake:
            self.canvas.create_rectangle(
                x * cs,
                y * cs,
                x * cs + cs,
                y * cs + cs,
                fill="green",
                outline="",
            )

        self.canvas.update_idletasks()

    def tick(self) -> None:
        if not self.is_alive:
            return

        now = self._now_ms()
        if now - self.last_update_ms > 120:
            self._update_snake()
            self.last_update_ms = now

        if self.is_alive:
            self._render()
            self.root.after(10, self.tick)
        else:
            try:
                messagebox.showinfo("Snake", f"Game over. Score: {len(self.snake)}")
            except TclError:
                pass
            self.root.after(0, self.root.destroy)


def main() -> None:
    root = tk.Tk()
    root.title("Snake")
    root.resizable(False, False)

    game = SnakeGame(root, GridConfig())
    root.after(10, game.tick)
    root.mainloop()


if __name__ == "__main__":
    main()

