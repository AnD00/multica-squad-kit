# セッションに属するプロセスへシグナルを送る。tests/run-one.sh と tests/run.sh が、テストを止めるために呼ぶ。
#
# 使い方: python3 -I tests/stop-session.py <セッションの ID> TERM|KILL|ALIVE
# TERM と KILL は、セッションの全プロセスにそのシグナルを送る。ALIVE は何も送らない。
# どれも、セッションにプロセスが 1 つでもあれば 0、なければ 1 で終わる。
# 終わってまだ回収されていないプロセス（ゾンビ）は、残っているものに数えない。
#
# pkill -s は macOS にないので、全プロセスの一覧から os.getsid() でセッションを引く。
# テストが別のプロセスグループに移した子も、同じセッションに残るので止められる。
import os
import signal
import subprocess
import sys

session = int(sys.argv[1])
mode = sys.argv[2]
sig = None if mode == 'ALIVE' else getattr(signal, 'SIG' + mode)
found = False
listing = subprocess.run(['ps', '-A', '-o', 'pid=,stat='], capture_output=True, text=True).stdout
for line in listing.splitlines():
    fields = line.split()
    if len(fields) < 2 or fields[1].startswith('Z'):
        continue
    pid = int(fields[0])
    try:
        if os.getsid(pid) != session:
            continue
        found = True
        if sig is not None:
            os.kill(pid, sig)
    except OSError:
        pass
sys.exit(0 if found else 1)
