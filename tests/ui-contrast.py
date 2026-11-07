"""ui_spec の各色が、黒と白の背景のどちらに対してもコントラスト比 3.5 以上かを確かめる。

使い方: ui-contrast.py <manual.md>。標準入力から「種類 太字 色番号」の行を読む。
manual.md の「表示の色と印」の表に、同じ番号と色コードがあることも確かめる。
"""
import sys

MINIMUM = 3.5
LEVELS = (0, 95, 135, 175, 215, 255)


def rgb(number):
    # xterm の 256 色。16〜231 は 6x6x6 の立方体、232〜255 は灰の階調。
    if 16 <= number <= 231:
        n = number - 16
        return LEVELS[n // 36], LEVELS[n // 6 % 6], LEVELS[n % 6]
    if 232 <= number <= 255:
        level = 8 + 10 * (number - 232)
        return level, level, level
    raise SystemExit(f"256 色の番号が範囲外（基本の 16 色は使わない）: {number}")


def luminance(color):
    def channel(value):
        value /= 255
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(v) for v in color)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


manual = open(sys.argv[1], encoding="utf-8").read()
checked = 0
failed = False
for line in sys.stdin:
    kind, _bold, color = line.split()
    if color == "-":
        continue
    number = int(color)
    value = rgb(number)
    black = ratio(value, (0, 0, 0))
    white = ratio(value, (255, 255, 255))
    code = "#%02x%02x%02x" % value
    print(f"{kind}: {number} {code} 黒 {black:.2f} 白 {white:.2f}")
    if black < MINIMUM or white < MINIMUM:
        print(f"  コントラスト比が {MINIMUM} 未満", file=sys.stderr)
        failed = True
    if f"（{number}、`{code}`）" not in manual:
        print(f"  manual.md の表に（{number}、`{code}`）がない", file=sys.stderr)
        failed = True
    checked += 1
if checked == 0 or failed:
    sys.exit(1)
