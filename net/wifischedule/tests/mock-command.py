#!/usr/bin/python3
"""External command doubles for the public CLI in an isolated test filesystem."""
import json
from pathlib import Path
import sys

root = Path('/state')
state = json.loads((root / 'state.json').read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'events.jsonl').open('a') as stream:
    stream.write(json.dumps([command, *args]) + '\n')

if command == 'uci':
    if args[0] == '-X':
        args = args[1:]
    elif args == ['show', 'wifi_schedule']:
        raise AssertionError('anonymous entry lookup must use stable section identities')
    if args[0] == 'get':
        value = state['config'].get(args[1])
        if value is None:
            sys.exit(1)
        print(value)
    elif args[0] == 'show':
        if args[1] == 'wifi_schedule':
            for name in state['entries']:
                print(f'wifi_schedule.{name}=entry')
        elif args[1] == 'wireless':
            print('wireless.radio0=wifi-device\nwireless.radio1=wifi-device')
    elif args[0] == 'set':
        key, value = args[1].split('=', 1)
        state['config'][key] = value
    elif args[0] != 'commit':
        raise AssertionError(args)
elif command == 'date':
    assert args == ['+%w %H:%M'], args
    print(state['now'])
elif command == 'crontab':
    if args == ['-l']:
        if state.get('crontab_read_error'):
            sys.exit(1)
        try:
            print(Path('/etc/crontabs/root').read_text(), end='')
        except FileNotFoundError:
            sys.exit(1)
    else:
        assert args == ['-'], args
        state['crontab'] = sys.stdin.read()
        Path('/etc/crontabs/root').write_text(state['crontab'])
        state.pop('crontab_missing', None)
elif command == 'iwinfo':
    if not args:
        print('wlan0  ESSID: "fixture"')
    else:
        assert args == ['wlan0', 'assoclist'], args
        print('\n'.join(state['clients']))
elif command == 'lock':
    if args[0] != '-u' and state.get('lock_failure'):
        sys.exit(1)
elif command == 'wifi':
    if state.get('wifi_failure'):
        sys.exit(7)
elif command == 'service':
    assert args[0] == 'cron', args
    if args[1] == 'running':
        sys.exit(0 if state.get('cron_running', True) else 1)
    assert not state.get('cron_context'), 'a scheduled job must not replace its cron owner'
    assert args[1] == 'start', args
    state['cron_running'] = True
elif command != 'logger':
    raise AssertionError(command)

# Read-only commands must not overwrite concurrent crontab pipeline updates.
if (command == 'uci' and args[0] == 'set') or (command == 'crontab' and args == ['-']) or command == 'service':
    (root / 'state.json').write_text(json.dumps(state))
