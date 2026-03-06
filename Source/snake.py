import random
import time
import tkinter as tk
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, Optional, Set, Tuple
from tkinter import TclError

Cell = Tuple[int, int]

FRAME_MS: int = 16
SNAKE_SPEED_MS: int = 120

_KEY_TO_DIR: Dict[str, Tuple[int, int]] = {
    "Up":    (0, -1),
    "Down":  (0,  1),
    "Left":  (-1, 0),
    "Right": (1,  0),
}


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
        self.occupied: Set[Cell] = set()
        self.empty: Set[Cell] = set()

        self.direction_x = 1
        self.direction_y = 0
        self.is_alive = True

        self.last_update_ms = self._now_ms()

        self._food_id: Optional[int] = None
        # cell -> canvas item id，用于精确删除蛇身格，避免 canvas 对象堆积
        self._cell_ids: Dict[Cell, int] = {}
        # 输入缓冲，最多缓存 2 个待处理方向
        self._input_buffer: Deque[Tuple[int, int]] = deque(maxlen=2)
        # 防止重复调度 tick 链
        self._tick_running: bool = False

        self.root.bind("<Up>", self._on_key)
        self.root.bind("<Down>", self._on_key)
        self.root.bind("<Left>", self._on_key)
        self.root.bind("<Right>", self._on_key)
        self.root.bind("<Escape>", self._on_key)
        self.root.bind("<r>", self._on_key)
        self.root.bind("<R>", self._on_key)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        self._tick_running = True
        self._reset()

    def _now_ms(self) -> int:
        return int(time.monotonic() * 1000)

    def _reset(self) -> None:
        self.snake.clear()
        self.occupied.clear()
        self._cell_ids.clear()
        self._input_buffer.clear()
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
        self.last_update_ms = self._now_ms()

        self.canvas.delete("all")
        self._food_id = None
        self._spawn_food()
        self._draw_head(start)

    def _spawn_food(self) -> None:
        if not self.empty:
            self._win()
            return

        self.food = random.choice(tuple(self.empty))
        self._draw_food()

    def _win(self) -> None:
        self.is_alive = False
        cx = self.config.width * self.config.cell_size // 2
        cy = self.config.height * self.config.cell_size // 2
        try:
            self.canvas.create_text(
                cx, cy,
                text=f"You Win!\nScore: {len(self.snake)}\nPress R to restart",
                fill="gold",
                font=("Arial", 12, "bold"),
                justify="center",
                tags="overlay",
            )
        except TclError:
            pass

    def _on_game_over(self) -> None:
        cx = self.config.width * self.config.cell_size // 2
        cy = self.config.height * self.config.cell_size // 2
        try:
            self.canvas.create_text(
                cx, cy,
                text=f"Game Over\nScore: {len(self.snake)}\nPress R to restart",
                fill="white",
                font=("Arial", 12, "bold"),
                justify="center",
                tags="overlay",
            )
        except TclError:
            pass

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
        item_id = self.canvas.create_rectangle(
            x * cs, y * cs,
            x * cs + cs, y * cs + cs,
            fill="green", outline="", tags="snake",
        )
        self._cell_ids[cell] = item_id

    def _erase_cell(self, cell: Cell) -> None:
        item_id = self._cell_ids.pop(cell, None)
        if item_id is not None:
            self.canvas.delete(item_id)

    def _on_close(self) -> None:
        self.is_alive = False
        self.root.after(0, self.root.destroy)

    def _on_key(self, event: tk.Event) -> None:
        key = event.keysym

        if not self.is_alive:
            if key in ("r", "R"):
                if not self._tick_running:
                    self._reset()
                    self._tick_running = True
                    self.root.after(FRAME_MS, self.tick)
            elif key == "Escape":
                self.root.after(0, self.root.destroy)
            return

        if key == "Escape":
            self.is_alive = False
            self.root.after(0, self.root.destroy)
            return

        if key in _KEY_TO_DIR:
            dx, dy = _KEY_TO_DIR[key]
            # 基于缓冲中最后一条指令（或当前方向）防止直接反向
            if self._input_buffer:
                last_dx, last_dy = self._input_buffer[-1]
            else:
                last_dx, last_dy = self.direction_x, self.direction_y
            if not (dx == -last_dx and dy == -last_dy):
                self._input_buffer.append((dx, dy))

    def _update_snake(self) -> None:
        # 消费输入缓冲
        if self._input_buffer:
            self.direction_x, self.direction_y = self._input_buffer.popleft()

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
            self._on_game_over()
            return

        new_head = (new_x, new_y)
        will_grow = new_head == self.food

        if not will_grow:
            tail = self.snake.pop()
            self.occupied.discard(tail)
            self.empty.add(tail)
            self._erase_cell(tail)

        # 食物来自 empty，与 occupied 互斥，will_grow=True 时不可能触发碰撞
        if new_head in self.occupied:
            self.is_alive = False
            self._on_game_over()
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
        if now - self.last_update_ms >= SNAKE_SPEED_MS:
            self._update_snake()
            self.last_update_ms = now

        if self.is_alive:
            self.root.after(FRAME_MS, self.tick)
        else:
            self._tick_running = False


def main() -> None:
    root = tk.Tk()
    root.title("Snake")
    root.resizable(False, False)

    game = SnakeGame(root, GridConfig())
    root.after(FRAME_MS, game.tick)
    root.mainloop()


if __name__ == "__main__":
    main()
