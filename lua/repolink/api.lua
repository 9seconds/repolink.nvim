local plenary_async = require("plenary.async")
local plenary_job = require("plenary.job")

local M = {
  c = {},
}

-- neovim 0.10 renames vim.loop to vim.uv
local uv = vim.uv or vim.loop

local function git(cmd)
  local args = { "-P" }

  for _, arg in ipairs(cmd) do
    table.insert(args, arg)
  end

  return plenary_job:new({
    command = "git",
    cwd = uv.cwd(),
    args = args,
    enable_recording = true,
  })
end

local find_git_root = (function()
  local cache = {}

  return plenary_async.wrap(function(callback)
    local key = uv.cwd()

    if cache[key] then
      return callback(cache[key], nil)
    end

    local job = git({ "rev-parse", "--show-toplevel" })

    job:after_success(function()
      cache[key] = job:result()[1]
      callback(cache[key], nil)
    end)
    job:after_failure(function()
      callback(nil, "Cannot find out a root of the repository")
    end)

    job:sync(M.c.timeout)
  end, 1)
end)()

local find_remote_url = (function()
  local cache = {}

  return plenary_async.wrap(function(name, callback)
    local key = uv.cwd() .. "::" .. (name or "")

    if cache[key] then
      return callback(cache[key], nil)
    end

    local args = { "ls-remote", "--get-url" }
    if name then
      table.insert(args, name)
    end

    local job = git(args)
    job:after_success(function()
      local url = job:result()[1]

      if url and url ~= name then
        cache[key] = url
        return callback(url, nil)
      end

      callback(nil, "Cannot find out remote URL")
    end)
    job:after_failure(function()
      callback(nil, "Cannot find out remote URL")
    end)

    job:sync(M.c.timeout)
  end, 2)
end)()

local function collect_git_path(send, path)
  local root, err = find_git_root()

  if err then
    send({ error = err })
  else
    send({ path = string.sub(path, 2 + #root) })
  end
end

local function collect_git_remote(send, name)
  local remote_url, err = find_remote_url(name)
  if not remote_url then
    return send({ error = err })
  end

  local url_patterns = {
    "^git@([^:]+):([^/]+)/(.+)%.git$",
    "^https?://([^/]+)/([^/]+)/(.+)%.git$",
  }

  if M.c.custom_url_parser then
    local host, host_data, parse_err = M.c.custom_url_parser(remote_url)

    if not parse_err then
      return send({
        host = host,
        host_data = host_data,
      })
    end
  end

  for _, pattern in pairs(url_patterns) do
    local host, user, project = string.match(remote_url, pattern)

    if host then
      return send({
        host = host,
        host_data = {
          user = user,
          project = project,
        },
      })
    end
  end

  send({ error = "Cannot parse remote URL" })
end

local function collect_git_commit_hash(send, branch)
  if branch then
    return send({ commit_hash = branch })
  end

  local args

  if M.c.use_full_commit_hash then
    args = { "rev-parse", "HEAD" }
  else
    args = { "rev-parse", "--short", "HEAD" }
  end

  local job = git(args)

  job:after_success(function()
    send({ commit_hash = job:result()[1] })
  end)
  job:after_failure(function()
    send({ error = "Cannot find a commit for a current repository head" })
  end)

  job:sync(M.c.timeout)
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
  local sender, receiver = plenary_async.control.channel.mpsc()

  plenary_async.run(function()
    collect_git_path(sender.send, opts.path)
  end)
  plenary_async.run(function()
    collect_git_remote(sender.send, opts.remote)
  end)
  plenary_async.run(function()
    collect_git_commit_hash(sender.send, opts.branch)
  end)

  plenary_async.void(function()
    while not env.error and vim.tbl_count(env) < 6 do
      for k, v in pairs(receiver.recv()) do
        env[k] = v
      end
    end
  end)()

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
  local url = (host or "https://github.com") .. "/%s/%s/blob/%s/%s#%s"

  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-L" .. tostring(args.end_line)
    end

    return string.format(
      url,
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_bitbucket(host)
  local url = (host or "https://bitbucket.org") .. "/%s/%s/src/%s/%s#%s"

  return function(args)
    local anchor = "lines-" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. ":" .. tostring(args.end_line)
    end

    return string.format(
      url,
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_gitlab(host)
  local url = (host or "https://gitlab.com") .. "/%s/%s/-/blob/%s/%s#%s"

  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-" .. tostring(args.end_line)
    end

    return string.format(
      url,
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_sourcehut(host)
  local url = (host or "https://git.sr.ht") .. "/%s/%s/tree/%s/item/%s#%s"

  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-" .. tostring(args.end_line)
    end

    return string.format(
      url,
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

function M.url_builder_for_gitea(host)
  local url = (host or "https://gitea.com") .. "/%s/%s/src/commit/%s/%s#%s"

  return function(args)
    local anchor = "L" .. tostring(args.start_line)
    if args.start_line ~= args.end_line then
      anchor = anchor .. "-L" .. tostring(args.end_line)
    end

    return string.format(
      url,
      args.host_data.user,
      args.host_data.project,
      args.commit_hash,
      args.path,
      anchor
    )
  end
end

return M
