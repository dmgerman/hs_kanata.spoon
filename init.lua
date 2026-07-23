--- Kanata keyboard monitor spoon.
-- Connects to Kanata TCP server and displays current layer on screen.
local obj = {}
obj.__index = obj
obj.name = "kanata"


-- Logger
local logger = hs.logger.new("Kanata")

obj.host = "127.0.0.1"
obj.port = 12340
obj.client = nil
obj.current_layer = "base"
obj.canvases = {}

-- Canvas configuration
obj.show_notification = true  -- Show layer name on screen
obj.canvas_width = 400
obj.canvas_height = 200
obj.text_size = 120
obj.text_color = {red = 1, green = 0, blue = 0}
obj.x_pos = 0.5   -- 0.0 = left, 0.5 = center, 1.0 = right
obj.y_pos = 0.75  -- 0.0 = top, 0.5 = center, 1.0 = bottom

-- Message callbacks
obj.callbacks = {}  -- {MessageType = function(msg) ... end}

--- Parse Kanata message format: {"LayerChange":{"new":"base"}}
-- Returns message type and payload as a clean table structure.
--
-- @param message (string): Raw JSON-ish message from Kanata
-- @return (boolean): Success flag
-- @return (table): {type = "LayerChange", new = "base", ...}, or nil if parse failed
-- @return (string): Message type, or nil if parse failed
local function parse_kanata_message(message)
  if not message or message == "" then return false, nil, nil end

  local success, decoded = pcall(function() return hs.json.decode(message) end)
  if success and decoded and type(decoded) == "table" then
    for msg_type, payload in pairs(decoded) do
      if type(payload) == "table" then
        local result = {type = msg_type}
        for k, v in pairs(payload) do
          result[k] = v
        end
        return true, result, msg_type
      end
    end
  end

  return false, nil, nil
end

--- Update layer display on all screens.
-- Creates/updates canvases for each connected screen, shows/hides based on layer.
--
-- @param layer (string): Layer name to display, or "base" to hide
function obj:update_layer_display(layer)
  if not self.show_notification then return end

  self.current_layer = layer

  local screens = hs.screen.allScreens()

  if layer == "base" then
    for screen_id, canvas in pairs(self.canvases) do
      if canvas:isShowing() then
        canvas:hide()
      end
    end
    return
  end

  -- Create/update canvases for each screen
  for i, screen in ipairs(screens) do
    local frame = screen:frame()

    -- Calculate canvas position based on x_pos and y_pos (0-1 scale)
    local canvas_frame = {
      x = frame.x + frame.w * self.x_pos - self.canvas_width / 2,
      y = frame.y + frame.h * self.y_pos - self.canvas_height / 2,
      w = self.canvas_width,
      h = self.canvas_height
    }

    local screen_id = tostring(screen:id())
    local canvas = self.canvases[screen_id]

    if not canvas then
      canvas = hs.canvas.new(canvas_frame)
      canvas[1] = {
        type = "text",
        text = layer,
        textColor = self.text_color,
        textSize = self.text_size,
        textAlignment = "center"
      }
      self.canvases[screen_id] = canvas
    else
      canvas:frame(canvas_frame)
      canvas[1].text = layer
    end

    if not canvas:isShowing() then
      canvas:show()
    end
  end
end

--- Process parsed Kanata message.
-- Calls user-provided callbacks and handles built-in notifications.
--
-- @param msg (table): Parsed message {type = "LayerChange", new = "base", ...}
-- @param msg_type (string): Message type ("LayerChange", etc.)
function obj:kanata_callback(msg, msg_type)
  -- Call user-provided callback if registered
  if self.callbacks[msg_type] then
    pcall(function() self.callbacks[msg_type](msg) end)
  end

  -- Handle built-in LayerChange notification
  if msg_type == "LayerChange" then
    self:update_layer_display(msg.new or "unknown")
  end
end

--- Configure canvas appearance and position.
--
-- @param config (table): Configuration table with optional keys:
--   - canvas_width (number): Canvas width in pixels (default: 400)
--   - canvas_height (number): Canvas height in pixels (default: 200)
--   - text_size (number): Text size in points (default: 120)
--   - text_color (table): Color table {red, green, blue} (default: {red=1, green=0, blue=0})
--   - x_pos (number): Horizontal position 0-1 (default: 0.5 = center)
--   - y_pos (number): Vertical position 0-1 (default: 0.5 = center)
--
-- @return (self): Spoon object for chaining
function obj:configure(config)
  if not config then return self end

  if config.canvas_width then self.canvas_width = config.canvas_width end
  if config.canvas_height then self.canvas_height = config.canvas_height end
  if config.text_size then self.text_size = config.text_size end
  if config.text_color then self.text_color = config.text_color end
  if config.x_pos then self.x_pos = config.x_pos end
  if config.y_pos then self.y_pos = config.y_pos end

  return self
end

--- Report current connection status.
-- Shows an alert with a one-line summary and logs details to the console.
--
-- @return (self): Spoon object for chaining
function obj:status()
  local connected = false
  if self.client then
    local ok, result = pcall(function() return self.client:connected() end)
    connected = ok and result or false
  end

  local state = connected and "connected" or "disconnected"
  local endpoint = self.host .. ":" .. self.port
  local canvas_count = 0
  for _ in pairs(self.canvases) do canvas_count = canvas_count + 1 end
  local callback_count = 0
  for _ in pairs(self.callbacks) do callback_count = callback_count + 1 end

  local summary = string.format("Kanata: %s (%s) layer=%s", state, endpoint, self.current_layer)
  hs.alert.show(summary)

  logger.i(summary)
  logger.i(string.format("  client=%s canvases=%d callbacks=%d show_notification=%s",
    tostring(self.client), canvas_count, callback_count, tostring(self.show_notification)))

  return self
end

--- Close the socket connection.
-- Safely disconnects from Kanata server.
function obj:close()
  if self.client then
    pcall(function() self.client:close() end)
    self.client = nil
  end
end

--- Restart the connection to Kanata.
-- Closes existing connection and reconnects to server.
--
-- @return (self): Spoon object for chaining
function obj:restart()
  self:close()
  self:init()
  return self
end

--- Handler for incoming socket data.
-- Processes Kanata messages and queues next read operation.
--
-- @param self: Spoon object (via closure)
-- @param data (string): Raw data received from socket
-- @param tag: Socket tag (unused)
local function handle_socket_data(obj, data, tag)
  if type(data) == "string" and data ~= "" then
    logger.d("Received: " .. data)
    local success, msg, msg_type = parse_kanata_message(data)
    if success then
      obj:kanata_callback(msg, msg_type)
    end
    -- Queue next read to receive subsequent data
    obj.client:read("\n", 1)
  elseif data == nil then
    -- nil indicates EOF or connection closed by remote
    logger.i("Connection closed")
  end
end

--- Initialize and start monitoring Kanata.
--
-- @param callbacks (table): Message type callbacks {MessageType = function(msg) ... end}
--
-- @return (self): Spoon object for chaining
function obj:init(callbacks)
  if callbacks then
    self.callbacks = callbacks
  end

  local socket = require("hs.socket")
  self.client = socket.new()

  -- hs.socket is asynchronous: setCallback + read() queues a read operation,
  -- callback fires when delimiter is encountered. Must queue next read inside
  -- callback to keep the stream flowing.
  self.client:setCallback(function(data, tag)
    handle_socket_data(self, data, tag)
  end)

  if not pcall(function() self.client:connect(self.host, self.port) end) then
    hs.alert.show("Kanata: Failed to connect to " .. self.host .. ":" .. self.port)
    return self
  end

  -- Initiate first read operation; callback will handle all subsequent reads
  pcall(function() self.client:read("\n", 1) end)

  return self
end

obj.publicCommands = {
  { fn = function() obj:restart() end,       desc = "restart - restart the client" },
  { fn = function() obj:close() end,         desc = "close - close the client" },
  { fn = function() obj:init() end,          desc = "init - start the client" },
  { fn = function() obj:status() end,        desc = "status - show connection status" },


}


return obj
