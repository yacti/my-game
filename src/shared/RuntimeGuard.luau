local RuntimeGuard = {}

local function formatError(label, err)
	local prefix = "[" .. tostring(label or "RuntimeGuard") .. "] "
	local message = prefix .. tostring(err)
	if type(debug) == "table" and type(debug.traceback) == "function" then
		return debug.traceback(message, 2)
	end
	return message
end

function RuntimeGuard.Try(label, callback, ...)
	local args = table.pack(...)
	return xpcall(function()
		return callback(table.unpack(args, 1, args.n))
	end, function(err)
		return formatError(label, err)
	end)
end

function RuntimeGuard.Run(label, callback, ...)
	local results = table.pack(RuntimeGuard.Try(label, callback, ...))
	if results[1] ~= true then
		warn(results[2])
	end
	return table.unpack(results, 1, results.n)
end

function RuntimeGuard.Connect(signal, label, callback)
	local ok, connection = RuntimeGuard.Run("connect " .. tostring(label), function()
		return signal:Connect(function(...)
			RuntimeGuard.Run(label, callback, ...)
		end)
	end)
	return ok and connection or nil
end

function RuntimeGuard.Spawn(label, callback, ...)
	local args = table.pack(...)
	task.spawn(function()
		RuntimeGuard.Run(label, callback, table.unpack(args, 1, args.n))
	end)
end

return RuntimeGuard
