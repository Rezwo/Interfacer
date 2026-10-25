--!strict

const Compatibility = require("./Compatibility")
const Graph = require("./Graph")

local Enum = Compatibility.Enum

local DisposeResource = Graph.Dispose
local CreateState = Graph.State

export type Services = {
	GuiService : GuiService,
	UserInputService : UserInputService,
}

export type HoverOptions = {

	Within : boolean?,
}

export type HoverServices = {
	GuiService : any,
	UserInputService : any,
	RunService : any,
	Events : ((Object : any) -> any)?,
}

local MouseMovementInput = Enum.UserInputType.MouseMovement
local PrimaryMouseInput = Enum.UserInputType.MouseButton1
local TouchInput = Enum.UserInputType.Touch
local ActivationKeys : { [any] : boolean } = {
	[Enum.KeyCode.ButtonA] = true,
	[Enum.KeyCode.Return] = true,
	[Enum.KeyCode.KeypadEnter] = true,
}

local Engine : HoverServices? = nil

const function EngineServices() : HoverServices?
	local Resolved = Engine
	if Resolved == nil then
		local GuiService = Compatibility.GetService("GuiService")
		if GuiService == nil then
			return nil
		end
		Resolved = {
			GuiService = GuiService,
			UserInputService = Compatibility.GetService("UserInputService"),
			RunService = Compatibility.GetService("RunService"),
		} :: HoverServices
		Engine = Resolved
	end
	return Resolved
end

const function MenuOpen(Services : { GuiService : any }?) : boolean
	return Services ~= nil and Services.GuiService.MenuIsOpen == true
end

local function PointIn(
	HorizontalPosition : number,
	VerticalPosition : number,
	Object : GuiObject
) : boolean
	local PointerCoordinates, Size = Object.AbsolutePosition, Object.AbsoluteSize
	return HorizontalPosition >= PointerCoordinates.X
		and HorizontalPosition <= PointerCoordinates.X + Size.X
		and VerticalPosition >= PointerCoordinates.Y
		and VerticalPosition <= PointerCoordinates.Y + Size.Y
end

local MemoToken : any = nil
local MemoRoot : Instance? = nil
local MemoX, MemoY = 0, 0
local MemoList : { GuiObject } = {}

const function GuisAt(
	Root : BasePlayerGui,
	HorizontalPosition : number,
	VerticalPosition : number
) : { GuiObject }?
	local Passed, List =
		pcall(Root.GetGuiObjectsAtPosition, Root, HorizontalPosition, VerticalPosition)
	return if Passed then List :: { GuiObject } else nil
end

const function Hits(
	Root : BasePlayerGui,
	HorizontalPosition : number,
	VerticalPosition : number,
	Token : any?
) : { GuiObject }?
	if
		Token ~= nil
		and Token == MemoToken
		and Root == MemoRoot
		and HorizontalPosition == MemoX
		and VerticalPosition == MemoY
	then
		return MemoList
	end
	local List = GuisAt(Root, HorizontalPosition, VerticalPosition)
	if List ~= nil and Token ~= nil then
		MemoToken, MemoRoot, MemoX, MemoY, MemoList =
			Token, Root, HorizontalPosition, VerticalPosition, List
	end
	return List
end

const function Claims(GuiObject : GuiObject, Object : GuiObject, Within : boolean) : boolean
	return (GuiObject.Active or GuiObject.InputSink.Value ~= 0)
		and not (Within and GuiObject:IsDescendantOf(Object))
end

const function Scan(List : { GuiObject }, Object : GuiObject, Within : boolean) : (boolean, boolean)
	local Claimed = false
	for _, GuiObject in List do
		if GuiObject == Object then
			return true, Claimed
		elseif not Claimed and Claims(GuiObject, Object, Within) then
			Claimed = true
		end
	end
	return false, Claimed
end

const function ClaimedAt(
	Services : { GuiService : any }?,
	HorizontalPosition : number,
	VerticalPosition : number,
	Object : GuiObject,
	Token : any?,
	Within : boolean
) : boolean
	local Root = Object:FindFirstAncestorWhichIsA("BasePlayerGui")
	if Root == nil then
		return false
	elseif MenuOpen(Services) then
		return true
	end
	local List = Hits(Root, HorizontalPosition, VerticalPosition, Token)
	if List == nil then
		return false
	end
	local _, Claimed = Scan(List, Object, Within)
	return Claimed
end

local function Sunk(
	HorizontalPosition : number,
	VerticalPosition : number,
	Object : GuiObject,
	Token : any?
) : boolean
	return ClaimedAt(EngineServices(), HorizontalPosition, VerticalPosition, Object, Token, false)
end

local function Covered(
	HorizontalPosition : number,
	VerticalPosition : number,
	Object : GuiObject,
	Token : any?
) : boolean
	return ClaimedAt(EngineServices(), HorizontalPosition, VerticalPosition, Object, Token, true)
end

type Listener = {
	Count : number,
	Connections : { RBXScriptConnection }?,
	Open : () -> { RBXScriptConnection },
}

const function Retain(EventListener : Listener)
	EventListener.Count += 1
	if EventListener.Count == 1 and EventListener.Connections == nil then
		EventListener.Connections = EventListener.Open()
	end
end

const function Release(EventListener : Listener)
	EventListener.Count -= 1
	local Connections = EventListener.Connections
	if EventListener.Count == 0 and Connections ~= nil then
		EventListener.Connections = nil
		DisposeResource(Connections)
	end
end

type Handler = (any) -> ()

type Hub = Listener & {
	Handlers : { [Instance] : { [Handler] : true } },
	Last : Instance?,
}

type Entry = {
	Object : GuiObject,
	State : Graph.Node<boolean>,
	Within : boolean,
	Root : Instance?,
	Touch : InputObject?,
}

type Tracker = Listener & {
	InputEnvironment : HoverServices,
	Inside : { [Entry] : true },
	Touched : { [Entry] : true },
	HorizontalPosition : number?,
	VerticalPosition : number?,
}

type Registry = { Activate : Hub, Selected : Hub, Hover : Tracker }

local Registries : { [any] : Registry } = setmetatable({}, { __mode = "k" }) :: any

const function Dispatch(InputHub : Hub, Object : Instance?, InputValue : any)
	local SetNodeValue = if Object ~= nil then InputHub.Handlers[Object] else nil
	if SetNodeValue == nil then
		return
	end
	for EventHandler in SetNodeValue do
		EventHandler(InputValue)
	end
end

const function HubAdd(InputHub : Hub, Object : Instance, EventHandler : Handler)
	local SetNodeValue = InputHub.Handlers[Object]
	if SetNodeValue == nil then
		SetNodeValue = {}
		InputHub.Handlers[Object] = SetNodeValue
	end
	if not SetNodeValue[EventHandler] then
		SetNodeValue[EventHandler] = true
		Retain(InputHub)
	end
end

const function HubRemove(InputHub : Hub, Object : Instance, EventHandler : Handler)
	local SetNodeValue = InputHub.Handlers[Object]
	if SetNodeValue == nil or not SetNodeValue[EventHandler] then
		return
	end
	SetNodeValue[EventHandler] = nil
	if next(SetNodeValue) == nil then
		InputHub.Handlers[Object] = nil
	end
	Release(InputHub)
end

const function LeavesMouse(Kind : any) : boolean
	return Kind == TouchInput or string.sub(Kind.Name, 1, 7) == "Gamepad"
end

const function SettleTouch(InputTracker : Tracker, ActiveEntry : Entry)
	if ActiveEntry.Touch ~= nil then
		ActiveEntry.Touch = nil
		InputTracker.Touched[ActiveEntry] = nil
		Release(InputTracker)
	end
	if ActiveEntry.Root == nil then
		ActiveEntry.State:Set(false)
	end
	MemoToken, MemoRoot, MemoList = nil, nil, {}
end

const function Leave(InputTracker : Tracker, ActiveEntry : Entry)
	if ActiveEntry.Root ~= nil then
		ActiveEntry.Root = nil
		InputTracker.Inside[ActiveEntry] = nil
		Release(InputTracker)
	end
	if ActiveEntry.Touch == nil then
		ActiveEntry.State:Set(false)
	end
end

const function Step(InputTracker : Tracker)
	if MenuOpen(InputTracker.InputEnvironment) then
		for ActiveEntry in InputTracker.Inside do
			ActiveEntry.State:Set(false)
		end
		for ActiveEntry in InputTracker.Touched do
			SettleTouch(InputTracker, ActiveEntry)
		end
		return
	end
	local HorizontalPosition, VerticalPosition = InputTracker.HorizontalPosition, InputTracker.VerticalPosition
	if HorizontalPosition == nil or VerticalPosition == nil then
		return
	end
	local LastRoot : any, LastList : { GuiObject } = nil, {}
	for ActiveEntry in InputTracker.Inside do
		local Root = ActiveEntry.Root :: any
		if Root ~= LastRoot then
			local List = GuisAt(Root, HorizontalPosition, VerticalPosition)
			if List == nil then
				return
			end
			LastRoot, LastList = Root, List
		end
		local Found, Claimed = Scan(LastList, ActiveEntry.Object, ActiveEntry.Within)
		if not Found then
			Leave(InputTracker, ActiveEntry)
		elseif ActiveEntry.Touch == nil then
			ActiveEntry.State:Set(not Claimed)
		end
	end
end

const function ConnectTracker(InputTracker : Tracker) : { RBXScriptConnection }
	local Services = InputTracker.InputEnvironment
	InputTracker.HorizontalPosition, InputTracker.VerticalPosition = nil, nil
	local Input = Services.UserInputService
	local function ClearMouse()
		for ActiveEntry in InputTracker.Inside do
			Leave(InputTracker, ActiveEntry)
		end
		MemoToken, MemoRoot, MemoList = nil, nil, {}
	end
	return {
		Services.RunService.Heartbeat:Connect(function()
			Step(InputTracker)
		end),
		Input.InputChanged:Connect(function(Changed : InputObject)
			if Changed.UserInputType == MouseMovementInput then
				InputTracker.HorizontalPosition, InputTracker.VerticalPosition = Changed.Position.X, Changed.Position.Y
			end
		end),
		Input.InputEnded:Connect(function(Ended : InputObject)
			if Ended.UserInputType == TouchInput then
				for ActiveEntry in InputTracker.Touched do
					if ActiveEntry.Touch == Ended then
						SettleTouch(InputTracker, ActiveEntry)
					end
				end
			end
		end),
		Input.LastInputTypeChanged:Connect(function(Kind : any)
			if LeavesMouse(Kind) then
				ClearMouse()
			end
		end),
		Input.WindowFocusReleased:Connect(ClearMouse),
	}
end

const function RegistryFor(Services : any) : Registry
	local InputRegistry = Registries[Services]
	if InputRegistry ~= nil then
		return InputRegistry
	end

	local Activate : Hub = { Handlers = {}, Count = 0 } :: any
	Activate.Open = function() : { RBXScriptConnection }
		local UserInput = Services.UserInputService
		return {
			UserInput.InputBegan:Connect(function(Input : InputObject)
				if
					ActivationKeys[Input.KeyCode]
					and UserInput:GetFocusedTextBox() == nil
					and not MenuOpen(Services)
				then
					Dispatch(Activate, Services.GuiService.SelectedObject, Input)
				end
			end),
		}
	end

	local Selected : Hub = { Handlers = {}, Count = 0 } :: any
	Selected.Open = function() : { RBXScriptConnection }
		local GuiService = Services.GuiService
		Selected.Last = GuiService.SelectedObject
		return {
			GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
				local Now = GuiService.SelectedObject
				local Last = Selected.Last
				if Now ~= Last then
					Selected.Last = Now
					Dispatch(Selected, Last, false)
					Dispatch(Selected, Now, true)
				end
			end),
		}
	end

	local InputTracker : Tracker =
		{ InputEnvironment = Services, Inside = {}, Touched = {}, Count = 0 } :: any
	InputTracker.Open = function() : { RBXScriptConnection }
		return ConnectTracker(InputTracker)
	end

	InputRegistry = { Activate = Activate, Selected = Selected, Hover = InputTracker }
	Registries[Services] = InputRegistry
	return InputRegistry
end

const function Expose(
	StateHandle : Graph.Node<boolean>,
	Object : Instance,
	OnRelease : () -> ()
) : Graph.Node<boolean>
	local Settled = false
	local DestructionSignal : RBXScriptConnection? = nil
	local function Settle()
		if Settled then
			return
		end
		Settled = true
		if DestructionSignal ~= nil then
			DestructionSignal:Disconnect()
			DestructionSignal = nil
		end
		OnRelease()
	end
	DestructionSignal = Object.Destroying:Connect(Settle)
	StateHandle:OnDestroy(Settle)
	if Graph.GetOwner() then
		Graph.Cleanup(Settle)
	end
	return StateHandle
end

const function Enter(
	InputTracker : Tracker,
	ActiveEntry : Entry,
	HorizontalPosition : number?,
	VerticalPosition : number?
)
	if ActiveEntry.Root == nil then
		local Root = ActiveEntry.Object:FindFirstAncestorWhichIsA("BasePlayerGui")
		if Root == nil then
			return
		end
		ActiveEntry.Root = Root
		InputTracker.Inside[ActiveEntry] = true
		Retain(InputTracker)
	end
	if HorizontalPosition ~= nil then
		InputTracker.HorizontalPosition, InputTracker.VerticalPosition = HorizontalPosition, VerticalPosition
	elseif InputTracker.HorizontalPosition == nil then
		local Services = InputTracker.InputEnvironment
		local Passed, At = pcall(function() : Vector2
			return Services.UserInputService:GetMouseLocation() - Services.GuiService:GetGuiInset()
		end)
		if Passed then
			InputTracker.HorizontalPosition, InputTracker.VerticalPosition = At.X, At.Y
		end
	end
end

local function HoverWith(
	Object : GuiObject,
	Services : HoverServices?,
	Options : HoverOptions?
) : Graph.Node<boolean>
	local Within = Options ~= nil and Options.Within == true
	local Hovering = CreateState(false)
	local Events : any = if Services ~= nil and Services.Events ~= nil
		then Services.Events(Object)
		else Object
	local ActiveEntry : Entry = { Object = Object, State = Hovering, Within = Within }
	local InputTracker = if Services ~= nil then RegistryFor(Services).Hover else nil

	local function Track(Input : InputObject)
		local Kind = Input.UserInputType
		if Kind ~= MouseMovementInput and Kind ~= TouchInput then
			return
		end
		local PointerPosition = Input.Position
		local On = not MenuOpen(Services)
			and not ClaimedAt(Services, PointerPosition.X, PointerPosition.Y, Object, Input, Within)
		Hovering:Set(On)
		if Kind == MouseMovementInput then
			if InputTracker ~= nil then
				Enter(InputTracker, ActiveEntry, PointerPosition.X, PointerPosition.Y)
			end
		elseif InputTracker ~= nil then
			if On and ActiveEntry.Touch == nil then
				ActiveEntry.Touch = Input
				InputTracker.Touched[ActiveEntry] = true
				Retain(InputTracker)
			elseif not On and ActiveEntry.Touch ~= nil then
				SettleTouch(InputTracker, ActiveEntry)
			end
		end
	end

	local Connections : { RBXScriptConnection } = {
		Events.InputBegan:Connect(Track),
		Events.InputChanged:Connect(Track),
		Events.InputEnded:Connect(function(Input : InputObject)
			local Kind = Input.UserInputType
			if Kind == MouseMovementInput then
				if InputTracker ~= nil then
					Leave(InputTracker, ActiveEntry)
				else
					Hovering:Set(false)
				end
			elseif Kind == TouchInput then
				if InputTracker ~= nil and ActiveEntry.Touch ~= nil then
					SettleTouch(InputTracker, ActiveEntry)
				end
				Hovering:Set(false)
			end
		end),
	}
	local MouseEnterSignal : any = Events.MouseEnter
	local MouseLeaveSignal : any = Events.MouseLeave
	if InputTracker ~= nil and MouseEnterSignal ~= nil then
		local Tracking : Tracker = InputTracker
		table.insert(
			Connections,
			MouseEnterSignal:Connect(function()
				if
					not LeavesMouse(Tracking.InputEnvironment.UserInputService:GetLastInputType())
				then
					Enter(Tracking, ActiveEntry)
				end
			end) :: RBXScriptConnection
		)
		table.insert(
			Connections,
			MouseLeaveSignal:Connect(function()
				Leave(Tracking, ActiveEntry)
			end) :: RBXScriptConnection
		)
	end

	return Expose(Hovering, Object, function()
		DisposeResource(Connections)
		table.clear(Connections)
		if InputTracker ~= nil then
			if ActiveEntry.Touch ~= nil then
				SettleTouch(InputTracker, ActiveEntry)
			end
			Leave(InputTracker, ActiveEntry)
		end
		Hovering:Set(false)
	end)
end

local HoverOverride : HoverServices? = nil

local function Hover(Object : GuiObject, Options : HoverOptions?) : Graph.Node<boolean>
	return HoverWith(Object, HoverOverride or EngineServices(), Options)
end

local function UseHoverServices(Services : HoverServices?) : HoverServices?
	local Previous = HoverOverride
	HoverOverride = Services
	return Previous
end

local function PressWith(Object : GuiObject, Services : Services) : Graph.Node<boolean>
	local Pressed = CreateState(false)
	local Held : InputObject? = nil
	local ReleaseListener : RBXScriptConnection? = nil
	local MenuListener : RBXScriptConnection? = nil

	local function ReleasePress()
		Held = nil
		if MenuListener ~= nil then
			MenuListener:Disconnect()
			MenuListener = nil
		end
		local EventListener = ReleaseListener
		if EventListener ~= nil then
			ReleaseListener = nil
			EventListener:Disconnect()
		end
		Pressed:Set(false)
	end

	local function IsHeld(Input : InputObject) : boolean
		local Current = Held
		if Current == nil then
			return false
		elseif Input == Current then
			return true
		end
		local Kind = Current.UserInputType
		return Kind ~= TouchInput
			and Input.UserInputType == Kind
			and Input.KeyCode == Current.KeyCode
	end

	local function Hold(Input : InputObject)
		if Held ~= nil or MenuOpen(Services) then
			return
		end
		Held = Input
		Pressed:Set(true)
		MenuListener = Services.GuiService:GetPropertyChangedSignal("MenuIsOpen"):Connect(function()
			if MenuOpen(Services) then
				ReleasePress()
			end
		end)
		ReleaseListener = Services.UserInputService.InputEnded:Connect(function(Ended : InputObject)
			if IsHeld(Ended) then
				ReleasePress()
			end
		end)
	end

	local Pointer = Object.InputBegan:Connect(function(Input : InputObject)
		local Kind = Input.UserInputType
		if Kind == PrimaryMouseInput or Kind == TouchInput then
			local PointerCoordinates = Input.Position
			if
				not ClaimedAt(
					Services,
					PointerCoordinates.X,
					PointerCoordinates.Y,
					Object,
					Input,
					false
				)
			then
				Hold(Input)
			end
		end
	end)
	local InputHub = RegistryFor(Services).Activate
	HubAdd(InputHub, Object, Hold :: any)

	return Expose(Pressed, Object, function()
		Pointer:Disconnect()
		HubRemove(InputHub, Object, Hold :: any)
		ReleasePress()
	end)
end

local function Press(Object : GuiObject) : Graph.Node<boolean>
	return PressWith(Object, EngineServices() :: any)
end

local function SelectedWith(Object : GuiObject, Services : Services) : Graph.Node<boolean>
	local GuiService = Services.GuiService
	local IsSelected = CreateState(GuiService.SelectedObject == Object)
	local InputHub = RegistryFor(Services).Selected
	local function Follow(On : any)
		IsSelected:Set(On == true)
	end
	HubAdd(InputHub, Object, Follow)

	return Expose(IsSelected, Object, function()
		HubRemove(InputHub, Object, Follow)
		IsSelected:Set(false)
	end)
end

local function Selected(Object : GuiObject) : Graph.Node<boolean>
	return SelectedWith(Object, EngineServices() :: any)
end

const function CreateFocusState(FocusedTextBox : TextBox) : Graph.Node<boolean>
	local IsFocused = CreateState(FocusedTextBox:IsFocused())
	local Connections = {
		FocusedTextBox.Focused:Connect(function()
			IsFocused:Set(true)
		end),
		FocusedTextBox.FocusLost:Connect(function()
			IsFocused:Set(false)
		end),
	}

	return Expose(IsFocused, FocusedTextBox, function()
		DisposeResource(Connections)
		IsFocused:Set(false)
	end)
end

return table.freeze({
	PointIn = PointIn,
	Sunk = Sunk,
	Covered = Covered,

	Hover = Hover,
	Press = Press,
	Selected = Selected,
	Focused = CreateFocusState,

	HoverWith = HoverWith,

	UseHoverServices = UseHoverServices,

	PressWith = PressWith,

	SelectedWith = SelectedWith,
})
