-- Hindsight backend for the memory plugin.
-- When enabled, memories are stored/retrieved via Hindsight API instead of local files.

local M = {}

M.DEFAULT_BASE_URL = "http://localhost:8888"
M.DEFAULT_BANK = "maki"

-- Configuration (set by init.lua from opts)
M.base_url = M.DEFAULT_BASE_URL
M.bank = M.DEFAULT_BANK

-- Extract port from URL, default to 8888 for Hindsight
local function extract_port(url)
  local port_str = url:match(":(%d+)/?")
  if port_str then
    return tonumber(port_str)
  end
  -- Default ports
  if url:match("^https://") then
    return 443
  end
  return 80
end

-- Build the full endpoint URL
local function endpoint(path)
  local base = M.base_url:gsub("/$", "")
  return base .. path
end

-- Get the allowed loopback port from the configured URL
local function get_loopback_port()
  return extract_port(M.base_url)
end

-- Make a JSON POST request to Hindsight
local function post_json(path, body)
  local json_body = maki.json.encode(body)
  local res, err = maki.net.request(endpoint(path), {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = json_body,
    allow_loopback_port = get_loopback_port(),
  })
  if err then
    return nil, "request failed: " .. err
  end
  if res.status >= 400 then
    return nil, "HTTP " .. res.status .. ": " .. (res.body or "")
  end
  local decoded, decode_err = maki.json.decode(res.body)
  if decode_err then
    return nil, "failed to parse response: " .. decode_err
  end
  return decoded
end

-- Check if Hindsight server is reachable
function M.is_available()
  local res, err = maki.net.request(endpoint("/health"), {
    method = "GET",
    timeout = 2,
    allow_loopback_port = get_loopback_port(),
  })
  if err then
    return false
  end
  return res.status < 400
end

-- List memories, optionally filtered by tags
-- Returns formatted string similar to file-based format_list
function M.list(tags)
  local body = {
    bank_id = M.bank,
    limit = 100,
  }
  -- If tags provided, use them as a query filter
  if tags and #tags > 0 then
    body.query = "tags: " .. table.concat(tags, ", ")
  end

  local result, err = post_json("/v1/recall", body)
  if err then
    return nil, err
  end

  local memories = result.memories or result.results or result
  if type(memories) ~= "table" or #memories == 0 then
    return "No memories found."
  end

  -- Group by tags for display similar to file-based backend
  local by_tag = {}
  local tag_order = {}
  for _, mem in ipairs(memories) do
    local mem_tags = (mem.metadata and mem.metadata.tags) or { "untagged" }
    if type(mem_tags) == "string" then
      mem_tags = { mem_tags }
    end
    for _, tag in ipairs(mem_tags) do
      if not by_tag[tag] then
        by_tag[tag] = {}
        tag_order[#tag_order + 1] = tag
      end
      by_tag[tag][#by_tag[tag] + 1] = {
        id = mem.id or "unknown",
        preview = (mem.content or ""):sub(1, 50):gsub("\n", " "),
      }
    end
  end

  local parts = {}
  for _, tag in ipairs(tag_order) do
    local entries = by_tag[tag]
    parts[#parts + 1] = string.format("## %s (%d)", tag, #entries)
    for _, e in ipairs(entries) do
      parts[#parts + 1] = string.format("- [%s] %s...", e.id, e.preview)
    end
  end

  return table.concat(parts, "\n")
end

-- Read memories by tags (semantic search)
function M.read_by_tags(tags)
  if not tags or #tags == 0 then
    return nil, "tags required for read"
  end

  local body = {
    bank_id = M.bank,
    query = table.concat(tags, " "),
    limit = 10,
  }

  local result, err = post_json("/v1/recall", body)
  if err then
    return nil, err
  end

  local memories = result.memories or result.results or result
  if type(memories) ~= "table" or #memories == 0 then
    return "No memories matched the given tags."
  end

  local parts = {}
  for i, mem in ipairs(memories) do
    local header = string.format("## Memory %d", i)
    if mem.id then
      header = header .. string.format(" (id: %s)", mem.id)
    end
    local content = mem.content or mem.text or "(empty)"
    parts[#parts + 1] = header .. "\n\n" .. content
  end

  return table.concat(parts, "\n\n---\n\n")
end

-- Read a specific memory by ID (path in file-based terms)
function M.read_by_path(path)
  -- In Hindsight, "path" is treated as a memory ID or a search query
  local body = {
    bank_id = M.bank,
    query = path,
    limit = 1,
  }

  local result, err = post_json("/v1/recall", body)
  if err then
    return nil, err
  end

  local memories = result.memories or result.results or result
  if type(memories) ~= "table" or #memories == 0 then
    return nil, "memory not found: " .. path
  end

  local mem = memories[1]
  return mem.content or mem.text or "(empty)"
end

-- Write a memory with optional tags
function M.write(path, content, tags)
  if not content or content == "" then
    return nil, "content required"
  end

  local metadata = {}
  if path and path ~= "" then
    metadata.path = path
  end
  if tags and #tags > 0 then
    metadata.tags = tags
  end

  local body = {
    bank_id = M.bank,
    content = content,
  }
  if next(metadata) then
    body.metadata = metadata
  end

  local result, err = post_json("/v1/retain", body)
  if err then
    return nil, err
  end

  local id = result.id or result.memory_id or "(unknown)"
  local tag_str = (tags and #tags > 0) and table.concat(tags, ", ") or "none"
  return string.format("stored memory %s (tags: %s)", id, tag_str)
end

-- Delete is not directly supported by Hindsight's simple API
-- We return an error explaining this limitation
function M.delete(path)
  -- Hindsight doesn't have a simple delete-by-id in the basic API
  -- This would require the full management API
  return nil, "delete not supported with Hindsight backend; use Hindsight UI to manage memories"
end

-- Format tag line for system prompt (similar to file-based)
function M.format_tag_line(max_tags)
  local body = {
    bank_id = M.bank,
    limit = 50,
  }

  local result, err = post_json("/v1/recall", body)
  if err then
    return nil
  end

  local memories = result.memories or result.results or result
  if type(memories) ~= "table" or #memories == 0 then
    return nil
  end

  -- Collect unique tags
  local seen = {}
  local tags = {}
  for _, mem in ipairs(memories) do
    local mem_tags = (mem.metadata and mem.metadata.tags) or {}
    if type(mem_tags) == "string" then
      mem_tags = { mem_tags }
    end
    for _, tag in ipairs(mem_tags) do
      if not seen[tag] then
        seen[tag] = true
        tags[#tags + 1] = tag
        if #tags >= (max_tags or 50) then
          break
        end
      end
    end
    if #tags >= (max_tags or 50) then
      break
    end
  end

  if #tags == 0 then
    return nil
  end

  return table.concat(tags, ", ")
end

return M
