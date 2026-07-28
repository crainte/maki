local ToolView = require("maki.tool_view")
local helpers = require("memory_helpers")
local ListPicker = require("maki.list_picker")

-- Options for memory backend configuration
local opts = maki.api.register_options({
  backend = {
    default = "file",
    desc = "Memory backend: 'file' (local markdown files) or 'hindsight' (Hindsight server).",
  },
  hindsight_url = {
    default = "http://localhost:8888",
    desc = "Hindsight server base URL (when backend='hindsight').",
  },
  hindsight_bank = {
    default = "maki",
    desc = "Hindsight bank ID for storing/retrieving memories.",
  },
})

-- Lazy-load hindsight backend only when needed
local hindsight = nil
local function get_hindsight()
  if not hindsight then
    hindsight = require("hindsight_backend")
  end
  -- Update config from opts
  hindsight.base_url = opts.hindsight_url
  hindsight.bank = opts.hindsight_bank
  return hindsight
end

local function use_hindsight()
  return opts.backend == "hindsight"
end

-- File backend helpers
local function memories_path_suffix()
  local cwd = maki.uv.cwd()
  local root = maki.fs.root(cwd, ".git") or cwd
  return "projects/" .. helpers.project_id(root) .. "/memories"
end

local function resolve_dir(check_legacy)
  if check_legacy then
    local legacy = maki.env.legacy_dir()
    if legacy then
      local dir = maki.fs.joinpath(legacy, memories_path_suffix())
      local meta = maki.fs.metadata(dir)
      if meta and meta.is_dir then
        return dir
      end
    end
  end
  local state = maki.env.state_dir()
  if not state then
    return nil, "cannot resolve state dir"
  end
  return maki.fs.joinpath(state, memories_path_suffix())
end

-- Prompt hint for system prompt - shows available tags
maki.api.register_prompt_hint({
  prompt = "system",
  slot = "after_instructions",
  content = function()
    if use_hindsight() then
      local hs = get_hindsight()
      local tag_line = hs.format_tag_line(helpers.MAX_TAGS)
      if not tag_line then
        return nil
      end
      return "\n\nMemory tags (memory tool, `read tags=[...]`): " .. tag_line .. " [via Hindsight]\n"
    else
      local dir = resolve_dir(true)
      if not dir then
        return nil
      end
      local tag_line = helpers.format_tag_line(dir, helpers.MAX_TAGS)
      if not tag_line then
        return nil
      end
      return "\n\nMemory tags (memory tool, `read tags=[...]`): " .. tag_line .. "\n"
    end
  end,
})

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = "- Proactively save non-obvious project gotchas and architecture decisions to **memory**.",
})

local function render_content(content, path, ctx)
  local buf = maki.ui.buf()
  local tol = ctx:tool_output_lines()
  local view = ToolView.new(buf, {
    max_lines = (tol and tol.other) or 20,
    keep = "head",
  })
  buf:on("click", function()
    view:toggle()
  end)

  local ext = path:match("%.([^%.]+)$") or "md"
  if not view:set_highlight(content, ext) then
    view:append_text(content)
  end
  view:finish()
  return buf
end

-- File backend commands
local function file_cmd_read(path, dir, ctx)
  local file_path, err = helpers.safe_resolve(dir, path)
  if not file_path then
    return nil, err
  end
  local content, read_err = maki.fs.read(file_path)
  if not content then
    return nil, "read error: " .. read_err
  end
  local formatted =
    helpers.cap_read_output(helpers.format_read_entry(path, #content, content), helpers.CAP_HINT_REWRITE)
  return {
    llm_output = formatted,
    body = render_content(formatted, path, ctx),
  }
end

local function file_cmd_write(path, content, tags, dir, ctx)
  local file_path, err = helpers.safe_resolve(dir, path)
  if not file_path then
    return nil, err
  end

  local size_err = helpers.validate_write_size(content)
  if size_err then
    return nil, size_err
  end
  local normalized, tag_err, note = helpers.validate_write_tags(tags or {})
  if tag_err then
    return nil, tag_err
  end
  local full = helpers.encode_frontmatter(normalized) .. content
  maki.fs.mkdir(dir, { parents = true })
  local ok, write_err = maki.fs.write(file_path, full)
  if not ok then
    return nil, "write error: " .. tostring(write_err)
  end
  return {
    llm_output = "wrote "
      .. path
      .. " (tags: "
      .. (#normalized > 0 and table.concat(normalized, ", ") or "none")
      .. ")"
      .. (note and ("; " .. note) or ""),
    body = render_content(content, path, ctx),
  }
end

local function file_cmd_delete(path, dir)
  local file_path, err = helpers.safe_resolve(dir, path)
  if not file_path then
    return nil, err
  end
  if not maki.fs.metadata(file_path) then
    return nil, "'" .. path .. "' does not exist"
  end
  local ok, rm_err = maki.fs.rm(file_path)
  if not ok then
    return nil, "delete error: " .. tostring(rm_err)
  end
  return "deleted " .. path
end

-- Hindsight backend commands
local function hs_cmd_list(tags, ctx)
  local hs = get_hindsight()
  local result, err = hs.list(tags)
  if err then
    return nil, err
  end
  return result
end

local function hs_cmd_read(path, tags, ctx)
  local hs = get_hindsight()
  local result, err
  if tags and #tags > 0 then
    result, err = hs.read_by_tags(tags)
  else
    result, err = hs.read_by_path(path)
  end
  if err then
    return nil, err
  end
  return {
    llm_output = result,
    body = render_content(result, path or "memory.md", ctx),
  }
end

local function hs_cmd_write(path, content, tags, ctx)
  local hs = get_hindsight()
  local result, err = hs.write(path, content, tags)
  if err then
    return nil, err
  end
  return {
    llm_output = result,
    body = render_content(content, path or "memory.md", ctx),
  }
end

local function hs_cmd_delete(path)
  local hs = get_hindsight()
  return hs.delete(path)
end

-- Build description based on backend
local function get_description()
  local base = "Persistent, project-scoped scratchpad for learnings, patterns, decisions, and gotchas across sessions.\n\n"
    .. "- Notes are retrieved by tag; reuse the tags from your system prompt when they fit.\n"
    .. "- Save important context before compaction or to build up project knowledge.\n"
    .. "- Keep entries concise and current. Delete outdated information."
  if use_hindsight() then
    base = base .. "\n\n(Backed by Hindsight: " .. opts.hindsight_url .. ", bank: " .. opts.hindsight_bank .. ")"
  end
  return base
end

maki.api.register_tool({
  name = "memory",
  description = "Persistent, project-scoped scratchpad for learnings, patterns, decisions, and gotchas across sessions.\n\n"
    .. "- Notes are retrieved by tag; reuse the tags from your system prompt when they fit.\n"
    .. "- Save important context before compaction or to build up project knowledge.\n"
    .. "- Keep entries concise and current. Delete outdated information.",

  schema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        enum = { "list", "read", "write", "delete" },
        description = "- `list [tags]`: tag-grouped index, no bodies.\n"
          .. "- `read path|tags`: one body (path) or collated bodies (tags).\n"
          .. "- `write path tags content`: create or overwrite a note.\n"
          .. "- `delete path`",
        required = true,
      },
      path = {
        type = "string",
        description = "Relative path, e.g. 'architecture.md'.",
      },
      content = { type = "string", description = "Body for write (frontmatter added automatically)." },
      tags = {
        type = "array",
        items = { type = "string" },
        description = "snake_case tags. Filter for list/read; assigned on write (defaults to filename stem).",
      },
    },
  },

  header = function(input)
    local parts = { input.command or "" }
    if input.path then
      parts[#parts + 1] = input.path
    elseif input.tags then
      parts[#parts + 1] = table.concat(input.tags, ",")
    end
    return table.concat(parts, " ")
  end,

  restore = function(input, output, _is_error, ctx)
    local content = (input.command == "write" and input.content) or output
    return render_content(content, input.path or "memory.md", ctx)
  end,

  handler = function(input, ctx)
    if type(input.tags) == "string" then
      input.tags = { input.tags }
    end
    local verr = helpers.validate_input(input)
    if verr then
      return { llm_output = "error: " .. verr, is_error = true }
    end

    local cmd = input.command
    local result, err

    if use_hindsight() then
      -- Hindsight backend
      if cmd == "list" then
        result, err = hs_cmd_list(input.tags, ctx)
      elseif cmd == "read" then
        result, err = hs_cmd_read(input.path, input.tags, ctx)
      elseif cmd == "write" then
        result, err = hs_cmd_write(input.path, input.content, input.tags, ctx)
      elseif cmd == "delete" then
        result, err = hs_cmd_delete(input.path)
      end
    else
      -- File backend (original behavior)
      local dir, dir_err = resolve_dir(cmd == "list" or cmd == "read")
      if not dir then
        return { llm_output = "error: " .. dir_err, is_error = true }
      end

      if cmd == "list" then
        result, err = helpers.format_list(dir, input.tags)
      elseif cmd == "read" then
        if input.tags and #input.tags > 0 then
          result, err = helpers.format_read(dir, input.tags)
        else
          result, err = file_cmd_read(input.path, dir, ctx)
        end
      elseif cmd == "write" then
        result, err = file_cmd_write(input.path, input.content, input.tags, dir, ctx)
      elseif cmd == "delete" then
        result, err = file_cmd_delete(input.path, dir)
      end
    end

    if err then
      return { llm_output = "error: " .. err, is_error = true }
    end
    return result
  end,
})

-- File picker UI (only works with file backend)
local function popup_build_items(dir)
  local groups, warnings = helpers.grouped_tags(dir)
  local items = {}
  for _, g in ipairs(groups) do
    for _, f in ipairs(g.files) do
      items[#items + 1] = {
        label = f.name,
        detail = "(" .. f.size .. " bytes)",
        section = g.tag,
        section_detail = "(" .. #g.files .. ")",
      }
    end
  end
  return items, warnings
end

maki.api.register_command({
  name = "/memory",
  description = "View, edit, and delete memory files",
  handler = function()
    if use_hindsight() then
      maki.ui.flash("Memory browser not available with Hindsight backend; use Hindsight UI at " .. opts.hindsight_url)
      return
    end

    local dir = resolve_dir(true)
    if not dir then
      maki.ui.flash("Cannot resolve memory directory")
      return
    end

    local items, warnings = popup_build_items(dir)
    if #items == 0 then
      maki.ui.flash("No memories yet")
      return
    end
    if #warnings > 0 then
      maki.ui.flash(#warnings .. " unreadable memory file(s)")
    end
    local last_cursor = 1
    while true do
      if last_cursor > #items then
        last_cursor = math.max(1, #items)
      end
      local event = ListPicker.open(items, {
        title = " Memory Files ",
        cursor = last_cursor,
        submit_keys = { "ctrl+o" },
        footer = {
          { "Enter", "open" },
          { "Ctrl+O", "edit" },
          { "Ctrl+D", "delete" },
        },
      })

      if event.type == "close" then
        break
      end

      last_cursor = event.index
      if event.type == "choice" then
        local item = items[event.index]
        if item then
          local path = maki.fs.joinpath(dir, item.label)
          local code = maki.ui.open_editor(path)
          if code == 0 then
            items = popup_build_items(dir)
          end
        end
      elseif event.type == "delete" then
        local item = items[event.index]
        local ok, rm_err = maki.fs.rm(maki.fs.joinpath(dir, item.label))
        if ok then
          maki.ui.flash("Deleted " .. item.label)
          items = popup_build_items(dir)
          if #items == 0 then
            break
          end
        else
          maki.ui.flash("Delete failed: " .. tostring(rm_err))
        end
      else
        break
      end
    end
  end,
})
