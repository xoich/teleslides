#!/usr/bin/env lua
--[[
  A server that responds with an infinite server-side-events format.
  https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#Event_stream_format

  Usage: lua examples/server_sent_events.lua [<port>]
]]

local port = arg[1] or 0 -- 0 means pick one at random

local cqueues = require "cqueues"
local http_server = require "http.server"
local http_headers = require "http.headers"
local lustache = require "lustache"
local condition = require "cqueues.condition"

local slides = {}
local slidesdata = {}
slideindex = 1

local changecond = condition.new()

do
  local ls = io.popen("ls slides")
  for s in ls:lines() do
    local n = string.match(s, "%d+")
    local path = "slides/"..s
    local f = assert(io.open(path))
    local data = f:read("a")
    f:close()
    table.insert(slides, {path = path, n = n})
    slidesdata["/"..path] = data
  end
  ls:close()
end
local template
do
  local f = io.open("index-template.html")
  template = f:read("a")
  f:close()
end
local page = lustache:render(template, {slides = slides})
local cq = cqueues.new()

local myserver =
  assert(http_server.listen {
           host = "localhost";
           port = port;
           cq = cq;
           onstream = function(myserver, stream) -- luacheck: ignore 212
             -- Read in headers
             local req_headers = assert(stream:get_headers())
             local req_method = req_headers:get ":method"

             -- Build response headers
             local res_headers = http_headers.new()
             if req_method ~= "GET" and req_method ~= "HEAD" then
               res_headers:upsert(":status", "405")
               assert(stream:write_headers(res_headers, true))
               return
             end
             if req_headers:get ":path" == "/" then
               res_headers:append(":status", "200")
               res_headers:append("content-type", "text/html")
               -- Send headers to client; end the stream immediately if this was a HEAD request
               assert(stream:write_headers(res_headers, req_method == "HEAD"))
               if req_method ~= "HEAD" then
                 assert(stream:write_chunk(page, true))
               end
             elseif req_headers:get ":path" == "/next" then
               res_headers:append(":status", "200")
               if slideindex < #slides then
                 slideindex = slideindex + 1
                 changecond:signal()
               end
               assert(stream:write_headers(res_headers, true))
             elseif req_headers:get ":path" == "/prev" then
               res_headers:append(":status", "200")
               if slideindex > 1 then
                 slideindex = slideindex - 1
                 changecond:signal()
               end
               assert(stream:write_headers(res_headers, true))
             elseif string.match(req_headers:get ":path", "/slides/fpres%-%d%d%.png") then
               local data = slidesdata[req_headers:get ":path"]
               if not data then
                 res_headers:append(":status", "404")
                 assert(stream:write_headers(res_headers, true))
               else
                 res_headers:append(":status", "200")
                 res_headers:append("content-type", "image/png")
                 assert(stream:write_headers(res_headers, req_method == "HEAD"))
                 if req_method ~= "HEAD" then
                   assert(stream:write_chunk(data, true))
                 end
               end
             elseif req_headers:get ":path" == "/event-stream" then
               res_headers:append(":status", "200")
               res_headers:append("content-type", "text/event-stream")
               -- Send headers to client; end the stream immediately if this was a HEAD request
               assert(stream:write_headers(res_headers, req_method == "HEAD"))
               if req_method ~= "HEAD" then
                 -- Start a loop that sends the current time to the client each second
                 local msg = string.format("data: slide-%02d\n\n", slideindex)
                 assert(stream:write_chunk(msg, false))
                 while true do
                   cqueues.poll(changecond, 1)
                   local msg = string.format("data: slide-%02d\n\n", slideindex)
                   assert(stream:write_chunk(msg, false))
                 end
               end
             else
               res_headers:append(":status", "404")
               assert(stream:write_headers(res_headers, true))
             end
           end;
           onerror = function(myserver, context, op, err, errno) -- luacheck: ignore 212
             local msg = op .. " on " .. tostring(context) .. " failed"
             if err then
               msg = msg .. ": " .. tostring(err)
             end
             assert(io.stderr:write(msg, "\n"))
           end;
  })

-- Manually call :listen() so that we are bound before calling :localname()
assert(myserver:listen())
do
  local bound_port = select(3, myserver:localname())
  assert(io.stderr:write(string.format("Now listening on port %d\nOpen http://localhost:%d/ in your browser\n", bound_port, bound_port)))
end

local nn = false
local inputco = coroutine.create(function()
    while true do
      cqueues.poll({pollfd = 0, events = function() return "r" end})
      local cmd = io.read("l")
      if cmd == nil then
        if slideindex > 1 then slideindex = slideindex - 1 end
      elseif slideindex < #slides then
        slideindex = slideindex + 1
      end
      changecond:signal()
    end
end)
cq:attach(inputco)

-- Start the main server loop
assert(myserver:loop())
