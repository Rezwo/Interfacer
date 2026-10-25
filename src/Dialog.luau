--!strict
const Graph = require("./Graph")
const Overlay = require("./Overlay")
const Interact = require("./Interact")
const ExitVisual = require("./ExitVisual")

export type DialogOptions = {
	ExitDuration : number?,
	KeyboardDismissKey : Enum.KeyCode?,
	CloseOnKeyboardDismiss : boolean?,
	CloseOnGamepadBack : boolean?,
	CloseOnOutsidePress : boolean?,
}

export type DismissReason = "KeyboardDismiss" | "GamepadBack" | "OutsidePress"
export type DialogFactory = (Layer : Frame, Close : () -> ()) -> (GuiObject?, GuiObject?)

type DialogData = {
	Owner : Graph.Node<unknown>?,
	OpenState : Graph.State<boolean>?,
	Stack : Overlay.ModalStack?,
	Factory : DialogFactory?,
	Modal : Overlay.Modal?,
	Content : GuiObject?,
	CancelMount : (() -> ())?,
	Generation : number,
	Opening : boolean,
	Closed : boolean,
	ActionName : string,
	InputGeneration : number?,
	ExitDuration : number,
	ExitVisual : ExitVisual.Visual?,
	KeyboardDismissKey : Enum.KeyCode,
	CloseOnKeyboardDismiss : boolean,
	CloseOnGamepadBack : boolean,
	CloseOnOutsidePress : boolean,
}

const function GetIsOpen(Self : DialogData) : boolean
	local State = Self.OpenState
	return if State then State:Get() else false
end

const function GetContent(Self : DialogData) : GuiObject?
	local Modal = Self.Modal
	return if Modal and Modal:GetRoot() then Self.Content else nil
end

const function ClearOpen(Self : DialogData)
	Self.Generation += 1
	Self.Opening = false
	local Modal, Cancel = Self.Modal, Self.CancelMount
	Self.Modal, Self.Content, Self.CancelMount = nil, nil, nil
	local State = Self.OpenState
	if State then State:Set(false) end
	if Cancel then Cancel() end
	if Modal then Modal:Destroy() end
end

const function CancelExit(Self : DialogData)
	local Visual = Self.ExitVisual
	Self.ExitVisual = nil
	if Visual then Visual:Destroy() end
end

const function CloseDialog(Self : DialogData)
	if Self.Closed then return end
	if Self.ExitDuration == 0 then ClearOpen(Self); return end
	local Modal = Self.Modal
	local Root = if Modal then Modal:GetRoot() else nil
	if not Root then
		if Self.Opening then ClearOpen(Self) end
		return
	end
	if not Self.Stack or Self.Stack:GetTop() ~= Modal then ClearOpen(Self); return end
	local Host = Root.Parent
	local PreviousChildren = if Host then Host:GetChildren() else {}
	local Generation = Self.Generation + 1
	local Captured, Snapshot = pcall(ExitVisual.Capture, Root)
	local Passed, Failure = pcall(ClearOpen, Self)
	if not Passed then
		if Captured and Snapshot then Snapshot:Destroy() end
		error(Failure, 0)
	end
	if not Captured then error(Snapshot, 0) end
	if not Snapshot then return end
	local Owner = Self.Owner
	local function IsCurrent() : boolean
		if Self.Closed or Self.Generation ~= Generation or Self.Modal ~= nil then return false end
		if Host then
			for _, Child in Host:GetChildren() do
				if Child:IsA("GuiObject") and Child.Name ~= "InterfacerExitVisual" and not table.find(PreviousChildren, Child) then return false end
			end
		end
		return true
	end
	if not Owner or not Host or not IsCurrent() then Snapshot:Destroy(); return end
	local Visual = ExitVisual.Play(Owner, Snapshot, Host, Self.ExitDuration, IsCurrent, function()
		if Self.Generation == Generation then Self.ExitVisual = nil end
	end)
	if IsCurrent() and Visual:GetRoot() then Self.ExitVisual = Visual else Visual:Destroy() end
	table.clear(PreviousChildren)
end

const function FinishModal(Self : DialogData, Generation : number)
	if Self.Generation ~= Generation then return end
	Self.Generation += 1
	Self.Opening = false
	Self.Modal, Self.Content, Self.CancelMount = nil, nil, nil
	local State = Self.OpenState
	if State then State:Set(false) end
end

const function IsTop(Self : DialogData) : boolean
	local Stack, Modal = Self.Stack, Self.Modal
	return not Self.Closed and Stack ~= nil and Modal ~= nil and Modal:GetRoot() ~= nil and Stack:GetTop() == Modal
end

const function RequestClose(Self : DialogData, Reason : DismissReason) : boolean
	assert(Reason == "KeyboardDismiss" or Reason == "GamepadBack" or Reason == "OutsidePress", "unknown dialog dismissal reason")
	if not IsTop(Self) then return false end
	local Allowed = if Reason == "KeyboardDismiss" then Self.CloseOnKeyboardDismiss
		elseif Reason == "GamepadBack" then Self.CloseOnGamepadBack
		else Self.CloseOnOutsidePress
	if not Allowed then return false end
	CloseDialog(Self)
	return true
end

const function OpenDialog(Self : DialogData)
	assert(not Self.Closed, "Dialog is destroyed")
	local Owner, Stack, Factory = Self.Owner, Self.Stack, Self.Factory
	assert(Owner and Stack and Factory, "Dialog owner is unavailable")
	CancelExit(Self)
	if Self.Opening or (Self.Modal and Self.Modal:GetRoot()) then return end
	Self.Generation += 1
	local Generation = Self.Generation
	Self.Opening = true
	local Passed, Result = pcall(function()
		return Graph.WithOwner(Owner, function()
			return Stack:Open(function(Layer, Cancel)
				Self.CancelMount = Cancel
				Graph.Cleanup(function() FinishModal(Self, Generation) end)
				Layer.BackgroundTransparency = 1
				local Content, InitialFocus = Factory(Layer, function()
					if Self.Generation == Generation then CloseDialog(Self) end
				end)
				if Self.Generation ~= Generation or Self.Closed then return nil end
				assert(Content and Content:IsA("GuiObject") and Content:IsDescendantOf(Layer), "Dialog factory must return content inside its layer")
				assert(not InitialFocus or InitialFocus == Content or InitialFocus:IsDescendantOf(Content), "Dialog initial focus must belong to its content")
				Self.Content = Content
				local Actions = game:GetService("ContextActionService")
				local Input = game:GetService("UserInputService")
				local GuiService = game:GetService("GuiService")
				local ActionName = Self.ActionName
				Graph.Cleanup(function()
					if Self.InputGeneration == Generation then
						Self.InputGeneration = nil
						Actions:UnbindAction(ActionName)
					end
				end)
				Self.InputGeneration = Generation
				Actions:BindActionAtPriority(ActionName, function(_Name : string, State : Enum.UserInputState, Event : InputObject)
					if State ~= Enum.UserInputState.Begin or Self.Generation ~= Generation
						or GuiService.MenuIsOpen or Input:GetFocusedTextBox() ~= nil then
						return Enum.ContextActionResult.Pass
					end
					local Reason : DismissReason = if Event.KeyCode == Enum.KeyCode.ButtonB then "GamepadBack" else "KeyboardDismiss"
					return if RequestClose(Self, Reason) then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
				end, false, Enum.ContextActionPriority.High.Value, Self.KeyboardDismissKey, Enum.KeyCode.ButtonB)
				if Self.CloseOnOutsidePress then
					Graph.Cleanup(Layer.InputBegan:Connect(function(Event : InputObject)
						if Self.Generation ~= Generation or GuiService.MenuIsOpen then return end
						if Event.UserInputType ~= Enum.UserInputType.MouseButton1 and Event.UserInputType ~= Enum.UserInputType.Touch then return end
						local Position = Event.Position
						if not Interact.PointIn(Position.X, Position.Y, Content) then RequestClose(Self, "OutsidePress") end
					end))
				end
				return InitialFocus
			end)
		end)
	end)
	if not Passed then
		FinishModal(Self, Generation)
		error(Result, 0)
	end
	if Self.Generation ~= Generation or Self.Closed then
		Result:Destroy()
		return
	end
	Self.Modal = Result
	Self.CancelMount = nil
	Self.Opening = false
	local State = Self.OpenState
	if State then State:Set(Result:GetRoot() ~= nil) end
end

const function ToggleDialog(Self : DialogData)
	assert(not Self.Closed, "Dialog is destroyed")
	if Self.Opening or GetIsOpen(Self) then CloseDialog(Self) else OpenDialog(Self) end
end

const function DestroyDialog(Self : DialogData)
	if Self.Closed then return end
	Self.Closed = true
	CancelExit(Self)
	ClearOpen(Self)
	local Owner = Self.Owner
	Self.Owner, Self.Stack, Self.Factory, Self.OpenState = nil, nil, nil, nil
	if Owner then Owner:Destroy() end
end

const DialogMethods = table.freeze({
	GetIsOpen = GetIsOpen,
	GetContent = GetContent,
	Open = OpenDialog,
	Close = CloseDialog,
	Toggle = ToggleDialog,
	RequestClose = RequestClose,
	Destroy = DestroyDialog,
})
const DialogMetatable = table.freeze({ __index = DialogMethods })
export type Dialog = typeof(setmetatable({} :: DialogData, DialogMetatable))

const function New(Stack : Overlay.ModalStack, Factory : DialogFactory, Options : DialogOptions?) : Dialog
	assert(Graph.GetOwner() ~= nil, "Dialog requires a declaring reactive owner")
	local Configuration : DialogOptions = Options or {}
	local Duration = Configuration.ExitDuration or 0
	assert(Duration == Duration and Duration >= 0 and Duration <= 5, "ExitDuration must be finite and between zero and five seconds")
	local Data : DialogData = {
		Owner = nil, OpenState = nil, Stack = Stack, Factory = Factory, Modal = nil, Content = nil, CancelMount = nil,
		Generation = 0, Opening = false, Closed = false, InputGeneration = nil, ExitDuration = Duration, ExitVisual = nil,
		ActionName = "InterfacerDialog_" .. game:GetService("HttpService"):GenerateGUID(false),
		KeyboardDismissKey = Configuration.KeyboardDismissKey or Enum.KeyCode.Backspace,
		CloseOnKeyboardDismiss = Configuration.CloseOnKeyboardDismiss ~= false,
		CloseOnGamepadBack = Configuration.CloseOnGamepadBack ~= false,
		CloseOnOutsidePress = Configuration.CloseOnOutsidePress == true,
	}
	local Handle = setmetatable(Data, DialogMetatable)
	local Owner = Graph.Scope(function()
		local State = Graph.State(false)
		Data.OpenState = State
		Graph.Cleanup(State)
		Graph.Cleanup(function() DestroyDialog(Data) end)
	end)
	if Data.Closed then Owner:Destroy() else Data.Owner = Owner end
	return Handle
end

return table.freeze({ New = New })
