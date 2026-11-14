vim.api.nvim_create_user_command("YqParser", function(opts)
	require("parser").init(opts)
end, {
	range = true,
	force = false,
	desc = "Open YAML or JSON in the yq parser",
})
