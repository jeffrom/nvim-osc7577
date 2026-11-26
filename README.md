# neovim-osc7577

Nvim support for the [OSC 7577 Program Resume](https://www.superlogical.com/rex/docs/build/program-resume)
protocol (draft rev 0.5). When the terminal restarts (crash, reboot, closed window), it can
relaunch each Nvim with the same windows, tabs and buffers.

Requires Nvim 0.12+ (`nvim_ui_send()`). It does nothing unless the terminal sets `OSC7577_TOKEN`.

## Install

The plugin sets itself up when it loads, so no `setup()` call is needed. Don't lazy-load it
on a command or a key: it has to load at startup to report and to save the session.

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'jeffrom/nvim-osc7577', lazy = false }
-- with options (lazy.nvim passes them to setup()):
{ 'jeffrom/nvim-osc7577', lazy = false, opts = { debounce_ms = 500 } }
```

`vim.pack` (Nvim 0.12+):

```lua
vim.pack.add({ 'https://github.com/jeffrom/nvim-osc7577' })
```

[mini.deps](https://github.com/echasnovski/mini.deps):

```lua
MiniDeps.add({ source = 'jeffrom/nvim-osc7577' })
```

[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'jeffrom/nvim-osc7577'
```

A local checkout:

```lua
vim.opt.rtp:append('~/repos/nvim-osc7577')
```

### Let the terminal trust it

Getting reports isn't enough. A terminal resumes only commands it trusts, and Rex
ships trust rules only for `claude`, `codex` and `opencode`. Without a rule, Rex keeps the
record but never runs it, and its server log says
`program resume record not trusted ... reason=no_rule`. Add this to `~/.config/rex/init.lua`:

```lua
-- Program Resume (OSC 7577): trust nvim-osc7577's resume command, `nvim -S <session file>`.
local state = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
rex.set("resume.trust", {
  nvim = {
    command = { "nvim", "-S", rex.match.under(state .. "/nvim/osc7577") },
    flags = { ["-S"] = { "drop", values = 1 } },
  },
})
```

Then run `rex config reload`. `rex config check` should list the `nvim` rule. If you change
`dir` (or `NVIM_APPNAME`), change the `rex.match.under()` path to match it. If `cmd` is an
absolute path, use that path in place of `"nvim"`.

Optional config, set before the plugin loads or passed to `setup()`:

```lua
vim.g.osc7577 = {
  dir = vim.fn.stdpath('state') .. '/osc7577', -- session files, one per instance
  debounce_ms = 1000,  -- delay before saving after a layout change
  prune_days = 30,     -- delete session files untouched this long
  cmd = nil,           -- argv[0]; default "nvim" if that is this binary, else v:progpath
}
```

Run `:checkhealth osc7577` to see what it's reporting.

## What it does

- **On startup:** takes `OSC7577_TOKEN` out of the environment, so `:terminal`, jobs and
  `system()` never see it. Then it creates `<dir>/<time>-<pid>.vim` with mode 0600, saves a
  session into it, and reports this resume command:
  `nvim -S <file>` plus `cwd`. The session file is a plain argument so that a terminal's
  trust rule can match it by directory.
- **While running:** re-saves the session (`:mksession!`, debounced) whenever windows,
  tabs or buffers change, on `CursorHold`, and right away on `FocusLost` and `VimSuspend`.
  It runs under `noautocmd` and restores `v:this_session`, so a session plugin you already
  use is unaffected. It reports again on `DirChanged`, on `VimResume`, and when a new TUI
  attaches.
- **On a deliberate quit** (`:q`, `:qa`, `ZZ`, `:cq`): sends `clear=1` and deletes the file.
- **On terminal loss** (window closed, SIGHUP, the TUI killed): keeps the record and the
  file. That is the case the record exists for.
- **When resumed:** it notices `v:this_session` points into `dir`, keeps using that file,
  and reports again from the new process.
- **On `:restart`:** keeps the record. The new server reports its own file after 1 second,
  because `time` must strictly increase for the same TUI pid.

## Design notes

- **Owner pid.** The pty belongs to the TUI process, not to the `nvim --embed` server where
  plugins run. The plugin reports the TUI's pid (the server's parent, checked against the
  `pid` the TUI sends in `nvim_set_client_info`). It reports only when exactly one
  `stdout_tty` UI is attached over stdio. It never reports for headless instances, GUIs,
  `--remote-ui`, or several attached UIs, because the token belongs to the terminal this
  server was started in.
- **Output path.** Reports go through `nvim_ui_send()`, which the TUI writes to the host
  terminal. They do not use `io.stdout` or `/dev/tty`.
- **How a deliberate quit is detected.** Closing the terminal also runs `VimLeavePre`, with
  `v:exitreason == "quit"` (via `preserve_exit()` → `getout()`). The difference is that the
  TUI channel is already gone by then. So "deliberate" means our TUI is still attached in
  `VimLeavePre`.
- **Rejected reports.** A rejected report wipes the record, so argv and cwd are validated
  first: no control characters, `argv[0]` a bare name or an absolute path, at most 64
  elements, and a sequence of at most 2048 bytes. If they fail, it sends `clear` instead.

## Caveats

- Resuming after a crash restores files from disk. Unsaved changes are in swap files, so you
  get Nvim's usual `ATTENTION`/recover prompt. That's intentional.
- If the session file is gone when Nvim is resumed, `-S` shows `E484: Can't open file` and
  Nvim starts empty.
- `NVIM_APPNAME` and other environment variables aren't passed to the resumed process (the
  protocol has no env field). The session path is absolute, so it is still found.
- What the session restores depends on your `'sessionoptions'`. With `terminal` in it,
  `:terminal` buffers are restarted.

## Tests

```sh
nvim -l tests/unit.lua         # protocol encoding, spec mac test vector, validation
python3 tests/pty_test.py      # real TUI in a pty: report, clear, terminal loss, resume
```
