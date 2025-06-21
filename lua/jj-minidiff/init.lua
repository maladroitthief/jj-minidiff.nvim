local M = require("mini.diff")
local JJ = {}

JJ.cache = {}
JJ.jj_cache = {}
JJ.bom_bytes = {
	["utf-8"] = string.char(0xef, 0xbb, 0xbf),
	["utf-16be"] = string.char(0xfe, 0xff),
	["utf-16"] = string.char(0xfe, 0xff),
	["utf-16le"] = string.char(0xff, 0xfe),
	-- In 'fileencoding', 'utf-32' is transformed into 'ucs-4'
	["utf-32be"] = string.char(0x00, 0x00, 0xfe, 0xff),
	["ucs-4be"] = string.char(0x00, 0x00, 0xfe, 0xff),
	["utf-32"] = string.char(0x00, 0x00, 0xfe, 0xff),
	["ucs-4"] = string.char(0x00, 0x00, 0xfe, 0xff),
	["utf-32le"] = string.char(0xff, 0xfe, 0x00, 0x00),
	["ucs-4le"] = string.char(0xff, 0xfe, 0x00, 0x00),
}
JJ.get_buf_realpath = function(buf_id)
	return vim.loop.fs_realpath(vim.api.nvim_buf_get_name(buf_id)) or ""
end

JJ.get_buftext = function(buf_id)
	local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
	-- NOTE: Appending '\n' makes more intuitive diffs at end-of-file
	local text = table.concat(lines, "\n") .. "\n"
	if not vim.bo[buf_id].bomb then
		return text, lines
	end
	local bytes = JJ.bom_bytes[vim.bo[buf_id].fileencoding] or ""
	lines[1] = bytes .. lines[1]
	return bytes .. text, lines
end

JJ.jj_start_watching_tree_state = function(buf_id, path)
	local stdout = vim.loop.new_pipe()
	local args = { "workspace", "root" }
	local spawn_opts = {
		args = args,
		cwd = vim.fn.fnamemodify(path, ":h"),
		stdio = { nil, stdout, nil },
	}

	local on_not_in_jj = vim.schedule_wrap(function()
		if not vim.api.nvim_buf_is_valid(buf_id) then
			JJ.cache[buf_id] = nil
			return
		end
		M.fail_attach(buf_id)
		JJ.jj_cache[buf_id] = {}
	end)

	local process, stdout_feed = nil, {}
	local on_exit = function(exit_code)
		process:close()

		-- Watch index only if there was no error retrieving path to it
		if exit_code ~= 0 or stdout_feed[1] == nil then
			return on_not_in_jj()
		end

		-- Set up index watching
		local jj_dir_path = table.concat(stdout_feed, ""):gsub("\n+$", "") .. "/.jj/working_copy"
		JJ.jj_setup_tree_state_watch(buf_id, jj_dir_path)

		-- Set reference text immediately
		JJ.jj_set_ref_text(buf_id)
	end

	process = vim.loop.spawn("jj", spawn_opts, on_exit)
	JJ.jj_read_stream(stdout, stdout_feed)
end

JJ.jj_setup_tree_state_watch = function(buf_id, jj_dir_path)
	local buf_fs_event, timer = vim.loop.new_fs_event(), vim.loop.new_timer()
	local buf_jj_set_ref_text = function()
		JJ.jj_set_ref_text(buf_id)
	end

	local watch_tree_state = function(_, filename, _)
		if filename ~= "tree_state" then
			return
		end
		-- Debounce to not overload during incremental staging (like in script)
		timer:stop()
		timer:start(50, 0, buf_jj_set_ref_text)
	end
	buf_fs_event:start(jj_dir_path, { recursive = false }, watch_tree_state)

	JJ.jj_invalidate_cache(JJ.jj_cache[buf_id])
	JJ.jj_cache[buf_id] = { fs_event = buf_fs_event, timer = timer }
end

JJ.jj_set_ref_text = vim.schedule_wrap(function(buf_id)
	if not vim.api.nvim_buf_is_valid(buf_id) then
		return
	end

	local buf_set_ref_text = vim.schedule_wrap(function(text)
		pcall(M.set_ref_text, buf_id, text)
	end)

	-- NOTE: Do not cache buffer's name to react to its possible rename
	local path = JJ.get_buf_realpath(buf_id)
	if path == "" then
		return buf_set_ref_text({})
	end
	local cwd, basename = vim.fn.fnamemodify(path, ":h"), vim.fn.fnamemodify(path, ":t")

	-- Set
	local stdout = vim.loop.new_pipe()
	local spawn_opts = {
		args = { "file", "show", "-r", "@-", "./" .. basename },
		cwd = cwd,
		stdio = { nil, stdout, nil },
	}

	local process, stdout_feed = nil, {}
	local on_exit = function(exit_code)
		process:close()

		if exit_code ~= 0 or stdout_feed[1] == nil then
			return buf_set_ref_text({})
		end

		-- Set reference text accounting for possible 'crlf' end of line in index
		local text = table.concat(stdout_feed, ""):gsub("\r\n", "\n")
		buf_set_ref_text(text)
	end

	process = vim.loop.spawn("jj", spawn_opts, on_exit)
	JJ.jj_read_stream(stdout, stdout_feed)
end)

JJ.jj_get_path_data = function(path)
	-- Get path data needed for proper patch header
	local cwd, basename = vim.fn.fnamemodify(path, ":h"), vim.fn.fnamemodify(path, ":t")
	local stdout = vim.loop.new_pipe()

	local args = {
		"file",
		"list",
		"--",
		basename,
	}
	local spawn_opts = {
		args = args,
		cwd = cwd,
		stdio = { nil, stdout, nil },
	}

	local process, stdout_feed, res, did_exit = nil, {}, { cwd = cwd }, false
	local on_exit = function(exit_code)
		process:close()

		did_exit = true
		if exit_code ~= 0 then
			return
		end
		-- Parse data about path
		local out = table.concat(stdout_feed, ""):gsub("\n+$", "")
		res.rel_path = out
	end

	process = vim.loop.spawn("jj", spawn_opts, on_exit)
	JJ.jj_read_stream(stdout, stdout_feed)
	vim.wait(1000, function()
		return did_exit
	end, 1)
	return res
end

JJ.jj_format_patch = function(buf_id, hunks, path_data)
	local _, buf_lines = JJ.get_buftext(buf_id)
	local ref_lines = vim.split(JJ.cache[buf_id].ref_text, "\n")

	local args = {
		"diff",
		"--no-pager",
		"--git",
		path_data.rel_path,
	}

	local spawn_opts = {
		args = args,
		cwd = cwd,
		stdio = { nil, stdout, nil },
	}

	local process, stdout_feed, patch, did_exit = nil, {}, { cwd = cwd }, false
	local on_exit = function(exit_code)
		process:close()

		did_exit = true
		if exit_code ~= 0 then
			return
		end

		local text = table.concat(stdout_feed, ""):gsub("\r\n", "\n")
		patch = text
	end

	process = vim.loop.spawn("jj", spawn_opts, on_exit)
	JJ.jj_read_stream(stdout, stdout_feed)
	vim.wait(1000, function()
		return did_exit
	end, 1)

	return patch
end

JJ.jj_read_stream = function(stream, feed)
	local callback = function(err, data)
		if data ~= nil then
			return table.insert(feed, data)
		end
		if err then
			feed[1] = nil
		end
		stream:close()
	end
	stream:read_start(callback)
end

JJ.jj_invalidate_cache = function(cache)
	if cache == nil then
		return
	end
	pcall(vim.loop.fs_event_stop, cache.fs_event)
	pcall(vim.loop.timer_stop, cache.timer)
end

JJ.setup = function(config)
  JJ.config = config or {}

	local attach = function(buf_id)
		-- Try attaching to a buffer only once
		if JJ.jj_cache[buf_id] ~= nil then
			return false
		end
		-- - Possibly resolve symlinks to get data from the original repo
		local path = JJ.get_buf_realpath(buf_id)
		if path == "" then
			return false
		end

		JJ.jj_cache[buf_id] = {}
		JJ.jj_start_watching_tree_state(buf_id, path)
	end

	local detach = function(buf_id)
		local cache = JJ.jj_cache[buf_id]
		JJ.jj_cache[buf_id] = nil
		JJ.jj_invalidate_cache(cache)
	end

	local apply_hunks = function(buf_id, hunks)
    -- TODO: I don't think this is relevant for jj, but leaving it here
    -- for future reference -ian
    --
		-- local path_data = JJ.jj_get_path_data(JJ.get_buf_realpath(buf_id))
		-- if path_data == nil or path_data.rel_path == nil then
		-- 	return
		-- end
		-- local patch = JJ.jj_format_patch(buf_id, hunks, path_data)
		-- JJ.jj_apply_patch(path_data, patch)
	end

	return {
		name = "jj",
		attach = attach,
		detach = detach,
		apply_hunks = apply_hunks,
	}
end

return JJ
