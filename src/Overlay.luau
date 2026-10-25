--!strict
const Graph = require("./Graph")
const Edit = require("./Edit")

type PortalData = {
	Root : Frame?,
	Owner : Graph.Node<unknown>?,
	Closed : boolean,
	Connections : { RBXScriptConnection },
	OnClosed : (() -> ())?,
}

const function GetPortalRoot(Self : PortalData) : Frame?
	return Self.Root
end

const function DestroyPortal(Self : PortalData)
	if Self.Closed then
		return
	end
	Self.Closed = true
	local Owner, OnClosed = Self.Owner, Self.OnClosed
	Self.Owner, Self.Root, Self.OnClosed = nil, nil, nil
	local Connections = Self.Connections
	Self.Connections = {}
	for _, Connection in Connections do
		Connection:Disconnect()
	end
	if Owner then
		Owner:Destroy()
	end
	if OnClosed then
		OnClosed()
	end
end

const PortalMethods = table.freeze({
	GetRoot = GetPortalRoot,
	Destroy = DestroyPortal,
})
const PortalMetatable = table.freeze({ __index = PortalMethods })
export type Portal = typeof(setmetatable({} :: PortalData, PortalMetatable))
export type Modal = Portal

const function MountPortal(
	Host : Instance,
	Render : (Root : Frame) -> (),
	OnClosed : (() -> ())?,
	Cancellation : { Closed : boolean }?
) : Portal
	assert(Graph.GetOwner() ~= nil, "Portal requires a declaring reactive owner")
	assert(Host:IsA("GuiObject") or Host:IsA("LayerCollector"), "Portal requires a GUI host")
	local Data : PortalData =
		{ Root = nil, Owner = nil, Closed = false, Connections = {}, OnClosed = OnClosed }
	local Handle = setmetatable(Data, PortalMetatable)
	local Passed, Owner = pcall(function()
		return Graph.Scope(function()
			Graph.Cleanup(function()
				DestroyPortal(Data)
			end)
			table.insert(
				Data.Connections,
				Host.Destroying:Connect(function()
					DestroyPortal(Data)
				end)
			)
			local Root = Edit.New("Frame", {
				Name = "InterfacerPortal",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}) :: Frame
			Data.Root = Root
			table.insert(
				Data.Connections,
				Root.Destroying:Connect(function()
					DestroyPortal(Data)
				end)
			)
			Render(Root)
			if Cancellation and Cancellation.Closed then
				DestroyPortal(Data)
			end
			if not Data.Closed then
				Graph.Flush()
				if Cancellation and Cancellation.Closed then
					DestroyPortal(Data)
				elseif not Data.Closed then
					Edit.Edit(Root, { Parent = Host })
				end
			end
		end)
	end)
	if not Passed then
		DestroyPortal(Data)
		error(Owner, 0)
	end
	if Data.Closed then
		Owner:Destroy()
	else
		Data.Owner = Owner
	end
	return Handle
end

const function CreatePortal(Host : Instance, Render : (Root : Frame) -> ()) : Portal
	return MountPortal(Host, Render, nil, nil)
end

type ModalEntry = {
	Stack : StackData?,
	Portal : Portal?,
	Root : Frame?,
	InitialFocus : GuiObject?,
	LastFocus : GuiObject?,
	Closed : boolean,
}

type StackData = {
	Host : ScreenGui?,
	Entries : { ModalEntry },
	OriginalFocus : GuiObject?,
	GuiService : GuiService?,
	Connections : { RBXScriptConnection },
	Closed : boolean,
	ChangingFocus : boolean,
}

local ActiveStack : StackData? = nil

const function CanSelect(Target : GuiObject?) : boolean
	if not Target or not Target.Selectable or not Target.Parent then
		return false
	end
	local Position, Size = Target.AbsolutePosition, Target.AbsoluteSize
	local MinimumHorizontal, MinimumVertical = Position.X, Position.Y
	local MaximumHorizontal, MaximumVertical = Position.X + Size.X, Position.Y + Size.Y
	if MaximumHorizontal <= MinimumHorizontal or MaximumVertical <= MinimumVertical then
		return false
	end
	local Ancestor : Instance? = Target
	while Ancestor do
		if Ancestor:IsA("GuiObject") and not Ancestor.Visible then
			return false
		elseif Ancestor:IsA("ScreenGui") and not Ancestor.Enabled then
			return false
		elseif Ancestor:IsA("PlayerGui") then
			return true
		end
		if
			Ancestor:IsA("ScreenGui") or (Ancestor:IsA("GuiObject") and Ancestor.ClipsDescendants)
		then
			local BoundaryPosition, BoundarySize = Ancestor.AbsolutePosition, Ancestor.AbsoluteSize
			MinimumHorizontal = math.max(MinimumHorizontal, BoundaryPosition.X)
			MinimumVertical = math.max(MinimumVertical, BoundaryPosition.Y)
			MaximumHorizontal = math.min(MaximumHorizontal, BoundaryPosition.X + BoundarySize.X)
			MaximumVertical = math.min(MaximumVertical, BoundaryPosition.Y + BoundarySize.Y)
			if MaximumHorizontal <= MinimumHorizontal or MaximumVertical <= MinimumVertical then
				return false
			end
		end
		Ancestor = Ancestor.Parent
	end
	return false
end

const function BelongsTo(Target : GuiObject?, Root : Frame?) : boolean
	return Target ~= nil and Root ~= nil and (Target == Root or Target:IsDescendantOf(Root))
end

const function FindFocus(Entry : ModalEntry) : GuiObject?
	local Root = Entry.Root
	if not Root or not Root.Parent then
		return nil
	end
	local Previous = Entry.LastFocus
	if Previous and CanSelect(Previous) and BelongsTo(Previous, Root) then
		return Previous
	end
	local Initial = Entry.InitialFocus
	if Initial and CanSelect(Initial) and BelongsTo(Initial, Root) then
		return Initial
	end
	local Best : GuiObject? = nil
	for _, Child in Root:GetDescendants() do
		if
			Child:IsA("GuiObject")
			and CanSelect(Child)
			and (not Best or Child.SelectionOrder < Best.SelectionOrder)
		then
			Best = Child
		end
	end
	return Best or (if CanSelect(Root) then Root else nil)
end

const function RefreshFocus(Self : StackData)
	local Service = Self.GuiService
	if Self.Closed or Self.ChangingFocus or not Service then
		return
	end
	local Top = Self.Entries[#Self.Entries]
	if not Top then
		return
	end
	local Selected = Service.SelectedObject
	if CanSelect(Selected) and BelongsTo(Selected, Top.Root) then
		Top.LastFocus = Selected
		return
	end
	local Target = FindFocus(Top)
	if Selected ~= Target then
		Self.ChangingFocus = true
		Service.SelectedObject = Target
		Self.ChangingFocus = false
	end
	if not Top.Closed then
		Top.LastFocus = Target
	end
end

const function RestoreFocus(Self : StackData)
	local Service, Previous = Self.GuiService, Self.OriginalFocus
	Self.OriginalFocus = nil
	if Service then
		Self.ChangingFocus = true
		Service.SelectedObject = if CanSelect(Previous) then Previous else nil
		Self.ChangingFocus = false
	end
end

const function RemoveEntry(Entry : ModalEntry)
	local Stack = Entry.Stack
	Entry.Closed = true
	Entry.Stack, Entry.Portal, Entry.Root, Entry.InitialFocus, Entry.LastFocus =
		nil, nil, nil, nil, nil
	if not Stack then
		return
	end
	local Index = table.find(Stack.Entries, Entry)
	if Index then
		table.remove(Stack.Entries, Index)
	end
	if Stack.Closed then
		return
	end
	for Layer, Remaining in table.clone(Stack.Entries) do
		local Root = Remaining.Root
		if not Remaining.Closed and Root then
			Root.ZIndex = Layer
		end
	end
	if #Stack.Entries == 0 then
		RestoreFocus(Stack)
	else
		RefreshFocus(Stack)
	end
end

const function CloseEntry(Entry : ModalEntry)
	if Entry.Portal then
		Entry.Portal:Destroy()
	else
		Entry.Closed = true
	end
end

const function OpenModal(
	Self : StackData,
	Render : (Layer : Frame, Close : () -> ()) -> GuiObject?
) : Modal
	assert(not Self.Closed, "ModalStack is destroyed")
	assert(Graph.GetOwner() ~= nil, "Modal requires a declaring reactive owner")
	local Host, Service = Self.Host, Self.GuiService
	assert(Host and Service, "ModalStack host is unavailable")
	if #Self.Entries == 0 then
		Self.OriginalFocus = Service.SelectedObject
	end
	local Entry : ModalEntry = {
		Stack = Self,
		Portal = nil,
		Root = nil,
		InitialFocus = nil,
		LastFocus = nil,
		Closed = false,
	}
	table.insert(Self.Entries, Entry)
	local Passed, Handle = pcall(function()
		return MountPortal(Host, function(Root)
			Entry.Root = Root
			Root.Name = "InterfacerModal"
			Root.BackgroundColor3 = Color3.new()
			Root.BackgroundTransparency = 0.35
			Root.Active, Root.Selectable, Root.SelectionGroup = true, true, true
			Root.SelectionBehaviorUp, Root.SelectionBehaviorDown =
				Enum.SelectionBehavior.Stop, Enum.SelectionBehavior.Stop
			Root.SelectionBehaviorLeft, Root.SelectionBehaviorRight =
				Enum.SelectionBehavior.Stop, Enum.SelectionBehavior.Stop
			Root.ZIndex = #Self.Entries
			Graph.Cleanup(Root.DescendantRemoving:Connect(function()
				task.defer(RefreshFocus, Self)
			end))
			Entry.InitialFocus = Render(Root, function()
				CloseEntry(Entry)
			end)
		end, function()
			RemoveEntry(Entry)
		end, Entry)
	end)
	if not Passed then
		RemoveEntry(Entry)
		error(Handle, 0)
	end
	if Entry.Closed or Self.Closed then
		Handle:Destroy()
	else
		Entry.Portal = Handle
		RefreshFocus(Self)
	end
	return Handle
end

const function CloseTop(Self : StackData)
	local Top = Self.Entries[#Self.Entries]
	if Top then
		CloseEntry(Top)
	end
end

const function GetCount(Self : StackData) : number
	return #Self.Entries
end

const function GetTop(Self : StackData) : Modal?
	local Top = Self.Entries[#Self.Entries]
	return if Top and not Top.Closed then Top.Portal else nil
end

const function DestroyStack(Self : StackData)
	if Self.Closed then
		return
	end
	Self.Closed = true
	if ActiveStack == Self then
		ActiveStack = nil
	end
	for _, Connection in Self.Connections do
		Connection:Disconnect()
	end
	table.clear(Self.Connections)
	local Entries = table.clone(Self.Entries)
	for Index = #Entries, 1, -1 do
		CloseEntry(Entries[Index])
		RemoveEntry(Entries[Index])
	end
	table.clear(Self.Entries)
	RestoreFocus(Self)
	Self.Host, Self.GuiService = nil, nil
end

const StackMethods = table.freeze({
	Open = OpenModal,
	CloseTop = CloseTop,
	GetCount = GetCount,
	GetTop = GetTop,
	Destroy = DestroyStack,
})
const StackMetatable = table.freeze({ __index = StackMethods })
export type ModalStack = typeof(setmetatable({} :: StackData, StackMetatable))

const function CreateModalStack(Host : ScreenGui) : ModalStack
	assert(Graph.GetOwner() ~= nil, "ModalStack requires a declaring reactive owner")
	assert(game:GetService("RunService"):IsClient(), "ModalStack is client-only")
	assert(
		Host.ZIndexBehavior == Enum.ZIndexBehavior.Sibling,
		"ModalStack requires sibling ZIndex behavior"
	)
	local Player = game:GetService("Players").LocalPlayer
	local PlayerGui = if Player then Player:FindFirstChildOfClass("PlayerGui") else nil
	assert(
		PlayerGui and Host:IsDescendantOf(PlayerGui),
		"ModalStack requires a live local PlayerGui host"
	)
	assert(ActiveStack == nil, "one active ModalStack is supported per import")
	local Self : StackData = {
		Host = Host,
		Entries = {},
		OriginalFocus = nil,
		GuiService = game:GetService("GuiService"),
		Connections = {},
		Closed = false,
		ChangingFocus = false,
	}
	ActiveStack = Self
	local Handle = setmetatable(Self, StackMetatable)
	Graph.Cleanup(function()
		DestroyStack(Self)
	end)
	table.insert(
		Self.Connections,
		Host.Destroying:Connect(function()
			DestroyStack(Self)
		end)
	)
	local Service = Self.GuiService
	assert(Service, "GuiService required")
	table.insert(
		Self.Connections,
		Service:GetPropertyChangedSignal("SelectedObject"):Connect(function()
			RefreshFocus(Self)
		end)
	)
	return Handle
end

const function AllowsSelection(Target : GuiObject) : boolean
	if not CanSelect(Target) then
		return false
	end
	local Stack = ActiveStack
	local Entry = if Stack then Stack.Entries[#Stack.Entries] else nil
	local Root = if Entry then Entry.Root else nil
	return Root == nil or Target == Root or Target:IsDescendantOf(Root)
end

return table.freeze({
	Portal = CreatePortal,
	ModalStack = CreateModalStack,
	AllowsSelection = AllowsSelection,
})
