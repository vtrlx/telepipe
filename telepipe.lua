--[[ telepipe.lua (graphical command-line shell)
Copyright © 2026 Victoria Lacroix

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. ]]--

-- SECTION: Helper functions

local lib = require "telepipelib"

local _ = lib.gettext

local app_title = _ "Telepipe"
local app_id = lib.get_app_id()
local install_prefix = lib.get_install_prefix()

-- Replace's the user's $HOME with the tilde "~" character, a common convention when displaying paths.
function lib.fmtdir(path)
	return path:gsub("^" .. os.getenv "HOME", "~", 1)
end

function lib.expanddir(path)
	return path:gsub("^~", os.getenv "HOME", 1)
end

function lib.strip(text)
	return text:gsub("^%s*", ""):gsub("%s*$", "")
end

function lib.fileexists(path)
	local ok, err, code = os.rename(path, path)
	if not ok and code == 13 then
		-- In Linux, error code 13 when moving a file means that it failed because the directory cannot be made its own child. Any other error means the file does not exist.
		return true
	end
	return ok
end

function lib.isdir(path)
	if path == "/" then return true end
	-- If the given path points to a directory, then adding a "/" suffix will show the file as still existing.
	return lib.fileexists(path .. "/")
end

function lib.unescapeutf(str)
	assert(type(str) == "string")
	-- Single-quotes need to be escaped, because the string itself will be single-quoted.
	str = str:gsub("'", "\\'")
	local src = ("return '%s'"):format(str)
	local f = assert(load(src))
	return f()
end

function lib.unflatpakize(file)
	local path
	local fileinfo = file:query_info "xattr::document-portal.host-path"
	if fileinfo then
		path = fileinfo:get_attribute_string "xattr::document-portal.host-path"
		path = lib.unescapeutf(path)
	end
	if not path then
		path = file:get_path()
		path = lib.unescapeutf(path)
	end
	if path:match "^/run/host" then
		path = path:gsub("^/run/host", "", 1)
	end
	return path
end

-- Simple class implementation without inheritance.
function lib.newclass(init)
	local c = {}
	local mt = {}
	c.__index = c
	function mt:__call(...)
		local obj = setmetatable({}, c)
		init(obj, ...)
		return obj
	end
	function c:isa(klass)
		return getmetatable(self) == klass
	end
	return setmetatable(c, mt)
end

-- SECTION: Application

if lib.get_is_flatpak() then
	-- This app runs in Flatpak, which puts Lua libraries outside of the standard paths. These lines tell Lua to look for libraries where Flatpak has put them.
	package.cpath = install_prefix .. "/lib/lua/5.5/?.so;" .. package.cpath
	package.path = install_prefix .. "/share/lua/5.5/?.lua;" .. package.path
end

local LuaGObject = require "LuaGObject"

local Adw = LuaGObject.Adw
local Gdk = LuaGObject.Gdk
local Gio = LuaGObject.Gio
local GLib = LuaGObject.GLib
local GObject = LuaGObject.GObject
local Gtk = LuaGObject.Gtk

local app = Adw.Application {
	application_id = lib.get_app_id(),
	resource_base_path = "/ca/vtrlx/Telepipe", -- Needs to be hardcoded.
	flags = { "HANDLES_COMMAND_LINE" }, -- Only for --new-window.
}

app:add_main_option("new-window", string.byte "n", "IN_MAIN", "NONE", "Create a new window.")

local accels = {
	["win.focus-cmdbar"] = { "<Ctrl>K" },
	["win.new-tab"] = { "<Ctrl>T" },
	["win.dup-tab"] = { "<Ctrl><Shift>T" },
	["win.close-tab"] = { "<Ctrl>W" },
	["win.new-win"] = { "<Ctrl>N" },
	["win.overview"] = { "<Ctrl><Shift>O" },
	["win.enter-file-path"] = { "<Ctrl>J" },
	["win.enter-folder-path"] = { "<Ctrl><Shift>J" },
	["win.chdir"] = { "<Ctrl>M" },
	["win.open-folder"] = { "<Ctrl>D" },
	["win.search"] = { "<Ctrl>F" },
	["win.signal-kill"] = { "<Ctrl><Alt>C" },
	["win.signal-endinput"] = { "<Ctrl><Alt>D" },
	["win.signal-background"] = { "<Ctrl><Alt>Z" },
	["win.preferences"] = { "<Ctrl>comma" },
	["win.shortcuts"] = { "<Ctrl><Shift>question" },
	["win.about"] = { "F1" },
}
for k, v in pairs(accels) do
	app:set_accels_for_action(k, v)
end

-- SECTION: GResources

do -- Load and register GResource.
	local resource = Gio.Resource.load(install_prefix .. "/data/telepipe.gresource")
	assert(resource)
	Gio.resources_register(resource)
end -- Load and register GResource.

-- SECTION: Important variables

local windows = {}
local runners = {}

local function get_focused_window()
	if not app.active_window then return end
	return windows[app.active_window]
end

local function get_focused_runner()
	local win = get_focused_window()
	if not win then return end
	local tabview = win.tabview
	if not tabview then return end
	local page = tabview.selected_page
	if not page then return end
	return runners[page.child]
end

-- SECTION: Custom styling

do
	local styleman = Adw.StyleManager.get_default()
	local display = Gdk.Display.get_default()
	local provider = Gtk.CssProvider()
	provider:load_from_string [[
		/* Even without actions, images will become more opque on hover. This prevents that from happening. */
		image.nohover:hover {
			opacity: 0.7;
		}
	]]
	Gtk.StyleContext.add_provider_for_display(display, provider, 1000000)
end

-- SECTION: Environment Variables

local envvarmodel = Gtk.StringList()

local validname = "[A-Za-z_][A-Za-z0-9_]*"
local envvars = {}

local confdir = os.getenv "XDG_CONFIG_HOME" .. "/telepipe/"
local envfile = confdir .. "env"
local envfilenext = confdir .. "envnext"

local function mkdir(path)
	local file = Gio.File.new_for_path(path)
	file:make_directory_with_parents()
end

-- Returns a generator that iterates over all variable names in alphabetical order (as determined by Lua).
local function varnames()
	local names = {}
	for name in pairs(envvars) do table.insert(names, name) end
	table.sort(names)
	return coroutine.wrap(function()
		for _, name in ipairs(names) do coroutine.yield(name) end
	end)
end

local function saveenv()
	local env = ""
	for name in varnames() do
		local value = envvars[name]
		env = env .. ("%s=%s\n"):format(name, value)
	end
	-- This should be guaranteed to work, because of Flatpak.
	io.open(envfilenext, "w"):write(env):close()
	os.rename(envfilenext, envfile)
end

local function setenv(name, value)
	if envvars[name] then
		local formatted = ("%s=%s"):format(name, envvars[name])
		local index = envvarmodel:find(formatted)
		envvarmodel:remove(index)
	end
	if value then
		envvarmodel:append(("%s=%s"):format(name, value))
	end
	envvars[name] = value
	saveenv()
end

local function parseenv(env)
	local pattern = ("(%s)=([^\n]*)"):format(validname)
	for name, value in env:gmatch(pattern) do
		-- Added manually to prevent stomping out the environment.
		envvarmodel:append(("%s=%s"):format(name, value))
		envvars[name] = value
	end
end

local function loadenv()
	-- If the "next" file exists, then a partial write wasn't completed.
	if lib.fileexists(envfilenext) then
		os.rename(envfilenext, envfile)
	end
	if not lib.fileexists(envfile) then return end
	parseenv(io.open(envfile):read "a")
end


do -- Load the configured global environment variables.
	if lib.fileexists(confdir) and not lib.isdir(confdir) then
		-- Configuration is broken due to external influence. Because this app runs in a Flatpak sandbox, any files inside of it should be expected to be under control of the app, so deleting it shouldn't violate any reasonable user expectations.
		os.remove(tallydir)
	end
	if not lib.fileexists(confdir) then mkdir(confdir) end
	loadenv()
end

-- SECTION: Command runner class

local runnermenu = Gio.Menu()
runnermenu:append(_ "Stop Running Command", "win.signal-kill")
runnermenu:append(_ "Close Command Input", "win.signal-endinput")
runnermenu:append(_ "Send to Background", "win.signal-background")

local runner = lib.newclass(function(self, params)
	if type(params) ~= "table" then params = {} end
	self.env = {}
	self.pwd = params.pwd or os.getenv "HOME"
	self.outputqueue = ""
	local factory = Gtk.SignalListItemFactory {
		on_setup = function(_, ...) self:setupitem(...) end,
		on_bind = function(_, ...) self:binditem(...) end,
		on_unbind = function(_, ...) self:unbinditem(...) end,
		on_teardown = function(_, ...) self:teardownitem(...) end,
	}
	self.prefix = params.prefix or ""
	if not params.history then
		self.history = {
			[self.prefix] = Gtk.StringList(),
		}
	else
		self.history = {}
		for prefix, list in pairs(params.history) do
			self.history[prefix] = Gtk.StringList()
			for i = 1, list.n_items do
				local index = i - 1
				self.history[prefix]:append(list:get_string(index))
			end
		end
	end
	self.listitems = {}
	self.histview = Gtk.ListView {
		valign = "END",
		width_request = 300,
		factory = factory,
		model = Gtk.NoSelection {
			model = self:gethistory(),
		},
	}
	self.matches = {}
	self.textview = Gtk.TextView {
		extra_css_classes = { "numeric" },
		top_margin = 12,
		bottom_margin = 12,
		left_margin = 18,
		right_margin = 18,
		pixels_above_lines = 2,
		pixels_below_lines = 2,
		pixels_inside_wrap = 0,
		wrap_mode = Gtk.WrapMode.WORD_CHAR,
	}
	self.buffer = self.textview.buffer
	self.scrolledwin = Gtk.ScrolledWindow {
		child = self.textview,
		hscrollbar_policy = "NEVER",
	}
	local vadjust = self.scrolledwin.vadjustment
	local oldupper = vadjust.upper
	self.doscroll = true
	function vadjust.on_value_changed()
		-- If the scroll bar is at the bottom of the command output, further output should cause the scroll bar to continue scrolling down.
		if vadjust.value >= vadjust.upper - vadjust.page_size then
			self.doscroll = true
		else
			self.doscroll = false
		end
	end
	function vadjust.on_notify.upper()
		local upper = vadjust.upper
		if self.doscroll then
			-- This is a best-guess attempt at determining a good delay for actually scrolling the window down after its upper bound has changed, because the scroll window takes some time to adjust its content size.
			local factor = math.floor((vadjust.upper / vadjust.page_size) / 5)
			local timeout = math.max(5, math.min(100, factor))
			GLib.timeout_add(20, timeout, function()
				vadjust.value = math.maxinteger
				-- It's very possible that self.doscroll might not get re-enabled due to recalculations of the scrolled window's size, so because this *should* result in scrolling to the bottom, just forcibly enable scrolling now to ensure that it continues after a later resize.
				self.doscroll = true
			end)
		elseif vadjust.upper == vadjust.page_size then
			-- If the output was cleared after previously having been scrolled to the top, the value hasn't changed but the bottom has and so automatic scrolling should be reenabled.
			self.doscroll = true
		end
		oldupper = upper
	end

	if params.buffer then
		self.buffer.text = params.buffer.text
	end

	-- Search
	self.searchentry = Gtk.Text {
		placeholder_text = _ "Find in output…",
		hexpand = true,
		on_activate = function()
			self:searchnext(self.searchentry.text)
		end,
	}
	function self.searchentry.on_notify.text()
		if not self.searchbar.search_mode_enabled then return end
		if #self.searchentry.text == 0 then
			self.matchlabel.label = ""
			self.searchclearbutton.visible = false
			return
		end
		self:findall(self.searchentry.text)
		self.searchclearbutton.visible = true
	end
	self.searchclearbutton = Gtk.Button {
		css_name = "image",
		icon_name = "tp-clear-symbolic",
		margin_start = 12,
		visible = false,
		on_clicked = function()
			self.searchentry.text = ""
			self.searchentry:grab_focus()
		end,
	}
	self.matchlabel = Gtk.Label {
		extra_css_classes = { "numeric" },
		halign = "END",
		hexpand = false,
		margin_start = 6,
		margin_end = 6,
	}
	function self.matchlabel.on_notify.text()
		self.matchlabel.visible = #self.matchlabel.text > 0
	end
	local searchentrybox = Gtk.Box {
		orientation = "HORIZONTAL",
		css_name = "entry",
		Gtk.Image {
			extra_css_classes = { "nohover" },
			icon_name = "tp-search-symbolic",
		},
		self.searchentry,
		self.searchclearbutton,
		self.matchlabel,
	}
	local prevmatchbutton = Gtk.Button {
		icon_name = "tp-up-symbolic",
		tooltip_text = _ "Go to previous match",
		on_clicked = function()
			self:searchprev(self.searchentry.text)
		end,
	}
	local nextmatchbutton = Gtk.Button {
		icon_name = "tp-down-symbolic",
		tooltip_text = _ "Go to next match",
		on_clicked = function()
			self:searchnext(self.searchentry.text)
		end,
	}
	local searchbox = Gtk.Box {
		orientation = "HORIZONTAL",
		extra_css_classes = { "linked" },
		searchentrybox,
		prevmatchbutton,
		nextmatchbutton,
	}
	local searchclamp = Adw.Clamp {
		orientation = "HORIZONTAL",
		child = searchbox,
		maximum_size = 600,
	}
	self.searchbar = Gtk.SearchBar {
		child = searchclamp,
		search_mode_enabled = false,
		show_close_button = true,
	}
	self.searchbar:connect_entry(self.searchentry)
	function self.buffer.on_changed()
		if self.searchbar.search_mode_enabled then
			self:findall(self.searchentry.text)
		end
	end
	self.chdirbutton = Gtk.Button {
		action_name = "win.chdir",
		icon_name = "tp-folder-symbolic",
		tooltip_text = _ "Select new working directory…",
	}
	local menupopover = Gtk.PopoverMenu.new_from_model(runnermenu)
	menupopover.halign = "START"
	self.menubutton = Gtk.MenuButton {
		icon_name = "tp-signal-symbolic",
		direction = "UP",
		tooltip_text = _ "Signal to running command…",
		popover = menupopover,
		visible = false,
	}
	local prefixlabel, prefixtooltip = self:getprefixlabel()
	self.prefixbutton = Gtk.Button {
		tooltip_text = prefixtooltip,
		label = prefixlabel,
		visible = #self.prefix > 0,
		on_clicked = function()
			self:switchprefix ""
			self:ensurenewlines()
			self:putstring "Prefix was cleared."
			self:print "\n"
			self:grab()
		end,
	}
	self.historybutton = Gtk.MenuButton {
		tooltip_text = _ "Command history",
		icon_name = "tp-history-symbolic",
		visible = self.history[self.prefix].n_items > 0,
		direction = "UP",
		popover = Gtk.Popover {
			halign = "END",
			child = Gtk.ScrolledWindow {
				child = self.histview,
				max_content_height = 300,
				propagate_natural_height = true,
				hscrollbar_policy = "NEVER",
			},
		}
	}
	function self.historybutton.popover.child.child.on_map()
		-- This isn't ideal, but there are no good options here.
		self.histview.width_request = math.max(300,
			math.floor(self.entry.width * 0.75))
		scrolled = self.historybutton.popover.child.child
		GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
			scrolled.vadjustment.value = scrolled.vadjustment.upper
		end)
	end
	self.sendbutton = Gtk.Button {
		extra_css_classes = { "suggested-action" },
		icon_name = "tp-run-symbolic",
		tooltip_text = _ "Run command",
		sensitive = false,
		on_clicked = function()
			self:doactivate()
		end,
	}
	self.entry = Gtk.Text {
		extra_css_classes = { "numeric" },
		placeholder_text = _ "Run a command…",
		hexpand = true,
		on_changed = function()
			self.sendbutton.sensitive = #self.entry.text > 0
			self.clearbutton.visible = #self.entry.text > 0
		end,
		on_activate = function()
			self:doactivate()
		end,
	}
	self.clearbutton = Gtk.Button {
		icon_name = "tp-clear-symbolic",
		margin_start = 12,
		css_name = "image",
		can_focus = false,
		visible = false,
		on_clicked = function()
			self.entry.text = ""
			self:grab()
		end,
	}
	local entrybox = Gtk.Box {
		orientation = "HORIZONTAL",
		css_name = "entry",
		self.entry,
		self.clearbutton,
	}
	local lbox = Gtk.Box {
		orientation = "HORIZONTAL",
		extra_css_classes = { "linked" },
		self.chdirbutton,
		self.prefixbutton,
		self.menubutton,
		entrybox,
		self.historybutton,
	}
	local box = Gtk.Box {
		orientation = "HORIZONTAL",
		margin_top = 6,
		margin_bottom = 6,
		margin_start = 6,
		margin_end = 6,
		spacing = 6,
		lbox,
		self.sendbutton,
	}
	self.toolbarview = Adw.ToolbarView {
		content = self.scrolledwin,
		bottom_bar_style = "RAISED_BORDER",
		bottom_bars = { self.searchbar, box },
	}
	runners[self.toolbarview] = self
end)

function runner:doactivate()
	-- Blank lines are allowed for running apps.
	if not self.subproc and #self.entry.text == 0 then return end
	local text = self.entry.text
	self.entry.text = ""
	self:send(text)
end

function runner:grab()
	if self.tabview.selected_page ~= self.tabpage then return end
	self.entry:set_position(-1)
	self.entry:grab_focus_without_selecting()
end

function runner:enterfile(path)
	assert(path)
	local buffer = self.entry.buffer
	local text = buffer.text
	local position = self.entry:get_position()
	local bound, ins = self.entry:get_selection_bounds()
	if bound and ins then
		position = math.max(bound, ins)
		self.entry:select_region(position, position)
	end
	if position == -1 and not text:match "%s$" then
		position = position + buffer:insert_text(position, " ", -1)
	end
	if path:match "[%s'\"]" then
		-- As a nice bonus, the %q format specifier also escapes quotes.
		path = ("%q"):format(path)
	end
	path = path .. " "
	position = position + buffer:insert_text(position, path, -1)
	self.entry:select_region(position, position)
end

function runner:selectfiles(dofolders)
	local pwd = Gio.File.new_for_path(self.pwd)
	local filedialog = Gtk.FileDialog {
		initial_folder = pwd,
	}
	Gio.Async.start(function()
		local list
		if dofolders then
			list = filedialog:async_select_multiple_folders(app.active_window)
		else
			list = filedialog:async_open_multiple(app.active_window)
		end
		if not list then return end
		for i = 1, list.n_items do
			-- Gio's API documents say that ListModel's :get_item() method is not available to language bindings and to use :get_object() instead. That's not the case for LuaGObject, which binds :get_item() and returns the object itself instead of a pointer.
			local file = list:get_item(i - 1)
			-- The files returned by the dialog are sandboxed by Flatpak, but versions with the real paths are needed for the relative path calculation to work correctly.
			file = Gio.File.new_for_path(lib.unflatpakize(file))
			local path = pwd:get_relative_path(file)
			if not path and not dofolders then
				-- The ability to query a file's host path is a little dicey in the case of symlinks to files. What works better is querying the parent's path and then just tacking the file's basename at the end.
				local dir = file:get_parent()
				path = lib.unflatpakize(dir)
				path = path .. "/" .. file:get_basename()
			elseif not path then
				path = lib.unflatpakize(file)
			end
			self:enterfile(path)
		end
	end)() --Call wrapped async context.
end

function runner:getpwdlabel()
	return lib.fmtdir(self.pwd)
end

function runner:getprefixlabel(short)
	assert(self.prefix and type(self.prefix) == "string")
	local tooltip = (_ "Clear prefix %q"):format(self.prefix)
	if short and #self.prefix > 0 then
		return (self.prefix:match("^%S*"))
	elseif #self.prefix > 24 then
		local prefixslice = utf8.char(utf8.codepoint(self.prefix, 1, 20))
		prefixslice = prefixslice:gsub("%s$", "") -- Strip trailing space.
		return prefixslice .. "…", tooltip
	else
		return self.prefix, tooltip
	end
end

function runner:gettitle()
	local prefix = self:getprefixlabel(true)
	local pwd = self:getpwdlabel()
	local pretty = pwd
	if #prefix > 0 then
		pretty = ("(%s) %s"):format(prefix, pwd)
	end
	local icon
	if self.subproc then
		icon = "tp-running-symbolic"
	end
	return self.commandname, pwd, pretty, icon
end

function runner:updatetitle()
	if not self.settitle then return end
	self:settitle(self:gettitle())
end

function runner:trychdir()
	local pwd = Gio.File.new_for_path(self.pwd)
	local filedialog = Gtk.FileDialog {
		title = _ "Change Directory",
		initial_folder = pwd,
	}
	Gio.Async.start(function()
		self.entry.sensitive = false
		self.chdirbutton.visible = false
		self.prefixbutton.visible = false
		self.menubutton.visible = false
		self.historybutton.visible = false
		self.sendbutton.sensitive = false
		local dir = filedialog:async_select_folder(app.active_window)
		if dir then
			-- guaranteed to be a dir, so there will be a message
			self:ensurenewlines(2)
			self:chdir(lib.unflatpakize(dir))
		end
		self:finish()
	end)() --Call wrapped async context.
end

function runner:chdir(path)
	if self.subproc then return end
	self.pwd = path
	self:ensurenewlines(1)
	local message = _ "New working directory →	%s\n"
	self:print(message:format(self:getpwdlabel()))
	self:inserthistory("cd " .. self:getpwdlabel())
	self:updatetitle()
end

function runner:showfolder()
	local launcher = Gio.SubprocessLauncher.new { "STDOUT_SILENCE", "STDERR_SILENCE" }
	local subproc = launcher:spawnv {
		"flatpak-spawn",
		"--host",
		"--watch-bus",
		"/usr/bin/xdg-open",
		self.pwd,
	}
end

function runner:putstring(text)
	local bound, insert
	local first, second = self:gettextiters()
	-- If the buffer has a selection that extends to the end of the buffer, it needs to be preserved, so mark it.
	if self.buffer:get_has_selection() and second:is_end() then
		bound = self.buffer:create_mark(nil, first, true)
		insert = self.buffer:create_mark(nil, second, true)
	end
	local enditer = self.buffer:get_end_iter()
	self.buffer:insert(enditer, text, -1)
	-- If marks were made to preserve selection, then reselect now and delete those marks.
	if bound and insert then
		first = self.buffer:get_iter_at_mark(bound)
		second = self.buffer:get_iter_at_mark(insert)
		self:selecttext(first, second)
		self.buffer:delete_mark(bound)
		self.buffer:delete_mark(insert)
	end
end

function runner:flush()
	if #self.outputqueue < 1 then return end
	if not self.outputqueue:match "[^\n]" then return end
	local output = self.outputqueue
	local bel = "\u{07}"
	if output:match(bel) and self.tabview.selected_page ~= self.tabpage then
		self.tabpage.needs_attention = true
	end
	output = output:gsub(bel, "")
	local newlines = self.outputqueue:match "\n*$"
	output = output:gsub("\n*$", "")
	if output then
		self:putstring(output)
	end
	self.outputqueue = newlines or ""
end

function runner:print(... items)
	local text = table.concat(items, "	")
	self.outputqueue = self.outputqueue .. text
	local outputcount = #self.outputqueue
	GLib.timeout_add(10, 120, function()
		-- If the output queue length hasn't changed, then flush it.
		if #self.outputqueue == outputcount then
			self:flush()
		end
	end)
end

function runner:ensurenewlines(n)
	self:flush()
	if not n then n = 2 end
	local pattern = ""
	for i = 1, n do pattern = pattern .. "\n" end
	while #self.buffer.text > 0 and self.buffer.text:sub(-n, -1) ~= pattern do
		self:putstring "\n"
	end
	self.outputqueue = self.outputqueue:match "[^\n].*" or ""
end

function runner:handlepipe(pipe, callback, copyafter)
	Gio.Async.start(function()
		repeat
			-- This is technically a broken implementation. Telepipe uses UTF-8 to encode text, so the last byte(s) of the returned array may be an incomplete code point. In practice, this doesn't really matter as the next read happens nearly-instantly because this async context has maximum io_priority and so the broken code point is fixed in the next write.
			local bytes = pipe:async_read_bytes(4096)
			if not self.closepipes and #bytes.data > 0 then
				callback(bytes.data)
			else
				pipe:async_close()
			end
		until pipe:is_closed()
		-- Only copy to the clipboard if the underlying process wasn't severed from the application.
		if copyafter and not self.closepipes then self:copy() end
	end)() -- Call wrapped async context.
end

function runner:copy()
	if not self.copyqueue then
		return
	elseif #self.copyqueue > 0 then
		local clipboard = Gdk.Display.get_default():get_clipboard()
		clipboard:set(GObject.Value(GObject.Type.STRING, self.copyqueue))
		self:ensurenewlines(1)
		self:putstring(_ "Copied output to clipboard.")
		self:print "\n"
	else
		self:ensurenewlines(1)
		self:putstring(_ "Nothing to copy; Clipboard has not been modified.")
		self:print "\n"
	end
	self.copyqueue = nil
end

function runner:finish()
	self.forcedexit = nil
	self.commandname = nil
	self.closepipes = false
	self.subproc = nil
	self.allowsever = false
	self.chdirbutton.visible = true
	self.prefixbutton.visible = #self.prefix > 0
	self.menubutton.visible = false
	self.historybutton.visible = self:gethistory().n_items > 0
	self.entry.sensitive = true
	self.entry.placeholder_text = _ "Run a command…"
	self.sendbutton.icon_name = "tp-run-symbolic"
	self.sendbutton.tooltip_text = _ "Run command"
	if #self.entry.text > 0 then self.sendbutton.sensitive = true end
	self:updatetitle()
	self:grab()
end

function runner:waitend(async)
	if not self.subproc then return self:finish() end
	local subproc = self.subproc
	Gio.Async.start(function()
		self.subproc:async_wait()
		if self.subproc ~= subproc then return end
		local status = math.ceil(self.subproc:get_status() / 256)
		if self.forcedexit then
			self:ensurenewlines(1)
			self:putstring(_ "Command was stopped.")
			self:print "\n"
		elseif status ~= 0 then
			self:ensurenewlines(1)
			self:putstring((_ "Exited with status code %d."):format(status))
			self:print "\n"
		end
		self:finish()
	end)() -- Call wrapped async context.
end

function runner:gethistory()
	assert(self.history[self.prefix])
	return self.history[self.prefix]
end

function runner:removehistory(command)
	local history = self:gethistory()
	repeat
		local index = history:find(command)
		if index >= history.n_items or index < 0 then break end
		history:remove(index)
	until false
	if history.n_items == 0 then
		self.historybutton.visible = false
		self.historybutton.popover:popdown()
	end
end

function runner:inserthistory(command)
	local history = self:gethistory()
	self:removehistory(command)
	history:append(command)
	if history.n_items > 0 then
		self.historybutton.visible = true
	end
end

function runner:switchprefix(prefix)
	assert(type(prefix) == "string")
	self.prefix = prefix
	if not self.history[self.prefix] then
		self.history[self.prefix] = Gtk.StringList()
		self:inserthistory("prefix " .. prefix)
	end
	self.histview.model = Gtk.NoSelection {
		model = self:gethistory(),
	}
	local prefixlabel, prefixtooltip = self:getprefixlabel()
	self.prefixbutton.label = prefixlabel
	self.prefixbutton.tooltip_text = prefixtooltip
	self.prefixbutton.visible = #self.prefix > 0
	self:updatetitle()
end

-- ListView handlers.

function runner:setupitem(listitem)
	local label = Gtk.Label {
		extra_css_classes = { "numeric" },
		halign = "START",
		hexpand = true,
		margin_start = 6,
		margin_end = 24,
		selectable = true,
		wrap = true,
		wrap_mode = "WORD_CHAR",
	}

	-- It is normally a better idea to bind signal handlers in the ::bind signal, after an item is bound. However, LuaGObject kind of makes it a bit of a nightmare to unbind signals. Someone should fix that.
	local transferbutton = Gtk.Button {
		icon_name = "tp-transfer-symbolic",
		tooltip_text = _ "Copy to command entry",
		valign = "CENTER",
		on_clicked = function()
			local command = listitem.item.string
			self.historybutton.popover:popdown()
			self.historybutton.active = false
			self.entry.text = command
			self:grab()
		end,
	}
	local deletebutton = Gtk.Button {
		icon_name = "tp-delete-symbolic",
		extra_css_classes = { "destructive-action" },
		tooltip_text = _ "Remove from history",
		valign = "CENTER",
		on_clicked = function()
			local command = listitem.item.string
			local history = self:gethistory()
			local index = history:find(command)
			self:removehistory(command)
			GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
				if index >= history.n_items then
					index = history.n_items - 1
				end
				if index >= 0 then
					self.histview:scroll_to(index)
				end
			end)
		end,
	}

	listitem.child = Gtk.Box {
		orientation = "HORIZONTAL",
		halign = "FILL",
		spacing = 12,
		margin_top = 6,
		margin_bottom = 6,
		margin_start = 6,
		margin_end = 6,
		label,
		Gtk.Box {
			orientation = "HORIZONTAL",
			spacing = 12,
			margin_start = 12,
			margin_end = 12,
			halign = "END",
			transferbutton,
			deletebutton,
		},
	}
end

function runner:binditem(listitem)
	-- Because the label is the box's first child, it's easy to find.
	listitem.child.children[1].label = listitem.item.string
end

function runner:unbinditem(listitem)
	-- Same as in :binditem().
	listitem.child.children[1].label = ""
end

function runner:teardownitem(listitem)
	-- Everything should just get GC'd at this point, so no need to do anything.
end

-- Execution

function runner:getenv(name)
	return self.env[name] or envvars[name] or ""
end

function runner:getexecargs(command)
	-- Basic flatpak-spawn parameters
	local args = {
		"flatpak-spawn",
		"--host",
		("--directory=%s"):format(self.pwd),
		"--watch-bus",
	}
	-- Environment variables
	for name, value in pairs(envvars) do
		table.insert(args, ("--env=%s=%s"):format(name, value))
	end
	for name, value in pairs(self.env) do
		table.insert(args, ("--env=%s=%s"):format(name, value))
	end
	-- The shell command itself
	local shell = self:getenv "SHELL"
	if #shell == 0 then
		-- If not explicitly configured, get the shell from Telepipe's environment.
		shell = os.getenv "SHELL" or os.getenv "shell"
	end
	if #shell == 0 or shell:sub(1, 1) ~= "/" then
		-- Shell param needs to be an absolute path, so if it doesn't exist it must be set, otherwise Telepipe cannot execute commands.
		shell = "/bin/bash"
	end
	table.insert(args, shell)
	table.insert(args, "-c")
	table.insert(args, command)
	return args
end

function runner:tryexec(command)
	command = lib.strip(command)
	if #command == 0 then return end
	local name = command:match "^%S*"
	if runner.builtin[name] then
		self:ensurenewlines()
		self:putstring("⇒	" .. command)
		self:print "\n"
		local param = command:match "%s+(.*)"
		-- The "cd" command has special behaviour for history handling.
		if name ~= "cd" then
			self:inserthistory(command)
		end
		runner.builtin[name](self, param)
		self.historybutton.visible = self:gethistory().n_items > 0
	else
		self:exec(command)
	end
end

function runner:exec(command)
	self:inserthistory(command)
	self:ensurenewlines()
	local prefix = command:sub(1, 1)
	local dopipein = prefix == ">" or prefix == "|"
	local dopipeout = prefix == "<" or prefix == "|"
	local dobackground = prefix == "&"
	self.allowsever = not dopipeout
	if dopipein then
		self.entry.sensitive = false
		self:putstring "Pasting to "
	elseif not dobackground then
		self.entry.placeholder_text = _ "Send to running command…"
		self.sendbutton.tooltip_text = _ "Send to running command"
	end
	if dobackground then
		self:putstring(_ "Spawning ⇒	" .. command)
	else
		self:putstring("⇒	" .. command)
	end
	self:print "\n"
	self.commandname = command
	if dopipein or dopipeout or dobackground then
		command = lib.strip(command:sub(2))
	end
	if #self.prefix > 0 then
		self.commandname = ("(%s) %s"):format(self.prefix, command)
		command = self.prefix .. " " .. command
	end
	local launcherargs = { "STDIN_PIPE", "STDOUT_PIPE", "STDERR_PIPE" }
	if not dopipeout then
		-- If the output isn't being copied, then the streams need to be merged.
		launcherargs[3] = "STDERR_MERGE"
	end
	local launcher = Gio.SubprocessLauncher.new(launcherargs)
	self.subproc = launcher:spawnv(self:getexecargs(command))
	if not self.subproc then
		self:ensurenewlines(1)
		self:putstring(_ "Failed to run command.")
		self:print "\n"
		self:finish()
		return
	end
	if dobackground then
		self:sever()
		return
	end
	self.chdirbutton.visible = false
	self.prefixbutton.visible = false
	self.menubutton.visible = true
	self.historybutton.visible = false
	self.sendbutton.icon_name = "tp-send-symbolic"
	self.sendbutton.tooltip_text = _ "Send to running command"
	if dopipein then self:paste() end
	local function copycb(text)
		self.copyqueue = self.copyqueue .. text
	end
	local function printcb(text)
		self:print(text)
	end
	local stdout = self.subproc:get_stdout_pipe()
	if dopipeout then
		self.copyqueue = ""
		self:handlepipe(stdout, copycb, true)
		local stderr = self.subproc:get_stderr_pipe()
		self:handlepipe(stderr, printcb)
	else
		self:handlepipe(stdout, printcb)
	end
	self:updatetitle()
	self:waitend()
end

function runner:sever()
	if not self.subproc or not self.allowsever then return false end
	-- Tell the output pipe handlers to abort.
	self.closepipes = true
	self:close "stdin"
	self:close "stdout"
	self:close "stderr"
	self:finish()
end

function runner:kill()
	if not self.subproc then return end
	self.forcedexit = true
	self.subproc:force_exit()
end

function runner:send(line)
	-- Scroll to the bottom (and reenable automatic scrolling) before printing anything. No matter what is done here, there should always be *something* printed here, so this is not a loss.
	local vadjust = self.scrolledwin.vadjustment
	vadjust.value = vadjust.upper - vadjust.page_size
	if not self.subproc then return self:tryexec(line) end
	local stdin = self.subproc:get_stdin_pipe()
	if stdin:is_closed() or stdin:is_closing() then return end
	line = line .. "\n"
	-- Print the user input before sending it, in case the program exits before the print is registered. Otherwise, an error status message may appear before what the user sent.
	if line:match "[^\n]" then
		self:print(line)
		self:flush()
	else
		-- If the user input only consisted of newlines, then print them immediately instead of queueing them for the next print.
		self:putstring(line)
	end
	Gio.Async.start(function()
		stdin:async_write(line, #line)
		stdin:async_flush()
	end)() -- Call wrapped async context.
end

function runner:paste()
	Gio.Async.start(function()
		local stdin = self.subproc:get_stdin_pipe()
		if stdin:is_closed() then return end
		local clipboard = Gdk.Display.get_default():get_clipboard()
		local inputtext = clipboard:async_read_text()
		if not inputtext or #inputtext < 1 then
			self:ensurenewlines(1)
			self:putstring(_ "Nothing to paste.")
			self:print "\n"
		else
			stdin:async_write(inputtext, #inputtext)
		end
		stdin:async_flush()
		stdin:async_close()
	end)() -- Call wrapped async context.
end

function runner:close(pipename)
	assert(pipename)
	if not self.subproc then return end
	-- Keep the subproc active in-memory, at least until the closure ends.
	local subproc = self.subproc
	if not pipename then pipename = "stdin" end
	Gio.Async.start(function()
		local pipefunc = "get_" .. pipename .. "_pipe"
		local pipe = subproc[pipefunc](subproc)
		if not pipe or pipe:is_closed() then return end
		if pipename == "stdin" then
			self.entry.sensitive = false
			self.sendbutton.sensitive = false
		end
		pipe:async_close()
	end)() -- Call wrapped async context.
end

function runner:getbound()
	return self.buffer:get_selection_bound()
end

function runner:getinsert()
	return self.buffer:get_insert()
end

function runner:gettextiters()
	local first = self.buffer:get_iter_at_mark(self:getbound())
	local second = self.buffer:get_iter_at_mark(self:getinsert())
	first:order(second)
	return first, second
end

function runner:selecttext(first, second)
	assert(first, second)
	first:order(second)
	-- Gtk.TextBuffer expects the bound, followed by the insert.
	self.buffer:select_range(second, first)
end

function runner:scrollselection()
	local buf, tv = self.buffer, self.textview
	self.textview:scroll_to_mark(self:getbound(), 0.4999, false, 0.0, 0.0)
	self.textview:scroll_to_mark(self:getinsert(), 0.2, false, 0.0, 0.0)
end

function runner:selectrange(bound, insert)
	assert(type(bound) == "number")
	assert(type(insert) == "number")
	local first = self.buffer:get_start_iter()
	first:forward_chars(bound - 1)
	local second = self.buffer:get_start_iter()
	second:forward_chars(insert - 1)
	self:selecttext(first, second)
end

-- Search functions.

function runner:beginsearch()
	if self.searchbar.search_mode_enabled then
		self.searchentry:grab_focus_without_selecting()
		return
	end
	-- Replace the search entry if the current selection doesn't match
	if self.buffer:get_has_selection() then
		self.searchentry.text = self.buffer:get_slice(self:gettextiters())
	else
		self.searchentry.text = ""
	end
	self.searchbar.search_mode_enabled = true
	if #self.searchentry.text > 0 then
		self:findall(self.searchentry.text)
	else
		self.matchlabel.label = ""
	end
	self.searchentry:grab_focus_without_selecting()
end

function runner:setmatches(total, current)
	if type(current) == "number" and type(total) == "number" then
		self.matchlabel.label = (_ "%d of %d"):format(current, total)
	elseif total == 0 then
		self.matchlabel.label = _ "no matches"
	elseif type(total) == "number" then
		self.matchlabel.label = ("%d"):format(total)
	elseif type(total) == "string" then
		self.matchlabel.label = total
	else
		self.matchlabel.label = ""
	end
end

function runner:findall(pattern)
	if #pattern == 0 then return end
	local byteindices = {}
	local text = self.buffer.text
	local len = #text
	local init = 1
	while init <= len do
		local i, j = text:find(pattern, init, true)
		if not i or not j then break end
		table.insert(byteindices, { i, j })
		init = j + 1
	end
	-- clear the table without reassigning
	while #self.matches > 0 do table.remove(self.matches) end
	local utftotal = 0
	init = 1
	for _, t in ipairs(byteindices) do
		local i = t[1]
		local j = t[2]
		local ulen1 = utf8.len(text, init, i, true)
		local ulen2 = utf8.len(text, i, j, true)
		assert(ulen1 and ulen2)
		ulen1 = utftotal + ulen1
		utftotal = ulen1
		ulen2 = utftotal + ulen2
		utftotal = ulen2 - 1
		table.insert(self.matches, { ulen1, ulen2 })
		init = j + 1
	end
	self:setmatches(#self.matches)
end

function runner:searchprev(...)
	self:findall(...)
	if #self.matches == 0 then return end
	local first, _ = self:gettextiters()
	local cursorpos = first:get_offset() + 1
	for i = 1, #self.matches do
		local idx = #self.matches - i + 1
		local m = self.matches[idx]
		if cursorpos >= m[2] then
			self:selectrange(m[1], m[2])
			self:scrollselection()
			self:setmatches(#self.matches, idx)
			return
		end
	end
	-- Wrap to end.
	local m = self.matches[#self.matches]
	self:selectrange(m[1], m[2])
	self:scrollselection()
	self:setmatches(#self.matches, #self.matches)
end

function runner:searchnext(...)
	self:findall(...)
	if #self.matches == 0 then return end
	local _, first = self:gettextiters()
	local cursorpos = first:get_offset()
	for i, m in ipairs(self.matches) do
		if m[1] > cursorpos then
			self:selectrange(m[1], m[2])
			self:scrollselection()
			self:setmatches(#self.matches, i)
			return
		end
	end
	-- Wrap to start.
	self:selectrange(self.matches[1][1], self.matches[1][2])
	self:scrollselection()
	self:setmatches(#self.matches, 1)
end

-- Built-in runner functions. If a command matches any of these names, it'll instead call a built-in.
runner.builtin = {}

-- The declaration for these functions is slightly misleading. Instead of self referring to the runner.builtin table, it instead refers to the runner instance due to how builtins are called. See runner:tryexec.

function runner.builtin:help()
	self:print(_ [=[
Telepipe is a command-line shell. Run command-line applications as you would in a terminal.

Shell commands may begin with a special control character to modify their behaviour. These are,
• &command
	Quietly runs "command" in the background, without input or output.
• >command
	Paste's the clipboard's contents into "command" as input.
• <command
	Copy the output of "command" into the clipboard once it finishes.
• |command
	Pastes the clipboards contents into "command", and copies the output of "command" back into the clipboard, allowing "command" to transform the clipboard's contents.

Telepipe can be controlled through certain built-in commands. These are,
• help
	Print this help text.
• exit
	Closes the current tab. If no tabs remain, closes the current window.
• cd [directory]
	Changes the current working directory to the given path. If no path is given, changes the current working directory to the home directory.
	Spaces and special characters in the given parameter will be interpreted verbatim—quotes and escape characters are not needed for the cd command.
• prefix [command [args…]]
	Sets this tab's prefix to the given command/arguments. If no command is given, deactivates the prefix instead. Whenever a prefix is set, it will be prepended to all subsequent shell commands—after any special prefix characters, if given.
• setenv [name[=[value]]]
	If no parameters are given, prints out the tab's environment variables.
	If a name is given, prints out the value of the given environment variable.
	If a name and equal sign are given, unsets the given environment variable.
	If a name, equal sign, and value are given, sets the given environment variable to the given value.
• clearenv
	Unsets all of the tab's environment variables.

Telepipe's built-in commands are not considered shell commands, and are thus unaffected by special control characters or prefixes.

THIS SOFTWARE IS EXPERIMENTAL. Expected command-line features may not exist and existing features may be subject to change. Many command-line programs will behave unusually, though in most cases this can be remedied through certain flags. Programs requiring the terminal will not function at all, and may output odd-looking text—avoid using these applications in Telepipe.

Visit Telepipe's code repository at https://github.com/vtrlx/telepipe/ for more information or to submit an issue.
]=])
end

function runner.builtin:cd(dir)
	if not dir or #dir == 0 or not dir:match "[^%s]" then dir = os.getenv "HOME" end
	dir = lib.expanddir(dir)
	local target
	if dir:match "^/" then
		-- Strips redundant info from path, like trailing slashes.
		dir = Gio.File.new_for_path(dir):get_path()
	else
		dir = Gio.File.new_for_path(self.pwd):resolve_relative_path(dir):get_path()
	end
	Gio.Async.call(function()
		self.entry.sensitive = false
		local launcher = Gio.SubprocessLauncher.new { "STDOUT_SILENCE", "STDERR_SILENCE" }
		local eval = ([[
			DIR=%q
			if [ -d "$DIR" ]
			then
				exit 0
			elif [ -f "$DIR" ]
			then
				exit 2 # Not a directory
			fi
			exit 1 # No such directory
		]]):format(dir)
		-- The use of flatpak-spawn to validate the existence of directories on the host system was recommended by Flathub's volunteers.
		local args = {
			"flatpak-spawn",
			"--host",
			("--directory=%s"):format(os.getenv "HOME"),
			"--watch-bus",
			"/usr/bin/env",
			"sh",
			"-c",
			eval,
		}
		local subproc = launcher:spawnv(args)
		self.chdirbutton.visible = false
		self.prefixbutton.visible = false
		self.menubutton.visible = false
		self.historybutton.visible = false
		self.sendbutton.sensitive = false
		subproc:async_wait()
		local status = math.ceil(subproc:get_status() / 256)
		assert(status <= 2)
		if status == 0 then
			self:chdir(dir)
		elseif status == 1 then
			self:ensurenewlines(1)
			self:putstring((_ "No such directory: %s"):format(dir))
			self:print "\n"
		elseif status == 2 then
			self:ensurenewlines(1)
			self:putstring((_ "Not a directory: %s"):format(dir))
			self:print "\n"
		end
		self:finish()
	end)() -- Call wrapped async context.
end

function runner.builtin:clearenv()
	local names = {}
	for name in pairs(self.env) do table.insert(names, name) end
	for _, name in ipairs(names) do self.env[name] = nil end
	self:ensurenewlines(1)
	self:putstring(_ "Environment variables were cleared.")
end

function runner.builtin:exit()
	-- No need to save history or anything, and this is guaranteed to be successful.
	self.tabview:close_page(self.tabpage)
	if self.tabview.n_pages == 0 then
		app.active_window:close()
	end
end

function runner.builtin:prefix(prefix)
	prefix = prefix or ""
	if #self.prefix == 0 and #prefix == 0 then
		self:ensurenewlines(1)
		self:putstring "No prefix given."
		self:print "\n"
		return
	end
	prefix = prefix:gsub("^%s*", ""):gsub("%s*$", "")
	self:switchprefix(prefix, 1)
	self:ensurenewlines(1)
	if #self.prefix == 0 then
		self:putstring(_ "Prefix was cleared.")
		self.prefixbutton.visible = false
	else
		self:putstring(_ "Active prefix →	" .. self.prefix)
	end
	self:print "\n"
end

function runner.builtin:setenv(param)
	if not param then
		for k, v in pairs(self.env) do
			self:ensurenewlines(1)
			self:putstring(k .. "=" .. v)
		end
		return
	end
	local pattern = "^%s*(" .. validname .. ")"
	local name = param:match(pattern)
	local value = param:match "=.*"
	if not name then
		self:ensurenewlines(1)
		self:putstring(_ "Given variable name is invalid.")
	elseif not value then
		self:ensurenewlines(1)
		value = self.env[name] or envvars[name]
		if value then
			self:putstring(name .. "=" .. value)
		else
			self:putstring((_ "Variable %s is unset."):format(name))
		end
	elseif #value == 1 then
		self.env[name] = nil
		self:ensurenewlines(1)
		self:putstring((_ "Cleared variable %s."):format(name))
	else
		value = value:sub(2)
		self.env[name] = value
		self:ensurenewlines(1)
		self:putstring((_ "Set variable %s to %q."):format(name, value))
	end
end

-- SECTION: Application menus

local appmenu = Gio.Menu()
appmenu:append(_ "New Window", "win.new-win")
appmenu:append(_ "Search Command Output", "win.search")
appmenu:append(_ "Open Working Directory", "win.open-folder")
appmenu:append(_ "Preferences", "win.preferences")
appmenu:append(_ "Keyboard Shortcuts", "win.shortcuts")
appmenu:append(_ "About " .. app_title, "win.about")

local function shortcuts(parent)
	local cut = Adw.ShortcutsItem.new_from_action
	local shortdlg = Adw.ShortcutsDialog {
		Adw.ShortcutsSection {
			title = _ "Telepipe Window",
			cut(_ "New Tab", "win.new-tab"),
			cut(_ "Duplicate Tab", "win.dup-tab"),
			cut(_ "New Window", "win.new-win"),
			cut(_ "Open Tab Switcher", "win.overview"),
			cut(_ "Open Preferences Dialog", "win.preferences"),
			cut(_ "Show Keyboard Shortcuts", "win.shortcuts"),
		},
		Adw.ShortcutsSection {
			title = _ "Command Runner Tab",
			cut(_ "Search Command Output", "win.search"),
			cut(_ "Show Working Directory in Files", "win.open-folder"),
			cut(_ "Stop Current Command", "win.signal-kill"),
			cut(_ "Close Command Input", "win.signal-endinput"),
			cut(_ "Quietly Send to Background", "win.signal-background"),
			cut(_ "Focus Command Entry", "win.focus-cmdbar"),
			cut(_ "Change Working Directory", "win.chdir"),
			cut(_ "Enter File Path in Entry", "win.enter-file-path"),
			cut(_ "Enter Folder Path in Entry", "win.enter-folder-path"),
			cut(_ "Close Current Tab", "win.close-tab"),
		},
	}
	shortdlg:present(parent)
end

local function about(parent)
	local aboutdlg = Adw.AboutDialog {
		application_icon = app_id,
		application_name = app_title,
		copyright = "© 2026 Victoria Lacroix",
		developer_name = "Victoria Lacroix",
		issue_url = "https://github.com/vtrlx/telepipe/issues/new",
		license_type = "GPL_3_0",
		release_notes_version = lib.get_app_ver(),
		translator_credits = _ "translator-credits",
		version = lib.get_app_ver(),
		website = "https://www.vtrlx.ca/apps/telepipe/",
	}

	aboutdlg:add_link(_ "Contact the developer", "mailto:victoria@vtrlx.ca?subject=Telepipe")
	aboutdlg:add_link(_ "Contribute a translation", "https://github.com/vtrlx/telepipe?tab=readme-ov-file#localization")
	aboutdlg:add_link(_ "Support this app", "https://liberapay.com/vtrlx/")

	aboutdlg:present(parent)
end

-- SECTION: Application window

local window
window = lib.newclass(function(self)
	self.windowtitle = Adw.WindowTitle.new(app_title, "")

	local newbutton = Gtk.Button {
		icon_name = "tp-newtab-symbolic",
		tooltip_text = _ "New Tab",
		on_clicked = function()
			self:newtab()
		end,
	}

	local menupopover = Gtk.PopoverMenu.new_from_model(appmenu)
	menupopover.halign = "END"
	local menubutton = Gtk.MenuButton {
		direction = "DOWN",
		icon_name = "tp-menu-symbolic",
		popover = menupopover,
	}

	self.tabview = Adw.TabView()
	function self.tabview.on_page_attached(tabview, page)
		local r = runners[page.child]
		if not r then return end
		r.tabview = self.tabview
		self.toolbarview.top_bar_style = "RAISED_BORDER"
		function r.settitle(r, title, subtitle, tabtitle, icon)
			page.title = title or tabtitle
			if icon then
				page.indicator_icon = Gio.Icon.new_for_string(icon)
			else
				page.indicator_icon = nil
			end
			if tabview.selected_page == page then
				self.win.title = subtitle
				self.windowtitle.subtitle = subtitle
			end
		end
		local title, subtitle = r:gettitle()
		page.title = title or subtitle
		self.windowtitle.subtitle = subtitle
		self.search.enabled = true
		self.showfolder.enabled = true
	end
	function self.tabview.on_page_detached(tabview, page)
		local r = runners[page.child]
		if not r then return end
		-- Stub it out to remove references to this tab view.
		function r:settitle() end
	end
	function self.tabview.on_notify(tabview, spec)
		if spec.name == "selected-page" and tabview.selected_page then
			tabview.selected_page.needs_attention = false
			local r = runners[self.tabview.selected_page.child]
			r:updatetitle()
			r.entry:grab_focus_without_selecting()
		end
	end
	function self.tabview.on_close_page(tabview, page)
		local r = runners[page.child]
		local do_close = true
		if r and r.subproc then
			do_close = false
		end
		self.tabview:close_page_finish(page, do_close)
		if not do_close then
			local body = _ "The command %q is running in this tab. Close anyway?"
			local name = r.commandname
			if #name > 20 then
				commandname = utf8.char(utf8.codepoint(name, 1, 20))
			end
			body = body:format(name)
			local dlg = Adw.AlertDialog.new(_ "Close This Tab?", body)
			dlg:add_response("close", _ "Keep Open")
			dlg:set_response_appearance("close", "DEFAULT")
			dlg:add_response("discard", _ "Stop Command and Close")
			dlg:set_response_appearance("discard", "DESTRUCTIVE")
			dlg:add_response("sever", _ "Send to Background and Close")
			dlg:set_response_appearance("sever", "DEFAULT")
			function dlg.on_response(dlg, response)
				if response == "discard" then
					r:kill()
					runners[page.child] = nil
					self.tabview:close_page(page)
				elseif response == "sever" then
					r:sever()
					runners[page.child] = nil
					self.tabview:close_page(page)
				end
			end
			dlg:choose(app.active_window)
		else
			runners[page.child] = nil
			if self.tabview:get_n_pages() == 0 then
				self.win.title = app_title
				self.windowtitle.title = app_title
				self.windowtitle.subtitle = ""
				self.toolbarview.top_bar_style = "FLAT"
				self.search.enabled = false
				self.showfolder.enabled = false
			end
		end
		return true
	end
	function self.tabview.on_create_window()
		local win = window()
		return win.tabview
	end

	self.tabbar = Adw.TabBar {
		view = self.tabview,
	}

	local tabbutton = Adw.TabButton {
		view = self.tabview,
		on_clicked = function()
			local r = get_focused_runner()
			if not r then return end
			self:overview()
		end,
	}

	self.toolbarview = Adw.ToolbarView {
		content = self.tabview,
		top_bar_style = "FLAT",
		top_bars = {
			Adw.HeaderBar {
				title_widget = self.windowtitle,
				start_packs = { newbutton },
				end_packs = { menubutton, tabbutton },
			},
			self.tabbar,
		},
	}

	self.win = Adw.ApplicationWindow {
		application = app,
		title = app_title,
		content = self.toolbarview,
		default_width = 640,
		default_height = 480,
		width_request = 360,
		height_request = 360,
	}
	function self.win.on_close_request()
		local n_pages = self.tabview:get_n_pages()
		local running = {}
		for i = 1, n_pages do
			local page = self.tabview:get_nth_page(n_pages - i)
			local r = runners[page.child]
			if r and r.subproc then
				table.insert(running, r)
			end
		end
		local function close()
			for _, r in ipairs(running) do
				r:kill()
			end
			Gio.Async.start(function()
				-- Need to wait for the subprocesses to actually finish befor attempting to close the window again.
				for _, r in ipairs(running) do
					if r.subproc then r.subproc:async_wait() end
				end
				-- Give it a tiny wait.
				GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
					self.win:close()
				end)
			end)()
		end
		if #running > 0 then
			local dlg = Adw.AlertDialog.new(_ "Stop Running Commands?", _ "There are commands running in this window. Close anway?")
			dlg:add_response("cancel", _ "Keep Open")
			dlg:set_response_appearance("cancel", "DEFAULT")
			dlg:add_response("discard", _ "Stop All and Close")
			dlg:set_response_appearance("discard", "DESTRUCTIVE")
			function dlg:on_response(response)
				if response == "discard" then close() end
			end
			dlg:choose(self.win)
			return true
		else
			-- Explicitly close each runner page to free their resources. Cleaner than hooking into e.g. __gc.
			for i = 1, n_pages do
				local page = self.tabview:get_nth_page(n_pages - i)
				self.tabview:close_page(page)
			end
			return false
		end
	end

	self:addnewaction("signal-kill", function()
		local r = get_focused_runner()
		if not r then return end
		r:kill()
	end)

	self:addnewaction("signal-endinput", function()
		local r = get_focused_runner()
		if not r then return end
		r:close "stdin"
	end)

	self:addnewaction("signal-background", function()
		local r = get_focused_runner()
		if not r then return end
		r:sever()
		r:ensurenewlines(1)
		r:putstring(_ "Command was sent to the background.")
		r:print "\n"
	end)

	self:addnewaction("focus-cmdbar", function()
		local r = get_focused_runner()
		if not r then return end
		r:grab()
	end)

	self.search = self:addnewaction("search", function()
		local r = get_focused_runner()
		if not r then return end
		r:beginsearch()
	end)
	self.search.enabled = false

	self.showfolder = self:addnewaction("open-folder", function()
		local r = get_focused_runner()
		if not r then return end
		r:showfolder()
	end)
	self.showfolder.enabled = false

	self:addnewaction("enter-file-path", function()
		local r = get_focused_runner()
		if not r then return end
		r:selectfiles()
	end)

	self:addnewaction("enter-folder-path", function()
		local r = get_focused_runner()
		if not r then return end
		r:selectfiles(true)
	end)

	self:addnewaction("chdir", function()
		local r = get_focused_runner()
		if not r then return end
		r:trychdir()
	end)

	self:addnewaction("new-tab", function()
		self:newtab()
	end)

	self:addnewaction("dup-tab", function()
		self:duptab()
	end)

	self:addnewaction("new-win", function()
		local win = window()
		win:newtab()
	end)

	self:addnewaction("close-tab", function()
		local page = self.tabview.selected_page
		if not page then return end
		self.tabview:close_page(page)
	end)

	self:addnewaction("overview", function()
		local r = get_focused_runner()
		if not r then return end
		self:overview()
	end)

	self:addnewaction("preferences", function()
		self:preferences()
	end)

	self:addnewaction("shortcuts", function()
		shortcuts(self.win)
	end)

	self:addnewaction("about", function()
		about(self.win)
	end)

	if lib.get_is_devel() then
		self.win:add_css_class "devel"
	end
	windows[self.win] = self
	self.win:present()
end)

function window:addnewaction(name, cb)
	local action = Gio.SimpleAction.new(name)
	action.enabled = true
	action.on_activate = cb
	self.win:add_action(action)
	return action
end

function window:newtab()
	local r = runner()
	r.tabpage = self.tabview:append(r.toolbarview)
	self.tabview:set_selected_page(r.tabpage)
end

-- Doesn't actually "duplicate" a tab, just opens a new one in the present working directory with the current prefix.
function window:duptab()
	local params = {}
	local selected = self.tabview.selected_page
	local position = 0
	if selected then
		local current = runners[selected.child]
		params.pwd = current.pwd
		params.prefix = current.prefix
		params.history = current.history
		params.buffer = current.buffer
		position = 1 + self.tabview:get_page_position(selected)
	end
	local r = runner(params)
	r.tabpage = self.tabview:insert(r.toolbarview, position)
	self.tabview:set_selected_page(r.tabpage)
end

function window:preferences()
	local envvargroup = Adw.PreferencesGroup {
		title = _ "Global Environment Variables",
		description = _ "Environment variables assigned here will be exported to every command that is executed.",
	}
	envvargroup:bind_model(envvarmodel, function(listitem)
		local line = listitem.string
		local pattern = "^%s*(" .. validname .. ")"
		local name = line:match(pattern)
		local value = (line:match "=.*"):sub(2)
		local deletebutton = Gtk.Button {
			extra_css_classes = { "flat" },
			icon_name = "tp-delete-symbolic",
			tooltip_text = _ "Clear this environment variable",
			valign = "CENTER",
			on_clicked = function()
				-- Causes the environment variable to be deleted.
				setenv(name, nil)
			end,
		}
		return Adw.ActionRow {
			extra_css_classes = { "property" },
			title = name,
			subtitle = value,
			suffixes = deletebutton,
		}
	end)

	local namerow = Adw.EntryRow {
		title = _ "Name",
	}
	local valuerow = Adw.EntryRow {
		title = _ "Value",
	}
	local addrow = Adw.ButtonRow {
		extra_css_classes = { "suggested-action" },
		title = _ "Set Variable",
		sensitive = false,
		on_activated = function()
			local pattern = "^%s*(" .. validname .. ")%s*$"
			local name = namerow.text:match(pattern)
			setenv(name, valuerow.text)
			namerow.text = ""
			valuerow.text = ""
		end,
	}

	local function validate()
		local isvalid = true
		local pattern = "^%s*(" .. validname .. ")%s*$"
		if not namerow.text:match(pattern) then
			namerow:add_css_class "error"
			isvalid = false
		else
			namerow:remove_css_class "error"
		end
		if #valuerow.text == 0 then
			valuerow:add_css_class "error"
			isvalid = false
		else
			valuerow:remove_css_class "error"
		end
		-- Don't show error when both are empty.
		if #namerow.text == 0 and #valuerow.text == 0 then
			namerow:remove_css_class "error"
			valuerow:remove_css_class "error"
		end
		addrow.sensitive = isvalid
	end
	namerow.on_changed = validate
	valuerow.on_changed = validate

	local envaddgroup = Adw.PreferencesGroup {
		title = _ "Set or Add Environment Variable",
		description = _ "If the named environment variable exists, its value will be set to the given value. Otherwise, the variable is added to the list.",
		namerow,
		valuerow,
		addrow,
	}

	local dialog = Adw.PreferencesDialog {
		Adw.PreferencesPage {
			title = _ "Preferences",
			envvargroup,
			envaddgroup,
		},
	}
	dialog:present(self.win)
end

-- Ideally, Adw.TabOverview would be used instead. Unfortunately, due to an issue with Gtk.TextView (see https://gitlab.gnome.org/GNOME/gtk/-/issues/7792), this is not possible. This implementation exists only as long as it is necessary.
function window:overview()
	local dialog

	local tabs = {}
	for i = 1, self.tabview.n_pages do
		local index = i - 1
		local page = self.tabview:get_nth_page(index)
		local indexlabel = Gtk.Label {
			label = ("%d"):format(i),
			extra_css_classes = { "numeric" },
			width_request = 30,
			xalign = 1,
		}
		local switchbutton = Gtk.Button {
			extra_css_classes = { "flat" },
			icon_name = "tp-rerun-symbolic",
			tooltip_text = _ "Switch to this tab",
			margin_end = 8,
			valign = "CENTER",
			on_clicked = function()
				self.tabview.selected_page = page
				dialog:close()
			end,
		}
		local r = runners[page.child]
		local title, subtitle, pretty = r:gettitle()
		table.insert(tabs, Adw.ActionRow {
			title = title or pretty,
			subtitle = (title and subtitle) or "",
			prefixes = { indexlabel },
			suffixes = { switchbutton },
			selectable = false,
			activatable = true,
			on_activated = function()
				self.tabview.selected_page = page
				dialog:close()
			end,
		})
	end

	local listbox = Gtk.ListBox {
		extra_css_classes = { "boxed-list" },
		valign = "START",
		margin_start = 24,
		margin_end = 24,
		margin_top = 24,
		margin_bottom = 24,
		table.unpack(tabs)
	}

	local scrolled = Gtk.ScrolledWindow {
		child = listbox,
		hscrollbar_policy = "NEVER",
		height_request = 300,
	}

	local entry = Gtk.Text {
		extra_css_classes = { "numeric" },
		placeholder_text = _ "Search open tabs…",
		hexpand = true,
		on_changed = function()
			listbox:invalidate_filter()
		end,
	}
	local function match(row)
		if #entry.text == 0 then return true end
		local query = lib.fmtdir(entry.text)
		local titlefound = row.title:find(query, 1, true) and true
		local subtitlefound = row.subtitle:find(query, 1, true) and true
		return titlefound or subtitlefound
	end
	listbox:set_filter_func(match)
	function entry.on_activate()
		if #entry.text == 0 then return end
		local last
		for i = 1, self.tabview.n_pages do
			index = i - 1
			local page = self.tabview:get_nth_page(index)
			local row = listbox:get_row_at_index(index)
			local found = match(row)
			if found and last then
				return
			elseif found then
				last = index
			end
		end
		if not last then return end
		self.tabview.selected_page = self.tabview:get_nth_page(last)
		dialog:close()
	end

	local clearbutton = Gtk.Button {
		css_name = "image",
		icon_name = "tp-clear-symbolic",
		margin_start = 12,
		visible = false,
		on_clicked = function()
			entry.text = ""
			entry:grab_focus()
		end,
	}

	local searchbox = Gtk.Box {
		css_name = "entry",
		orientation = "HORIZONTAL",
		margin_start = 30,
		margin_end = 30,
		Gtk.Image {
			extra_css_classes = { "nohover" },
			icon_name = "tp-search-symbolic",
		},
		entry,
		clearbutton,
	}

	local searchbar = Gtk.SearchBar {
		child = searchbox,
		search_mode_enabled = true,
		show_close_button = false
	}
	searchbar:connect_entry(entry)

	local toolbarview = Adw.ToolbarView {
		content = scrolled,
		top_bar_style = "RAISED_BORDER",
		top_bars = {
			Adw.HeaderBar(),
			searchbar,
		},
	}

	dialog = Adw.Dialog {
		child = toolbarview,
		title = _ "Search Tabs",
		content_width = 400,
		content_height = 400,
	}
	return dialog:present(self.win)
end

-- SECTION: App startup

function app:on_activate()
	if not app.active_window then return end
	app.active_window:present()
end

-- Handles command-line options. Currently, only serves to open a new Telepipe window in an already-running instance, either from the command-line, by manually selecting the "New Window" action from the dash, or by middle-clicking the app icon in the dash.
function app:on_command_line(cli)
	local opts = cli:get_options_dict()
	if cli:get_is_remote() and opts:contains "new-window" then
		local win = window()
		win:newtab()
	end
	-- Signal that command line options have been handled and that the app should continue starting up.
	cli:set_exit_status(0)
	cli:done()
	return -1
end

function app:on_startup()
	local win = window()
	win:newtab()
	local r = get_focused_runner()
	r:print(_ [[
Welcome to Telepipe. Type "help" in the command entry below (without quotation marks) then press the Enter key for more information on using this application.
]])
end

return app:run { lib.get_cli_args() }
