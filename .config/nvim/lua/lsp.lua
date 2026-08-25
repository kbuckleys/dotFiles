-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local candidates = {
  "rust_analyzer",
  "lua_ls",
  "clangd",
  "gopls",
  "basedpyright",
  "ruff",
  "ts_ls",
  "bashls",
  "jsonls",
  "yamlls",
  "taplo",
  "marksman",
  "html",
  "cssls",
}

for _, name in ipairs(candidates) do
  local ok, cfg = pcall(function() return vim.lsp.config[name] end)
  local cmd = ok and cfg and cfg.cmd
  local exe = type(cmd) == "table" and cmd[1] or nil
  if exe and vim.fn.executable(exe) == 1 then
    vim.lsp.enable(name)
  end
end

vim.diagnostic.config({
  virtual_text = { prefix = "▪", spacing = 2 },
  underline = true,
  severity_sort = true,
})
