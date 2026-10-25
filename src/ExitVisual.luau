--!strict
const Graph = require("./Graph")
const Edit = require("./Edit")
const Motion = require("./Motion")
const Clock = require("./Clock")

type VisualData = {
	Root : CanvasGroup?,
	Owner : Graph.Node<unknown>?,
	Timer : thread?,
	Finished : (() -> ())?,
	Closed : boolean,
}

const function Destroy(Self : VisualData)
	if Self.Closed then return end
	Self.Closed = true
	local Owner, Timer, Finished = Self.Owner, Self.Timer, Self.Finished
	Self.Owner, Self.Timer, Self.Root, Self.Finished = nil, nil, nil, nil
	if Timer then Clock.Cancel(Timer) end
	if Owner then Owner:Destroy() end
	if Finished then Finished() end
end

const function GetRoot(Self : VisualData) : CanvasGroup?
	return Self.Root
end

const Methods = table.freeze({ Destroy = Destroy, GetRoot = GetRoot })
const Metatable = table.freeze({ __index = Methods })
export type Visual = typeof(setmetatable({} :: VisualData, Metatable))

const function Capture(Root : Frame) : Frame?
	if not Root.Archivable then return nil end
	local Descendants = Root:GetDescendants()
	if #Descendants > 512 then return nil end
	for _, Child in Descendants do
		if not Child.Archivable then return nil end
	end
	local Snapshot = Root:Clone()
	local Passed, Failure = pcall(function()
		local Objects = Snapshot:GetDescendants()
		table.insert(Objects, Snapshot)
		for _, Object in Objects do
			if Object:IsA("LuaSourceContainer") then
				Object:Destroy()
			elseif Object:IsA("GuiObject") then
				Object.Active, Object.Selectable, Object.Interactable = false, false, false
				for _, Property in { "NextSelectionUp", "NextSelectionDown", "NextSelectionLeft", "NextSelectionRight", "SelectionImageObject" } do
					Object:ResetPropertyToDefault(Property)
				end
				if Object:IsA("TextBox") then Object.TextEditable = false end
			end
		end
	end)
	if not Passed then Snapshot:Destroy(); error(Failure, 0) end
	return Snapshot
end

const function Play(
	Owner : Graph.Node<unknown>, Snapshot : Frame, Host : Instance, Duration : number,
	IsCurrent : () -> boolean, Finished : () -> ()
) : Visual
	local Data : VisualData = { Root = nil, Owner = nil, Timer = nil, Finished = Finished, Closed = false }
	local Handle = setmetatable(Data, Metatable)
	local Passed, VisualOwner = pcall(function()
		return Graph.WithOwner(Owner, function()
			return Graph.Scope(function()
				Graph.Cleanup(function() Destroy(Data) end)
				local Target = Graph.State(0)
				Graph.Cleanup(Target)
				local Progress = Motion.Tween(Target, TweenInfo.new(Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
				local Wrapper = Edit.New("CanvasGroup", {
					Name = "InterfacerExitVisual", BackgroundTransparency = 1,
					Size = Snapshot.Size, Position = Snapshot.Position, AnchorPoint = Snapshot.AnchorPoint,
					Active = false, Selectable = false, Interactable = false, ZIndex = Snapshot.ZIndex,
					GroupTransparency = Progress,
				}) :: CanvasGroup
				Data.Root = Wrapper
				Graph.Cleanup(Wrapper.Destroying:Connect(function() Destroy(Data) end))
				Graph.Cleanup(Host.Destroying:Connect(function() Destroy(Data) end))
				Graph.Cleanup(Host.ChildAdded:Connect(function(Child)
					if Child:IsA("GuiObject") and Child.Name ~= "InterfacerExitVisual" then Destroy(Data) end
				end))
				Snapshot.Size, Snapshot.Position, Snapshot.AnchorPoint = UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Vector2.zero
				Snapshot.Parent = Wrapper
				Target:Set(1)
				Graph.Flush()
				if IsCurrent() and not Data.Closed then Edit.Edit(Wrapper, { Parent = Host }) end
				if IsCurrent() and not Data.Closed then
					Data.Timer = Clock.Delay(Duration, function()
						Data.Timer = nil
						Destroy(Data)
					end)
				end
			end)
		end)
	end)
	if not Passed then Destroy(Data); Snapshot:Destroy(); error(VisualOwner, 0) end
	if Data.Closed or not IsCurrent() then VisualOwner:Destroy(); Destroy(Data) else Data.Owner = VisualOwner end
	return Handle
end

return table.freeze({ Capture = Capture, Play = Play })
