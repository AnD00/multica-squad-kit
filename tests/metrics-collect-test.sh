#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/metrics-collect.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
export METRICS_TEST_ROOT="$root"
cat >"$test_dir/bin/multica" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
work=$METRICS_TEST_WORK
if [[ $1 == version ]]; then
    python3 "$METRICS_TEST_ROOT/tests/cli-stub.py" metrics "$work" multica calls record -- "$@"
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$METRICS_TEST_ROOT/tests/fixtures/cli/METRICS-CAPTURE.json"
    exit
fi
case "$1 $2" in
    'issue list')
        key=metrics-issues
        offset=
        previous=
        for arg in "$@"; do [[ $previous != --offset ]] || offset=$arg; previous=$arg; done
        file="$work/issues-$offset.json"
        ;;
    'agent list') key=metrics-agents; file="$work/agents.json" ;;
    'issue comment')
        key=metrics-comments
        page=first
        for arg in "$@"; do [[ $arg != --before ]] || page=next; done
        file="$work/comments-$4-$page.json"
        ;;
    'issue timeline') key=issue-timeline; file="$work/timeline-$3.json" ;;
    'issue runs') key=metrics-runs; file="$work/runs-$3.json" ;;
    *) exit 97 ;;
esac
python3 "$METRICS_TEST_ROOT/tests/cli-stub.py" metrics "$work" multica calls emit "$key" "$file" -- "$@"
[[ ! -f $file.stderr ]] || cat "$file.stderr" >&2
if [[ -f $file.status ]]; then exit "$(cat "$file.status")"; fi
STUB
chmod +x "$test_dir/bin/multica"
PATH="$test_dir/bin:$PATH" python3 "$root/tests/metrics-collect-check.py" "$root" "$test_dir"
