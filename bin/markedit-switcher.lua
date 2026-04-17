-- markedit-switcher.lua
-- Hammerspoon module: quick-switch between open MarkEdit tabs/windows (Cmd+Shift+E)
--
-- Install:
--   ln -s /path/to/MarkEdit/bin/markedit-switcher.lua ~/.hammerspoon/markedit-switcher.lua
--   Add require("markedit-switcher") to ~/.hammerspoon/init.lua
--
-- The hotkey is always registered but only acts when MarkEdit is frontmost.
--
-- Why 3 languages (AppleScript + Lua + JavaScript):
--
--   AppleScript — MarkEdit only exposes window/document info through its
--   scripting dictionary. There is no CLI API or IPC mechanism, so AppleScript
--   is the only way to enumerate open windows and switch between them.
--
--   Lua — Hammerspoon is the only practical way to bind a global hotkey and
--   intercept keyboard/mouse events on macOS without building a standalone app.
--   It also provides the event-tap infrastructure that makes the popup feel modal.
--
--   JavaScript — Hammerspoon's built-in hs.chooser is too rigid for custom
--   styling, fuzzy filtering, and mouse interaction. A lightweight WebView with
--   inline HTML/CSS/JS gives full control over the UI while staying self-contained
--   (no external files or dependencies).

local BUNDLE_ID = "app.cyan.markedit"
local HOME = os.getenv("HOME")

---------------------------------------------------------------------------
-- config
---------------------------------------------------------------------------

local config = {
	hotkey = {
		mods = { "cmd", "shift" },
		key = "e",
	},
	width = 500,
	maxRows = 10,
	yOffset = 0.22,

	theme = {
		bg = "rgba(40,40,40,0.95)",
		fg = "#e0e0e0",
		searchFontSize = "16px",
		listFontSize = "13px",
		itemPadding = "8px 14px",
		itemMargin = "1px 8px",
		itemRadius = "6px",
		selectedBg = "rgba(255,255,255,0.1)",
		nameFontWeight = "500",
		nameColor = "#f0f0f0",
		dirFontSize = "11px",
		dirColor = "rgba(255,255,255,0.35)",
		placeholderColor = "rgba(255,255,255,0.3)",
		separatorColor = "rgba(255,255,255,0.08)",
		scrollbarColor = "rgba(255,255,255,0.2)",
		cornerRadius = "10px",
	},
}

local KEYS = {
	escape = 53,
	enter = 36,
	backspace = 51,
	up = 126,
	down = 125,
	left = 123,
	right = 124,
	n = 45,
	p = 35,
	j = 38,
	k = 40,
	a = 0,
}

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------

-- persistent webview and event taps (created once, reused)
local webview = nil
local controller = nil
local keyTap = nil
local mouseTap = nil
local currentFrame = nil

-- cached tab list, refreshed on app activate
local cachedTabs = nil

local visible = false

local function js(expression)
	if webview then
		webview:evaluateJavaScript(expression)
	end
end

local function dismiss()
	if not visible then
		return
	end
	visible = false
	keyTap:stop()
	mouseTap:stop()
	webview:hide()
	local app = hs.application.get(BUNDLE_ID)
	if app then
		app:activate()
	end
end

---------------------------------------------------------------------------
-- applescript
---------------------------------------------------------------------------

local function applescript(source)
	local ok, result = hs.osascript.applescript(source)
	return ok and result or nil
end

local function getEditorTabs()
	local output = applescript([[
    tell application "MarkEdit"
      set results to {}
      repeat with w in every window
        try
          -- skip non-document windows (panels, accessory views)
          set docName to name of document of w
          try
            set filePath to POSIX path of (file of document of w as text)
          on error
            set filePath to ""
          end try
          set end of results to (name of w & "\t" & id of w & "\t" & filePath as text)
        end try
      end repeat
      return results
    end tell
  ]])
	if not output then
		return {}
	end

	local tabs = {}
	for _, entry in ipairs(output) do
		local name, windowID, filePath = entry:match("^(.-)\t(.-)\t(.*)$")
		if name and name ~= "" then
			local directory = (filePath:match("^(.*)/[^/]*$") or ""):gsub("^" .. HOME, "~")
			table.insert(tabs, {
				name = name,
				windowID = tonumber(windowID),
				dir = directory,
			})
		end
	end
	return tabs
end

local function refreshCache()
	cachedTabs = getEditorTabs()
end

local function switchToTab(windowID)
	applescript(string.format('tell application "MarkEdit" to set index of window id %d to 1', windowID))
end

---------------------------------------------------------------------------
-- input dispatch
---------------------------------------------------------------------------

-- stylua: ignore start
local keyBindings = {
  dismiss = {
    { code = KEYS.escape },
  },
  select = {
    { code = KEYS.enter },
  },
  down = {
    { code = KEYS.down },
    { code = KEYS.n, ctrl = true },
    { code = KEYS.j, ctrl = true },
  },
  up = {
    { code = KEYS.up },
    { code = KEYS.p, ctrl = true },
    { code = KEYS.k, ctrl = true },
  },
  backspace = {
    { code = KEYS.backspace },
  },
  deleteWord = {
    { code = KEYS.backspace, alt = true },
  },
  selectAll = {
    { code = KEYS.a, cmd = true },
  },
  wordLeft = {
    { code = KEYS.left, alt = true },
  },
  wordRight = {
    { code = KEYS.right, alt = true },
  },
  lineStart = {
    { code = KEYS.left, cmd = true },
  },
  lineEnd = {
    { code = KEYS.right, cmd = true },
  },
}
-- stylua: ignore end

local keyActions = {
	dismiss = function()
		dismiss()
	end,
	select = function()
		js("selectItem()")
	end,
	down = function()
		js("moveDown()")
	end,
	up = function()
		js("moveUp()")
	end,
	backspace = function()
		js("backspace()")
	end,
	deleteWord = function()
		js("deleteWord()")
	end,
	selectAll = function()
		js("searchElement.select()")
	end,
	wordLeft = function()
		js("wordJump('left')")
	end,
	wordRight = function()
		js("wordJump('right')")
	end,
	lineStart = function()
		js("searchElement.setSelectionRange(0, 0)")
	end,
	lineEnd = function()
		js("searchElement.setSelectionRange(searchElement.value.length, searchElement.value.length)")
	end,
}

local keyLookup = {}
for action, bindings in pairs(keyBindings) do
	for _, binding in ipairs(bindings) do
		local lookupKey = binding.code
			.. ":" .. tostring(binding.ctrl or false)
			.. ":" .. tostring(binding.alt or false)
			.. ":" .. tostring(binding.cmd or false)
		keyLookup[lookupKey] = action
	end
end

local function onKeyEvent(event)
	if not visible then
		return false
	end
	local keyCode = event:getKeyCode()
	local flags = event:getFlags()
	local key = event:getCharacters()

	local lookupKey = keyCode
		.. ":" .. tostring(flags.ctrl or false)
		.. ":" .. tostring(flags.alt or false)
		.. ":" .. tostring(flags.cmd or false)
	local action = keyLookup[lookupKey]
	if action then
		keyActions[action]()
		return true
	end
	if flags.cmd and key and key:match("^[1-9]$") then
		js(string.format("jumpTo(%d)", tonumber(key) - 1))
		return true
	end
	if key and #key == 1 and not flags.cmd and not flags.ctrl then
		js(string.format("typeChar(%q)", key))
		return true
	end
	return false
end

local mouseActions = {
	[hs.eventtap.event.types.leftMouseDown] = function(x, y)
		js(string.format("handleClick(%d,%d)", x, y))
		return true
	end,
	[hs.eventtap.event.types.mouseMoved] = function(x, y)
		js(string.format("handleHover(%d,%d)", x, y))
		return false
	end,
	[hs.eventtap.event.types.scrollWheel] = function(x, y, event)
		local delta = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
		js(string.format("handleScroll(%d)", delta))
		return true
	end,
}

local function onMouseEvent(event)
	if not visible then
		return false
	end
	local position = hs.mouse.absolutePosition()
	local frame = currentFrame
	local inside = position.x >= frame.x
		and position.x <= frame.x + frame.w
		and position.y >= frame.y
		and position.y <= frame.y + frame.h

	if not inside then
		if event:getType() == hs.eventtap.event.types.leftMouseDown then
			dismiss()
		end
		return false
	end

	local handler = mouseActions[event:getType()]
	if not handler then
		return false
	end
	return handler(math.floor(position.x - frame.x), math.floor(position.y - frame.y), event)
end

local messageActions = {
	switch = function(message)
		dismiss()
		switchToTab(message.windowID)
	end,
	dismiss = function()
		dismiss()
	end,
}

local function onMessage(message)
	local decoded = message and message.body and hs.json.decode(message.body)
	if not decoded then
		return
	end
	local handler = messageActions[decoded.action]
	if handler then
		handler(decoded)
	end
end

---------------------------------------------------------------------------
-- html (self-contained: CSS + JS inline, theme injected via Lua)
---------------------------------------------------------------------------

-- stylua: ignore start
local function buildHTML(initialItems)
  local t = config.theme
  return ([[
<!DOCTYPE html>
<html>
<head>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { height: 100%%; }

  body {
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    font-size: ]] .. t.listFontSize .. [[;
    background: ]] .. t.bg .. [[;
    color: ]] .. t.fg .. [[;
    overflow: hidden;
    -webkit-user-select: none;
    display: flex;
    flex-direction: column;
    border-radius: ]] .. t.cornerRadius .. [[;
  }

  #search-bar {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    padding: 12px 16px;
    gap: 10px;
    border-bottom: 1px solid ]] .. t.separatorColor .. [[;
  }

  #search-icon {
    flex-shrink: 0;
    width: 16px;
    height: 16px;
    opacity: 0.4;
  }

  #search {
    flex: 1;
    font-size: ]] .. t.searchFontSize .. [[;
    font-family: inherit;
    background: transparent;
    border: none;
    color: #fff;
    outline: none;
  }

  #search::placeholder {
    color: ]] .. t.placeholderColor .. [[;
  }

  #list {
    flex: 1;
    overflow-y: auto;
    padding: 6px 0;
  }

  #list::-webkit-scrollbar {
    width: 4px;
  }

  #list::-webkit-scrollbar-thumb {
    background: ]] .. t.scrollbarColor .. [[;
    border-radius: 2px;
  }

  .item {
    padding: ]] .. t.itemPadding .. [[;
    cursor: default;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    line-height: 1.5;
    display: flex;
    align-items: baseline;
    gap: 10px;
    border-radius: ]] .. t.itemRadius .. [[;
    margin: ]] .. t.itemMargin .. [[;
  }

  .item.selected {
    background: ]] .. t.selectedBg .. [[;
  }

  .item-name {
    font-weight: ]] .. t.nameFontWeight .. [[;
    color: ]] .. t.nameColor .. [[;
    flex-shrink: 0;
  }

  .item-dir {
    font-size: ]] .. t.dirFontSize .. [[;
    color: ]] .. t.dirColor .. [[;
    overflow: hidden;
    text-overflow: ellipsis;
  }
</style>
</head>
<body>

<div id="search-bar">
  <svg id="search-icon" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2">
    <circle cx="8.5" cy="8.5" r="5.5" />
    <line x1="12.5" y1="12.5" x2="17" y2="17" />
  </svg>
  <input id="search" type="text" placeholder="Switch to Document..." />
</div>

<div id="list"></div>

<script>
  let items = %s;
  const listElement = document.getElementById("list");
  const searchElement = document.getElementById("search");
  let filtered = [...items];
  let selectedIndex = 0;

  function updateItems(newItems) {
    items = newItems;
    searchElement.value = "";
    filtered = [...items];
    selectedIndex = 0;
    render();
  }

  function render() {
    listElement.innerHTML = "";
    filtered.forEach((item, i) => {
      const row = document.createElement("div");
      row.className = "item" + (i === selectedIndex ? " selected" : "");

      const name = document.createElement("span");
      name.className = "item-name";
      name.textContent = item.name;
      row.appendChild(name);

      if (item.dir) {
        const directory = document.createElement("span");
        directory.className = "item-dir";
        directory.textContent = item.dir;
        row.appendChild(directory);
      }

      listElement.appendChild(row);
    });

    const selected = listElement.querySelector(".selected");
    if (selected) {
      selected.scrollIntoView({ block: "nearest" });
    }
  }

  function fuzzyScore(query, text) {
    const lower = text.toLowerCase();
    const q = query.toLowerCase();
    let queryIndex = 0;
    let score = 0;
    let consecutive = 0;
    let firstMatchPos = -1;
    for (let i = 0; i < lower.length && queryIndex < q.length; i++) {
      if (lower[i] === q[queryIndex]) {
        if (firstMatchPos < 0) {
          firstMatchPos = i;
        }
        consecutive++;
        // reward consecutive runs quadratically
        score += consecutive * consecutive;
        // reward matching at start of text or after separators
        if (i === 0 || "-_./  ".includes(lower[i - 1])) {
          score += 5;
        }
        queryIndex++;
      } else {
        consecutive = 0;
      }
    }
    if (queryIndex < q.length) {
      return -1;
    }
    // penalize late first match
    score -= firstMatchPos;
    return score;
  }

  function filter() {
    const query = searchElement.value;
    if (!query) {
      filtered = [...items];
      selectedIndex = 0;
      render();
      return;
    }
    filtered = items
      .map((item) => {
        const nameScore = fuzzyScore(query, item.name);
        const dirScore = fuzzyScore(query, item.dir);
        const best = Math.max(nameScore, dirScore);
        return { item, score: best };
      })
      .filter((entry) => entry.score >= 0)
      .sort((a, b) => b.score - a.score)
      .map((entry) => entry.item);
    selectedIndex = 0;
    render();
  }

  function post(object) {
    window.webkit.messageHandlers.hammerspoon.postMessage(JSON.stringify(object));
  }

  function selectItem() {
    if (filtered[selectedIndex]) {
      post({ action: "switch", windowID: filtered[selectedIndex].windowID });
    }
  }

  function moveDown() {
    selectedIndex = (selectedIndex + 1) %% filtered.length;
    render();
  }

  function moveUp() {
    selectedIndex = (selectedIndex - 1 + filtered.length) %% filtered.length;
    render();
  }

  function jumpTo(index) {
    if (index < filtered.length) {
      selectedIndex = index;
      selectItem();
    }
  }

  function typeChar(character) {
    const start = searchElement.selectionStart;
    const end_ = searchElement.selectionEnd;
    searchElement.value = searchElement.value.slice(0, start) + character + searchElement.value.slice(end_);
    searchElement.setSelectionRange(start + 1, start + 1);
    filter();
  }

  function backspace() {
    const start = searchElement.selectionStart;
    const end_ = searchElement.selectionEnd;
    if (start !== end_) {
      searchElement.value = searchElement.value.slice(0, start) + searchElement.value.slice(end_);
      searchElement.setSelectionRange(start, start);
    } else if (start > 0) {
      searchElement.value = searchElement.value.slice(0, start - 1) + searchElement.value.slice(start);
      searchElement.setSelectionRange(start - 1, start - 1);
    }
    filter();
  }

  function findWordBoundary(text, pos, direction) {
    if (direction === "left") {
      if (pos <= 0) return 0;
      let i = pos - 1;
      while (i > 0 && /\s/.test(text[i - 1])) i--;
      while (i > 0 && /\S/.test(text[i - 1])) i--;
      return i;
    } else {
      if (pos >= text.length) return text.length;
      let i = pos;
      while (i < text.length && /\s/.test(text[i])) i++;
      while (i < text.length && /\S/.test(text[i])) i++;
      return i;
    }
  }

  function deleteWord() {
    const pos = searchElement.selectionStart;
    const boundary = findWordBoundary(searchElement.value, pos, "left");
    searchElement.value = searchElement.value.slice(0, boundary) + searchElement.value.slice(pos);
    searchElement.setSelectionRange(boundary, boundary);
    filter();
  }

  function wordJump(direction) {
    const pos = searchElement.selectionStart;
    const boundary = findWordBoundary(searchElement.value, pos, direction);
    searchElement.setSelectionRange(boundary, boundary);
  }

  function findItem(x, y) {
    const element = document.elementFromPoint(x, y);
    if (!element) {
      return -1;
    }
    const item = element.closest(".item");
    if (!item) {
      return -1;
    }
    return Array.from(listElement.children).indexOf(item);
  }

  function handleClick(x, y) {
    const index = findItem(x, y);
    if (index >= 0) {
      selectedIndex = index;
      selectItem();
    }
  }

  function handleHover(x, y) {
    const index = findItem(x, y);
    if (index >= 0 && index !== selectedIndex) {
      selectedIndex = index;
      render();
    }
  }

  function handleScroll(delta) {
    listElement.scrollTop -= delta * 20;
  }

  searchElement.addEventListener("input", filter);
  render();
</script>

</body>
</html>
]]):format(initialItems or "[]")
end
-- stylua: ignore end

---------------------------------------------------------------------------
-- webview lifecycle (created once, reused)
---------------------------------------------------------------------------

-- returns true if the webview was just created (first use)
local function ensureWebview()
	if webview then
		return false
	end

	controller = hs.webview.usercontent.new("hammerspoon")
	controller:setCallback(onMessage)

	-- create offscreen with a default size; showSwitcher repositions it
	webview = hs.webview.new(hs.geometry.rect(0, 0, config.width, 200), { developerExtrasEnabled = false }, controller)
	webview:windowStyle(
		hs.webview.windowMasks.borderless | hs.webview.windowMasks.utility | hs.webview.windowMasks.nonactivating
	)
	webview:level(hs.drawing.windowLevels.floating)
	webview:allowTextEntry(true)
	webview:transparent(true)

	keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKeyEvent)
	mouseTap = hs.eventtap.new({
		hs.eventtap.event.types.leftMouseDown,
		hs.eventtap.event.types.scrollWheel,
		hs.eventtap.event.types.mouseMoved,
	}, onMouseEvent)

	return true
end

---------------------------------------------------------------------------
-- show
---------------------------------------------------------------------------

local function tabsToJS(tabs)
	local items = {}
	for _, tab in ipairs(tabs) do
		table.insert(
			items,
			string.format('{name:%q,windowID:%d,dir:%q}', tab.name, tab.windowID, tab.dir or "")
		)
	end
	return "[" .. table.concat(items, ",") .. "]"
end

local function showSwitcher()
	local front = hs.application.frontmostApplication()
	if not front or front:bundleID() ~= BUNDLE_ID then
		return false
	end
	if visible then
		dismiss()
		return true
	end

	-- use cached tabs if available, otherwise fetch now
	local tabs = cachedTabs or getEditorTabs()
	if #tabs == 0 then
		return true
	end

	local isNew = ensureWebview()

	-- reposition for current screen and tab count
	local screen = hs.screen.mainScreen():frame()
	local width = config.width
	local height = 48 + 12 + (math.min(#tabs, config.maxRows) * 34)
	local x = screen.x + (screen.w - width) / 2
	local y = screen.y + (screen.h * config.yOffset)

	webview:frame(hs.geometry.rect(x, y, width, height))
	currentFrame = {
		x = x,
		y = y,
		w = width,
		h = height,
	}

	-- first creation: bake tabs into HTML so they render immediately
	-- subsequent shows: push via JS (webview is already loaded)
	local tabData = tabsToJS(tabs)
	if isNew then
		webview:html(buildHTML(tabData))
	else
		js("updateItems(" .. tabData .. ")")
	end

	visible = true
	webview:show()
	webview:bringToFront()
	keyTap:start()
	mouseTap:start()

	-- refresh cache in the background so next invocation is fresh
	hs.timer.doAfter(0, refreshCache)

	return true
end

---------------------------------------------------------------------------
-- app watcher (pre-fetch tabs when MarkEdit activates)
---------------------------------------------------------------------------

local appWatcher = hs.application.watcher.new(function(appName, eventType, app)
	if eventType == hs.application.watcher.activated and app and app:bundleID() == BUNDLE_ID then
		refreshCache()
	end
	if eventType == hs.application.watcher.deactivated and app and app:bundleID() == BUNDLE_ID then
		cachedTabs = nil
	end
end)

appWatcher:start()

---------------------------------------------------------------------------
-- hotkey
---------------------------------------------------------------------------

hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, function()
	if not showSwitcher() then
		hs.eventtap.keyStroke(config.hotkey.mods, config.hotkey.key, 0, hs.application.frontmostApplication())
	end
end)

return { show = showSwitcher }
