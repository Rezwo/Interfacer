--!nonstrict

local IS_ROBLOX = game ~= nil

local sert
if IS_ROBLOX then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	sert = require(ReplicatedStorage:WaitForChild("sert")) :: any

	require(ReplicatedStorage:WaitForChild("Flux.unit"))
else
	sert = require("./sert") :: any
	require("./unit")
end

local filter = if IS_ROBLOX then nil else ... :: string?

return sert.run({ filter = filter })
