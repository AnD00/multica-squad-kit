"""端末の出力を 100 桁で折り返し、色と全角の幅を保って PNG に描く。

描画だけが Pillow を使う。出力の読み取りは標準ライブラリだけなので、CI でも確かめられる。
"""
import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import unicodedata


COLUMNS = 100
FONT_SIZE = 20
BACKGROUND = (24, 24, 24)
FOREGROUND = (229, 229, 229)
# CSI、OSC、その他の ESC の列。SGR 以外は画面の文字として描かない。
CONTROL = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[ -/]*[@-~])")


def xterm_color(index):
    """xterm の 16 色、6×6×6 の色、24 段階の灰色。"""
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


def terminal_lines(text, columns=COLUMNS):
    """SGR の状態を文字ごとに残し、全角は 2 桁として折り返す。"""
    lines = [[]]
    column = 0
    color, bold = FOREGROUND, False
    position = 0
    while position < len(text):
        control = CONTROL.match(text, position)
        if control:
            sequence = control.group()
            if sequence.startswith("\x1b[") and sequence.endswith("m"):
                values = sequence[2:-1].split(";")
                if all(not value or value.isdecimal() for value in values):
                    codes = [int(value or 0) for value in values]
                    i = 0
                    while i < len(codes):
                        code = codes[i]
                        if code == 0:
                            color, bold = FOREGROUND, False
                        elif code == 1:
                            bold = True
                        elif code == 22:
                            bold = False
                        elif code == 39:
                            color = FOREGROUND
                        elif code in (38, 48) and codes[i + 1:i + 2] == [5] and i + 2 < len(codes):
                            if code == 38 and 0 <= codes[i + 2] <= 255:
                                color = xterm_color(codes[i + 2])
                            i += 2
                        elif code in (38, 48) and codes[i + 1:i + 2] == [2]:
                            # 対象外の RGB 指定を、戻す指定の 0 と読み違えない。
                            i += 4
                        i += 1
            position = control.end()
            continue
        char = text[position]
        position += 1
        if char == "\n":
            lines.append([])
            column = 0
            continue
        if unicodedata.category(char).startswith("C"):
            continue
        width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        if column + width > columns:
            lines.append([])
            column = 0
        lines[-1].append(Glyph(char, column, width, color, bold))
        column += width
    # 改行で終わる出力の、最後の空行は次の入力位置であり、描く行には含めない。
    if len(lines) > 1 and not lines[-1]:
        lines.pop()
    return lines


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
    parser.add_argument("output", type=Path)
    parser.add_argument("--last-lines", type=int, help="折り返したあとに残す行数（確認の画面は 40）")
    parser.add_argument("--font", help="半角用の等幅フォントのパス")
    parser.add_argument("--wide-font", help="全角用の日本語フォントのパス")
    args = parser.parse_args()
    if args.last_lines is not None and args.last_lines < 1:
        parser.error("--last-lines は 1 以上にしてください")
    lines = terminal_lines(args.input.read_bytes().decode("utf-8", errors="replace"))
    if args.last_lines:
        lines = lines[-args.last_lines:]
    try:
        render(lines, args.output, args.font, args.wide_font)
    except ModuleNotFoundError:
        parser.error("Pillow がありません。python -m pip install -r tests/release-screens-requirements.txt で入れてください")
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
