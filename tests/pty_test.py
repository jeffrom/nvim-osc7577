#!/usr/bin/env python3
"""End-to-end test: run a real Nvim TUI in a pty with OSC7577_TOKEN set and check the
OSC 7577 reports it writes to the terminal.

Run: python3 tests/pty_test.py [path/to/nvim]
"""

import base64
import hashlib
import os
import pty
import re
import select
import shutil
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NVIM = sys.argv[1] if len(sys.argv) > 1 else shutil.which("nvim")
TOKEN = "test-token-0123456789abcdef"
SEQ = re.compile(rb"\x1b\]7577;([^\x07\x1b]*)(?:\x1b\\|\x07)")


def parse(body):
    pre, mac = body.rsplit(":mac=", 1)
    assert hashlib.sha256((pre + ":" + TOKEN).encode()).hexdigest() == mac, "bad mac"
    kv = dict(p.split("=", 1) for p in pre.split(":"))
    if "argv" in kv:
        kv["argv"] = [base64.b64decode(a).decode() for a in kv["argv"].split(",")]
    if "cwd" in kv:
        kv["cwd"] = base64.b64decode(kv["cwd"]).decode()
    return kv


def run(state_home, keys, extra_args=(), wait=2.0):
    env = dict(os.environ, OSC7577_TOKEN=TOKEN, XDG_STATE_HOME=state_home, TERM="xterm-256color")
    argv = [NVIM, "--clean", "--cmd", f"set rtp^={ROOT}", "-c", "set updatecount=0", *extra_args]
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(NVIM, argv, env)
    out = b""

    def pump(secs):
        nonlocal out
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    return False
        return True

    pump(wait)
    for k in keys:
        if isinstance(k, (int, float)):
            pump(k)
        else:
            os.write(fd, k.encode())
            pump(0.3)
    pump(1.5)
    alive = os.waitpid(pid, os.WNOHANG)[0] == 0
    if alive:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    return pid, [parse(b.decode()) for b in SEQ.findall(out)], alive


def main():
    failures = []

    def check(cond, what):
        print(("ok   " if cond else "FAIL ") + what)
        if not cond:
            failures.append(what)

    with tempfile.TemporaryDirectory() as state:
        sdir = os.path.join(state, "nvim", "osc7577")

        # 1. Start, open a file, quit deliberately: report then clear, file removed.
        f = os.path.join(state, "hello.txt")
        open(f, "w").write("hi\n")
        tui_pid, reports, alive = run(state, [f":e {f}\r", 1.5, ":qa!\r"])
        check(not alive, "nvim exited")
        check(len(reports) >= 2, f"got report + clear ({len(reports)} sequences)")
        if reports:
            r = reports[0]
            check(int(r["pid"]) == tui_pid, "pid is the TUI process")
            check(r["argv"][0] == "nvim" or r["argv"][0].startswith("/"), f"argv[0] = {r['argv'][0]}")
            check(len(r["argv"]) == 3 and r["argv"][1] == "-S" and r["argv"][2].startswith(sdir + "/"), "argv shape")
            check(r.get("cwd", "").startswith("/"), "cwd absolute")
            check(reports[-1].get("clear") == "1", "last sequence is clear")
            times = [int(x["time"]) for x in reports]
            check(times == sorted(times) and len(set(times)) == len(times), "times strictly increase")
        check(not os.path.exists(sdir) or os.listdir(sdir) == [], "session file removed on quit")

        # 2. Lose the terminal (SIGKILL the TUI ~= terminal gone): no clear, file stays.
        tui_pid, reports, alive = run(state, [f":e {f}\r", 2.0])
        check(alive, "nvim still running before kill")
        check(reports and all(r.get("clear") is None for r in reports), "no clear on terminal loss")
        time.sleep(1.0)  # let the orphaned server notice and exit
        files = os.listdir(sdir) if os.path.isdir(sdir) else []
        check(len(files) == 1, f"session file kept ({files})")
        if files:
            path = os.path.join(sdir, files[0])
            check(oct(os.stat(path).st_mode & 0o777) == "0o600", "session file is 0600")
            check(f in open(path).read(), "session mentions the open file")

            # 3. Resume with the reported argv: reloads the buffer, adopts the same file.
            argv = reports[0]["argv"]
            _, reports2, _ = run(state, [1.5, ":qa!\r"], extra_args=argv[1:])
            check(reports2 and reports2[0]["argv"] == argv, f"resumed nvim reports the same command ({reports2 and reports2[0]['argv']} vs {argv})")

    if failures:
        print(f"{len(failures)} failed")
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
