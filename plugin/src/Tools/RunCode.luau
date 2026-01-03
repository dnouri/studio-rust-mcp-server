local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")

local function runCodeWithOutput(command: string): string
	local output = ""

	local function getTableType(arg)
		local hasArray = false
		local hasTable = false
		for key, _value in arg do
			if typeof(key) == "number" then
				hasArray = true
			else
				hasTable = true
			end
			if hasArray and hasTable then
				break
			end
		end
		return hasArray, hasTable
	end

	local function serializeTable(arg): any
		if typeof(arg) == "table" then
			local _, isTable = getTableType(arg)

			local newArg = {}
			for key, value in arg do
				local newKey = serializeTable(key)
				newArg[if isTable then tostring(newKey) else newKey] = serializeTable(value)
			end
			return newArg
		elseif type(arg) == "userdata" then
			return tostring(arg) or "UNABLE_TO_SERIALIZE"
		end
		return arg
	end

	local function deepClone(t, cache)
		local clone = {}
		for key, value in t do
			local newKey = key
			if typeof(key) == "table" then
				if not cache[key] then
					cache[key] = deepClone(key, cache)
				end
				newKey = cache[key]
			end

			local newValue = value
			if typeof(value) == "table" then
				if not cache[value] then
					cache[value] = deepClone(value, cache)
				end
				newValue = cache[value]
			end

			clone[newKey] = newValue
		end
		return clone
	end

	local function toStrTable(t: { any }): { string }
		local clonedTable = deepClone(t, {})
		local strTable = table.create(#clonedTable)
		for i, arg in clonedTable do
			local serializedArg = serializeTable(arg)
			strTable[i] = if typeof(serializedArg) == "table"
				then HttpService:JSONEncode(serializedArg)
				else serializedArg
		end
		return strTable
	end

	local function addToOutput(header: string, ...)
		local strResults = toStrTable(table.pack(...))
		output ..= header .. " " .. table.concat(strResults, "\t") .. "\n"
	end

	local function executeCode()
		local chunk = loadstring(command) :: any
		local chunkfenv = getfenv(chunk)

		local oldPrint = print
		chunkfenv.print = function(...)
			oldPrint(...)
			addToOutput("[OUTPUT]", ...)
		end

		local oldWarn = warn
		chunkfenv.warn = function(...)
			oldWarn(...)
			addToOutput("[WARNING]", ...)
		end

		local oldError = error
		chunkfenv.error = function(...)
			oldError(...)
			addToOutput("[ERROR]", ...)
		end

		-- Find MCPBridge if it exists
		local ServerScriptService = game:GetService("ServerScriptService")
		local mcpBridge = nil
		for _, child in ServerScriptService:GetChildren() do
			if child:IsA("BindableFunction") and child.Name == "MCPBridge" then
				mcpBridge = child
				break
			end
		end

		-- Helper: create a proxy that forwards calls through the bridge
		local function createModuleProxy(modulePath: string)
			local propertyCache = {} -- Cache which keys are properties vs functions

			return setmetatable({}, {
				__index = function(_, key)
					-- Check cache first
					if propertyCache[key] == "property" then
						-- Known property: fetch and return value directly
						local result = mcpBridge:Invoke(modulePath, key)
						if typeof(result) == "table" and result.success then
							return result.result
						end
						return nil
					elseif propertyCache[key] == "function" then
						-- Known function: return callable
						return function(...)
							local result = mcpBridge:Invoke(modulePath, key, ...)
							if typeof(result) == "table" and result.success ~= nil then
								if not result.success then
									oldError("[MCP] " .. (result.error or "Unknown error"))
									return nil
								end
								return result.result
							end
							return result
						end
					end

					-- First access: probe bridge to determine type WITHOUT calling functions
					local probeResult = mcpBridge:Invoke("_getType", modulePath, key)
					if typeof(probeResult) == "table" and probeResult.success then
						if probeResult.isProperty then
							-- It's a property, cache type and fetch value
							propertyCache[key] = "property"
							local valueResult = mcpBridge:Invoke(modulePath, key)
							if typeof(valueResult) == "table" and valueResult.success then
								return valueResult.result
							end
							return nil
						else
							-- It's a function, cache and return callable
							propertyCache[key] = "function"
							return function(...)
								local result = mcpBridge:Invoke(modulePath, key, ...)
								if typeof(result) == "table" and result.success ~= nil then
									if not result.success then
										oldError("[MCP] " .. (result.error or "Unknown error"))
										return nil
									end
									return result.result
								end
								return result
							end
						end
					elseif typeof(probeResult) == "table" and not probeResult.success then
						oldError("[MCP] " .. (probeResult.error or "Unknown error"))
					end
					return nil
				end,
			})
		end

		-- Override require() to transparently use MCPBridge for game modules
		local oldRequire = require
		chunkfenv.require = function(module)
			if typeof(module) == "Instance" and mcpBridge then
				local path = module:GetFullName()
				-- Game modules go through the bridge
				if
					path:match("^ReplicatedStorage")
					or path:match("^ServerScriptService")
					or path:match("^ServerStorage")
				then
					return createModuleProxy(path)
				end
			end
			-- Non-game modules or no bridge: use regular require
			return oldRequire(module)
		end

		local results = table.pack(chunk())
		if #results > 0 then
			addToOutput("[RETURNED RESULTS]", table.unpack(results))
		end

		return results
	end

	local ok, errorMessage = pcall(executeCode)
	if not ok then
		addToOutput("[UNEXPECTED ERROR]", errorMessage)
	end

	return output
end

local function handleRunCode(args: Types.ToolArgs): string?
	if not args["RunCode"] then
		return nil
	end

	local runCodeArgs: Types.RunCodeArgs = args["RunCode"]
	if type(runCodeArgs.command) ~= "string" then
		error("Missing command in RunCode")
	end

	return runCodeWithOutput(runCodeArgs.command)
end

return handleRunCode :: Types.ToolFunction
