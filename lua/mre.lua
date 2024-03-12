local M = {}

M.opts = {}
M.edits = {}
M.cursor = 1

-- todo: although this does store a copy of row/col in the main table, I think it probably shouldn't. It needs to be
-- serialized, but when in memory it should probably just look into the extmark for everything.

-- todo: how do you define a lua type spec for this?
-- each location looks like this:
-- {
--   file = file,
--   bufnr = bufnr,
--   id = id, -- the extmark id
--   row = row,
--   col = col,
--   virt_text = virt_text
-- }

function M.debug(msg)
  M.opts.debug = true
  if M.opts.debug then
    vim.notify(vim.inspect(msg))
  end
end

function M.log(msg)
  M.opts.verbose = true
  if M.opts.verbose then
    vim.print(msg)
  end
end

function M.open_or_edit(file)
  local existing = vim.fn.bufnr(file)
  if existing ~= -1 then
    vim.cmd.buffer(existing)
    return
  end

  vim.cmd.edit(file)
end

local function reversedipairsiter(t, i)
  i = i - 1
  if i ~= 0 then
    return i, t[i]
  end
end

local function reversedipairs(t)
  return reversedipairsiter, t, #t + 1
end

function M.create_extmark(file, bufnr, row, col, virt_text, id)
  local ns_id = vim.api.nvim_create_namespace("mre")

  -- see if there is already an extmark on this line
  id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, col, {
    id = id,
    virt_text = { { virt_text, "Function" } },
    virt_text_pos = "right_align",
    strict = false
  })

  local location = { file = file, bufnr = bufnr, id = id, row = row, col = col, virt_text = virt_text }

  return location
end

function M.track_edit(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)

  -- set extmark at this location with text that says "edited"
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  -- see if there is an existing mark at this line
  local existing_mark = nil
  for _, location in ipairs(M.edits) do
    if location.file == file and location.row == row then
      existing_mark = location
      break
    end
  end

  -- setting id to nil will create a new mark
  local id = nil
  if existing_mark then
    id = existing_mark.id
  end

  local virt_text = M.opts.virt_text
  -- virt text is position in the list
  if M.opts.dynamic_virt_text then
    virt_text = tostring(#M.edits)
  end

  -- sometimes column is out of bounds even though it shouldn't be? I don't really get it
  local success, location = pcall(M.create_extmark, file, bufnr, row, col, virt_text, id)
  if success then
    -- pop this onto the edits list. We will store the extmark_id, row, col, virt_text, and file.

    if existing_mark then
      -- replace the existing mark
      for i, edit in reversedipairs(M.edits) do
        if edit.id == existing_mark.id then
          M.edits[i] = location
          break
        end
      end
    else
      table.insert(M.edits, location)
    end

    M.cursor = #M.edits + 1
  else
    -- M.debug("failed to create extmark")
  end

  -- remove entries for this file that are past max_history_per_file or max_history
  local edits_per_file = {}
  for _, l in reversedipairs(M.edits) do
    edits_per_file[l.file] = (edits_per_file[l.file] or 0) + 1

    if edits_per_file[l.file] > M.opts.max_history_per_file then
      local ns_id = vim.api.nvim_create_namespace("mre")
      if l.bufnr then
        vim.api.nvim_buf_del_extmark(l.bufnr, ns_id, l.id)
      end
      table.remove(M.edits, 1)
    end
  end

  -- remove all entries past max_history
  while #M.edits > M.opts.max_history do
    local ns_id = vim.api.nvim_create_namespace("mre")
    local l = M.edits[1]
    if l.bufnr then
      vim.api.nvim_buf_del_extmark(l.bufnr, ns_id, l.id)
    end
    table.remove(M.edits, 1)
  end

  -- loop through all locations and delete the ones that point to the same row/col
  if M.opts.dedupe_line then
    local seen = {}
    for i, l in ipairs(M.edits) do
      if seen[l.file] and seen[l.file][l.row] then
        if not M.opts.dedupe_column then
          M.delete_location(l, i)
        else
          if seen[l.file] and seen[l.file][l.row] and seen[l.file][l.row][l.col] then
            M.delete_location(l, i)
          end
        end
      end

      if not seen[l.file] then
        seen[l.file] = {}
      end

      if not seen[l.file][l.row] then
        seen[l.file][l.row] = {}
      end

      seen[l.file][l.row][l.col] = true
    end
  end


  -- todo: loop through the edits and set index so that dynamic_virt_text can actually work/enable fancy highlighting

  -- todo: should this happen async?
  -- todo: when saving cache, we probably need to loop through the extmarks and update the location table with each
  -- extmarks updated line/col, because they will auto update but our table will not.
  M.save_cache(M.edits)
end

-- pass this the location entry and the index its at in the edits table
function M.delete_location(location, index)
  local ns_id = vim.api.nvim_create_namespace("mre")
  if location.bufnr then
    vim.api.nvim_buf_del_extmark(location.bufnr, ns_id, location.id)
  end
  table.remove(M.edits, index)
end

function M.clear()
  M.edits = {}
  M.cursor = 1

  -- loop through all open buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("mre"), 0, -1)
  end

  M.save_cache(M.edits)
end

function M.jump_next()
  -- if cursor is out of bounds, wrap it around
  if M.cursor >= #M.edits then
    M.cursor = 0
  end

  M.cursor = M.cursor + 1
  M.jump_to(M.edits[M.cursor])
end

function M.jump_prev()
  -- if cursor is out of bounds, wrap it around
  if M.cursor <= 1 then
    M.cursor = #M.edits + 1
  end

  M.cursor = M.cursor - 1
  M.jump_to(M.edits[M.cursor])
end

function M.jump_to(location)
  if location == nil then
    M.log("no location to jump to, resetting cursor")

    M.cursor = 1

    return
  end

  -- if bufnr is set but the buffer isn't loaded, that means it could just be stale.
  -- attempt to open the buffer, but don't create an extmark for it.
  if location.bufnr ~= nil then
    local bufnr = location.bufnr
    if vim.api.nvim_buf_is_loaded(bufnr) == 0 then
      -- vim.api.nvim_command("e " .. location.file)
      M.open_or_edit(location.file)

      M.debug("buffer isn't loaded")

      -- then update the buffer number
      bufnr = vim.api.nvim_get_current_buf()
      for i, edit in ipairs(M.edits) do
        if edit.id == location.id then
          M.edits[i].bufnr = bufnr
        end
      end
    end
  end

  -- if bufnr is nil, this means we loaded this entry from cache, but didn't create an extmark for it
  -- we will attempt to create that extmark now.
  if location.bufnr == nil then
    local bufnr = vim.fn.bufadd(location.file)
    vim.fn.setbufvar(bufnr, "&buflisted", 1)

    -- necessary?
    -- vim.api.nvim_command("e " .. location.file)

    local success, new_better_location = pcall(M.create_extmark, location.file, bufnr, location.row, location.col,
      location.virt_text, nil)
    if success then
      location = new_better_location
      M.edits[M.cursor] = location
    else
      -- if we failed to create the extmark, we will just skip this entry.
      M.debug("failed to create extmark for location")
      return
    end

    -- todo: there is a bug where it looks like you're not jumping when multiple edits point to the same line, which is
    -- possible when extmarks join into each other. could maybe detect that here and go to the next spot. Or
    -- alternatively could have track_edit loop through all the marks and delete duplicates.
  end

  -- todo: probably need to augment this to check more intelligently if the bufnr is infact pointing to the thing in
  -- location.file. I've been experiencing situations where an edit is stored in a plugins buffer that isn't a file.
  vim.api.nvim_win_set_buf(0, location.bufnr)

  -- get the extmark from location.id
  local pos = M.get_position_from_entry(location)

  if pos == nil then
    -- should probably log something here huh
    pos = { row = location.row, col = location.col }
  end

  M.log("jumping to: [" .. M.cursor .. "] " .. location.file .. " " .. pos.row .. " " .. pos.col)

  vim.api.nvim_win_set_cursor(0, { pos.row, pos.col })
end

function M.get_position_from_entry(location)
  local ns_id = vim.api.nvim_create_namespace("mre")
  local success, extmark = pcall(vim.api.nvim_buf_get_extmark_by_id, location.bufnr, ns_id, location.id,
    { details = true })
  if success then
    if extmark == {} or extmark == nil then
      return
    end

    local row = extmark[1] + 1
    local col = extmark[2]

    return { row = row, col = col }
  else
    -- do nothing?
    return
  end
end

function M.cache_path()
  return vim.fn.stdpath("cache") .. "/mre"
end

function M.save_cache(edits)
  local path = M.cache_path()

  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, "p")
  end

  local cache = M.serialize_cache(edits)

  vim.fn.writefile(cache, path .. "/cache")
end

function M.load_cache()
  local path = M.cache_path()

  local success, data = pcall(vim.fn.readfile, path .. "/cache")
  if success then
    M.deserialize_cache(data)
  else
    -- do nothing?
  end
end

function M.serialize_cache(edits)
  local lines = {}
  for _, location in ipairs(edits) do
    local pos = M.get_position_from_entry(location)
    -- local pos = nil

    if pos == nil then
      pos = { row = location.row, col = location.col }
    end

    local entry = string.format(
      "%s:%s:%s:%s:%s",
      location.file,
      location.bufnr,
      pos.row,
      pos.col,
      location.virt_text
    )
    table.insert(lines, entry)
  end

  return lines
end

function M.deserialize_cache(lines)
  -- loop through every entry and create extmarks for them
  for _, line in ipairs(lines) do
    local parts = vim.fn.split(line, ":")

    local entry = {
      file = parts[1],
      bufnr = tonumber(parts[2]),
      row = tonumber(parts[3]),
      col = tonumber(parts[4]),
      virt_text =
          parts[5]
    }

    -- before we try to create one, check if the entry.file is the current buffer
    if entry.file == vim.api.nvim_buf_get_name(0) then
      -- then check if entry.bufnr is not the bufnr of the current buffer
      if entry.bufnr ~= vim.api.nvim_get_current_buf() then
        -- if it's not, then we need to update the bufnr to the current buffer
        entry.bufnr = vim.api.nvim_get_current_buf()
      end
    end

    -- ^ the reason you have to do this is when saving and loading the cache, the bufnr will be different when you reload the buffer

    -- this could fail for a number of reasons, including this buffer not being open yet.
    -- if that is the case, we will try to create the extmark again when the buffer is opened.
    local success, location = pcall(M.create_extmark, entry.file, entry.bufnr, entry.row, entry.col, entry.virt_text, nil)
    if success then
      table.insert(M.edits, location)
      M.cursor = #M.edits + 1
    else
      -- this is where we will insert the location without the extmark into the edits table.
      -- the fact that it's missing some key things will clue later functions into the fact that they should try to create the extmark again.
      local location = {
        file = entry.file,
        bufnr = nil,
        id = nil,
        row = entry.row,
        col = entry.col,
        virt_text = entry.virt_text
      }

      table.insert(M.edits, location)
      M.cursor = #M.edits + 1
    end
  end
end

M.defaults = {
  max_history_per_file = 30,
  max_history = 100,
  virt_text = "-",
  dynamic_virt_text = false,
  dedupe_line = true,
  dedupe_column = false,
  verbose = true,
  debug = true,
}

function M.setup(opts)
  opts = vim.tbl_deep_extend("force", M.defaults, opts or {})

  M.opts = opts

  -- set of filetypes that changes will not be tracked on
  -- todo: accept config for this
  local ignore_filetypes = {
    "fugitive",
    "fugitiveblame",
    "gitcommit",
    "gitrebase",
    "git",
    "qf",
    "help",
    "copilot"
  }

  vim.api.nvim_create_autocmd({ "TextChanged", "InsertEnter" }, {
    pattern = "*",
    callback = function(e)
      if vim.tbl_contains(ignore_filetypes, vim.bo.filetype) then
        return
      end

      -- ignore if not modifiable, not buflisted or buftype is not empty
      if vim.bo.modifiable == false or vim.bo.buflisted == 0 or vim.bo.buftype ~= "" then
        return
      end

      require('mre').track_edit(e.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "VimEnter" }, {
    pattern = '*',
    callback = function()
      M.load_cache()
    end,
  })
end

return M
