if vim.g.loaded_osc7577 then
  return
end
vim.g.loaded_osc7577 = true

-- Configure with `vim.g.osc7577 = { ... }` before this runs, or call
-- `require('osc7577').setup({ ... })` yourself.
require('osc7577').setup(vim.g.osc7577)
