local Main = script:FindFirstAncestor("MCPStudioPlugin")
local MockWebSocketService = require(Main.MockWebSocketService)
local Types = require(Main.Types)

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local StudioService = game:GetService("StudioService")

local URI = "http://localhost:44755"
local RECEIVE_ENDPOINT = "/request"
local SEND_ENDPOINT = "/response"

--------------------------------------------------------------------------------
-- CONTEXT DETECTION
-- Determine which DataModel we're running in: Edit, Server, or Client
--------------------------------------------------------------------------------
local function getContext(): string
	if RunService:IsEdit() then
		return "edit"
	elseif RunService:IsRunning() then
		if RunService:IsServer() and not RunService:IsClient() then
			return "server"
		elseif RunService:IsClient() and not RunService:IsServer() then
			return "client"
		else
			-- Both IsServer and IsClient are true - "Run" mode, treat as server
			return "server"
		end
	end
	return "unknown"
end

local CONTEXT = getContext()
print("[MCP Plugin] Running in context:", CONTEXT)

-- Client-side plugins can't make HTTP requests during play mode
-- Only proceed if we're in edit, server, or run mode
if CONTEXT == "client" then
	print("[MCP Plugin] Skipping client context (no HTTP allowed)")
	return
end

--------------------------------------------------------------------------------
-- LOGGING
--------------------------------------------------------------------------------
local ENABLE_LOGGING = true

local function log(...)
	if ENABLE_LOGGING then
		print("[MCP " .. CONTEXT .. "]", ...)
	end
end

--------------------------------------------------------------------------------
-- TOOLS
--------------------------------------------------------------------------------
local function fetchBuiltinTools()
	local tools = {}
	for _, tool in Main.Tools:GetChildren() do
		if tool:IsA("ModuleScript") then
			table.insert(tools, require(tool) :: Types.ToolFunction)
		end
	end
	return tools
end

local tools = fetchBuiltinTools()

--------------------------------------------------------------------------------
-- WEBSOCKET CLIENT
--------------------------------------------------------------------------------
local function connectWebSocket()
	local client = MockWebSocketService:CreateClient(URI)
	-- Include context in endpoint so server can route to correct DataModel
	client:SetReceiveEndpoint(RECEIVE_ENDPOINT .. "?context=" .. CONTEXT)
	client:SetSendEndpoint(SEND_ENDPOINT)

	client.Opened:Once(function()
		log("Connection opened")
	end)

	client.Closed:Once(function()
		log("Connection closed")
	end)

	client.MessageReceived:Connect(function(message)
		log("Message received")

		local body = HttpService:JSONDecode(message)
		assert(body and body.id and body.args, "Invalid message received")

		local id: string = body.id
		local responseSent = false
		local function sendResponseOnce(response: string)
			if not responseSent then
				log("Sending response:", string.sub(response, 1, 100))
				responseSent = true
				client:Send({
					id = id,
					response = response,
					context = CONTEXT, -- Include our context in response
				})
			end
		end

		local args: Types.ToolArgs = body.args

		-- Only use ChangeHistoryService in edit mode
		local recording = nil
		if CONTEXT == "edit" then
			recording = ChangeHistoryService:TryBeginRecording("StudioMCP")
		end

		for _, tool in tools do
			local success, response = pcall(tool, args)

			if success and response then
				sendResponseOnce(response)
			elseif not success then
				sendResponseOnce("Error handling request: " .. tostring(response))
			end
		end

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end

		sendResponseOnce("No tool found to handle request")
		log("Successfully handled request")
	end)

	return client
end

--------------------------------------------------------------------------------
-- UI (Edit mode only)
--------------------------------------------------------------------------------
local function getButtonImage()
	local ok, response = pcall(function()
		return StudioService:GetClassIcon("PackageLink").Image
	end)
	return ok and response or "rbxasset://textures/ui/GuiImagePlaceholder.png"
end

-- Auto-connect in all modes
local currentClient: MockWebSocketService.MockWebSocketClient? = nil

local function tryConnect()
	local success, result = pcall(function()
		return connectWebSocket()
	end)
	if success then
		currentClient = result
		print("[MCP Plugin] Connected in", CONTEXT, "mode - ready for prompts.")
	else
		warn("[MCP Plugin] Failed to connect:", result)
	end
end

tryConnect()

-- Toolbar available in all modes
local toolbar = plugin:CreateToolbar("MCP")
local toggleButton = toolbar:CreateButton("Toggle MCP", "Toggle connection to the server", getButtonImage())
toggleButton.ClickableWhenViewportHidden = true
toggleButton:SetActive(currentClient ~= nil)

toggleButton.Click:Connect(function()
	if not currentClient then
		tryConnect()
		toggleButton:SetActive(currentClient ~= nil)
	else
		currentClient:Close()
		currentClient = nil
		toggleButton:SetActive(false)
		print("[MCP Plugin] Disconnected.")
	end
end)
