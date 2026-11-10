"""Check that each paragraph line holds one sentence and ends with the two-space line break."""
import re
import sys

OPENERS, CLOSERS = '「（([', '」）)]'


def count_sentences(line):
    depth, in_code, count = 0, False, 0
    for ch in line:
        if ch == '`':
            in_code = not in_code
        elif in_code:
            continue
        elif ch in OPENERS:
            depth += 1
        elif ch in CLOSERS:
            depth = max(0, depth - 1)
        elif ch == '。' and depth == 0:
            count += 1
    return count


def check(path):
    errors, paragraph, in_fence = [], [], False

    def flush():
        for i, (number, line) in enumerate(paragraph):
            where = f'{path}:{number}'
            if i == len(paragraph) - 1:
                if line.endswith(' '):
                    errors.append(f'{where}: 段落の最後の行は、末尾に空白を付けない')
            elif not line.endswith('  ') or line.endswith('   '):
                errors.append(f'{where}: 段落の途中の行は、末尾に半角空白 2 つを付ける')
            if count_sentences(line) > 1:
                errors.append(f'{where}: 段落は 1 行に 1 文にする')
        paragraph.clear()

    with open(path, encoding='utf-8') as source:
        for number, line in enumerate(source.read().split('\n'), 1):
            stripped = line.strip()
            if stripped.startswith('```'):
                in_fence = not in_fence
                flush()
                continue
            # 見出し・箇条書き・番号付きの項目・表・引用・HTML・字下げは段落に数えない。
            if (in_fence or not stripped or line[:1] in ' \t'
                    or stripped.startswith(('#', '|', '- ', '* ', '>', '<'))
                    or re.match(r'\d+\. ', stripped)):
                flush()
                continue
            paragraph.append((number, line))
    flush()
    return errors


errors = [error for path in sys.argv[1:] for error in check(path)]
for error in errors:
    print(f'FAIL doc-lines: {error}', file=sys.stderr)
sys.exit(1 if errors else 0)
