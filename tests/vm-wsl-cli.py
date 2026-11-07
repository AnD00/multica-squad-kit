"""Offline wsl.exe. Every install path must stay in this test's directory."""
import json
import os
import sys
from pathlib import Path

base = Path(sys.argv[1])
args = sys.argv[2:]
state_file = base / 'state.json'
state = json.loads(state_file.read_text())
with (base / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(dict(args=args, utf8=os.environ.get('WSL_UTF8'), wslenv=os.environ.get('WSLENV'))) + '\n')
fail = state.get('fail')
if fail == args[0] and args[0] != '--install':
    sys.exit('intentional WSL failure')

def save():
    state_file.write_text(json.dumps(state))


if args == ['--version']:
    print(state.get('version', 'WSL バージョン: 2.6.1.0\nカーネル バージョン: 6.6.0'))
elif args[:2] == ['--list', '--quiet']:
    assert args[2:] in ([], ['--running']), args
    print('\n'.join(state['running'] if '--running' in args else state['names']))
elif args[0] == '--install':
    assert args[1:3] == ['Ubuntu-24.04', '--name'] and args[4] == '--location', args
    assert args[6:] == ['--no-launch', '--version', '2'], args
    if fail == '--install':
        sys.exit('intentional installation failure')
    name, location = args[3], Path(args[5])
    assert location.is_relative_to(base), location
    location.mkdir(parents=True)
    (location / 'ext4.vhdx').write_text('test disk')
    if not state.get('no_registration'):
        state['names'].append(name)
        state['configured'] = False
    if state.get('partial_install'):
        save()
        sys.exit('intentional partial installation failure')
elif args[0] in ('--terminate', '--unregister'):
    assert len(args) == 2 and args[1] in state['names'], args
    state['running'] = [name for name in state['running'] if name != args[1]]
    if args[0] == '--unregister':
        state['names'].remove(args[1])
elif args[0] == '-d':
    name = args[1]
    assert name in state['names'] and '--exec' in args, args
    if name not in state['running']:
        state['running'].append(name)
    save()
    command = args[args.index('--exec') + 1:]
    root = args[2:5] == ['-u', 'root', '--exec']
    if command[:2] == ['wslpath', '-au']:
        assert root and len(command) == 3 and Path(command[2]).is_dir(), args
        print('/mnt/c/source kit with \'single\' and "quotes"/guest')
    elif command[0] == 'bash' and command[1].endswith('/provision.sh'):
        assert root and command[2] == 'wsl' and len(command) == 4, args
        assert command[1] == '/mnt/c/source kit with \'single\' and "quotes"/guest/provision.sh'
        if fail == 'provision':
            sys.exit('intentional provision failure')
        state['configured'] = True
        state['user'] = command[3]
    elif command == ['bash', '/usr/local/lib/multica-squad-vm/verify.sh', 'wsl']:
        assert not root and state.get('configured', True), args
        if fail == 'verify':
            sys.exit('intentional verify failure')
        print('PASS guest verification')
    elif command[:2] == ['bash', '-lc']:
        assert not root and 'multica daemon status --output json' in command[2], args
        status = state.get('daemon', dict(status='running', active_task_count=0))
        if state.get('cli_missing'):
            status = dict(status='not_running')
        print(status if isinstance(status, str) else json.dumps(status))
        save()
        sys.exit(state.get('status_code', 0))
    elif command[:2] == ['bash', '-c'] and 'if [ -f /var/lib/multica-squad-vm/keepalive.json ]' in command[2]:
        assert root, args
        if fail == 'pid-read':
            sys.exit('intentional keepalive read failure')
        if state.get('record') is not None:
            print(json.dumps(state['record']))
    elif command[:2] == ['bash', '-c'] and 'mktemp /var/lib/multica-squad-vm/keepalive.' in command[2]:
        assert root and command[-2] == '--' and 'umask 077' in command[2], args
        if fail == 'pid-write':
            sys.exit('intentional keepalive write failure')
        state['record'] = json.loads(command[-1])
    else:
        assert root and command == ['rm', '-f', '--', '/var/lib/multica-squad-vm/keepalive.json'], args
        state.pop('record', None)
else:
    raise AssertionError(args)
save()
