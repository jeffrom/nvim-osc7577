--- OSC 7577 "Program Resume" for Nvim.
---
--- Reports a resume command (`nvim -c "silent! source <session>"`) to the host terminal so it
--- can relaunch this Nvim, with its windows and buffers, after the terminal restarts.
---
--- Spec: https://www.superlogical.com/rex/docs/build/program-resume
local M = {}

local uv = vim.uv or vim.loop
local api = vim.api

--- Minimum sequence length every terminal must accept, prefix and terminator included.
local MAX_SEQ = 2048
local PREFIX = '\27]7577;'
local ST = '\27\\'

local defaults = {
  --- Where session files live (one per running instance).
  dir = vim.fs.joinpath(vim.fn.stdpath('state'), 'osc7577'),
  --- Delay before saving the session after a layout change.
  debounce_ms = 1000,
  --- Delete session files not saved or loaded for this many days.
  prune_days = 30,
  --- argv[0] of the resume command. nil: "nvim" if that resolves to this binary, else v:progpath.
  cmd = nil,
}

local cfg = vim.deepcopy(defaults)

--- Take the token out of the environment right away so that no child (`:terminal`, jobs,
--- `system()`) inherits it. It is kept only in this upvalue and never written anywhere.
---@return string?
local function take_token()
  local t = vim.env.OSC7577_TOKEN
  if t ~= nil then
    vim.env.OSC7577_TOKEN = nil
  end
  if type(t) == 'string' and #t >= 22 and #t <= 64 and t:match('^[A-Za-z0-9_-]+$') then
    return t
  end
end

local token = take_token()

local state = {
  path = nil, ---@type string? this instance's session file
  argv = nil, ---@type string[]? resume command
  owner = nil, ---@type integer? pid of the last report
  last_time = 0, ---@type integer `time` of the last report; must strictly increase per pid
  last_key = nil, ---@type string? what was last reported, to skip duplicates
  deferred = false,
  force_pending = false,
  save_timer = nil, ---@type uv.uv_timer_t?
}

-- Protocol ---------------------------------------------------------------------------------------

---@class osc7577.Report
---@field pid integer
---@field time integer
---@field argv? string[]
---@field cwd? string
---@field clear? boolean

--- The body before `:mac=`.
---@param r osc7577.Report
---@return string
function M._body(r)
  local parts = { 'pid=' .. r.pid, 'time=' .. r.time }
  if r.clear then
    parts[#parts + 1] = 'clear=1'
  else
    local enc = {}
    for i, a in ipairs(r.argv) do
      enc[i] = vim.base64.encode(a)
    end
    parts[#parts + 1] = 'argv=' .. table.concat(enc, ',')
    if r.cwd then
      parts[#parts + 1] = 'cwd=' .. vim.base64.encode(r.cwd)
    end
  end
  return table.concat(parts, ':')
end

--- SHA-256 over `body .. ":" .. token`, lowercase hex.
---@param body string
---@param tok string
---@return string
function M._mac(body, tok)
  return vim.fn.sha256(body .. ':' .. tok)
end

---@param r osc7577.Report
---@param tok string
---@return string
function M._sequence(r, tok)
  local body = M._body(r)
  return PREFIX .. body .. ':mac=' .. M._mac(body, tok) .. ST
end

--- C0 controls, DEL, and C1 controls (U+0080..U+009F encoded as C2 80..C2 9F).
---@param s string
local function has_controls(s)
  return s:find('[%z\1-\31\127]') ~= nil or s:find('\194[\128-\159]') ~= nil
end

--- Whether the terminal would accept this report. A rejected report clears the owner's
--- record, so never send one that fails these checks.
---@param r osc7577.Report
---@return boolean ok
---@return string? why
function M._validate(r)
  if r.clear then
    return true
  end
  local argv = r.argv
  if not argv or #argv == 0 or #argv > 64 then
    return false, 'argv must have 1..64 elements'
  end
  local a0 = argv[1]
  if a0 == '' or a0:sub(1, 1) == '-' then
    return false, 'argv[0] must be a command name or absolute path'
  end
  if a0:find('/') and a0:sub(1, 1) ~= '/' then
    return false, 'argv[0] must not be a relative path'
  end
  for _, a in ipairs(argv) do
    if has_controls(a) then
      return false, 'argv contains control characters'
    end
  end
  if r.cwd and (r.cwd:sub(1, 1) ~= '/' or has_controls(r.cwd)) then
    return false, 'cwd must be an absolute path without control characters'
  end
  return true
end

--- v:startreason and v:exitreason only exist in newer Nvim.
---@param name string
---@return string
local function vvar(name)
  local ok, v = pcall(api.nvim_get_vvar, name)
  return ok and type(v) == 'string' and v or ''
end

-- Owner ------------------------------------------------------------------------------------------

--- The pid that owns the pty: the TUI process that embeds this server. nil when there's no
--- single TUI attached over stdio (headless, GUI, `--remote-ui`, several UIs): the token
--- belongs to the terminal this server was started in, so only that terminal may get reports.
---@return integer?
local function owner_pid()
  local tty_uis = {}
  for _, ui in ipairs(api.nvim_list_uis()) do
    if ui.stdout_tty then
      tty_uis[#tty_uis + 1] = ui
    end
  end
  if #tty_uis ~= 1 or not tty_uis[1].chan or tty_uis[1].chan == 0 then
    return nil
  end
  local ok, info = pcall(api.nvim_get_chan_info, tty_uis[1].chan)
  if not ok or info.stream ~= 'stdio' then
    return nil
  end
  local ppid = uv.os_getppid()
  local attrs = info.client and info.client.attributes
  local pid = attrs and tonumber(attrs.pid)
  if pid and pid ~= ppid then
    return nil
  end
  return ppid
end

-- Session file -----------------------------------------------------------------------------------

local function dir()
  return vim.fs.normalize(cfg.dir)
end

local function resolve_cmd()
  if cfg.cmd then
    return cfg.cmd
  end
  local prog = vim.v.progpath
  local onpath = vim.fn.exepath('nvim')
  if onpath ~= '' and uv.fs_realpath(onpath) == uv.fs_realpath(prog) then
    return 'nvim'
  end
  return prog
end

local function save()
  if not state.path or vim.v.exiting ~= vim.NIL then
    return
  end
  -- Not while a prompt, the command line or the cmdwin is active.
  local mode = vim.fn.mode()
  if mode:find('^[cr]') or vim.fn.getcmdwintype() ~= '' then
    M._schedule_save()
    return
  end
  -- :mksession sets v:this_session and fires SessionWritePost; keep both away from the user's
  -- own session setup.
  local prev = vim.v.this_session
  pcall(vim.cmd, 'silent noautocmd mksession! ' .. vim.fn.fnameescape(state.path))
  vim.v.this_session = prev
end

function M._schedule_save()
  if not state.path then
    return
  end
  state.save_timer = state.save_timer or uv.new_timer()
  state.save_timer:stop()
  state.save_timer:start(cfg.debounce_ms, 0, vim.schedule_wrap(save))
end

local function remove_file()
  if state.path then
    os.remove(state.path)
  end
end

local function prune()
  local d = dir()
  local cutoff = os.time() - cfg.prune_days * 86400
  for name, kind in vim.fs.dir(d) do
    local p = vim.fs.joinpath(d, name)
    if kind == 'file' and name:match('%.vim$') and p ~= state.path then
      local st = uv.fs_stat(p)
      if st and st.mtime.sec < cutoff then
        os.remove(p)
      end
    end
  end
end

-- Reporting --------------------------------------------------------------------------------------

---@param r osc7577.Report
local function send(r)
  api.nvim_ui_send(M._sequence(r, token))
  state.owner, state.last_time = r.pid, r.time
end

local function send_clear()
  local now = os.time()
  -- A report whose `time` isn't later than the last accepted one is ignored. The terminal
  -- clears the record itself once the owner exits, so skipping this is fine.
  if state.owner and now > state.last_time then
    send({ pid = state.owner, time = now, clear = true })
  end
  state.last_key = nil
end

--- Report the resume command. Skipped if nothing changed since the last report unless `force`.
---@param force? boolean
function M.report(force)
  if not token or not state.argv then
    return
  end
  force = force or state.force_pending
  local pid = owner_pid()
  if not pid then
    return
  end
  if pid ~= state.owner then
    -- New UI (e.g. reattached after :detach). The old owner's record goes when it exits.
    state.last_key, state.last_time = nil, 0
  end
  local cwd = vim.fn.getcwd(-1, -1)
  local key = pid .. '\0' .. cwd
  if not force and key == state.last_key then
    return
  end
  local now = os.time()
  if now <= state.last_time then
    state.force_pending = force
    if not state.deferred then
      state.deferred = true
      vim.defer_fn(function()
        state.deferred = false
        M.report()
      end, 1000)
    end
    return
  end
  state.force_pending = false
  local r = { pid = pid, time = now, argv = state.argv, cwd = cwd }
  local ok = M._validate(r)
  if not ok or #M._sequence(r, token) > MAX_SEQ then
    -- Can't express this resume command; don't leave a stale one behind.
    send_clear()
    return
  end
  send(r)
  state.last_key = key
end

-- Lifecycle --------------------------------------------------------------------------------------

local function start()
  if state.path then
    return
  end
  local d = dir()
  vim.fn.mkdir(d, 'p', tonumber('700', 8))

  -- Resumed by the terminal? The resume command sources our own file: keep using it.
  -- Sourcing resolves symlinks in v:this_session (e.g. /var -> /private/var on macOS), so compare
  -- real paths but keep our own spelling, so the reported command stays byte-identical.
  local ts = vim.v.this_session
  if
    ts ~= ''
    and ts:match('%.vim$')
    and uv.fs_realpath(vim.fs.dirname(ts)) == uv.fs_realpath(d)
  then
    state.path = vim.fs.joinpath(d, vim.fs.basename(ts))
    vim.v.this_session = ''
  else
    state.path = vim.fs.joinpath(d, ('%d-%d.vim'):format(os.time(), vim.fn.getpid()))
  end
  -- Create it user-only; :mksession! keeps the mode of an existing file.
  local fd = uv.fs_open(state.path, 'a', tonumber('600', 8))
  if fd then
    uv.fs_close(fd)
  end
  pcall(uv.fs_chmod, state.path, tonumber('600', 8))

  state.argv = { resolve_cmd(), '-c', 'silent! source ' .. vim.fn.fnameescape(state.path) }
  save()
  pcall(prune)

  if vvar('startreason'):match('^restart') then
    -- The previous server may have reported this same second for the same owner pid.
    vim.defer_fn(function()
      M.report(true)
    end, 1000)
  else
    M.report(true)
  end
end

--- VimLeavePre also runs when the terminal goes away: the TUI's channel closes, then
--- preserve_exit() -> getout() runs autocmds with v:exitreason "quit", just like :q. That is
--- exactly when the record and session file must survive. What differs is that the channel
--- is already disconnected, so a deliberate exit is one where our TUI is still attached.
local function leave()
  if vim.v.dying ~= 0 or not owner_pid() then
    return
  end
  local reason = vvar('exitreason')
  if reason ~= 'restart' and reason ~= 'restart!' then
    send_clear()
  end
  -- On :restart the record stays; the new server reports its own file.
  remove_file()
end

--- Configure and enable. Safe to call more than once; later calls replace the config.
---@param opts? table
function M.setup(opts)
  cfg = vim.tbl_deep_extend('force', defaults, opts or {})
  local group = api.nvim_create_augroup('osc7577', { clear = true })
  if not token or not api.nvim_ui_send then
    return
  end

  local function on(event, fn)
    api.nvim_create_autocmd(event, { group = group, callback = fn })
  end

  if vim.v.vim_did_enter == 1 then
    vim.schedule(start)
  else
    on('VimEnter', start)
  end
  on('UIEnter', function()
    M.report()
  end)
  on('VimResume', function()
    M.report(true)
  end)
  on('DirChanged', function()
    M.report()
    M._schedule_save()
  end)
  on({
    'BufWinEnter',
    'BufDelete',
    'BufWritePost',
    'WinNew',
    'WinClosed',
    'WinResized',
    'TabNew',
    'TabClosed',
    'CursorHold',
  }, M._schedule_save)
  -- The terminal may go away while we're suspended or unfocused: save right now.
  on({ 'VimSuspend', 'FocusLost' }, save)
  on('VimLeavePre', leave)
end

--- Info for :checkhealth.
function M._status()
  return {
    token = token ~= nil,
    ui_send = api.nvim_ui_send ~= nil,
    owner = token and owner_pid() or nil,
    path = state.path,
    argv = state.argv,
    last_time = state.last_time,
  }
end

return M
