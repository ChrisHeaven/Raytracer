import random
import time
import tkinter as tk
from collections import deque
from dataclasses import dataclass
from typing import Deque, Optional, Set, Tuple
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
        # 用 set 替代二维 bool 数组，spawn_food 时直接从空格集合随机选取
        self.occupied: Set[Cell] = set()
        self.empty: Set[Cell] = set()

        self.direction_x = 1
        self.direction_y = 0
        self.is_alive = True

        self.last_update_ms = self._now_ms()

        # canvas item id 缓存，避免重复创建/删除
        self._food_id: Optional[int] = None

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
        self.occupied.clear()
        self.empty = {
            (x, y)
            for y in range(self.config.height)
            for x in range(self.config.width)
        }

        start = (self.config.width // 2, self.config.height // 2)
        self.snake.appendleft(start)
        self.occupied.add(start)
        self.empty.discard(start)

        self.direction_x = 1
        self.direction_y = 0
        self.is_alive = True

        self.canvas.delete("all")
        self._food_id = None
        self._spawn_food()
        self._draw_head(start)

    def _spawn_food(self) -> None:
        if not self.empty:
            self.is_alive = False
            try:
                messagebox.showinfo("Snake", "You win! The grid is full.")
            except TclError:
                pass
            self.root.after(0, self.root.destroy)
            return

        self.food = random.choice(tuple(self.empty))
        self._draw_food()

    def _draw_food(self) -> None:
        cs = self.config.cell_size
        fx, fy = self.food
        if self._food_id is not None:
            self.canvas.coords(
                self._food_id,
                fx * cs, fy * cs,
                fx * cs + cs, fy * cs + cs,
            )
        else:
            self._food_id = self.canvas.create_rectangle(
                fx * cs, fy * cs,
                fx * cs + cs, fy * cs + cs,
                fill="red", outline="",
            )

    def _draw_head(self, cell: Cell) -> None:
        cs = self.config.cell_size
        x, y = cell
        self.canvas.create_rectangle(
            x * cs, y * cs,
            x * cs + cs, y * cs + cs,
            fill="green", outline="", tags="snake",
        )

    def _erase_cell(self, cell: Cell) -> None:
        cs = self.config.cell_size
        x, y = cell
        self.canvas.create_rectangle(
            x * cs, y * cs,
            x * cs + cs, y * cs + cs,
            fill="black", outline="",
        )

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

        if (
            new_x < 0
            or new_x >= self.config.width
            or new_y < 0
            or new_y >= self.config.height
        ):
            self.is_alive = False
            return

        new_head = (new_x, new_y)
        will_grow = new_head == self.food

        if not will_grow:
            tail = self.snake.pop()
            self.occupied.discard(tail)
            self.empty.add(tail)
            self._erase_cell(tail)

        if new_head in self.occupied:
            self.is_alive = False
            return

        self.snake.appendleft(new_head)
        self.occupied.add(new_head)
        self.empty.discard(new_head)
        self._draw_head(new_head)

        if will_grow:
            self._spawn_food()

    def tick(self) -> None:
        if not self.is_alive:
            return

        now = self._now_ms()
        if now - self.last_update_ms > 120:
            self._update_snake()
            self.last_update_ms = now
            self.canvas.update_idletasks()

        if self.is_alive:
            self.root.after(16, self.tick)
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
    root.after(16, game.tick)
    root.mainloop()


if __name__ == "__main__":
    main()
