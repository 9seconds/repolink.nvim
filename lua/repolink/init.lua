local M = {}

function M.setup(config)
  local configs = require("repolink.config")
  local api = require("repolink.api")

  configs.c = vim.tbl_deep_extend("force", {
    use_full_commit_hash = false,
    custom_url_parser = nil,
    timeout = 5000,
    url_builders = {
      ["github.com"] = api.url_builder_for_github("https://github.com"),
      ["bitbucket.org"] = api.url_builder_for_bitbucket("https://bitbucket.org"),
      ["gitlab.com"] = api.url_builder_for_gitlab("https://gitlab.com"),
      ["git.sr.ht"] = api.url_builder_for_sourcehut("https://git.sr.ht"),
    },
  }, config or {})

  vim.api.nvim_create_user_command("RepoLink", function(args)
    local url = api.create_link({
      branch = args.fargs[1] or ".",
      remote = args.fargs[2],
      path = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)),
      start_line = args.line1,
      end_line = args.line2,
    })
    if url then
      vim.notify(url)
    end
  end, {
    nargs = "*",
    range = true,
  })
end

return setmetatable(M, {
  __index = function(_, name)
    local api = require("repolink.api")

    if api[name] then
      return api[name]
    end
  end,
})
