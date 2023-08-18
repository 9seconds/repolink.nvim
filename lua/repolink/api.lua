local M = {
  c = {}
}

local function git(cmd)
  local args = { "-P" }

  for _, arg in ipairs(cmd) do
    table.insert(args, arg)
  end

  return require("plenary.job"):new({
    command = "git",
    cwd = vim.loop.cwd(),
    args = args,
    enable_recording = true,
  })
end

local get_git_root = (function()
  local cache = {}

  return function()
    local key = vim.loop.cwd()

    if not cache[key] then
      cache[key] = git({ "rev-parse", "--show-toplevel" }):sync()[1]
    end

    return cache[key]
  end
end)()

local get_remote_url = (function()
  local cache = {}

  return function(name)
    local key = get_git_root() .. "::" .. (name or "")

    if cache[key] then
      return cache[key]
    end

    local args = { "ls-remote", "--get-url" }
    if name then
      table.insert(args, name)
    end

    local url = git(args):sync()[1]

    if url and url ~= name then
      cache[key] = url

      return url
    end
  end
end)()

local function collect_git_data_commit_hash(env, branch)
  if branch then
    env.commit_hash = branch
    return
  end

  local args

  if M.c.use_full_commit_hash then
    args = { "rev-parse", "HEAD" }
  else
    args = { "rev-parse", "--short", "HEAD" }
  end

  local commit_job = git(args)

  commit_job:after_success(function(j)
    env.commit_hash = j:result()[1]
  end)
  commit_job:after_failure(function()
    env.error = "Cannot find a commit for a current repository head"
  end)

  commit_job:start()
end

local function collect_git_data_remote(env, remote)
  local remote_url = get_remote_url(remote)
  if not remote_url then
    env.error = "Cannot resolve a remote URL"
    return
  end

  local url_patterns = {
    "^git@([^:]+):([^/]+)/(.+)%.git$",
    "^https?://([^/]+)/([^/]+)/(.+)%.git$",
  }

  if M.c.custom_url_parser then
    local host, data = M.c.custom_url_parser(remote_url)

    env.host = host
    env.host_data = data
  end

  if env.host then
    return
  end

  for _, pattern in pairs(url_patterns) do
    local host, user, project = string.match(remote_url, pattern)

    if host then
      env.host = host
      env.host_data = {
        user = user,
        project = project,
      }
      return
    end
  end

  env.error = "Cannot parse remote URL"
end

local function collect_git_data_path(env, path)
  env.path = string.sub(path, 2 + #get_git_root())
end

function M.create_link(opts)
  -- opts: {
  --   branch = "master" or "." (autodetect),
  --   remote = "origin" or nil,
  --   path = /path/to/file or nil,
  --   start_line = 1,
  --   end_line = 1
  -- }

  if not vim.fn.executable("git") then
    return nil, "git is not installed"
  end

  if not opts.path then
    return nil, "Buffer is not backed by any known file"
  end

  local start_line = opts.start_line
  local end_line = opts.end_line or start_line

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local env = {
    start_line = start_line,
    end_line = end_line,
    -- commit_hash = "sdfsdfds"
    -- host = "github.com"
    -- host_data = {user, project}
    -- path = "..."
  }
  collect_git_data_commit_hash(env, opts.branch)
  collect_git_data_remote(env, opts.remote)
  collect_git_data_path(env, opts.path)

  if not vim.wait(M.c.timeout, function()
    return env.error or vim.tbl_count(env) == 6
  end, 20) then
    return nil, "Task takes too much time"
  end

  if env.error then
    return nil, env.error
  end

  local builder = M.c.url_builders[env.host]
  if builder then
    return builder(env)
  end

  return nil, "Do not know how to build URL for " .. env.host
end

function M.url_builder_for_github(host)
  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-L" .. tostring(args.end_line)
    end

    return string.format(
      (host or "https://github.com") .. "/%s/%s/blob/%s/%s#%s",
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_bitbucket(host)
  return function(args)
    local anchor = "lines-" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. ":" .. tostring(args.end_line)
    end

    return string.format(
      (host or "https://bitbucket.org") .. "/%s/%s/src/%s/%s#%s",
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_gitlab(host)
  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-" .. tostring(args.end_line)
    end

    return string.format(
      (host or "https://gitlab.com") .. "/%s/%s/-/blob/%s/%s#%s",
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_sourcehut(host)
  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-" .. tostring(args.end_line)
    end

    return string.format(
      (host or "https://git.sr.ht") .. "/%s/%s/tree/%s/item/%s#",
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_gitea(host)
  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-L" .. tostring(args.end_line)
    end

    return string.format(
      -- this works only for branches
      (host or "https://gitea.com") .. "/%s/%s/src/commit/%s/%s#",
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

return M
