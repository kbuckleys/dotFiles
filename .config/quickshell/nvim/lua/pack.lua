-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

vim.pack.add({
  'https://github.com/lukas-reineke/indent-blankline.nvim.git',
  'https://github.com/brenoprata10/nvim-highlight-colors.git',
  'https://github.com/nvim-treesitter/nvim-treesitter.git',
  'https://github.com/nvim-tree/nvim-web-devicons.git',
  'https://github.com/nvim-lualine/lualine.nvim.git',
  "https://github.com/rafamadriz/friendly-snippets",
  'https://github.com/akinsho/bufferline.nvim.git',
  'https://github.com/nvim-lua/plenary.nvim.git',
  'https://github.com/mikavilpas/yazi.nvim.git',
  "https://github.com/neovim/nvim-lspconfig",
  "https://github.com/mason-org/mason.nvim",
  "https://github.com/folke/which-key.nvim",
  "https://github.com/chentoast/marks.nvim",
  "https://github.com/nvim-mini/mini.nvim",
  "https://github.com/tpope/vim-fugitive",
  "https://github.com/windwp/nvim-autopairs",
})

-- Update
vim.api.nvim_create_user_command("PackUpdate", function()
    vim.pack.update()
end, { desc = "Update all plugins" })

require("nvim-autopairs").setup({
  check_ts = true, -- Enable Treesitter integration
  disable_filetype = { "TelescopePrompt", "spectre_panel" },
  fast_wrap = {}
})

require('marks').setup()
require("mini.surround").setup()

require('nvim-highlight-colors').setup({
  render = 'background',
})

require("ibl").setup({
  indent = { char = "│" },
  scope = {
    enabled = true,
    show_start = true,
    show_end = true
  }
})

require("mini.notify").setup({
    -- only show messages
    content = {
        format = function(notif)
            return notif.msg
        end
    }
})

require("mini.completion").setup({
    lsp_completion = {
        auto_setup = true
    }
})

-- friendly-snippets ships VSCode-style json that from_lang() picks up off the
-- runtimepath; without a snippet engine those files were never read.
local snippets = require("mini.snippets")
snippets.setup({
    snippets = { snippets.gen_loader.from_lang() }
})

-- Every keymap in binds.lua carries a `desc`, which only ever surfaces here.
require("which-key").setup({
    preset = "helix"
})

-- Registers :Mason. Nothing is installed yet, so LSP servers are picked up
-- from PATH in lsp.lua rather than assumed to exist.
require("mason").setup()

-- main branch: setup() only configures install paths. Highlighting is opt-in
-- per buffer via vim.treesitter.start(), which is what makes the @-group
-- theming in zenon.lua actually apply.
require("nvim-treesitter").setup()

vim.api.nvim_create_autocmd("FileType", {
  desc = "Start treesitter highlighting when a parser is available",
  callback = function(ev)
    local lang = vim.treesitter.language.get_lang(ev.match)
    if lang and pcall(vim.treesitter.start, ev.buf, lang) then
      vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end
  end
})
