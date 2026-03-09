import random
import time
import tkinter as tk
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, Optional, Tuple
from tkinter import TclError

# ---------------------------------------------------------------------------
# Type alias
# ---------------------------------------------------------------------------
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
    """贪吃蛇游戏主类。

    核心数据结构选择：
    - snake       : deque[Cell]  — 头部 appendleft / 尾部 pop，两端 O(1)。
    - occupied    : set[Cell]    — O(1) 碰撞检测，同时作为"已占用格"的权威来源。
                                   不再维护 empty 集合，避免双重写操作与潜在不同步。
    - _cell_ids   : dict[Cell, int] — canvas item id 映射，O(1) 精确删除画布对象。
    - _input_buffer : deque(maxlen=2) — 最多缓存 2 帧输入，防止按键丢失又防止过度缓存。
    """

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
        self.occupied: set = set()          # 仅维护一个集合，empty = 全集 - occupied

        self.direction_x = 1
        self.direction_y = 0
        self.is_alive = True

        self.last_update_ms = self._now_ms()

        self._food_id: Optional[int] = None
        self._cell_ids: Dict[Cell, int] = {}
        self._input_buffer: Deque[Tuple[int, int]] = deque(maxlen=2)
        self._tick_running: bool = False

        self.root.bind("<Up>",    self._on_key)
        self.root.bind("<Down>",  self._on_key)
        self.root.bind("<Left>",  self._on_key)
        self.root.bind("<Right>", self._on_key)
        self.root.bind("<Escape>", self._on_key)
        self.root.bind("<r>", self._on_key)
        self.root.bind("<R>", self._on_key)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        self._reset()

    # ------------------------------------------------------------------
    # 公共入口
    # ------------------------------------------------------------------

    def start(self) -> None:
        """启动 tick 循环。由外部（main）统一调用，避免调度逻辑分散。"""
        self._tick_running = True
        self.root.after(FRAME_MS, self.tick)

    # ------------------------------------------------------------------
    # 内部工具
    # ------------------------------------------------------------------

    def _now_ms(self) -> int:
        return int(time.monotonic() * 1000)

    # ------------------------------------------------------------------
    # 重置 / 初始化
    # ------------------------------------------------------------------

    def _reset(self) -> None:
        self.snake.clear()
        self.occupied.clear()
        self._cell_ids.clear()
        self._input_buffer.clear()
        # 不再构建 empty 集合；空闲格通过 "全集 - occupied" 隐式表示

        start = (self.config.width // 2, self.config.height // 2)
        self.snake.appendleft(start)
        self.occupied.add(start)

        self.direction_x = 1
        self.direction_y = 0
        self.is_alive = True
        self.last_update_ms = self._now_ms()

        self.canvas.delete("all")
        self._food_id = None
        self._spawn_food()
        self._draw_head(start)

    # ------------------------------------------------------------------
    # 食物
    # ------------------------------------------------------------------

    def _spawn_food(self) -> None:
        """在随机空闲格放置食物。

        优化要点（对比旧版）：
        旧版：random.choice(tuple(self.empty))
              每次调用将整个 empty 集合复制为 tuple，O(n) 时间 + O(n) 内存分配。

        新版：reservoir_sample(self.occupied 的补集)
              使用蓄水池抽样 (reservoir sampling) 对隐式的空闲格集合做单遍 O(n) 扫描，
              无任何额外集合或列表的内存分配，且不需要维护 empty 集合。
              对于本游戏的 20×20=400 格规模，O(n) 扫描绝对不是瓶颈；
              相比旧版额外的好处是消除了每步移动中对 empty 集合的两次写操作。
        """
        total = self.config.width * self.config.height
        free_count = total - len(self.occupied)

        if free_count == 0:
            self._show_overlay(
                f"You Win!\nScore: {len(self.snake)}\nPress R to restart",
                "gold",
            )
            self.is_alive = False
            return

        # 蓄水池抽样：在单次遍历中以等概率选出一个空闲格，无中间容器分配
        chosen: Optional[Cell] = None
        seen = 0
        for y in range(self.config.height):
            for x in range(self.config.width):
                cell = (x, y)
                if cell not in self.occupied:
                    seen += 1
                    # 以 1/seen 的概率替换当前选中格
                    if random.randrange(seen) == 0:
                        chosen = cell

        # seen == free_count > 0，chosen 必然被赋值
        assert chosen is not None
        self.food = chosen
        self._draw_food()

    # ------------------------------------------------------------------
    # 绘制
    # ------------------------------------------------------------------

    def _draw_food(self) -> None:
        cs = self.config.cell_size
        fx, fy = self.food
        if self._food_id is not None:
            self.canvas.coords(
                self._food_id,
                fx * cs,      fy * cs,
                fx * cs + cs, fy * cs + cs,
            )
        else:
            self._food_id = self.canvas.create_rectangle(
                fx * cs,      fy * cs,
                fx * cs + cs, fy * cs + cs,
                fill="red", outline="",
            )

    def _draw_head(self, cell: Cell) -> None:
        cs = self.config.cell_size
        x, y = cell
        item_id = self.canvas.create_rectangle(
            x * cs,      y * cs,
            x * cs + cs, y * cs + cs,
            fill="green", outline="", tags="snake",
        )
        self._cell_ids[cell] = item_id

    def _erase_cell(self, cell: Cell) -> None:
        item_id = self._cell_ids.pop(cell, None)
        if item_id is not None:
            self.canvas.delete(item_id)

    def _show_overlay(self, text: str, color: str) -> None:
        """在画布中央显示叠加文字（胜利 / 游戏结束共用，消除重复代码）。"""
        cx = self.config.width  * self.config.cell_size // 2
        cy = self.config.height * self.config.cell_size // 2
        try:
            self.canvas.create_text(
                cx, cy,
                text=text,
                fill=color,
                font=("Arial", 12, "bold"),
                justify="center",
                tags="overlay",
            )
        except TclError:
            pass

    # ------------------------------------------------------------------
    # 输入处理
    # ------------------------------------------------------------------

    def _on_close(self) -> None:
        self.is_alive = False
        self.root.after(0, self.root.destroy)

    def _on_key(self, event: tk.Event) -> None:
        key = event.keysym

        if not self.is_alive:
            if key in ("r", "R"):
                if not self._tick_running:
                    self._reset()
                    self.start()
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

    # ------------------------------------------------------------------
    # 游戏逻辑
    # ------------------------------------------------------------------

    def _update_snake(self) -> None:
        # 消费输入缓冲中最早的一条指令
        if self._input_buffer:
            self.direction_x, self.direction_y = self._input_buffer.popleft()

        head_x, head_y = self.snake[0]
        new_x = head_x + self.direction_x
        new_y = head_y + self.direction_y

        # 边界检测
        if not (0 <= new_x < self.config.width and 0 <= new_y < self.config.height):
            self.is_alive = False
            self._show_overlay(
                f"Game Over\nScore: {len(self.snake)}\nPress R to restart",
                "white",
            )
            return

        new_head = (new_x, new_y)
        will_grow = new_head == self.food

        # 先移除尾部（若不增长），使尾格回归隐式的空闲集合（从 occupied 中丢弃即可）
        if not will_grow:
            tail = self.snake.pop()
            self.occupied.discard(tail)
            self._erase_cell(tail)

        # 碰撞检测（食物格来自空闲集合，will_grow=True 时 new_head 不在 occupied 中，
        # 因此此分支仅在 will_grow=False 时有实际意义）
        if new_head in self.occupied:
            self.is_alive = False
            self._show_overlay(
                f"Game Over\nScore: {len(self.snake)}\nPress R to restart",
                "white",
            )
            return

        # 更新蛇体
        self.snake.appendleft(new_head)
        self.occupied.add(new_head)
        self._draw_head(new_head)

        if will_grow:
            self._spawn_food()

    def tick(self) -> None:
        if not self.is_alive:
            self._tick_running = False
            return

        now = self._now_ms()
        if now - self.last_update_ms >= SNAKE_SPEED_MS:
            self._update_snake()
            self.last_update_ms = now

        if self.is_alive:
            self.root.after(FRAME_MS, self.tick)
        else:
            self._tick_running = False


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def main() -> None:
    root = tk.Tk()
    root.title("Snake")
    root.resizable(False, False)

    game = SnakeGame(root, GridConfig())
    game.start()          # 调度职责统一收归 SnakeGame
    root.mainloop()


if __name__ == "__main__":
    main()
