local BaseMod = require("hlchunk.base_mod")

local utils = require("hlchunk.utils.utils")
local Array = require("hlchunk.utils.array")
local ft = require("hlchunk.utils.filetype")
local api = vim.api
local fn = vim.fn
local ROWS_INDENT_RETCODE = utils.ROWS_INDENT_RETCODE

---@class IndentOpts: BaseModOpts
---@field use_treesitter boolean
---@field chars table<string, string>

---@class IndentMod: BaseMod
---@field options IndentOpts
local indent_mod = BaseMod:new({
    name = "indent",
    options = {
        enable = true,
        notify = true,
        use_treesitter = false,
        chars = {
            "│",
        },
        style = {
            fn.synIDattr(fn.synIDtrans(fn.hlID("Whitespace")), "fg", "gui"),
        },
        exclude_filetypes = ft.exclude_filetypes,
    },
})

function _G.clear_context_indent()
    local success, render = pcall(require, "treesitter-context.render")
    if success then
        local win = vim.api.nvim_get_current_win()
        for stored_winid, window_context in pairs(render.get_window_contexts()) do
            if stored_winid == win then
                self:clear(nil, nil, vim.api.nvim_win_get_buf(window_context.context_winid))
            end
        end
    end
end

local function line_has_namespace(buf, line, name_space, type)
    buf = buf or 0
    local ns = api.nvim_create_namespace(name_space)
    local extmarks = api.nvim_buf_get_extmarks(
        buf,
        ns,
        { line - 1, 0 },
        { line - 1, -1 },
        { limit = 1, details = true, type = type }
    )
    for _, extmark in ipairs(extmarks) do
        if extmark[4].hl_group == "GitSignsDeleteLn" then
            return false
        end
    end
    return extmarks ~= nil and #extmarks ~= 0
end

function indent_mod:render_line(index, indent, win, mini)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].hl_disable then
        return
    end
    if
        line_has_namespace(buf, index, "gitsigns_signs_", "highlight")
        or line_has_namespace(buf, index, "gitsigns_signs_staged", "highlight")
        or line_has_namespace(buf, index, "visual_range", "sign")
        or line_has_namespace(buf, index, "symbol_highlight", nil)
        or line_has_namespace(buf, index, "gitsigns_preview_inline", "highlight")
    then
        return
    end
    local row_opts = {
        virt_text_pos = "overlay",
        virt_text_hide = true,
        hl_mode = "combine",
        priority = 12,
    }
    local shiftwidth = vim.api.nvim_buf_call(buf, fn.shiftwidth)
    local render_char_num = math.floor(indent / shiftwidth)
    local win_info = nil
    if vim.api.nvim_win_is_valid(win) then
        win_info = vim.api.nvim_win_call(win, function()
            return fn.winsaveview()
        end)
    else
        win_info = fn.winsaveview()
    end
    local text = ""
    for _ = 1, render_char_num do
        text = text .. "|" .. (" "):rep(shiftwidth - 1)
    end
    text = text:sub(win_info.leftcol + 1)
    local count = 0
    for i = 1, #text do
        local c = text:at(i)
        if not c:match("%s") then
            count = count + 1
            local Indent_chars_num = Array:from(self.options.chars):size()
            local Indent_style_num = Array:from(self.options.style):size()
            local char = self.options.chars[(count - 1) % Indent_chars_num + 1]
            local style = "HLIndent" .. tostring((count - 1) % Indent_style_num + 1)
            row_opts.virt_text = { { char, style } }
            row_opts.virt_text_win_col = i - 1
            if
                row_opts.virt_text_win_col < 0
                or row_opts.virt_text_win_col
                    >= vim.api.nvim_buf_call(buf, function()
                        return fn.indent(index)
                    end)
            then
                -- if the len of the line is 0, so we should render the indent by its context
                if api.nvim_buf_get_lines(buf, index - 1, index, false)[1] ~= "" then
                    return
                end
            end
            if win ~= vim.api.nvim_get_current_win() and mini then
                local n = vim.api.nvim_create_namespace("MiniIndentscope")
                local ext_marks = api.nvim_buf_get_extmarks(0, n, 0, -1, { details = true })
                if ext_marks ~= nil and #ext_marks ~= 0 then
                    local _, _, _, info = unpack(ext_marks[1])
                    local mini_wincol = info.virt_text_win_col
                    if i - 1 == mini_wincol then
                        row_opts.virt_text[1][2] = "MiniIndentscopeSymbol"
                    end
                end
            end
            row_opts.virt_text_hide = true
            api.nvim_buf_set_extmark(buf, self.ns_id, index - 1, 0, row_opts)
        end
    end
end

local last_rows_indent = {}

function indent_mod:render(winid, mini, force)
    if vim.g.hlchunk_disable then
        return
    end
    local tabnum = vim.fn.tabpagenr()
    if tabnum ~= 1 then
        self:clear()
        return
    end

    force = force or true
    winid = winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(winid)
    if vim.b[buf].gitsigns_preview == true then
        return
    end
    if (not self.options.enable) or self.options.exclude_filetypes[vim.bo[buf].filetype] then
        return
    end
    local retcode, rows_indent = utils.get_rows_indent(self, nil, nil, {
        use_treesitter = self.options.use_treesitter,
        virt_indent = true,
    }, winid)
    if not force and vim.deep_equal(last_rows_indent, rows_indent) then
        return
    end
    self.ns_id = api.nvim_create_namespace(self.name)
    if retcode == ROWS_INDENT_RETCODE.NO_TS then
        if self.options.notify then
            self:notify("[hlchunk.indent]: no parser for " .. vim.bo.filetype, nil, { once = true })
        end
        return
    end

    if api.nvim_win_is_valid(winid) then
        self:clear(nil, nil, vim.api.nvim_win_get_buf(winid))
    else
        self:clear()
    end
    for index, _ in pairs(rows_indent) do
        self:render_line(index, rows_indent[index], winid, mini)
    end
    last_rows_indent = rows_indent
end

--- @generic F: function
--- @param f F
--- @param ms? number
--- @return F
local function throttle(f, ms)
    ms = ms or 20
    local timer = assert(vim.loop.new_timer())
    local waiting = 0
    return function()
        if timer:is_active() then
            waiting = waiting + 1
            return
        end
        waiting = 0
        f() -- first call, execute immediately
        timer:start(ms, 0, function()
            if waiting > 1 then
                vim.schedule(f) -- only execute if there are calls waiting
            end
        end)
    end
end

local update = throttle(function()
    indent_mod:render()
end)
local update_slow = throttle(function()
    -- local time = vim.uv.hrtime()
    indent_mod:render()
    -- Time(time, "slow: ")
end, 100)

_G.indent_update = function(winid)
    winid = winid or vim.api.nvim_get_current_win()
    vim.schedule(function()
        indent_mod:render(winid, nil, true)
    end)
end

_G.hlchunk_clear = function(s, e, buf)
    indent_mod:clear(s, e, buf or 0)
end

-- update treesitter-context's window's hlchunk and fake mini.indentscope
function _G.update_indent(mini, winid)
    if winid ~= nil then
        indent_mod:render(winid, nil, true)
    end
    local success, render = pcall(require, "treesitter-context.render")
    if success then
        winid = winid or vim.api.nvim_get_current_win()
        for stored_winid, window_context in pairs(render.get_window_contexts()) do
            if stored_winid == winid then
                indent_mod:render(window_context.context_winid, mini, true)
            end
        end
    end
end

function indent_mod:enable_mod_autocmd()
    BaseMod.enable_mod_autocmd(self)

    api.nvim_create_autocmd({ "BufWinEnter", "WinScrolled" }, {
        group = self.augroup_name,
        pattern = "*",
        callback = function()
            vim.defer_fn(function()
                indent_mod:render()
            end, 50)
        end,
    })

    api.nvim_create_autocmd({ "TextChanged" }, {
        group = self.augroup_name,
        pattern = "*",
        callback = function()
            indent_mod:render()
        end,
    })

    api.nvim_create_autocmd({ "CursorMoved" }, {
        group = self.augroup_name,
        pattern = "*",
        callback = function()
            vim.schedule(function()
                indent_mod:render(nil, nil, false)
            end)
        end,
    })

    api.nvim_create_autocmd({ "TextChangedI" }, {
        group = self.augroup_name,
        pattern = "*",
        callback = function()
            if vim.g.type_o then
                return
            end
            vim.schedule(update_slow)
        end,
    })
    -- api.nvim_create_autocmd({ "OptionSet" }, {
    --     group = self.augroup_name,
    --     pattern = "list,listchars,shiftwidth,tabstop,expandtab",
    --     callback = function()
    --         vim.defer_fn(function()
    --             indent_mod:render()
    --         end, 100)
    --     end,
    -- })
end

function indent_mod:disable()
    BaseMod.disable(self)
end

return indent_mod
