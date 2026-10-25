--!nonstrict

local IS_ROBLOX = game ~= nil

local Flux
local sert
if IS_ROBLOX then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	Flux = require(ReplicatedStorage:WaitForChild("Flux")) :: any
	sert = require(ReplicatedStorage:WaitForChild("sert")) :: any
else
	Flux = require("../src") :: any
	sert = require("./sert") :: any
end

sert.afterEach(function()
	Flux.Flags.Defaults = true
	Flux.Responsive.Viewport:Set(
		(if IS_ROBLOX then Vector2.new(1920, 1080) else { X = 1920, Y = 1080 }) :: any
	)
	if IS_ROBLOX and Flux.Clock.IsManual() then
		Flux.Clock.Manual(false)
	else
		Flux.Clock.Reset()
	end
end)

if IS_ROBLOX then

	local initSpec : ModuleScript? = nil
	for _, child in script:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		elseif child.Name == "Init.spec" then
			initSpec = child :: ModuleScript
		else
			require(child :: ModuleScript)
		end
	end
	if initSpec then
		require(initSpec)
	end
else
	require("./unit/Graph.spec")
	require("./unit/Clean.spec")
	require("./unit/Store.spec")
	require("./unit/Wrap.spec")
	require("./unit/For.spec")
	require("./unit/Selector.spec")
	require("./unit/Conditional.spec")
	require("./unit/Safe.spec")
	require("./unit/Context.spec")
	require("./unit/Async.spec")
	require("./unit/Find.spec")
	require("./unit/Edit.spec")
	require("./unit/Bind.spec")
	require("./unit/Motion.spec")
	require("./unit/Color.spec")
	require("./unit/Responsive.spec")
	require("./unit/Layout.spec")
	require("./unit/Interact.spec")
	require("./unit/Init.spec")
end

return {}
