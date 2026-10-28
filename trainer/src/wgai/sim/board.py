"""5×12 翻翻棋棋盘几何：格子、行营、公路邻接与铁路线。

规则来源见 `shared/rules/fanfanqi.md` 与 `shared/rules/rules.json`。
本模块只负责“哪些格子相连、哪些线是铁路”，不含军衔/吃子判断。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Iterator

Coord = tuple[int, int]

_ORTHOGONAL = ((-1, 0), (1, 0), (0, -1), (0, 1))
_DIAGONAL = ((-1, -1), (-1, 1), (1, -1), (1, 1))


@dataclass
class BoardSpec:
    """棋盘拓扑。

    - 普通格只与上下左右普通格相连（公路一步）。
    - 行营只与四个斜角格相连（实测棋盘上的 X 形道路）。
    - 铁路：`railway_rows` 的整行、`railway_cols` 的整列；两条铁路交叉处可转弯
      （工兵可任意转弯，其他棋子只能直走）。
    """

    rows: int
    cols: int
    camps: frozenset[int]
    railway_rows: frozenset[int]
    railway_cols: frozenset[int]
    _neighbors: dict[int, tuple[int, ...]] = field(init=False, repr=False)
    _railway_neighbors: dict[int, tuple[int, ...]] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        if self.rows <= 0 or self.cols <= 0:
            raise ValueError("棋盘尺寸必须为正")
        for index in self.camps:
            if not 0 <= index < self.rows * self.cols:
                raise ValueError(f"行营索引越界：{index}")
        for row in self.railway_rows:
            if not 0 <= row < self.rows:
                raise ValueError(f"铁路行越界：{row}")
        for col in self.railway_cols:
            if not 0 <= col < self.cols:
                raise ValueError(f"铁路列越界：{col}")

        neighbors: dict[int, tuple[int, ...]] = {}
        railway: dict[int, tuple[int, ...]] = {}
        for index in range(self.size):
            row, col = self.coord(index)
            cells: list[int] = []
            if index in self.camps:
                # 行营只有 X 形斜线，连接四个斜角（可能是普通格，也可能是中营）。
                steps = _DIAGONAL
                for dr, dc in steps:
                    nr, nc = row + dr, col + dc
                    if not (0 <= nr < self.rows and 0 <= nc < self.cols):
                        continue
                    cells.append(self.index(nr, nc))
            else:
                # 普通格：上下左右走公路；四个斜角只有行营才有路。
                # 注意邻接必须对称：行营的斜线邻居也要把普通格列回来。
                for dr, dc in _ORTHOGONAL:
                    nr, nc = row + dr, col + dc
                    if not (0 <= nr < self.rows and 0 <= nc < self.cols):
                        continue
                    other = self.index(nr, nc)
                    if other in self.camps:
                        continue
                    cells.append(other)
                for dr, dc in _DIAGONAL:
                    nr, nc = row + dr, col + dc
                    if not (0 <= nr < self.rows and 0 <= nc < self.cols):
                        continue
                    other = self.index(nr, nc)
                    if other in self.camps:
                        cells.append(other)
            neighbors[index] = tuple(dict.fromkeys(cells))

            rail_cells: list[int] = []
            if row in self.railway_rows:
                if col > 0:
                    rail_cells.append(self.index(row, col - 1))
                if col + 1 < self.cols:
                    rail_cells.append(self.index(row, col + 1))
            if col in self.railway_cols:
                if row > 0:
                    rail_cells.append(self.index(row - 1, col))
                if row + 1 < self.rows:
                    rail_cells.append(self.index(row + 1, col))
            railway[index] = tuple(dict.fromkeys(rail_cells))

        self._neighbors = neighbors
        self._railway_neighbors = railway

    # -- 基础换算 ---------------------------------------------------------

    @property
    def size(self) -> int:
        return self.rows * self.cols

    def index(self, row: int, col: int) -> int:
        if not (0 <= row < self.rows and 0 <= col < self.cols):
            raise IndexError(f"坐标越界：({row}, {col})")
        return row * self.cols + col

    def coord(self, index: int) -> Coord:
        if not 0 <= index < self.size:
            raise IndexError(f"格子索引越界：{index}")
        return divmod(index, self.cols)

    def is_camp(self, index: int) -> bool:
        return index in self.camps

    def is_railway(self, index: int) -> bool:
        row, col = self.coord(index)
        return row in self.railway_rows or col in self.railway_cols

    def is_horizontal_railway(self, index: int) -> bool:
        row, _ = self.coord(index)
        return row in self.railway_rows

    def is_vertical_railway(self, index: int) -> bool:
        _, col = self.coord(index)
        return col in self.railway_cols

    # -- 邻接 -------------------------------------------------------------

    def neighbors(self, index: int) -> tuple[int, ...]:
        """公路一步可达的格子（不含铁路远程）。"""
        return self._neighbors[index]

    def railway_neighbors(self, index: int) -> tuple[int, ...]:
        """铁路网上相邻的格子（用于工兵 BFS）。"""
        return self._railway_neighbors[index]

    def railway_slides(self, index: int) -> Iterator[tuple[int, ...]]:
        """非工兵的四条直线铁路，按方向返回从近到远的格子序列。

        只返回真正属于铁路的方向；调用方遇到第一个占位格即停止。
        """
        row, col = self.coord(index)
        if row in self.railway_rows:
            left = tuple(self.index(row, c) for c in range(col - 1, -1, -1))
            right = tuple(self.index(row, c) for c in range(col + 1, self.cols))
            yield left
            yield right
        if col in self.railway_cols:
            up = tuple(self.index(r, col) for r in range(row - 1, -1, -1))
            down = tuple(self.index(r, col) for r in range(row + 1, self.rows))
            yield up
            yield down

    def railway_reachable(
        self,
        start: int,
        is_blocked,
        can_land,
    ) -> set[int]:
        """工兵沿铁路网可达的落点（可转弯）。

        `is_blocked(cell)` 为真时不能穿过；`can_land(cell)` 决定空/敌方格
        是否作为落点。起点不返回。
        """
        reached: set[int] = set()
        seen = {start}
        stack = [start]
        while stack:
            current = stack.pop()
            for nxt in self._railway_neighbors[current]:
                if nxt in seen:
                    continue
                if is_blocked(nxt):
                    # 占位格不能穿过；若可作为落点（敌方），由 can_land 决定。
                    if can_land(nxt):
                        reached.add(nxt)
                    seen.add(nxt)
                    continue
                seen.add(nxt)
                reached.add(nxt)
                stack.append(nxt)
        return reached

    # -- 构造 -------------------------------------------------------------

    @classmethod
    def from_dict(cls, data: dict) -> "BoardSpec":
        camps = frozenset(
            row * int(data["cols"]) + col for row, col in data.get("camps", [])
        )
        return cls(
            rows=int(data["rows"]),
            cols=int(data["cols"]),
            camps=camps,
            railway_rows=frozenset(int(v) for v in data.get("railwayRows", [])),
            railway_cols=frozenset(int(v) for v in data.get("railwayCols", [])),
        )

    def describe(self) -> dict:
        return {
            "rows": self.rows,
            "cols": self.cols,
            "camps": [list(self.coord(index)) for index in sorted(self.camps)],
            "railwayRows": sorted(self.railway_rows),
            "railwayCols": sorted(self.railway_cols),
        }


@dataclass
class Cell:
    index: int
    row: int
    col: int
    is_camp: bool
    piece: object | None = None
    revealed: bool = False

    @property
    def is_empty(self) -> bool:
        return self.piece is None

    @property
    def is_hidden(self) -> bool:
        return self.piece is not None and not self.revealed


class Board:
    """可变的棋盘格子容器；棋子对象由 `rules.Piece` 提供。"""

    def __init__(self, spec: BoardSpec) -> None:
        self.spec = spec
        self.cells: list[Cell] = []
        for index in range(spec.size):
            row, col = spec.coord(index)
            self.cells.append(
                Cell(
                    index=index,
                    row=row,
                    col=col,
                    is_camp=spec.is_camp(index),
                )
            )

    def __iter__(self) -> Iterator[Cell]:
        return iter(self.cells)

    def __len__(self) -> int:
        return len(self.cells)

    def cell(self, index: int) -> Cell:
        if not 0 <= index < len(self.cells):
            raise IndexError(f"格子索引越界：{index}")
        return self.cells[index]

    def piece_at(self, index: int) -> object | None:
        return self.cell(index).piece

    def is_empty(self, index: int) -> bool:
        return self.cell(index).is_empty

    def is_hidden(self, index: int) -> bool:
        return self.cell(index).is_hidden

    def is_revealed(self, index: int) -> bool:
        cell = self.cell(index)
        return cell.piece is not None and cell.revealed

    def place(self, index: int, piece: object, revealed: bool = False) -> None:
        cell = self.cell(index)
        if cell.piece is not None:
            raise ValueError(f"格子 {index} 已有棋子")
        cell.piece = piece
        cell.revealed = revealed

    def remove(self, index: int) -> object:
        cell = self.cell(index)
        if cell.piece is None:
            raise ValueError(f"格子 {index} 没有棋子")
        piece = cell.piece
        cell.piece = None
        cell.revealed = False
        return piece

    def move(self, from_cell: int, to_cell: int) -> object:
        piece = self.remove(from_cell)
        self.place(to_cell, piece, revealed=True)
        return piece

    def reveal(self, index: int) -> object:
        cell = self.cell(index)
        if cell.piece is None:
            raise ValueError(f"格子 {index} 没有棋子")
        cell.revealed = True
        return cell.piece

    def hidden_indices(self) -> list[int]:
        return [cell.index for cell in self.cells if cell.is_hidden]

    def revealed_indices(self) -> list[int]:
        return [cell.index for cell in self.cells if self.is_revealed(cell.index)]

    def pieces(self) -> Iterable[tuple[int, object, bool]]:
        for cell in self.cells:
            if cell.piece is not None:
                yield cell.index, cell.piece, cell.revealed

    def copy(self) -> "Board":
        clone = Board(self.spec)
        for cell in self.cells:
            clone.cells[cell.index].piece = cell.piece
            clone.cells[cell.index].revealed = cell.revealed
        return clone

    def render(self) -> str:
        """调试用：暗子 `##`，空格 `..`，明子用颜色首字母 + 军衔首字。"""
        symbols = {
            "commander": "司",
            "army_commander": "军",
            "division_commander": "师",
            "brigade_commander": "旅",
            "regiment_commander": "团",
            "battalion_commander": "营",
            "company_commander": "连",
            "platoon_commander": "排",
            "engineer": "工",
            "mine": "雷",
            "bomb": "炸",
            "flag": "旗",
        }
        rows = []
        for row in range(self.spec.rows):
            parts = []
            for col in range(self.spec.cols):
                cell = self.cell(self.spec.index(row, col))
                if cell.piece is None:
                    parts.append("..")
                elif not cell.revealed:
                    parts.append("##")
                else:
                    color = getattr(cell.piece, "color", "")
                    prefix = "R" if getattr(color, "value", color) == "red" else "B"
                    parts.append(prefix + symbols.get(getattr(cell.piece, "kind", ""), "?"))
            rows.append(" ".join(parts))
        return "\n".join(rows)
