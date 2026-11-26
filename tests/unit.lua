-- Run: nvim -l tests/unit.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(arg[0] or 'tests/unit.lua')))
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

vim.env.OSC7577_TOKEN = 'abcdefghijklmnopqrstuvwxyz'
local m = require('osc7577')

local failed = 0
local function eq(want, got, what)
  if vim.deep_equal(want, got) then
    print('ok   ' .. what)
  else
    failed = failed + 1
    print(('FAIL %s\n  want: %s\n  got:  %s'):format(what, vim.inspect(want), vim.inspect(got)))
  end
end

eq(nil, vim.env.OSC7577_TOKEN, 'token removed from environment on load')
eq('', vim.fn.system({ 'sh', '-c', 'printf %s "$OSC7577_TOKEN"' }), 'children do not inherit token')

-- Test vector from the spec.
local body = m._body({ pid = 74877, time = 1795543200, clear = true })
eq('pid=74877:time=1795543200:clear=1', body, 'clear body')
eq(
  'c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93',
  m._mac(body, 'dummy-token-replace-me'),
  'mac matches spec test vector'
)

-- nvim = bnZpbQ==, -S = LVM= per the spec example.
eq(
  'pid=1:time=2:argv=bnZpbQ==,LVM=,L3g=:cwd=L3RtcA==',
  m._body({ pid = 1, time = 2, argv = { 'nvim', '-S', '/x' }, cwd = '/tmp' }),
  'argv/cwd body'
)
local seq = m._sequence({ pid = 1, time = 2, clear = true }, 'dummy-token-replace-me')
eq(true, seq:sub(1, 7) == '\27]7577;' and seq:sub(-2) == '\27\\', 'sequence framing')
eq(true, seq:match(':mac=%x+\27\\$') ~= nil and #seq:match(':mac=(%x+)') == 64, 'mac is 64 hex')

local function valid(argv, cwd)
  return (m._validate({ pid = 1, time = 2, argv = argv, cwd = cwd }))
end
eq(true, valid({ 'nvim', '-c', 'silent! source /a b.vim' }, '/tmp'), 'valid report')
eq(true, valid({ '/opt/bin/nvim' }), 'absolute argv[0]')
eq(false, valid({ './nvim' }), 'relative argv[0] rejected')
eq(false, valid({ '-nvim' }), 'dash argv[0] rejected')
eq(false, valid({ '' }), 'empty argv[0] rejected')
eq(true, valid({ 'nvim', '' }), 'empty later element allowed')
eq(false, valid({ 'nvim', 'a\nb' }), 'C0 control rejected')
eq(false, valid({ 'nvim', 'a\127b' }), 'DEL rejected')
eq(false, valid({ 'nvim', 'a\194\133b' }), 'C1 control rejected')
eq(true, valid({ 'nvim', 'caf\195\169' }), 'non-ASCII UTF-8 allowed')
eq(false, valid({ 'nvim' }, 'rel/dir'), 'relative cwd rejected')

if failed > 0 then
  print(failed .. ' failed')
  os.exit(1)
end
print('all passed')
