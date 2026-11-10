#!/usr/bin/env python3
"""Real-terminal tests for the choice prompt. Linux only (uses a pty). Run: python3 tests/run-tty-tests.py

Each test presses real keys in a pseudo-terminal against the manager on the fake server from
fake-server.sh. Synthetic data only. Easy-RSA, systemd, ss and flock are still stand-ins.
"""
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
UP, DOWN, ENTER, ESC, CTRL_C, TAB = '\x1b[A', '\x1b[B', '\r', '\x1b', '\x03', '\t'
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')
results = []


def check(name, condition, context=''):
    results.append((name, bool(condition)))
    print(('  ok   ' if condition else '  FAIL ') + name)
    if not condition and context:
        print('\n'.join('    | ' + line for line in context.splitlines()[-30:]))


class Manager:
    """The manager in a pty on a fresh fake server."""

    def __init__(self, base, colors=False, args=()):
        self.env_dir = os.path.join(base, 'env')
        subprocess.run(['bash', os.path.join(HERE, 'fake-server.sh'), REPO, self.env_dir], check=True,
                       stdout=subprocess.DEVNULL)
        env = dict(os.environ, E=self.env_dir, SERVER_CONF=self.env_dir + '/server/server.conf',
                   STUB_LOG=self.env_dir + '/stub.log', EASYRSA_PKI=self.env_dir + '/pki',
                   PATH=self.env_dir + '/bin:' + os.environ['PATH'], TERM='xterm-256color', LC_ALL='C.UTF-8')
        env.pop('NO_COLOR', None)
        if not colors:
            env['NO_COLOR'] = '1'
        self.env = env
        self.master, slave = pty.openpty()
        self.slave = slave
        self.proc = subprocess.Popen(['bash', self.env_dir + '/manager.sh', *args], stdin=slave, stdout=slave,
                                     stderr=slave, env=env, start_new_session=True,
                                     preexec_fn=lambda: __import__('fcntl').ioctl(0, termios.TIOCSCTTY, 0))
        self.seen = ''

    def wait_for(self, text, timeout=30):
        """Reads until text appears in the new output; returns everything read so far."""
        end = time.time() + timeout
        start = len(self.seen)
        while time.time() < end:
            if text in self.seen[start:]:
                return True
            ready, _, _ = select.select([self.master], [], [], 0.1)
            if ready:
                try:
                    self.seen += os.read(self.master, 65536).decode('utf-8', 'replace')
                except OSError:
                    break
        return text in self.seen[start:]

    def drain(self, seconds=0.4):
        end = time.time() + seconds
        out = ''
        while time.time() < end:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if ready:
                try:
                    out += os.read(self.master, 65536).decode('utf-8', 'replace')
                except OSError:
                    break
        self.seen += out
        return out

    def press(self, *keys):
        for key in keys:
            os.write(self.master, key.encode())
            time.sleep(0.12)

    def echo_on(self):
        return bool(termios.tcgetattr(self.slave)[3] & termios.ECHO)

    def close(self):
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except OSError:
            pass
        self.proc.wait()
        os.close(self.master)
        os.close(self.slave)

    def index_state(self, name):
        with open(self.env_dir + '/pki/index.txt') as handle:
            return ''.join(line[0] for line in handle if line.rstrip('\n').endswith('/CN=' + name))

    def to_revoke_prompt(self):
        assert self.wait_for('Choose [0-9]'), self.seen[-400:]
        self.press('4', ENTER)
        assert self.wait_for('Number or name'), self.seen[-400:]
        self.press('alice', ENTER)
        assert self.wait_for('Esc: Cancel'), self.seen[-400:]
        self.drain()


def plain(text):
    return ANSI.sub('', text)


def scenario(name, function, **options):
    print(name)
    base = tempfile.mkdtemp(prefix='darban-tty.')
    manager = Manager(base, **options)
    try:
        function(manager)
    except AssertionError as error:
        check(name + ': did not reach the expected screen', False, str(error))
    finally:
        manager.close()
        shutil.rmtree(base, ignore_errors=True)


def default_is_no(m):
    m.to_revoke_prompt()
    screen = plain(m.seen)
    check('option 1 is the safe answer', '1  No, keep this client' in screen, screen)
    check('option 2 names the client', '2  Revoke alice' in screen, screen)
    m.press(ENTER)
    check('Enter alone keeps the client', m.wait_for('Cancelled; nothing changed'), m.seen)
    check('index unchanged', m.index_state('alice') == 'V')
    check('terminal echo restored', m.echo_on())
    check('cursor shown again', m.seen.rfind('\x1b[?25h') > m.seen.rfind('\x1b[?25l'))


def down_then_enter_revokes(m):
    m.to_revoke_prompt()
    m.press(DOWN)
    m.drain()
    check('moving alone does nothing', m.index_state('alice') == 'V')
    m.press(ENTER)
    check('Down then Enter revokes', m.wait_for('Marked revoked'), m.seen)
    check('the restart question defaults to No', m.wait_for('1  No, do not restart'), m.seen)
    m.press(ENTER)
    check('revocation completes', m.wait_for('alice is revoked.'), m.seen)
    check('index revoked', m.index_state('alice') == 'R')


def digit_two_moves_only(m):
    m.to_revoke_prompt()
    m.press('2')
    m.drain()
    check('pressing 2 alone does nothing', m.index_state('alice') == 'V')
    m.press('1', ENTER)
    check('1 moves back and Enter keeps the client', m.wait_for('Cancelled; nothing changed'), m.seen)
    check('index unchanged', m.index_state('alice') == 'V')


def persian_digit_works(m):
    m.to_revoke_prompt()
    m.press('۲', ENTER)
    check('Persian 2 selects option 2', m.wait_for('Marked revoked'), m.seen)


def up_returns_to_no(m):
    m.to_revoke_prompt()
    m.press(DOWN, UP, ENTER)
    check('Down, Up, Enter keeps the client', m.wait_for('Cancelled; nothing changed'), m.seen)
    check('index unchanged', m.index_state('alice') == 'V')


def application_mode_arrows(m):
    m.to_revoke_prompt()
    m.press('\x1bOB', ENTER)
    check('arrow keys in application mode work', m.wait_for('Marked revoked'), m.seen)


def esc_cancels(m):
    m.to_revoke_prompt()
    m.press(DOWN)
    time.sleep(0.2)
    m.press(ESC)
    check('Esc cancels even on option 2', m.wait_for('Cancelled; nothing changed'), m.seen)
    check('index unchanged', m.index_state('alice') == 'V')
    check('terminal echo restored', m.echo_on())


def ctrl_c_cancels_and_restores(m):
    m.to_revoke_prompt()
    m.press(DOWN)
    m.press(CTRL_C)
    check('Ctrl+C cancels', m.wait_for('Cancelled.'), m.seen)
    check('index unchanged', m.index_state('alice') == 'V')
    check('terminal echo restored', m.echo_on())
    check('cursor shown again', m.seen.rfind('\x1b[?25h') > m.seen.rfind('\x1b[?25l'))
    check('line wrap restored', m.seen.rfind('\x1b[?7h') > m.seen.rfind('\x1b[?7l'))
    m.press(ENTER)
    check('back at the menu', m.wait_for('Choose [0-9]'), m.seen)


def unknown_keys_ignored(m):
    m.to_revoke_prompt()
    m.press('x', 'y', ' ', '9', '\x1b[3~', '\x1b[1;5C')
    m.drain()
    check('other keys change nothing', m.index_state('alice') == 'V')
    m.press(ENTER)
    check('still on option 1', m.wait_for('Cancelled; nothing changed'), m.seen)


def typed_ahead_keys_do_not_answer(m):
    assert m.wait_for('Choose [0-9]')
    m.press('4', ENTER)
    assert m.wait_for('Number or name')
    # 2 and Enter arrive together with the name, before the question has been shown.
    os.write(m.master, ('alice' + ENTER + '2' + ENTER).encode())
    m.wait_for('Esc: Cancel')
    m.drain(1.0)
    check('type-ahead does not revoke', m.index_state('alice') == 'V', m.seen)


def hint_says_what_enter_does(m):
    m.to_revoke_prompt()
    check('the hint names the default', 'Enter: No, keep this client' in plain(m.seen), m.seen[-300:])
    check('the hint says how to choose otherwise', 'Another option: press' in plain(m.seen), m.seen[-300:])
    m.press(DOWN)
    check('the hint follows the selection', m.wait_for('Enter: Revoke alice'), m.seen[-300:])
    m.press(UP)
    check('and back again', m.wait_for('Enter: No, keep this client'), m.seen[-300:])


def colors_follow_the_risk(m):
    m.to_revoke_prompt()
    screen = m.seen
    check('No is green and selected', '\x1b[1m\x1b[32m\x1b[7m' in screen and 'No, keep this client' in screen, repr(screen[-500:]))
    check('Revoke is red', '\x1b[31mRevoke alice' in screen, repr(screen[-500:]))
    before = len(m.seen)
    m.press(DOWN)
    m.drain()
    screen = m.seen[before:]
    check('after moving, Revoke is selected in red', '\x1b[1m\x1b[31m\x1b[7m' in screen, repr(screen))


def rows_redraw_in_place(m):
    m.to_revoke_prompt()
    before = len(m.seen)
    m.press(DOWN, UP, DOWN)
    m.drain()
    screen = m.seen[before:]
    check('each key redraws in place', screen.count('\x1b[5A') >= 3, repr(screen))
    check('nothing else is printed while moving', 'Revoke which' not in screen, repr(screen))


def restart_needs_two_key_presses(m):
    assert m.wait_for('Choose [0-9]')
    m.press('8', ENTER)
    assert m.wait_for('Choose [0-3')
    m.press('3', ENTER)
    assert m.wait_for('Esc: Cancel')
    check('the option is yellow', '\x1b[33mRestart OpenVPN' in m.seen, repr(m.seen[-400:]))
    m.drain()
    m.press(ENTER)
    check('Enter alone does not restart', m.wait_for('Cancelled; nothing changed'), m.seen)
    with open(m.env_dir + '/stub.log') as handle:
        check('no restart was issued', 'systemctl restart' not in handle.read())
    m.press(ENTER)
    assert m.wait_for('Choose [0-3')
    m.press('3', ENTER)
    assert m.wait_for('Esc: Cancel')
    m.drain()
    m.press(DOWN, ENTER)
    check('Down then Enter restarts', m.wait_for('listening on UDP 1194'), m.seen)


def revoke_alice(m):
    m.to_revoke_prompt()
    m.press(DOWN, ENTER)
    assert m.wait_for('Marked revoked')
    assert m.wait_for('Esc: Cancel')
    m.drain()
    m.press(ENTER)
    assert m.wait_for('alice is revoked.')
    m.press(ENTER)
    assert m.wait_for('Choose [0-9]')


def list_offers_revoked_history(m):
    revoke_alice(m)
    m.press('2', ENTER)
    assert m.wait_for('Esc: Cancel')
    check('the question is asked', 'Show revoked clients too?' in plain(m.seen), m.seen)
    check('the first view hides the revoked client', 'REVOKED' not in plain(m.seen), m.seen)
    m.drain()
    m.press(DOWN, ENTER)
    check('choosing option 2 shows it', m.wait_for('REVOKED'), m.seen)
    m.press(ENTER)
    check('back at the menu', m.wait_for('Choose [0-9]'), m.seen)


def name_reuse_asks_when_server_settings_exist(m):
    revoke_alice(m)
    os.makedirs(m.env_dir + '/server/ccd')
    with open(m.env_dir + '/server/ccd/alice', 'w') as handle:
        handle.write('ifconfig-push 10.8.0.50 255.255.255.0\n')
    with open(m.env_dir + '/server/server.conf', 'a') as handle:
        handle.write('client-config-dir ccd\n')
    m.press('1', ENTER)
    assert m.wait_for('New client name')
    m.press('alice', ENTER)
    assert m.wait_for('Esc: Cancel')
    m.drain()
    m.press(ENTER)
    check('Enter alone goes back to the name', m.wait_for('New client name'), m.seen)
    check('nothing was issued', m.index_state('alice') == 'R')
    m.press('alice', ENTER)
    assert m.wait_for('Esc: Cancel')
    m.drain()
    m.press(DOWN, ENTER)
    check('Down then Enter issues the new certificate', m.wait_for('created and verified'), m.seen)
    check('old record revoked, new one valid', m.index_state('alice') == 'RV')


def share_chooser_moves_with_keys(m):
    assert m.wait_for('Choose [0-9]')
    m.press('5', ENTER)
    assert m.wait_for('Number or name')
    m.press('alice', ENTER)
    assert m.wait_for('Esc: Cancel')
    screen = plain(m.seen)
    check('it asks how to share', 'How will alice get this profile?' in screen, screen)
    check('with two answers', '2  Keep it on the server' in screen and '3  ' not in screen.split('How will alice')[-1], screen)
    m.drain()
    m.press(DOWN, ENTER)
    assert m.wait_for('Esc: Cancel')
    check('it asks about a password', 'Lock the private key' in plain(m.seen), m.seen)
    m.drain()
    m.press(ENTER)
    check('it shows where the file is', m.wait_for('Kept on the server'), m.seen)
    screen = plain(m.seen)
    check('with the Windows command', 'USERPROFILE' in screen, screen)
    check('the macOS and Linux command', '~/Downloads/' in screen, screen)
    check('and the sftp address', 'sftp://' in screen, screen)


def share_esc_means_later(m):
    assert m.wait_for('Choose [0-9]')
    m.press('5', ENTER)
    assert m.wait_for('Number or name')
    m.press('alice', ENTER)
    assert m.wait_for('Esc: Cancel')
    m.drain()
    time.sleep(0.2)
    m.press(ESC)
    check('Esc keeps the file for later', m.wait_for('Kept on the server'), m.seen)
    check('terminal echo restored', m.echo_on())


def ctrl_c_at_main_menu_exits(m):
    assert m.wait_for('Choose [0-9]')
    m.drain()
    m.press(CTRL_C)
    time.sleep(0.5)
    check('Ctrl+C at the main menu exits at once', m.proc.poll() is not None, m.seen[-300:])


for function, options in [
    (default_is_no, {}), (down_then_enter_revokes, {}), (digit_two_moves_only, {}), (persian_digit_works, {}),
    (up_returns_to_no, {}), (application_mode_arrows, {}), (esc_cancels, {}), (ctrl_c_cancels_and_restores, {}),
    (unknown_keys_ignored, {}), (typed_ahead_keys_do_not_answer, {}), (colors_follow_the_risk, {'colors': True}),
    (hint_says_what_enter_does, {}), (rows_redraw_in_place, {}), (restart_needs_two_key_presses, {'colors': True}), (list_offers_revoked_history, {}),
    (name_reuse_asks_when_server_settings_exist, {}),
    (share_chooser_moves_with_keys, {}), (share_esc_means_later, {}), (ctrl_c_at_main_menu_exits, {}),
]:
    scenario(function.__name__, function, **options)

failed = [name for name, passed in results if not passed]
print(f'\n{len(results) - len(failed)} passed, {len(failed)} failed')
sys.exit(1 if failed else 0)
