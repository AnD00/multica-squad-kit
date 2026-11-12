"""端末の出力を 100 桁で折り返し、色と全角の幅を保って PNG に描く。

描画だけが Pillow を使う。出力の読み取りは標準ライブラリだけなので、CI でも確かめられる。
"""
import argparse
import codecs
from dataclasses import dataclass
from pathlib import Path
import re
import unicodedata


COLUMNS = 100
FONT_SIZE = 20
BACKGROUND = (24, 24, 24)
FOREGROUND = (229, 229, 229)
# CSI、OSC、その他の ESC の列。位置の変更と SGR だけを読む。
CONTROL = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|(?![\[\]])[ -/]*[@-~])")


def xterm_color(index):
    """xterm の 16 色、6×6×6 の色、24 色の灰色。"""
    base = (
        "000000", "cd0000", "00cd00", "cdcd00", "0000ee", "cd00cd", "00cdcd", "e5e5e5",
        "7f7f7f", "ff0000", "00ff00", "ffff00", "5c5cff", "ff00ff", "00ffff", "ffffff",
    )
    if not 0 <= index <= 255:
        raise ValueError("色の番号は 0〜255 です")
    if index < 16:
        return tuple(bytes.fromhex(base[index]))
    if index >= 232:
        level = 8 + (index - 232) * 10
        return (level, level, level)
    level = (0, 95, 135, 175, 215, 255)
    offset = index - 16
    return (level[offset // 36], level[(offset // 6) % 6], level[offset % 6])


@dataclass(frozen=True)
class Glyph:
    text: str
    column: int
    width: int
    color: tuple
    bold: bool


class Terminal:
    """画面と上へ流れた行を分けて持つ、出力の読み取り。"""

    def __init__(self, columns=COLUMNS, rows=40):
        self.columns, self.rows = columns, rows
        self.screen = [[None] * columns for _ in range(rows)]
        self.history = []
        self.row = self.column = 0
        self.color, self.bold = FOREGROUND, False
        self.wrap = False
        self.pending = ""

    @property
    def absolute_row(self):
        return len(self.history) + self.row

    def _down(self):
        if self.row == self.rows - 1:
            self.history.append(self.screen.pop(0))
            self.screen.append([None] * self.columns)
        else:
            self.row += 1

    def _clear_cell(self, column):
        line = self.screen[self.row]
        previous = line[column]
        if previous is not None and previous.width == 2:
            line[previous.column:previous.column + 2] = [None, None]
        else:
            line[column] = None

    def _write(self, char):
        width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        if self.wrap or self.column + width > self.columns:
            self.column = 0
            self._down()
        self.wrap = False
        for column in range(self.column, self.column + width):
            self._clear_cell(column)
        glyph = Glyph(char, self.column, width, self.color, self.bold)
        self.screen[self.row][self.column:self.column + width] = [glyph] * width
        end = self.column + width
        self.column = min(end, self.columns - 1)
        self.wrap = end == self.columns

    def _sgr(self, parameters):
        values = parameters.split(";")
        if not all(not value or value.isdecimal() for value in values):
            return
        codes = [int(value or 0) for value in values]
        i = 0
        while i < len(codes):
            code = codes[i]
            if code == 0:
                self.color, self.bold = FOREGROUND, False
            elif code == 1:
                self.bold = True
            elif code == 22:
                self.bold = False
            elif code == 39:
                self.color = FOREGROUND
            elif code in (38, 48) and codes[i + 1:i + 2] == [5] and i + 2 < len(codes):
                if code == 38 and 0 <= codes[i + 2] <= 255:
                    self.color = xterm_color(codes[i + 2])
                i += 2
            elif code in (38, 48) and codes[i + 1:i + 2] == [2]:
                i += 4
            i += 1

    def _control(self, sequence):
        if not sequence.startswith("\x1b["):
            return
        parameters, command = sequence[2:-1], sequence[-1]
        if command == "m":
            self._sgr(parameters)
        elif command == "A" and (not parameters or parameters.isdecimal()):
            self.row = max(0, self.row - (int(parameters or 1) or 1))
            self.wrap = False
        elif command == "K" and parameters == "2":
            self.screen[self.row] = [None] * self.columns
            self.wrap = False
        elif command == "J" and parameters in ("", "0"):
            for column in range(self.column, self.columns):
                self._clear_cell(column)
            for row in range(self.row + 1, self.rows):
                self.screen[row] = [None] * self.columns
            self.wrap = False

    def feed(self, text, final=False):
        text = self.pending + text
        self.pending = ""
        position = 0
        while position < len(text):
            control = CONTROL.match(text, position)
            if control:
                self._control(control.group())
                position = control.end()
                continue
            char = text[position]
            if char == "\x1b":
                if not final:
                    self.pending = text[position:]
                break
            position += 1
            if char == "\r":
                self.column, self.wrap = 0, False
            elif char == "\n":
                self.wrap = False
                self._down()
            elif not unicodedata.category(char).startswith("C"):
                self._write(char)

    def lines(self, trim=True):
        result = [[cell for column, cell in enumerate(line)
                   if cell is not None and cell.column == column]
                  for line in self.history + self.screen]
        while trim and len(result) > 1 and not result[-1]:
            result.pop()
        return result


def terminal_lines(text, columns=COLUMNS, rows=40):
    terminal = Terminal(columns, rows)
    terminal.feed(text, final=True)
    return terminal.lines()


def plain_text(lines):
    result = []
    for line in lines:
        text, column = "", 0
        for glyph in line:
            text += " " * (glyph.column - column) + glyph.text
            column = glyph.column + glyph.width
        result.append(text.rstrip())
    return "\n".join(result)


def choose_font(explicit, candidates, label):
    if explicit:
        if not Path(explicit).is_file():
            raise ValueError(f"{label}がありません: {explicit}")
        return explicit
    for candidate in candidates:
        if Path(candidate).is_file():
            return candidate
    raise ValueError(f"{label}がありません。--font と --wide-font で指定してください。Ubuntu の日本語フォントは fonts-noto-cjk で入れられます。")


def render(lines, output, font_path=None, wide_font_path=None):
    from PIL import Image, ImageDraw, ImageFont

    font_path = choose_font(font_path, (
        "/System/Library/Fonts/Menlo.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    ), "等幅のフォント")
    wide_font_path = choose_font(wide_font_path, (
        "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    ), "日本語のフォント")
    font = ImageFont.truetype(font_path, FONT_SIZE)
    wide_font = ImageFont.truetype(wide_font_path, FONT_SIZE)
    cell = round(font.getlength("M"))
    ascent = max(font.getmetrics()[0], wide_font.getmetrics()[0])
    line_height = ascent + max(font.getmetrics()[1], wide_font.getmetrics()[1]) + 6
    padding = 12
    image = Image.new("RGB", (COLUMNS * cell + padding * 2, max(1, len(lines)) * line_height + padding * 2), BACKGROUND)
    draw = ImageDraw.Draw(image)
    for row, line in enumerate(lines):
        for glyph in line:
            face = wide_font if glyph.width == 2 else font
            x = padding + glyph.column * cell
            x += (glyph.width * cell - face.getlength(glyph.text)) / 2
            draw.text((x, padding + row * line_height + ascent), glyph.text, font=face,
                      fill=glyph.color, anchor="ls", stroke_width=int(glyph.bold), stroke_fill=glyph.color)
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output, format="PNG")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path, nargs="?", help="PNG または文字の保存先。--text では省略すると標準出力")
    parser.add_argument("--text", action="store_true", help="PNG を描かず、画面に残る文字を出す")
    parser.add_argument("--before", type=Path, help="答えを送る前の出力。この画面に続けて input を読み、問いの行から残す")
    parser.add_argument("--last-lines", type=int, help="折り返したあとに残す行数（確認の画面は 40）")
    parser.add_argument("--font", help="半角用の等幅フォントのパス")
    parser.add_argument("--wide-font", help="全角用の日本語フォントのパス")
    args = parser.parse_args()
    if args.last_lines is not None and args.last_lines < 1:
        parser.error("--last-lines は 1 以上にしてください")
    if not args.text and args.output is None:
        parser.error("PNG の保存先を指定してください")
    terminal = Terminal()
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    start_row = 0
    if args.before:
        terminal.feed(decoder.decode(args.before.read_bytes()))
        start_row = terminal.absolute_row
    terminal.feed(decoder.decode(args.input.read_bytes(), final=True), final=True)
    lines = terminal.lines(trim=not bool(args.last_lines))[start_row:]
    if args.last_lines:
        lines = lines[-args.last_lines:]
    if args.text:
        text = plain_text(lines) + "\n"
        if args.output:
            args.output.write_text(text, encoding="utf-8")
        else:
            print(text, end="")
        return
    try:
        render(lines, args.output, args.font, args.wide_font)
    except ModuleNotFoundError:
        parser.error("Pillow がありません。python -m pip install -r tests/release-screens-requirements.txt で入れてください")
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
