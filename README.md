# jj-minidiff.nvim

A [jj](https://jj-vcs.github.io/jj/latest/) `mini.diff` source based heavily on
the `git` implementation for mini.diff.

## Usage

```lua
return {
	"echasnovski/mini.diff",
	version = false,
	dependencies = {
		"maladroitthief/jj-minidiff.nvim",
  },
	config = function()
		local M = require("mini.diff")

		M.setup({
			source = {
        M.gen_source.git(),
        require("jj-minidiff").setup({}),
      },
			view = {
				style = "sign",
				signs = {
					add = "▎",
					change = "▎",
					delete = "",
				},
			},
		})
	end,
}
```
