--!nonstrict
--[[
	Signal — minimal pure-Luau signal.

	Deliberately not a BindableEvent: those serialise their arguments, which
	would strip the SendResult tables handed to `notif.Sent` / `notif.Failed`
	of their identity and drop non-serialisable fields.

	Handlers are dispatched via task.spawn, so a yielding or erroring handler
	cannot stall the dispatcher worker.
]]

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self._connected then
		return
	end
	self._connected = false

	local handlers = self._signal._handlers
	local index = table.find(handlers, self)
	if index then
		table.remove(handlers, index)
	end
end

Connection.Destroy = Connection.Disconnect

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(handler)
	if type(handler) ~= "function" then
		error("Signal:Connect expects a function, got " .. typeof(handler), 2)
	end

	local connection = setmetatable({
		_signal = self,
		_handler = handler,
		_connected = true,
	}, Connection)

	table.insert(self._handlers, connection)
	return connection
end

function Signal:Once(handler)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Iterate a snapshot: a handler may disconnect itself (or others) mid-fire.
	for _, connection in table.clone(self._handlers) do
		if connection._connected then
			task.spawn(connection._handler, ...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	for _, connection in self._handlers do
		connection._connected = false
	end
	table.clear(self._handlers)
end

Signal.Destroy = Signal.DisconnectAll

return Signal
