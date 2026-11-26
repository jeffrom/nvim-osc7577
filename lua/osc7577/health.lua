local M = {}

function M.check()
  local h = vim.health
  local s = require('osc7577')._status()
  h.start('osc7577')
  if not s.ui_send then
    h.error('nvim_ui_send() is missing (needs Nvim 0.12+)')
  end
  if not s.token then
    h.info('OSC7577_TOKEN was not set (or invalid): the terminal does not support program resume')
    return
  end
  h.ok('terminal supports program resume')
  if s.owner then
    h.ok(('reporting for TUI pid %d'):format(s.owner))
  else
    h.warn('no single TUI attached over stdio: not reporting')
  end
  if s.path then
    h.info('session file: ' .. s.path)
    h.info('resume argv: ' .. table.concat(s.argv, ' '))
  elseif s.owner then
    h.warn('not started yet: no session file (the plugin loads at VimEnter; is it lazy-loaded?)')
  end
  h.info(
    'the terminal still has to trust this command. Rex: add a `resume.trust` rule for nvim'
      .. ' (see README), then check `rex config check`'
  )
end

return M
