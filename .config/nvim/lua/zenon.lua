-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local p = require("palette")

vim.opt.termguicolors = true
vim.opt.background = "dark"

local zenon = {
  normal = {
    c = { bg = p.lblack },
    a = { bg = p.lblack, gui = "bold" }
  },
  insert = {
    c = { fg = p.black, bg = p.green },
    a = { fg = p.black, bg = p.green, gui = "bold" }
  },
  visual = {
    c = { fg = p.black, bg = p.magenta },
    a = { fg = p.black, bg = p.magenta, gui = "bold" }
  },
  replace = {
    c = { fg = p.black, bg = p.red },
    a = { fg = p.black, bg = p.red, gui = "bold" }
  },
  command = {
    c = { fg = p.black, bg = p.yellow },
    a = { fg = p.black, bg = p.yellow, gui = "bold" }
  },
  inactive = {
    c = { bg = p.black },
    a = { bg = p.black, gui = "bold" }
  }
}

-- UI
vim.api.nvim_set_hl(0, "YankHighlight", { fg = p.black, bg = p.bright_red, nocombine = true })
vim.api.nvim_set_hl(0, "Visual", { fg = p.black, bg = p.magenta, nocombine = true })
vim.api.nvim_set_hl(0, "CursorLine", { bg = p.lblack, nocombine = true })
vim.api.nvim_set_hl(0, "Normal", { bg = "NONE" })
vim.api.nvim_set_hl(0, "WinSeparator", { fg = p.lblack, bg = p.lblack })

-- Better Yazi borders
vim.api.nvim_set_hl(0, "FloatBorder", { fg = p.lblack })
vim.api.nvim_set_hl(0, "WhichKeyNormal", { bg = p.lblack })

-- Bufferline
vim.api.nvim_set_hl(0, "BufferLineIndicatorSelected", { fg = p.black, bg = p.black, nocombine = true })
vim.api.nvim_set_hl(0, "BufferLineBufferSelected", { fg = p.white, bg = p.black, nocombine = true })
vim.api.nvim_set_hl(0, "BufferLineBackground", { bg = p.lblack })
vim.api.nvim_set_hl(0, "BufferLineFill", { bg = p.lblack })

-- Searching
vim.api.nvim_set_hl(0, "CurSearch", { fg = p.black, bg = p.red, bold = true, nocombine = true })
vim.api.nvim_set_hl(0, "Search", { fg = p.black, bg = p.bright_red, nocombine = true })
vim.api.nvim_set_hl(0, "IncSearch", { fg = p.black, bg = p.red })

-- Matching
vim.api.nvim_set_hl(0, "Substitute", { fg = p.black, bg = p.red })

-- Completion
vim.api.nvim_set_hl(0, "PmenuSel", { fg = p.black, bg = p.green })
vim.api.nvim_set_hl(0, "Pmenu", { fg = p.white, bg = p.lblack })

-- Diagnostics
vim.api.nvim_set_hl(0, "DiagnosticVirtualTextError", { fg = p.red, bg = "NONE" })
vim.api.nvim_set_hl(0, "DiagnosticVirtualTextWarn", { fg = p.yellow, bg = "NONE" })
vim.api.nvim_set_hl(0, "DiagnosticVirtualTextInfo", { fg = p.bright_red, bg = "NONE" })
vim.api.nvim_set_hl(0, "DiagnosticVirtualTextHint", { fg = p.cyan, bg = "NONE" })

require("lualine").setup({
  options = {
    theme = zenon,
    icons_enabled = false,
    section_separators = " 󰇙 ",
    component_separators = " 󰇙 "
  }
})

require("bufferline").setup({
  options = {
    separator_style = { "", "" },
    show_buffer_close_icons = false,
    always_show_bufferline = false,
    show_buffer_icons = false,
    tab_size = 25,
    modified_icon = "✎"
  },
  highlights = {
    modified = { fg = "#FFFFFF", bg = p.lblack },
    modified_selected = { bg = p.black }
  }
})

local function apply_terminal_syntax()
  local syntax_map = {
    Comment         = p.bright_black,
    String          = p.yellow,
    Constant        = p.bright_red,
    Number          = p.yellow,
    Boolean         = p.bright_red,
    Character       = p.yellow,

    Statement       = p.magenta,
    Keyword         = p.magenta,
    Conditional     = p.magenta,
    Repeat          = p.magenta,
    Label           = p.magenta,
    Operator        = p.magenta,

    Function        = p.green,
    Identifier      = p.green,

    Type            = p.cyan,
    StorageClass    = p.cyan,
    Structure       = p.cyan,
    Typedef         = p.cyan,

    PreProc         = p.magenta,
    Include         = p.magenta,
    Define          = p.magenta,
    Macro           = p.magenta,

    Special         = p.bright_red,
    SpecialChar     = p.bright_red,

    Error           = p.red,
    Todo            = p.bright_red,
  }

  for group, color in pairs(syntax_map) do
    vim.api.nvim_set_hl(0, group, { fg = color, bg = "NONE" })
  end

  local ts_map = {
    ["@comment"]              = p.bright_black,

    ["@string"]               = p.cyan,
    ["@string.escape"]        = p.cyan,
    ["@character"]            = p.cyan,

    ["@constant"]             = p.bright_red,
    ["@constant.builtin"]     = p.bright_red,
    ["@number"]               = p.yellow,
    ["@boolean"]              = p.bright_red,

    ["@keyword"]              = p.magenta,
    ["@keyword.function"]     = p.magenta,
    ["@keyword.return"]       = p.magenta,
    ["@conditional"]          = p.magenta,
    ["@repeat"]               = p.magenta,
    ["@operator"]             = p.magenta,
    ["@preproc"]              = p.magenta,

    ["@function"]             = p.green,
    ["@function.call"]        = p.green,
    ["@function.method"]      = p.green,
    ["@function.method.call"] = p.green,
    ["@constructor"]          = p.green,

    ["@variable"]             = p.white,
    ["@parameter"]            = p.white,
    ["@field"]                = p.white,
    ["@property"]             = p.white,
    ["@punctuation"]          = p.white,

    ["@type"]                 = p.yellow,
    ["@type.builtin"]         = p.yellow,
    ["@module"]               = p.yellow,
    ["@namespace"]            = p.yellow,

    ["@special"]              = p.bright_red,
    ["@error"]                = p.red,
  }

  for group, color in pairs(ts_map) do
    vim.api.nvim_set_hl(0, group, { fg = color, bg = "NONE" })
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "*",
  callback = apply_terminal_syntax
})
apply_terminal_syntax()
