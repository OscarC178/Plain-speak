-- Hotkeys capture the frontmost window; no clipboard copying is needed to read.
local M = {}
local base = 'http://127.0.0.1:8790'
local overlay, usercontent, dismissTap, ready, screenFrame
local tokenPath = os.getenv('HOME') .. '/.hammerspoon/plainspeak-token'
local function token()
  local f = io.open(tokenPath, 'r'); if not f then return nil end
  local t = f:read('*a'):match('^%s*(.-)%s*$'); f:close(); return t
end
local function selectedText(app)
  local ok, value = pcall(function()
    local ax = hs.axuielement.applicationElement(app)
    local focused = ax:attributeValue('AXFocusedUIElement')
    return focused and focused:attributeValue('AXSelectedText')
  end)
  return ok and type(value) == 'string' and value or nil
end
local function close()
  if dismissTap then dismissTap:stop(); dismissTap = nil end
  if overlay then local o = overlay; overlay = nil; o:delete() end
end
-- Escape closes the panel at any time and is consumed, so the app underneath
-- does not also act on it. Once the result is ready, a click outside the panel
-- closes it too; that click still reaches whatever was clicked.
local function watchDismiss()
  local types = hs.eventtap.event.types
  dismissTap = hs.eventtap.new({types.leftMouseDown, types.rightMouseDown, types.keyDown}, function(event)
    if not overlay then return false end
    if event:getType() == types.keyDown then
      if event:getKeyCode() ~= hs.keycodes.map.escape then return false end
      hs.timer.doAfter(0, close); return true
    end
    if not ready then return false end
    local p, f = event:location(), overlay:frame()
    if p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then hs.timer.doAfter(0, close) end
    return false
  end):start()
end
-- Fit the panel's height to its content, keeping it on screen.
local function resize(height)
  if not overlay or not height then return end
  local f = overlay:frame()
  local h = math.max(120, math.min(height, screenFrame.h - 16))
  overlay:frame({x=f.x, y=math.max(screenFrame.y + 8, math.min(f.y, screenFrame.y + screenFrame.h - h - 8)), w=f.w, h=h})
end
local width, gap = 460, 24
-- Open beside the pointer, where the reader is already looking, on the pointer's screen.
local function show(id, secret, pointer)
  close()
  ready = false
  usercontent = hs.webview.usercontent.new('plainspeak')
  usercontent:setCallback(function(message)
    local body = message.body
    if type(body) ~= 'table' then return end
    if body.action == 'close' then close()
    elseif body.action == 'ready' then ready = true
    elseif body.action == 'size' then resize(tonumber(body.text))
    elseif body.action == 'copy' and type(body.text) == 'string' then hs.pasteboard.setContents(body.text) end
  end)
  screenFrame = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local s, h = screenFrame, 200
  local x = pointer.x + gap
  if x + width > s.x + s.w - 8 then x = pointer.x - gap - width end
  x = math.max(s.x + 8, math.min(x, s.x + s.w - width - 8))
  local y = math.max(s.y + 8, math.min(pointer.y - 40, s.y + s.h - h - 8))
  overlay = hs.webview.new({x=x, y=y, w=width, h=h}, {developerExtrasEnabled=false}, usercontent)
  overlay:windowStyle({'borderless', 'nonactivating'}):transparent(true):shadow(true)
  overlay:level(hs.drawing.windowLevels.floating):allowTextEntry(true)
  overlay:url(base .. '/overlay#id=' .. id .. '&token=' .. secret):show()
  watchDismiss()
end
-- Keep high-resolution screenshots below the service's 8.1 MB JSON limit.
-- Rasterising at the requested size drops Retina representations while
-- preserving the whole window and its aspect ratio. Retry PNG encoding at
-- smaller dimensions for noisy images; never send an oversized payload.
local function encodeScreenshot(image)
  if not image then return nil end
  local size = image:size()
  if not size or size.w <= 0 or size.h <= 0 then return nil end
  local scale = math.min(1, 2560 / math.max(size.w, size.h))
  for attempt = 1, 10 do
    local target = {w=math.max(1, math.floor(size.w * scale)), h=math.max(1, math.floor(size.h * scale))}
    local bitmap = image:bitmapRepresentation(target)
    if not bitmap then return nil end
    local uri = bitmap:encodeAsURLString(false, 'PNG')
    local encoded = uri and uri:match('base64,(.+)')
    if not encoded then return nil end
    -- Leaves room for up to 40,000 characters of selected text and metadata.
    if #encoded <= 7500000 then return encoded end
    scale = scale * 0.8
  end
  return nil
end
local function capture(mode, context)
  -- Check without prompting: granting access may require a full app restart.
  if not hs.accessibilityState(false) then
    hs.alert.show('Hammerspoon Accessibility is not active. Enable it, then quit and reopen Hammerspoon.'); return
  end
  if mode ~= 'draft' and not hs.screenRecordingState(false) then
    hs.alert.show('Hammerspoon Screen Recording is not active. Enable it, then quit and reopen Hammerspoon.'); return
  end
  -- Capture before opening the overlay so the panel itself never becomes input.
  local window = hs.window.focusedWindow()
  if not window then hs.alert.show('No focused window'); return end
  local app = window:application()
  if app:name() == 'Hammerspoon' then hs.alert.show('Focus the message window first'); return end
  local secret = token()
  if not secret then hs.alert.show('Start Plainspeak first'); return end
  local text = selectedText(app)
  if mode == 'draft' and (not text or text:match('^%s*$')) then
    hs.alert.show('Select your own draft text first. This app may not expose selection to macOS.'); return
  end
  local payload = {app=app:name(),title=window:title() or '',mode=mode,text=text,context=context or false}
  local pointer = hs.mouse.absolutePosition()
  -- Drafts use selection only; reading captures the window with native Screen Recording permission.
  if mode ~= 'draft' then
    local image = window:snapshot()
    if not image then hs.alert.show('Capture failed. Enable Screen Recording for Hammerspoon.'); return end
    payload.image_base64 = encodeScreenshot(image)
    if not payload.image_base64 then hs.alert.show('Could not prepare screenshot within the capture limit'); return end
    -- Where the reader pointed, as fractions of the window, so Claude explains that
    -- message rather than everything visible. Omitted when the pointer is elsewhere.
    local f = window:frame()
    if f.w > 0 and f.h > 0 and pointer.x >= f.x and pointer.x <= f.x + f.w and pointer.y >= f.y and pointer.y <= f.y + f.h then
      local round = function(v) return math.floor(v * 100 + 0.5) / 100 end
      payload.pointer = {x=round((pointer.x - f.x) / f.w), y=round((pointer.y - f.y) / f.h)}
    end
  end
  hs.http.asyncPost(base .. '/capture', hs.json.encode(payload), {['Content-Type']='application/json',['Authorization']='Bearer '..secret}, function(code, body)
    local ok, data = pcall(hs.json.decode, body)
    if code ~= 202 or not ok then hs.alert.show(ok and data.error or 'Plainspeak unavailable. Check the session.'); return end
    show(data.request_id, secret, pointer)
  end)
end
M.read = function() capture('read',false) end
M.correct = function() capture('correct',false) end
M.draft = function() capture('draft',false) end
M.context = function() capture('read',true) end
M.search = M.context
M.close = close
hs.hotkey.bind({'ctrl','alt','cmd'},'R',M.read)
hs.hotkey.bind({'ctrl','alt','cmd'},'D',M.draft)
hs.hotkey.bind({'ctrl','alt','cmd'},'G',M.context)
-- Side-button routing. Keep references on M so Lua does not collect the taps.
-- IDs 3/4 are conventional back/front; calibration handles different drivers.
local mouseConfigPath = os.getenv('HOME') .. '/.hammerspoon/plainspeak-mouse.json'
local mouse = {front=4,back=3}
local f = io.open(mouseConfigPath, 'r')
if f then
  local ok, saved = pcall(hs.json.decode, f:read('*a')); f:close()
  if ok and type(saved) == 'table' then
    for _, key in ipairs({'front','back'}) do
      if type(saved[key]) == 'number' and saved[key] >= 3 and saved[key] <= 31 then mouse[key] = saved[key] end
    end
  end
end
if mouse.front == mouse.back then mouse = {front=4,back=3} end
local events = hs.eventtap.event.types
local buttonProperty = hs.eventtap.event.properties.mouseEventButtonNumber
local consumed = {}
M.mouseTap = hs.eventtap.new({events.otherMouseDown,events.otherMouseUp,events.otherMouseDragged}, function(event)
  local button = event:getProperty(buttonProperty)
  local kind = event:getType()
  -- Remember the down decision through release, even when modifiers change.
  if kind ~= events.otherMouseDown then
    local handled = consumed[button] == true
    if kind == events.otherMouseUp then consumed[button] = nil end
    return handled
  end
  if button ~= mouse.front and button ~= mouse.back then return false end
  local flags = event:getFlags()
  if flags.alt or flags.ctrl or flags.shift or flags.fn or (flags.cmd and button ~= mouse.back) then return false end
  consumed[button] = true
  local action = flags.cmd and M.search or button == mouse.front and M.correct or M.read
  hs.timer.doAfter(0, action) -- leave the input callback before capturing the screen
  return true -- no accidental browser Back/Forward
end):start()
function M.learnMouse(which)
  if M.learnTap then M.learnTap:stop() end
  if M.learnTimeout then M.learnTimeout:stop() end
  consumed = {}
  hs.alert.show('Press the ' .. which .. ' side button now')
  M.mouseTap:stop()
  local chosen
  M.learnTap = hs.eventtap.new({events.otherMouseDown,events.otherMouseUp}, function(event)
    local button = event:getProperty(buttonProperty)
    if button < 3 then return false end -- wheel/left/right are never rebound
    if event:getType() == events.otherMouseDown then chosen = button; return true end
    if chosen ~= button then return false end
    M.learnTap:stop()
    local other = which == 'front' and 'back' or 'front'
    if mouse[other] == chosen then mouse[other] = mouse[which] end
    mouse[which] = chosen
    local out = io.open(mouseConfigPath, 'w')
    if out then out:write(hs.json.encode(mouse)); out:close() end
    M.mouseTap:start()
    hs.alert.show('Plainspeak ' .. which .. ' button saved')
    return true
  end):start()
  -- Always restore ordinary handling if the user never presses a button.
  M.learnTimeout = hs.timer.doAfter(15,function()
    if M.learnTap and M.learnTap:isEnabled() then M.learnTap:stop(); M.mouseTap:start(); hs.alert.show('Button setup timed out') end
  end)
end
M.menu = hs.menubar.new():setTitle('PS'):setTooltip('Plainspeak mouse controls')
M.menu:setMenu({
  {title='Front: read and correct',fn=M.correct},
  {title='Back: read and simplify',fn=M.read},
  {title='Command + back: search notes and Drive',fn=M.search},
  {title='Set front mouse button…',fn=function() M.learnMouse('front') end},
  {title='Set back mouse button…',fn=function() M.learnMouse('back') end},
  {title='Close overlay',fn=M.close},
})
return M
