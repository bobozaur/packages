#!/usr/bin/python3
"""Run with the product CLI/helper and command doubles mounted in a container.

The test executes the unchanged public CLI. /sbin/wifi is a required command
double; no test may control real radios, crontabs, UCI configuration or locks.
"""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path('/state')
SCRIPT = '/usr/bin/wifi_schedule.sh'
MOCK = Path('/tests/mock-command.py')
assert Path('/sbin/wifi').read_bytes() == MOCK.read_bytes(), 'isolated mock required'
(ROOT / 'bin').mkdir(exist_ok=True)
for command in ('uci', 'date', 'crontab', 'iwinfo', 'lock', 'service', 'logger'):
    path = ROOT / 'bin' / command
    if not path.exists():
        path.symlink_to(MOCK)
env = dict(os.environ, PATH='/state/bin:/usr/bin:/bin')


def fixture(enabled='1', now='1 23:00', clients=False):
    return {'entries': [], 'now': now, 'clients': ['02:00:00:00:00:01'] if clients else [],
            'crontab': '', 'config': {'wifi_schedule.@global[0].logging': '0',
            'wifi_schedule.@global[0].enabled': enabled,
            'wifi_schedule.@global[0].unload_modules': '0',
            'wifi_schedule.@global[0].recheck_interval': '10'}}


def entry(state, name='night', days='Monday', start='22:0', stop='6:05', force='0', enabled='1'):
    state['entries'].append(name)
    state['config'][f'wifi_schedule.{name}'] = 'entry'
    for key, value in dict(daysofweek=days, starttime=start, stoptime=stop,
                           forcewifidown=force, enabled=enabled).items():
        state['config'][f'wifi_schedule.{name}.{key}'] = value


def invoke(state, *args, status=0):
    table = Path('/etc/crontabs/root')
    if state.get('crontab_missing'):
        table.unlink(missing_ok=True)
    else:
        table.write_text(state['crontab'])
    (ROOT / 'state.json').write_text(json.dumps(state))
    (ROOT / 'events.jsonl').write_text('')
    result = subprocess.run(['/bin/bash', SCRIPT, *args], env=env, capture_output=True, text=True)
    assert result.returncode == status, (args, result.returncode, result.stderr)
    events = [json.loads(line) for line in (ROOT / 'events.jsonl').read_text().splitlines()]
    unlocks = [x for x in events if x[:2] == ['lock', '-u']]
    assert len(unlocks) == (0 if state.get('lock_failure') else 1), events
    assert all(x == ['uci', 'commit', 'wireless'] for x in events if x[:2] == ['uci', 'commit'])
    return json.loads((ROOT / 'state.json').read_text()), events


def changed(events):
    return any(x[0] == 'wifi' or x[:2] == ['uci', 'set'] for x in events)


# Cron generation and startup agree on overnight/week rollover and H:M input.
s = fixture(now='1 1:00'); entry(s, days='Sunday', start='22:0', stop='6:05')
s['crontab'] = '# retained comment\nMAILTO=local\n* * * * * echo unrelated\n'
s, events = invoke(s, 'cron')
assert f'0 22 * * 0 {SCRIPT} start entry:night\n' in s['crontab']
assert f'5 6 * * 1 {SCRIPT} stop entry:night\n' in s['crontab']
assert s['crontab'].startswith('# retained comment\nMAILTO=local\n')
assert s['config']['wireless.radio0.disabled'] == '0'

s = fixture(now='1 6:05'); entry(s, start='6:5', stop='06:05', force='1')
s, events = invoke(s, 'cron')
assert f'5 6 * * 1 {SCRIPT} forcestop entry:night\n' in s['crontab']
assert f'{SCRIPT} start entry:night' not in s['crontab']
assert s['config']['wireless.radio0.disabled'] == '1'

for case in ('global-disabled', 'entry-disabled', 'entry-deleted'):
    s = fixture(enabled='0' if case == 'global-disabled' else '1')
    if case != 'entry-deleted':
        entry(s, enabled='0' if case == 'entry-disabled' else '1')
    s['crontab'] = f'*/10 * * * * {SCRIPT} recheck entry:night\n'
    s, events = invoke(s, 'start', 'entry:night')
    assert not changed(events) and 'recheck entry:night' not in s['crontab'], case

# Current force/union policy supersedes stale cron verbs and pending retries.
s = fixture(now='1 12:00', clients=True); entry(s)
s, events = invoke(s, 'forcestop', 'entry:night')
assert not changed(events) and 'recheck entry:night' in s['crontab']
s['config']['wifi_schedule.night.forcewifidown'] = '1'
s, events = invoke(s, 'recheck', 'entry:night')
assert changed(events) and 'recheck' not in s['crontab']

s = fixture(now='1 12:00', clients=True); entry(s, force='1')
entry(s, 'day', start='8:00', stop='18:00')
s, events = invoke(s, 'forcestop', 'entry:night')
assert not changed(events) and 'recheck' not in s['crontab']

# A scheduled deferral cannot replace an independent pending manual stop.
s = fixture(now='1 12:00', clients=True); entry(s, name='cfg001abc')
s, events = invoke(s, 'stop', 'manual')
s, events = invoke(s, 'stop', 'entry:cfg001abc')
assert 'recheck manual' in s['crontab'] and 'recheck entry:cfg001abc' in s['crontab']
s['config']['wifi_schedule.@global[0].enabled'] = '0'
s, events = invoke(s, 'recheck', 'entry:cfg001abc')
assert 'recheck manual' in s['crontab'] and 'recheck entry:cfg001abc' not in s['crontab']
s['clients'] = []
s, events = invoke(s, 'recheck', 'manual')
assert changed(events) and s['config']['wireless.radio0.disabled'] == '1'
s, events = invoke(s, 'start', 'manual')
assert s['config']['wireless.radio0.disabled'] == '0'

s = fixture(enabled='0'); entry(s, name='cfg001abc')
s['crontab'] = (f'*/10 * * * * {SCRIPT} recheck\n'
                f'*/10 * * * * /bin/nice -n 19 {SCRIPT} recheck manual\n')
s, events = invoke(s, 'recheck')
assert not changed(events) and s['crontab'].count('recheck') == 1
assert 'recheck manual' in s['crontab']

s = fixture(); entry(s, name='cfg001abc', days='Sunday')
s['crontab'] = (f'0 22 * * Sun {SCRIPT} start @entry[0]\n'
                f'*/10 * * * * {SCRIPT} recheck\n'
                f'*/10 * * * * {SCRIPT} recheck entry:cfg001abc\n'
                f'*/10 * * * * /bin/nice -n 19 {SCRIPT} recheck manual\n')
s, events = invoke(s, 'cron-only')
assert not changed(events) and '@entry[' not in s['crontab']
assert f'0 22 * * 0 {SCRIPT} start entry:cfg001abc' in s['crontab']
assert 'recheck entry:cfg001abc' in s['crontab'] and 'recheck manual' in s['crontab']
assert s['crontab'].count('recheck') == 2
s, events = invoke(s, 'forcestop', '@entry[0]')
assert not changed(events)

# A user entry named manual is still a schedule-owned request.
s = fixture(now='1 12:00', clients=True); entry(s, name='manual')
s, events = invoke(s, 'stop', 'manual')
s, events = invoke(s, 'stop', 'entry:manual')
assert 'recheck manual' in s['crontab'] and 'recheck entry:manual' in s['crontab']
s['config']['wifi_schedule.@global[0].enabled'] = '0'
s, events = invoke(s, 'forcestop', 'entry:manual')
assert not changed(events) and 'recheck manual' in s['crontab']
assert 'recheck entry:manual' not in s['crontab']

s = fixture(); s['lock_failure'] = True
_, events = invoke(s, 'start', 'manual', status=1)
assert not changed(events)
for action in ('start', 'stop', 'forcestop'):
    s = fixture(); s['wifi_failure'] = True
    invoke(s, action, 'manual', status=7)

# A job updates cron's files without restarting or replacing its parent daemon.
for action, now in [('start', '1 23:00'), ('forcestop', '1 12:00')]:
    s = fixture(now=now); entry(s, force='1'); s['cron_context'] = True
    _, events = invoke(s, action, 'entry:night')
    assert changed(events)
s = fixture(enabled='0'); s['cron_running'] = False
s, events = invoke(s, 'cron-only')
assert s['cron_running'] and ['service', 'cron', 'start'] in events

s = fixture(); entry(s); s['crontab_missing'] = True
s, events = invoke(s, 'cron-only')
assert 'start entry:night' in s['crontab']
s = fixture(); entry(s); s['crontab_read_error'] = True
s['crontab'] = '* * * * * echo retained\n'
s, events = invoke(s, 'cron-only', status=1)
assert s['crontab'] == '* * * * * echo retained\n'
assert ['crontab', '-'] not in events and not changed(events)
print('public scheduling CLI boundary cases passed')
