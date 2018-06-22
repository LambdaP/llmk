#!/usr/bin/env texlua

--
-- llmk.lua
--

-- program information
prog_name = 'llmk'
version = '0.0.0'
author = 'Takuto ASAKURA (wtsnjp)'

llmk_toml = 'llmk.toml'

-- option flags (default)
debug = {
  version = false,
  config = false,
  parser = false,
}
verbosity_level = 1

-- exit codes
exit_ok = 0
exit_error = 1
exit_parser = 2

----------------------------------------

-- basic config table
config = {
  latex = 'lualatex',
  sequence = { 'latex', 'dvipdf' },
  max_repeat = 3,
}

-- program presets
config.programs = {
  latex = {
    command = '',
    arg = '%T',
  },
  dvipdf = {
    command = '',
    arg = '%B',
  },
}

----------------------------------------

-- library
require 'lfs'

-- global functions
function err_print(err_type, msg)
  if (verbosity_level > 1) or (err_type == 'error') then
    io.stderr:write(prog_name .. ' ' .. err_type .. ': ' .. msg .. '\n')
  end
end

function dbg_print(dbg_type, msg)
  if debug[dbg_type] then
    io.stderr:write(prog_name .. ' debug-' .. dbg_type .. ': ' .. msg .. '\n')
  end
end

----------------------------------------

do
  local function parser_err(msg)
    err_print('error', 'parser: ' .. msg)
    os.exit(exit_parser)
  end

  local function parse_toml(toml)
    -- basic local variables
    local ws = '[\009\032]'
    local nl = '[\10\13\10]'

    local buffer = ''
    local cursor = 1

    local res = {}
    local obj = res

    -- basic local functions
    local function char(n)
      n = n or 0
      return toml:sub(cursor + n, cursor + n)
    end

    local function step(n)
      n = n or 1
      cursor = cursor + n
    end

    local function skip_ws()
      while(char():match(ws)) do
        step()
      end
    end

    local function trim(str)
      return str:gsub('^%s*(.-)%s*$', '%1')
    end

    local function bounds()
      return cursor <= toml:len()
    end

    -- parse functions for each type
    local function parse_string()
      -- TODO: multiline
      local del = char() -- ' or "
      local str = ''

      -- skip the quotes
      step()

      while(bounds()) do
        -- end of string
        if char() == del then
          step()
          break
        end

        if char():match(nl) then
          parser_err('Single-line string cannot contain line break')
        end

        -- TODO: process escape characters
        str = str .. char()
        step()
      end

      return str
    end

    local function parse_number()
      -- TODO: exp, date
      local num = ''

      while(bounds()) do
        if char():match('[%+%-%.eE_0-9]') then
          if char() ~= '_' then
            num = num .. char()
          end
        elseif char():match(ws) or char() == '#' or char():match(nl) then
          break
        else
          parser_err('Invalid number')
        end
        step()
      end

      return tonumber(num)
    end

    -- judge the type and get the value
    local function get_value()
      if (char() == '"' or char() == "'") then
        return parse_string()
      elseif char():match('[%+%-0-9]') then
        return parse_number()
      -- TODO: array, inline table, boolean
      end
    end

    -- main loop of parser
    while(cursor <= toml:len()) do
      -- ignore comments and whitespace
      if char() == '#' then
        while(not char():match(nl)) do
          step()
        end
      end

      if char():match(nl) then
        -- do nothing; skip
      end

      if char() == '=' then
        step()
        skip_ws()

        -- prepare the key
        key = trim(buffer)
        buffer = ''

        if key == '' then
          parser_err('Empty key name')
        end

        local value = get_value()
        if value then
          -- duplicate keys are not allowed
          if obj[key] then
            parser_err('Cannot redefine key "' .. key .. '"')
          end
          obj[key] = value
        end

        -- skip whitespace and comments
        skip_ws()
        if char() == '#' then
          while(bounds() and not char():match(nl)) do
            step()
          end
        end

        -- if garbage remains on this line, raise an error
        if not char():match(nl) and cursor < toml:len() then
          parser_err('Invalid primitive')
        end

      --elseif char() == '[' then
        -- TODO: arrays

      --elseif (char() == '"' or char() == "'") then
        -- TODO: quoted keys
      end

      -- put the char to the buffer and proceed
      buffer = buffer .. (char():match(nl) and '' or char())
      step()
    end

    return res
  end

  local function get_toml(fn)
    local toml = ''
    local toml_area = false

    f = io.open(fn)

    for l in f:lines() do
      if string.match(l, '^%s*%%%s*%+%+%++%s*$') then
        toml_area = not toml_area
      else
        if toml_area then
          toml = toml .. string.match(l, '^%s*%%%s*(.*)%s*$') .. '\n'
        end
      end
    end

    f:close()

    return toml
  end

  local function update_config(tab)
    -- merge the table from TOML
    for k, v in pairs(tab) do
      config[k] = v
    end

    -- set essential program names from top-level
    -- TODO: make DRY
    if (config.programs.latex.command == '' and config.latex) then
      config.programs.latex.command = config.latex
    end

    if (config.programs.dvipdf.command == '' and config.dvipdf) then
      config.programs.dvipdf.command = config.dvipdf
    end
  end

  function fetch_config_from_latex_source(fn)
    local toml = get_toml(fn)
    update_config(parse_toml(toml))
  end

  function fetch_config_from_llmk_toml()
    local f = io.open(llmk_toml)
    if f ~= nil then
      local toml = f:read('*all')
      update_config(parse_toml(toml))
      f:close()
    else
      err_print('error', 'not found: ' .. llmk_toml)
      os.exit(exit_error)
    end
  end
end

----------------------------------------

do
  local function construct_cmd(fn, prog)
    local cmd = prog.command
    local cmd_arg = prog.arg

    -- construct the argument
    local tmp = '/' .. fn
    local basename = tmp:match('^.*/(.*)%..*$')

    cmd_arg = cmd_arg:gsub('%%T', fn)
    cmd_arg = cmd_arg:gsub('%%B', basename)

    -- construct
    return cmd .. ' ' .. cmd_arg
  end

  local function run_latex(fn)
    for _, v in ipairs(config.sequence) do
      local prog = config.programs[v]

      if type(prog) ~= 'table' then
        err_print('error', 'Unknown program "' .. v .. '" deteted in the sequence.')
        os.exit(exit_error)
      end

      if type(prog.command) ~= 'string' then
        err_print('error', 'Command name for "' .. v .. '" is not detected.')
        os.exit(exit_error)
      end

      if #prog.command > 0 then
        local cmd = construct_cmd(fn, prog)
        err_print('info', 'running "' .. cmd .. '"')
        os.execute(cmd)
      else
        -- just skip
      end
    end
  end

  function make(fns)
    if #fns > 0 then
      local fn = fns[1]
      fetch_config_from_latex_source(fn)
      run_latex(fn)
    else
      fetch_config_from_llmk_toml()
      if config.source then
        run_latex(config.source)
      else
        err_print('error', 'No source detected')
        os.exit(exit_error)
      end
    end
  end
end

----------------------------------------

do
  -- help texts
  local usage_text = [[
Usage: llmk[.lua] [OPTION...] [FILE...]

Options:
  -h, --help            Print this help message.
  -V, --version         Print the version number.

  -q, --quiet           Suppress warnings and most error messages.
  -v, --verbose         Print additional information (eg, viewer command).
  -D, --debug           Activate all debug output (equal to "--debug=all").
  -dLIST, --debug=LIST  Activate debug output restricted to LIST.

Please report bugs to <wtsnjp@gmail.com>.
]]

  local version_text = [[
%s %s

Copyright 2018 %s.
License: The MIT License <https://opensource.org/licenses/mit-license.php>.
This is free software: you are free to change and redistribute it.
]]

  -- show uasage / help
  local function show_usage(out, text)
    out:write(usage_text)
  end

  -- execution functions
  local function read_options()
    local curr_arg
    local action = false

    -- modified Alternative Get Opt
    -- cf. http://lua-users.org/wiki/AlternativeGetOpt
    local function getopt(arg, options)
      local tmp
      local tab = {}
      local saved_arg = { table.unpack(arg) }
      for k, v in ipairs(saved_arg) do
        if string.sub(v, 1, 2) == "--" then
          table.remove(arg, 1)
          local x = string.find(v, "=", 1, true)
          if x then tab[string.sub(v, 3, x-1)] = string.sub(v, x+1)
          else   tab[string.sub(v, 3)] = true
          end
        elseif string.sub(v, 1, 1) == "-" then
          table.remove(arg, 1)
          local y = 2
          local l = string.len(v)
          local jopt
          while (y <= l) do
            jopt = string.sub(v, y, y)
            if string.find(options, jopt, 1, true) then
              if y < l then
                tmp = string.sub(v, y+1)
                y = l
              else
                table.remove(arg, 1)
                tmp = saved_arg[k + 1]
              end
              if string.match(tmp, '^%-') then
                tab[jopt] = false
              else
                tab[jopt] = tmp
              end
            else
              tab[jopt] = true
            end
            y = y + 1
          end
        end
      end
      return tab
    end

    opts = getopt(arg, 'd')
    for k, v in pairs(opts) do
      if #k == 1 then
        curr_arg = '-' .. k
      else
        curr_arg = '--' .. k
      end

      -- action
      if (curr_arg == '-h') or (curr_arg == '--help') then
        action = 'help'
      elseif (curr_arg == '-V') or (curr_arg == '--version') then
        action = 'version'
      -- debug
      elseif (curr_arg == '-D') or (curr_arg == '--debug' and v == 'all') then
        if verbosity_level < 1 then verbosity_level = 1 end
        for c, _ in pairs(debug) do
          debug[c] = true
        end
      elseif (curr_arg == '-d') or (curr_arg == 'debug') then
        if verbosity_level < 1 then verbosity_level = 1 end
        if debug[v] == nil then
          err_print('warning', 'unknown debug category: "' .. v .. '".')
        else
          debug['version'] = true
          debug[v] = true
        end
      -- verbosity
      elseif (curr_arg == '-q') or (curr_arg == '--quiet') then
        verbosity_level = 0
      elseif (curr_arg == '-v') or (curr_arg == '--verbose') then
        verbosity_level = 2
      -- problem
      else
        err_print('error', 'unknown option: ' .. curr_arg)
        os.exit(exit_error)
      end
    end

    return action
  end

  local function do_action()
    if action == 'help' then
      show_usage(io.stdout)
    elseif action == 'version' then
      io.stdout:write(version_text:format(prog_name, version, author))
    end
  end

  function main()
    action = read_options()

    if action then
      do_action()
      os.exit(exit_ok)
    end

    make(arg)
    os.exit(exit_ok)
  end
end

----------------------------------------

main()

-- EOF
