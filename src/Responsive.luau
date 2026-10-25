--!strict

const Compatibility = require("./Compatibility")
const Graph = require("./Graph")

local GetService = Compatibility.GetService
local ReportWarning = Compatibility.Warn

local CreateComputed = Graph.Computed
local ReadReactiveValue = Graph.Read
local CreateState = Graph.State

export type ScaleMode = "Minimum" | "Width" | "Height" | "Maximum"
export type Breakpoint = "Phone" | "Tablet" | "Desktop"
export type Platform = "Console" | "Mobile" | "Desktop" | "VirtualReality"
export type DisplaySize = "Small" | "Medium" | "Large"
export type Input = "Keyboard" | "Touch" | "Gamepad"
export type TextSize = "Medium" | "Large" | "Larger" | "Largest"
export type Breakpoints = { Phone : number, Tablet : number }

export type Configuration = {
	Reference : Vector2,
	Mode : ScaleMode,
	Minimum : number?,
	Maximum : number?,
	Breakpoints : Breakpoints,
}

export type PartialConfiguration = {
	Reference : Vector2?,
	Mode : ScaleMode?,
	Minimum : number?,
	Maximum : number?,
	Breakpoints : Breakpoints?,
	Viewport : Graph.Reactive<Vector2>?,
}

local DefaultViewportSize = Compatibility.Vector2.new(1920, 1080)

local DefaultConfiguration : Configuration = {
	Reference = DefaultViewportSize,
	Mode = "Minimum",
	Breakpoints = { Phone = 600, Tablet = 1024 },
}

local EmptyConfiguration : PartialConfiguration = {}
local WarnedModes : { [string] : boolean } = {}

const function ScaleFor(Width : number, Height : number, Partial : PartialConfiguration) : number
	local ReferenceSize = Partial.Reference or DefaultConfiguration.Reference
	local ReferenceWidth, ReferenceHeight =
		math.max(ReferenceSize.X, 1), math.max(ReferenceSize.Y, 1)
	local Mode = Partial.Mode or DefaultConfiguration.Mode

	local Factor : number
	if Mode == "Width" then
		Factor = Width / ReferenceWidth
	elseif Mode == "Height" then
		Factor = Height / ReferenceHeight
	elseif Mode == "Maximum" then
		Factor = math.max(Width / ReferenceWidth, Height / ReferenceHeight)
	else
		if Mode ~= "Minimum" then
			local Key = tostring(Mode)
			if not WarnedModes[Key] then
				WarnedModes[Key] = true
				ReportWarning(`[Flux] unknown scale mode "{Mode}"; falling back to "min"`)
			end
		end
		Factor = math.min(Width / ReferenceWidth, Height / ReferenceHeight)
	end

	local Minimum = if Partial.Minimum ~= nil then Partial.Minimum else DefaultConfiguration.Minimum
	if Minimum ~= nil and Factor < Minimum then
		Factor = Minimum
	end
	local Maximum = if Partial.Maximum ~= nil then Partial.Maximum else DefaultConfiguration.Maximum
	if Maximum ~= nil and Factor > Maximum then
		Factor = Maximum
	end

	return Factor
end

const function BreakpointFor(Width : number, Partial : PartialConfiguration) : Breakpoint
	local BreakpointThresholds = Partial.Breakpoints or DefaultConfiguration.Breakpoints
	if Width < BreakpointThresholds.Phone then
		return "Phone"
	elseif Width < BreakpointThresholds.Tablet then
		return "Tablet"
	end
	return "Desktop"
end

local ViewportState : Graph.Node<Vector2> = CreateState(DefaultViewportSize)

const function CreateScale(Partial : PartialConfiguration?) : Graph.Node<number>
	local Configuration = Partial or EmptyConfiguration
	local Source = Configuration.Viewport or ViewportState
	return CreateComputed(function() : number
		local ViewportSize = ReadReactiveValue(Source) :: Vector2
		return ScaleFor(ViewportSize.X, ViewportSize.Y, Configuration)
	end)
end

const function CreateBreakpoint(Partial : PartialConfiguration?) : Graph.Node<Breakpoint>
	local Configuration = Partial or EmptyConfiguration
	local Source = Configuration.Viewport or ViewportState
	return CreateComputed(function() : Breakpoint
		local ViewportSize = ReadReactiveValue(Source) :: Vector2
		return BreakpointFor(ViewportSize.X, Configuration)
	end)
end

local ScaleState : Graph.Node<number> = CreateScale()

local BreakpointState : Graph.Node<Breakpoint> = CreateBreakpoint()

local RunService = GetService("RunService")
local IsClient = RunService ~= nil and RunService:IsClient() and RunService:IsRunning()
local IsTenFootInterface = IsClient and GetService("GuiService"):IsTenFootInterface()

const function DetectPlatform() : Platform
	local UserInputService = GetService("UserInputService")
	return if GetService("VRService").VREnabled
		then "VirtualReality"
		elseif IsTenFootInterface then "Console"
		elseif UserInputService.KeyboardEnabled and UserInputService.MouseEnabled then "Desktop"
		else "Mobile"
end

local PlatformState : Graph.Node<Platform> =
	CreateState((if IsClient then DetectPlatform() else "Desktop") :: Platform)

local DisplaySizeState : Graph.Node<DisplaySize> =
	CreateState((if IsTenFootInterface then "Large" else "Medium") :: DisplaySize)

local InputsByName : { [string] : Input } = {
	KeyboardAndMouse = "Keyboard",
	Keyboard = "Keyboard",
	MouseMovement = "Keyboard",
	MouseButton1 = "Keyboard",
	MouseButton2 = "Keyboard",
	MouseButton3 = "Keyboard",
	MouseWheel = "Keyboard",
	Touch = "Touch",
	Gamepad = "Gamepad",
}
for Slot = 1, 8 do
	InputsByName[`Gamepad{Slot}`] = "Gamepad"
end

local function InputFor(InputName : string) : Input?
	return InputsByName[InputName]
end

local InputsByPlatform : { [Platform] : Input } = {
	Desktop = "Keyboard",
	Mobile = "Touch",
	Console = "Gamepad",
	VirtualReality = "Gamepad",
}

local InputState : Graph.Node<Input> = CreateState(InputsByPlatform[PlatformState:Peek()] :: Input)

local TextSizeState : Graph.Node<TextSize> = CreateState("Medium" :: TextSize)

local ReducedMotionState : Graph.Node<boolean> = CreateState(false)

local PreferredTransparencyState : Graph.Node<number> = CreateState(1)

if IsClient then
	local GuiService = GetService("GuiService")
	local Workspace = GetService("Workspace")
	local UserInputService = GetService("UserInputService")

	local ViewportConnection : RBXScriptConnection?
	local function BindCamera(CurrentCamera : Camera?)
		if ViewportConnection ~= nil then
			ViewportConnection:Disconnect()
			ViewportConnection = nil
		end
		if CurrentCamera ~= nil then
			ViewportState:Set(CurrentCamera.ViewportSize)
			ViewportConnection = CurrentCamera:GetPropertyChangedSignal("ViewportSize")
				:Connect(function()
					ViewportState:Set(CurrentCamera.ViewportSize)
				end)
		end
	end

	BindCamera(Workspace.CurrentCamera)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		BindCamera(Workspace.CurrentCamera)
	end)

	local function Mirror(
		Object : Instance,
		Property : string,
		Record : Graph.Node<any>,
		Map : ((Value : any) -> any)?
	) : boolean
		local Passed, Changed = pcall(Object.GetPropertyChangedSignal, Object, Property)
		if not Passed then
			return false
		end
		local function Synchronize()
			local RawValue = (Object :: any)[Property]
			local Value = if Map then Map(RawValue) else RawValue
			if Value ~= nil then
				Record:Set(Value)
			end
		end
		Synchronize()
		Changed:Connect(Synchronize)
		return true
	end

	local function NameOf(Item : EnumItem) : string
		return Item.Name
	end
	local function InputOf(Item : EnumItem) : Input?
		return InputFor(Item.Name)
	end
	local function SynchronizePlatform()
		PlatformState:Set(DetectPlatform())
	end
	local function BindPlatform(Object : Instance, Property : string)
		local Passed, Changed = pcall(Object.GetPropertyChangedSignal, Object, Property)
		if Passed then
			Changed:Connect(SynchronizePlatform)
		end
	end

	if not Mirror(UserInputService, "PreferredInput", InputState, InputOf) then
		UserInputService.LastInputTypeChanged:Connect(function(LastInputType : Enum.UserInputType)
			local Mode = InputFor(LastInputType.Name)
			if Mode ~= nil then
				InputState:Set(Mode)
			end
		end)
	end
	Mirror(GuiService, "PreferredTextSize", TextSizeState, NameOf)
	Mirror(GuiService, "ViewportDisplaySize", DisplaySizeState, NameOf)
	BindPlatform(UserInputService, "KeyboardEnabled")
	BindPlatform(UserInputService, "MouseEnabled")
	BindPlatform(GetService("VRService"), "VREnabled")
	Mirror(GuiService, "ReducedMotionEnabled", ReducedMotionState)
	Mirror(GuiService, "PreferredTransparency", PreferredTransparencyState)
end

return table.freeze({
	Configuration = DefaultConfiguration,
	Platform = PlatformState,

	Viewport = ViewportState,
	Scale = ScaleState,
	Breakpoint = BreakpointState,
	DisplaySize = DisplaySizeState,

	Input = InputState,
	TextSize = TextSizeState,
	ReducedMotion = ReducedMotionState,
	PreferredTransparency = PreferredTransparencyState,

	ScaleOf = CreateScale,
	BreakpointOf = CreateBreakpoint,

	InputFor = InputFor,
})
