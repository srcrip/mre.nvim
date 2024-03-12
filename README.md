# mre.nvim 🍽️

Ever wished the changelist worked across all open buffers, and had a persistent cache? Now it does!

## Features

- Tracks edits across all open buffers
- Persistent cache between sessions
- Visible extmark indicator of past edit locations

## Installation

### lazy.nvim

```lua
{
  'srcrip/mre.nvim',
  config = function()
    local mre = require('mre')

    mre.setup({
      max_history_per_file = 10,
      max_history = 100,
      virt_text = "-",
      -- whether to remove marks only on the same line as another
      dedupe_line = true,
      -- whether to remove marks only on the same line and column as another
      dedupe_column = false,
      -- print out some useful information when using the plugin
      verbose = true,
      -- debug information you probably won't need
      debug = false,
    })

    vim.keymap.set('n', '<tab>', mre.jump_prev, {})
    vim.keymap.set('n', '<s-tab>', mre.jump_next, {})

    vim.api.nvim_create_user_command('MREClear', mre.clear, {})
  end
}
```

## Roadmap

- [ ] Separate cache with a cache function (by directory, git branch, etc)
- [ ] Actual documentation
- [ ] More config options
- [ ] More virt_text options
- [ ] Special highlight groups for older entries
- [ ] Telescope/fzf integration
- [ ] Branching edit states/tree-like structures?

## Alternatives

`mre.nvim` is based on the work in [before.nvim](https://github.com/bloznelis/before.nvim). I always wanted a plugin
like this but wasn't quite sure how to implement it before.
