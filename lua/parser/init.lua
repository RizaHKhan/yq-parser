local M = {}

function M.init(opts)
	local input
	if opts and opts.range > 0 then
		-- Buffer indices are zero-based; the end index is exclusive.
		input = table.concat(vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false), "\n")
	else
		input = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	end

	if vim.fn.executable("yq") ~= 1 then
		vim.notify("YqParser: yq (Mike Farah v4) is not installed or not on PATH", vim.log.levels.ERROR)
		return
	end

	if input:match("^%s*$") then
		vim.notify("YqParser: input is empty", vim.log.levels.ERROR)
		return
	end

	-- Preserve the source format; detect JSON even in buffers without a filetype.
	local is_json = pcall(vim.json.decode, input)
	local source_filetype = vim.bo.filetype
	local format = (source_filetype == "json" or (source_filetype ~= "yaml" and is_json)) and "json" or "yaml"
	local function evaluate(filter)
		return vim.fn.system({
			"yq", "eval", "-p", format, "-o", format, "--prettyPrint", "-I", "2", "--expression", filter, "-",
		}, input)
	end

	local output = evaluate(".")
	if vim.v.shell_error ~= 0 then
		vim.notify("YqParser: yq could not parse input:\n" .. output, vim.log.levels.ERROR)
		return
	end

	-- Remember the working directory at creation, even if it changes later.
	local creation_cwd = vim.fn.getcwd()
	local source_extension = vim.fn.expand("%:e"):lower()
	local save_extension = (format == "yaml" and source_extension == "yml") and "yml" or format
	local result_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[result_buf].bufhidden = "wipe"
	vim.bo[result_buf].swapfile = false
	vim.bo[result_buf].filetype = format

	local function show_result(result)
		local lines = vim.split(result, "\n", { plain = true })
		if lines[#lines] == "" then
			table.remove(lines)
		end
		vim.bo[result_buf].modifiable = true
		vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
		vim.bo[result_buf].modified = false
		vim.bo[result_buf].modifiable = false
	end

	local last_filter = "."
	local function run_filter(filter)
		if not vim.api.nvim_buf_is_valid(result_buf) then
			return
		end
		-- Each filter runs against the original input, not the previous result.
		local filtered = evaluate(filter)
		if vim.v.shell_error ~= 0 then
			vim.notify("YqParser: yq filter failed:\n" .. filtered, vim.log.levels.ERROR)
			return
		end
		last_filter = filter
		show_result(filtered)
	end

	show_result(output)
	vim.api.nvim_buf_create_user_command(result_buf, "JsonFilter", function(command)
		run_filter(command.args)
	end, {
		nargs = "+",
		desc = "Run a yq filter against the original YAML or JSON input",
	})

	vim.keymap.set("n", "i", function()
		local function on_confirm(filter)
			if filter and filter:match("%S") then
				run_filter(filter)
			end
		end
		local input_opts = { prompt = "yq filter: ", default = last_filter }
		local ok, snacks = pcall(require, "snacks")
		if ok and snacks.input then
			snacks.input(input_opts, on_confirm)
		else
			vim.ui.input(input_opts, on_confirm)
		end
	end, { buffer = result_buf, desc = "Enter a yq filter" })

	vim.keymap.set("n", "s", function()
		local function on_confirm(path)
			if not path or not path:match("%S") or not vim.api.nvim_buf_is_valid(result_buf) then
				return
			end
			path = vim.fn.expand(path)
			if path:sub(1, 1) ~= "/" then
				path = vim.fs.joinpath(creation_cwd, path)
			end
			if vim.fn.fnamemodify(path, ":e") == "" then
				path = path .. "." .. save_extension
			end

			-- Exclusive creation prevents accidentally overwriting an existing file.
			local fd, open_error = vim.uv.fs_open(path, "wx", 420)
			if not fd then
				vim.notify("YqParser: could not save: " .. tostring(open_error), vim.log.levels.ERROR)
				return
			end
			local lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
			local content = table.concat(lines, "\n") .. "\n"
			local written, write_error = vim.uv.fs_write(fd, content, 0)
			local closed, close_error = vim.uv.fs_close(fd)
			if written ~= #content or not closed then
				vim.notify("YqParser: save failed: " .. tostring(write_error or close_error or "incomplete write"), vim.log.levels.ERROR)
				return
			end
			vim.notify("YqParser: saved " .. path, vim.log.levels.INFO)
		end
		local input_opts = {
			prompt = "save to:",
			default = vim.fs.joinpath(creation_cwd, "result." .. save_extension),
			completion = "file",
		}
		local ok, snacks = pcall(require, "snacks")
		if ok and snacks.input then
			snacks.input(input_opts, on_confirm)
		else
			vim.ui.input(input_opts, on_confirm)
		end
	end, { buffer = result_buf, desc = "Save to path" })

	vim.cmd("botright vsplit")
	vim.api.nvim_win_set_buf(0, result_buf)
end

return M
