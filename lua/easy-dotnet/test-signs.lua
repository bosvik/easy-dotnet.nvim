local polyfills = require("easy-dotnet.polyfills")
local logger = require("easy-dotnet.logger")
local M = {}

local function compare_paths(path1, path2)
  if not path1 or type(path1) == "userdata" then return false end
  if not path2 or type(path2) == "userdata" then return false end

  return vim.fs.normalize(path1):lower() == vim.fs.normalize(path2):lower()
end

local function run_test(name, namespace, cs_project_path, cb)
  local log_file_name = string.format("%s.xml", namespace:gsub("%b()", ""))
  local normalized_path = vim.fs.normalize(cs_project_path)
  local directory_path = vim.fs.dirname(normalized_path)
  local relative_log_file_path = polyfills.fs.joinpath(directory_path, "TestResults", log_file_name)

  local command = string.format("dotnet test --filter='%s' --nologo %s --logger='trx;logFileName=%s'", namespace:gsub("%b()", ""), cs_project_path, log_file_name)

  vim.fn.jobstart(command, {
    on_exit = function()
      require("easy-dotnet.test-runner.test-parser").xml_to_json(
        relative_log_file_path,
        ---@param unit_test_results TestCase
        function(unit_test_results)
          local result = unit_test_results[1]
          if result == nil then error(string.format("Status of %s was not present in xml file", name)) end
          cb(unit_test_results)
        end
      )
    end,
  })
end

local function debug_test_from_buffer()
  local success, dap = pcall(function() return require("dap") end)
  if not success then
    logger.error("nvim-dap not installed")
    return
  end

  local curr_file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  require("easy-dotnet.test-runner.render").traverse(nil, function(node)
    if (node.type == "test" or node.type == "test_group") and compare_paths(node.file_path, curr_file) and node.line_number - 1 == current_line then
      --TODO: Investigate why netcoredbg wont work without reopening the buffer????
      vim.cmd("bdelete")
      vim.cmd("edit " .. node.file_path)
      vim.api.nvim_win_set_cursor(0, { node.line_number and (node.line_number - 1) or 0, 0 })
      dap.toggle_breakpoint()

      local dap_configuration = {
        type = "coreclr",
        name = node.name,
        request = "attach",
        processId = function()
          local project_path = node.cs_project_path
          local res = require("easy-dotnet.debugger").start_debugging_test_project(project_path)
          return res.process_id
        end,
      }
      dap.run(dap_configuration)
      --return to avoid running multiple times in case of InlineData|ClassData
      return
    end
  end)
end

local function run_test_from_buffer()
  local options = require("easy-dotnet.test-runner.render").options
  local constants = require("easy-dotnet.constants")
  local signs = constants.signs
  local sign_ns = constants.sign_namespace

  local bufnr = vim.api.nvim_get_current_buf()
  local curr_file = vim.api.nvim_buf_get_name(bufnr)
  local current_line = vim.api.nvim_win_get_cursor(0)[1]

  ---@param node TestNode
  require("easy-dotnet.test-runner.render").traverse(nil, function(node)
    if (node.type == "test" or node.type == "test_group") and compare_paths(node.file_path, curr_file) and node.line_number - 1 == current_line then
      if node.is_MTP then
        logger.error("Running MTP tests directly from buffer is not supported yet")
        return
      end

      local spinner = require("easy-dotnet.ui-modules.spinner").new()
      spinner:start_spinner("Running test")

      run_test(node.name, node.namespace, node.cs_project_path, function(results)
        ---@type TestResult
        local worst_outcome = "Passed"

        for _, result in pairs(results) do
          if result.outcome == "Failed" then
            worst_outcome = "Failed"
          elseif result.outcome == "NotExecuted" and worst_outcome ~= "Failed" then
            worst_outcome = "NotExecuted"
          elseif result.outcome == "Passed" and worst_outcome ~= "Failed" and worst_outcome ~= "NotExecuted" then
            worst_outcome = "Passed"
          end
        end

        if worst_outcome == "Passed" then
          node.icon = options.icons.passed
          vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestPassed, bufnr, { lnum = current_line, priority = 20 })
          spinner:stop_spinner("Passed")
        elseif worst_outcome == "Failed" then
          node.icon = options.icons.failed
          vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestFailed, bufnr, { lnum = current_line, priority = 20 })
          spinner:stop_spinner("Failed", vim.log.levels.ERROR)
        elseif worst_outcome == "NotExecuted" then
          node.icon = options.icons.skipped
          vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestSkipped, bufnr, { lnum = current_line, priority = 20 })
          spinner:stop_spinner("Skipped", vim.log.levels.WARN)
        else
          node.icon = "??"
          spinner:stop_spinner("Test Result Errors", vim.log.levels.WARN)
          vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestError, bufnr, { lnum = current_line, priority = 20 })
        end
        require("easy-dotnet.test-runner.render").refreshTree()
      end)
      return
    end
  end)
end

function M.add_gutter_test_signs()
  local options = require("easy-dotnet.test-runner.render").options
  local constants = require("easy-dotnet.constants")
  local signs = constants.signs
  local sign_ns = constants.sign_namespace
  local is_test_file = false
  local bufnr = vim.api.nvim_get_current_buf()
  local curr_file = vim.api.nvim_buf_get_name(bufnr)

  ---@param node TestNode
  require("easy-dotnet.test-runner.render").traverse(nil, function(node)
    if (node.type == "test" or node.type == "test_group") and compare_paths(node.file_path, curr_file) then
      is_test_file = true
      local line = node.line_number
      vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestSign, bufnr, { lnum = line - 1, priority = 20 })

      if node.icon then
        if node.icon == options.icons.failed then
          vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestFailed, bufnr, { lnum = line - 1, priority = 20 })
        elseif node.icon == options.icons.skipped then
          vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestSkipped, bufnr, { lnum = line - 1, priority = 20 })
        elseif node.icon == options.icons.passed then
          vim.fn.sign_place(0, sign_ns, signs.EasyDotnetTestPassed, bufnr, { lnum = line - 1, priority = 20 })
        end
      end
    end
  end)

  local keymap = require("easy-dotnet.test-runner.render").options.mappings
  if is_test_file == true then
    vim.keymap.set("n", keymap.debug_test_from_buffer.lhs, function() debug_test_from_buffer() end, { silent = true, buffer = bufnr, desc = keymap.debug_test_from_buffer.desc })

    vim.keymap.set("n", keymap.run_test_from_buffer.lhs, function() run_test_from_buffer() end, { silent = true, buffer = bufnr, desc = keymap.run_test_from_buffer.desc })
  end
end

return M
