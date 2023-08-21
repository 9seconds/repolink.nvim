local api = require("repolink.api")

local M = {}

-- neovim 0.10 renames vim.loop to vim.uv
local uv = vim.uv or vim.loop

local function command_repolink(args)
  local branch = args.fargs[1] or "."

  if branch == "." then
    branch = nil
  end

  local url, error = api.create_link({
    branch = branch,
    remote = args.fargs[2],
    path = uv.fs_realpath(vim.api.nvim_buf_get_name(0)),
    start_line = args.line1,
    end_line = args.line2,
  })

  if error then
    vim.notify(error, "error", { title = "RepoLink" })
    return
  end

  if not url then
    return
  end

  -- let's add a small space to have a better copypasteability
  vim.notify(url .. " ", "info", { title = "RepoLink" })

  if args.bang and api.c.bang_register then
    vim.fn.setreg(api.c.bang_register, url, "c")
  end
end

function M.setup(config)
  api.c = vim.tbl_deep_extend("force", {
    use_full_commit_hash = false,
    custom_url_parser = nil,
    bang_register = "+",
    timeout = 5000,
    url_builders = {
      ["github.com"] = api.url_builder_for_github(),
      ["bitbucket.org"] = api.url_builder_for_bitbucket(),
      ["gitlab.com"] = api.url_builder_for_gitlab(),
      ["git.sr.ht"] = api.url_builder_for_sourcehut(),
    },
  }, config or {})

  vim.api.nvim_create_user_command("RepoLink", command_repolink, {
    bang = true,
    nargs = "*",
    range = true,
  })
end

return setmetatable(M, {
  __index = function(_, name)
    local api = require("repolink.api")

    if api[name] and name ~= "c" then
      return api[name]
    end
  end,
})
