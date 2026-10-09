-- Execute the production helper with image API doubles; no desktop capture,
-- token access, HTTP request or Claude notification occurs in this test.
local path = arg and arg[1] or 'hammerspoon/plainspeak.lua'
local file = assert(io.open(path)); local source = file:read('*a'); file:close()
local helper = source:match('(local function encodeScreenshot.-)\nlocal function capture')
local encode
if helper then encode = assert(load(helper .. '\nreturn encodeScreenshot'))()
else encode = function(image) local uri = image:encodeAsURLString(false); return uri:match('base64,(.+)') end end
local function image(w, h, cannotShrink)
  return {
    size = function() return {w=w, h=h} end,
    bitmapRepresentation = function(_, target) return image(target.w, target.h, cannotShrink) end,
    encodeAsURLString = function() return 'data:image/png;base64,' .. string.rep('A', cannotShrink and 8100001 or math.floor(w*h*4)) end
  }
end
local encoded = encode(image(3440, 1440))
assert(encoded and #encoded <= 7500000, 'large capture must shrink below the payload budget')
assert(encode(image(800, 600)) == string.rep('A', 800*600*4), 'small capture must preserve its dimensions')
assert(encode(nil) == nil, 'failed capture must not be encoded')
assert(encode(image(0, 10)) == nil, 'invalid dimensions must not divide by zero')
assert(encode(image(3440, 1440, true)) == nil, 'uncompressible image must fail rather than send too much')
print('PASS: large and small captures, failure, invalid dimensions, retry limit')
