--!strict
const Interfacer = require(game:GetService("ReplicatedStorage").InterfacerVirtual)
const RunService = game:GetService("RunService")

return function()
	local Checks = 0
	local function Check(Condition : boolean, Description : string)
		assert(Condition, Description)
		Checks += 1
	end
	local Host : ScreenGui
	local Viewport : ScrollingFrame
	local Collection : Interfacer.VirtualCollection
	local Player = assert(game:GetService("Players").LocalPlayer)
	local Owner = Interfacer.Scope(function()
		Host = Interfacer.New("ScreenGui")({ Parent = Player:WaitForChild("PlayerGui") })
		Viewport = Interfacer.New("ScrollingFrame")({ Size = UDim2.fromOffset(300, 150), Parent = Host })
		local Items = table.create(100, 0)
		for Index = 1, #Items do
			Items[Index] = Index
		end
		Collection = Interfacer.VirtualCollection(Viewport, {
			Items = Items,
			GetKey = function(Value : number)
				return Value
			end,
			Layout = { Kind = "List", ItemHeight = 40 },
			Render = function()
				return Instance.new("TextLabel")
			end,
		})
	end)
	local function WaitFrames(Count : number)
		for _ = 1, Count do
			RunService.Heartbeat:Wait()
		end
	end
	local Passed, Failure = pcall(function()
		WaitFrames(6)
		Check(Collection:GetStatistics().MountedRows > 0, "list mounts while visible")
		Host.Enabled = false
		WaitFrames(6)
		Check(Collection:GetStatistics().MountedRows == 0, "hide releases all rows")
		local Reconciliations = Collection:GetStatistics().Reconciliations
		local OriginalOffset = Viewport.CanvasPosition.Y
		for Index = 1, 8 do
			Viewport.CanvasPosition = Vector2.new(0, 100 + Index * 80)
			WaitFrames(2)
		end
		Check(Viewport.CanvasPosition.Y ~= OriginalOffset, "native canvas really changed while hidden")
		local Statistics = Collection:GetStatistics()
		Check(Statistics.MountedRows == 0, "hidden scrolling does not remount rows")
		Check(Statistics.Reconciliations == Reconciliations,
			`hidden scrolling must stay idle: {Statistics.Reconciliations - Reconciliations} unexpected reconciliations`)
		Host.Enabled = true
		WaitFrames(8)
		Check(Collection:GetStatistics().MountedRows > 0, "show restores the list after hidden scrolling")
	end)
	Interfacer.Dispose(Owner)
	if not Passed then
		error(Failure, 0)
	end
	return Checks
end
