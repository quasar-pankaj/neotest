local adapters = require("neotest.adapters")
local async = require("plenary.async")
local config = require("neotest.config")
local logger = require("neotest.logging")
local lib = require("neotest.lib")

---@class NeotestClient
---@field private _started boolean
---@field private _state NeotestState
---@field private _events NeotestEventProcessor
---@field private _processes NeotestProcessTracker
---@field private _files_read table<string, boolean>
---@field private _adapters table<integer, NeotestAdapter>
---@field listeners NeotestEventListeners
local NeotestClient = {}

function NeotestClient:new(events, state, processes)
  events = events or require("neotest.client.events").processor()
  state = state or require("neotest.client.state")(events)
  processes = processes or require("neotest.client.strategies")()

  local neotest = {
    _started = false,
    _adapters = {},
    _events = events,
    _state = state,
    _processes = processes,
    _files_read = {},
    listeners = events.listeners,
  }
  self.__index = self
  setmetatable(neotest, self)
  return neotest
end

---@async
---@param tree? Tree
---@param args table
function NeotestClient:run_tree(tree, args)
  local pos_ids = {}
  for _, pos in tree:iter() do
    table.insert(pos_ids, pos.id)
  end

  local pos = tree:data()
  local adapter_id, adapter = self:_get_adapter(pos.id, args.adapter)
  if not adapter_id then
    logger.error("Adapter not found for position", pos.id)
    return
  end
  self._state:update_running(adapter_id, pos.id, pos_ids)
  local results = self:_run_tree(tree, args, adapter)
  if pos.type ~= "test" then
    self:_collect_results(adapter_id, tree, results)
  end
  if pos.type == "test" or pos.type == "namespace" then
    results[pos.path] = nil
  end
  self._state:update_results(adapter_id, results)
end

---@param position Tree
function NeotestClient:stop(position)
  local running_process_root = self:is_running(position:data().id)
  if not running_process_root then
    lib.notify("No running process found", "warn")
    return
  end
  self._processes:stop(running_process_root)
end

function NeotestClient:_collect_results(adapter_id, tree, results)
  local root = tree:data()
  local running = {}
  for _, node in tree:iter_nodes() do
    local pos = node:data()

    if (pos.type == "test" or (pos.type == "file" and root.id ~= pos.id)) and results[pos.id] then
      for parent in node:iter_parents() do
        local parent_pos = parent:data()
        if not lib.positions.contains(root, parent_pos) then
          break
        end

        local parent_result = results[parent_pos.id]
        local pos_result = results[pos.id]
        if not parent_result then
          parent_result = { status = "passed", output = pos_result.output }
        end

        if pos_result.status ~= "skipped" then
          if parent_result.status == "passed" then
            parent_result.status = pos_result.status
          end
        end

        if pos_result.errors then
          parent_result.errors = vim.list_extend(parent_result.errors or {}, pos_result.errors)
        end

        results[parent_pos.id] = parent_result
      end
    end
  end

  for _, node in tree:iter_nodes() do
    local pos = node:data()
    if pos.type == "test" or pos.type == "namespace" then
      if self:is_running(root.id) then
        table.insert(running, pos.id)
      end
      if not results[pos.id] and results[root.id] then
        local root_result = results[root.id]
        results[pos.id] = { status = root_result.status, output = root_result.output }
      end
    end
  end
  if not vim.tbl_isempty(running) then
    self._state:update_running(adapter_id, root.id, running)
  end
end

---@param tree Tree
---@param args table
---@return table<string, NeotestResult>
function NeotestClient:_run_tree(tree, args, adapter)
  args = args or {}
  args.strategy = args.strategy or "integrated"
  local position = tree:data()

  async.util.scheduler()
  local spec = adapter.build_spec(vim.tbl_extend("force", args, {
    tree = tree,
  }))

  local results = {}

  if not spec then
    local function run_pos_types(pos_type)
      local async_runners = {}
      for _, node in tree:iter_nodes() do
        if node:data().type == pos_type then
          table.insert(async_runners, function()
            return self:_run_tree(node, args, adapter)
          end)
        end
      end
      local all_results = {}
      for i, res in ipairs(async.util.join(async_runners)) do
        all_results[i] = res[1]
      end
      return vim.tbl_extend("error", {}, unpack(all_results))
    end
    if position.type == "dir" then
      logger.warn("Adapter doesn't support running directories, attempting files")
      results = run_pos_types("file")
    elseif position.type == "file" then
      logger.warn("Adapter doesn't support running files")
      results = run_pos_types("test")
    end
  else
    spec.strategy = vim.tbl_extend(
      "force",
      spec.strategy or {},
      config.strategies[args.strategy] or {}
    )
    local process_result = self._processes:run(position.id, spec, args)
    results = adapter.results(spec, process_result, tree)
    if vim.tbl_isempty(results) then
      if #tree:children() ~= 0 then
        logger.warn("Results returned were empty, setting all positions to failed")
        for _, pos in tree:iter() do
          results[pos.id] = {
            status = "failed",
            errors = {},
            output = process_result.output,
          }
        end
      else
        results[tree:data().id] = { status = "skipped", output = process_result.output }
      end
    else
      for _, result in pairs(results) do
        if not result.output then
          result.output = process_result.output
        end
      end
    end
  end
  return results
end

---@async
---@param position Tree
function NeotestClient:attach(position)
  local node = position
  while node do
    local pos = node:data()
    if self._processes:attach(pos.id) then
      logger.debug("Attached to process for position", pos.name)
      return
    end
    node = node:parent()
  end
end

---@async
---@param file_path string
---@param row integer Zero-indexed row
---@return Tree | nil, integer | nil
function NeotestClient:get_nearest(file_path, row)
  local positions, adapter_id = self:get_position(file_path)
  if not positions then
    return
  end
  local nearest
  for _, pos in positions:iter_nodes() do
    local data = pos:data()
    if data.range and data.range[1] <= row then
      nearest = pos
    else
      return nearest, adapter_id
    end
  end
  return nearest, adapter_id
end

---@return string[]
function NeotestClient:get_adapters()
  return lib.func_util.map(function(adapter_id, adapter)
    return adapter_id, adapter.name
  end, self._adapters)
end

---@async
---@param position_id string
---@return Tree | nil, integer | nil
function NeotestClient:get_position(position_id, args)
  args = args or {}
  local refresh = args.refresh ~= false

  if not self._started then
    self:start()
  end
  if position_id and vim.endswith(position_id, lib.files.sep) then
    position_id = string.sub(position_id, 1, #position_id - #lib.files.sep)
  end
  local adapter_id = self:_get_adapter(position_id, args.adapter)
  local positions = self._state:positions(adapter_id, position_id)

  if refresh ~= false then
    -- To reduce memory, we lazy load files. We have to check the files are not
    -- read automatically more than once to prevent loops with empty files
    if
      positions
      and not self._files_read[position_id]
      and positions:data().type == "file"
      and #positions:children() == 0
    then
      self._files_read[position_id] = true
      self:update_positions(position_id, { adapter = adapter_id })
      positions = self._state:positions(adapter_id, position_id)
    end

    if not positions and position_id and lib.files.exists(position_id) then
      self:update_positions(position_id, { adapter = adapter_id })
      positions = self._state:positions(adapter_id, position_id)
    end
  end

  return positions, adapter_id
end

---@return table<string, NeotestResult>
function NeotestClient:get_results(adapter_id)
  return self._state:results(adapter_id)
end

function NeotestClient:is_running(position_id, args)
  args = args or {}
  if args.adapter then
    return self._state:running(args.adapter)[position_id] or false
  end
  for _, adapter_id in ipairs(self:get_adapters()) do
    if self._state:running(adapter_id)[position_id] then
      return true
    end
  end
  return false
end

function NeotestClient:is_test_file(file_path)
  return self:_get_adapter(file_path) ~= nil
end

---@async
---@param path string
function NeotestClient:update_positions(path, args)
  args = args or {}
  local adapter_id, adapter = self:_get_adapter(path, args.adapter)
  if not adapter then
    return
  end
  if not self._started then
    self:start()
  end
  local success, positions = pcall(function()
    if lib.files.is_dir(path) then
      local files = lib.func_util.filter_list(adapter.is_test_file, lib.files.find({ path }))
      return lib.files.parse_dir_from_files(path, files)
    else
      return adapter.discover_positions(path)
    end
  end)
  if not success then
    logger.info("Couldn't find positions in path", path, positions)
    return
  end
  local existing = self:get_position(path, { refresh = false, adapter = adapter_id })
  if positions:data().type == "file" and existing and #existing:children() == 0 then
    self:_propagate_results_to_new_positions(adapter_id, positions)
  end
  self._state:update_positions(adapter_id, positions)
end

---@return integer, NeotestAdapter | nil
function NeotestClient:_get_adapter(position_id, adapter_id)
  if not position_id and not adapter_id then
    adapter_id = self._adapters[1].name
  end
  if adapter_id then
    for _, adapter in ipairs(self._adapters) do
      if adapter_id == adapter.name then
        return adapter_id, adapter
      end
    end
  end
  for _, adapter in ipairs(self._adapters) do
    if self._state:positions(adapter.name, position_id) or adapter.is_test_file(position_id) then
      return adapter.name, adapter
    end
  end

  if not lib.files.exists(position_id) then
    return
  end

  local new_adapter = adapters.get_file_adapter(position_id)
  if not new_adapter then
    return
  end

  table.insert(self._adapters, new_adapter)
  return new_adapter.name, new_adapter
end

function NeotestClient:_propagate_results_to_new_positions(adapter_id, tree)
  local new_results = {}
  local results = self:get_results()
  for _, pos in tree:iter() do
    new_results[pos.id] = results[pos.id]
  end
  self:_collect_results(adapter_id, tree, new_results)
  if not vim.tbl_isempty(new_results) then
    self._state:update_results(adapter_id, new_results)
  end
end

function NeotestClient:_focused(path)
  local adapter_id = self:_get_adapter(path)
  if not adapter_id then
    return
  end
  self._state:update_focused(adapter_id, path)
end

function NeotestClient:start()
  self._started = true
  self:_update_adapters()
  vim.schedule(function()
    vim.cmd([[
      augroup Neotest 
        au!
        autocmd BufAdd,BufWritePost * lua require("neotest")._update_positions(vim.fn.expand("<afile>:p"))
        autocmd DirChanged * lua require("neotest")._dir_changed()
        autocmd BufDelete * lua require("neotest")._update_files(vim.fn.expand("<afile>:h"))
        autocmd BufEnter * lua require("neotest")._focus_file(vim.fn.expand("<afile>:p"))
      augroup END
    ]])
  end)
end

function NeotestClient:_update_adapters()
  local cwd = async.fn.getcwd()
  local all_adapters = vim.list_extend(
    adapters.adapters_with_root_dir(cwd),
    adapters.adapters_matching_open_bufs()
  )
  local new_adapters = {}
  local found = {}
  for _, adapter in pairs(self._adapters) do
    table.insert(new_adapters, adapter)
    found[adapter.name] = true
  end
  for _, adapter in ipairs(all_adapters) do
    if not found[adapter.name] then
      table.insert(new_adapters, adapter)
      found[adapter.name] = true
    end
  end
  self._adapters = new_adapters
  for _, adapter in ipairs(self._adapters) do
    local root = adapter.root(cwd)
    if not root then
      local existing_tree = self._state:positions(adapter.name)
      if existing_tree then
        root = existing_tree:data().path
      end
    end
    self:update_positions(root or cwd, { adapter = adapter.name })
  end
end
---@param events? NeotestEventProcessor
---@param state? NeotestState
---@param processes? NeotestProcessTracker
---@return NeotestClient
return function(events, state, processes)
  return NeotestClient:new(events, state, processes)
end
