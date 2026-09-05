-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

vim.g.netrw_banner = 0
vim.g.mapleader = " "
vim.opt.fillchars = { eob = " ", vert = "│" }

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.cursorline = true

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

vim.opt.wrap = true
vim.opt.smartindent = true
vim.opt.inccommand = "split"

-- Only number the real buffer line: v:virtnum is non-zero on wrapped
-- continuation rows and virtual lines, which would repeat the number
vim.opt.statuscolumn = "%=%{v:virtnum != 0 ? '' : (v:relnum == 0 ? v:lnum : v:relnum)} %s"

vim.opt.splitbelow = true
vim.opt.splitright = true

vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.laststatus = 3

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undodir = vim.fn.stdpath("data") .. "/undodir"
vim.opt.undofile = true

vim.opt.completeopt = "menuone,noselect,fuzzy,nosort"
vim.opt.shortmess:append("c")
vim.opt.clipboard:append("unnamedplus")
vim.opt.isfname:append("@-@")
vim.opt.scrolloff = 8

vim.opt.signcolumn = "yes"

vim.opt.cmdheight = 0

-- Neovim's default guicursor carries no blink timings, so it asks the terminal
-- for a *steady* cursor and kitty's cursor_blink_interval never gets to pulse.
-- Naming the timings opts in; kitty owns the actual rhythm and easing.
vim.opt.guicursor = "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,"
  .. "a:blinkwait700-blinkoff400-blinkon250"

require("yazi").setup({
  yazi_floating_window_border = "single"
})

-- Command bar pushes the Statusline upwards instead of overlapping it.
-- vim._core.ui2 is a private API: guarded so that if a future nvim renames or
-- drops it, this degrades to the stock cmdline instead of throwing and taking
-- the rest of this file -- and everything init.lua requires after it -- down.
local ok_ui2, ui2 = pcall(require, 'vim._core.ui2')
if ok_ui2 then
  ui2.enable({
    enable = true,
    msg = {
      targets = {
        [''] = 'msg',
        bufwrite = 'msg',
        echo = 'msg',
        echomsg = 'msg'
      },
      msg = {
        timeout = 5000
      }
    }
  })
end

-- Highlight yanked text
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function()
    vim.hl.on_yank({ higroup = "YankHighlight", timeout = 200 })
  end
})

-- Retain cursor position post-buffer closure
vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    local lcount = vim.api.nvim_buf_line_count(0)
    if mark[1] > 0 and mark[1] <= lcount then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end
})
