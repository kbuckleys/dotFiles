-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local fzf_files = require("fzf")
vim.keymap.set("n", "<leader>f", fzf_files.open, { desc = "Find (FZF)" })
vim.keymap.set("n", "<leader>h", fzf_files.history, { desc = "Update History" })
vim.keymap.set('n', '<leader><leader>', '<cmd>Yazi<cr>', { desc = 'Yazi' })

vim.keymap.set("n", "<C-Tab>", "<cmd>BufferLineCycleNext<cr>", { desc = "Next buffer" })
vim.keymap.set("n", "<C-S-Tab>", "<cmd>BufferLineCyclePrev<cr>", { desc = "Previous buffer" })

vim.keymap.set("n", "<Esc>", ":nohl<CR>", { desc = "Clear search highlighting", silent = true })
vim.keymap.set("n", "<C-c>", "<cmd>bd<cr>", { desc = "Close current buffer" })

vim.keymap.set("n", "<A-j>", ":m .+1<CR>==", { desc = "Move line down" })
vim.keymap.set("n", "<A-k>", ":m .-2<CR>==", { desc = "Move line up" })
vim.keymap.set("v", "<A-j>", ":m '>+1<CR>gv=gv", { desc = "Move selected lines down" })
vim.keymap.set("v", "<A-k>", ":m '<-2<CR>gv=gv", { desc = "Move selected lines up" })

vim.keymap.set("v", "<", "<gv", { desc = "Unindent and keep selection" })
vim.keymap.set("v", ">", ">gv", { desc = "Indent and keep selection" })

vim.keymap.set("n", "J", "mzJ`z", { desc = "Join lines without moving cursor" })

vim.keymap.set("n", "n", "nzzzv", { desc = "Next search result cursor centered" })
vim.keymap.set("n", "N", "Nzzzv", { desc = "Previous search result cursor centered" })

vim.keymap.set("n", "<leader>s", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]], { desc = "Replace word cursor is on globally" })
vim.keymap.set("n", "<leader>X", "<cmd>!chmod +x %<CR>", { silent = true, desc = "makes file executable" })

vim.keymap.set("n", "<leader>re", "<cmd>restart<cr>", { desc = "Restart config :restart)" })

vim.keymap.set("n", "<leader>+", function()
  vim.cmd("vertical resize +5")
end, { desc = "Increase panel width" })

vim.keymap.set("n", "<leader>-", function()
  vim.cmd("vertical resize -5")
end, { desc = "Decrease panel width" })

-- Native undotree
vim.keymap.set("n", "<leader>u", function()
    vim.cmd.packadd("nvim.undotree")
    require("undotree").open()
end, { desc = "Toggle Builtin Undotree" })

-- Delete mark menu
vim.keymap.set('n', '<Leader>dm', function()
  local mark = vim.fn.input('Delete mark: ')
  if mark ~= '' then
    vim.cmd('delmark ' .. mark)
  end
end, { desc = 'Delete a specific mark' })

vim.keymap.set('n', '<Leader>da', function()
  local confirm = vim.fn.input('Delete ALL marks in this file? (y/n): ')
  if confirm == 'y' or confirm == 'Y' then
    vim.cmd('delmarks!')
    vim.notify('All local marks deleted', vim.log.levels.INFO)
  end
end, { desc = 'Delete all marks in current file' })
