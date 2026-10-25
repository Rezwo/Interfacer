--!nonstrict
local IS_ROBLOX = game ~= nil

local Flux
local sert
if IS_ROBLOX then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	Flux = require(ReplicatedStorage:WaitForChild("Flux")) :: any
	sert = require(ReplicatedStorage:WaitForChild("sert")) :: any
else
	Flux = require("../../src") :: any
	sert = require("../sert") :: any
end

local test = sert.test
local rtest = sert.rtest
local expect = sert
local Interact = Flux.Interact

local InteractModule = if IS_ROBLOX
	then require(
			game:GetService("ReplicatedStorage"):WaitForChild("Flux"):WaitForChild("Interact")
		) :: any
	else require("../../src/Interact") :: any
local Compatibility = if IS_ROBLOX then nil else require("../../src/Compatibility") :: any
local Enum = if IS_ROBLOX then Enum else Compatibility.Enum
local Vector2 = if IS_ROBLOX then Vector2 else Compatibility.Vector2

local ctest = if IS_ROBLOX and game:GetService("Players").LocalPlayer ~= nil
	then sert.rtest
	else sert.skip

local function makeSignal()
	local listeners : { [any] : boolean } = {}
	return {
		Connect = function(_, fn : (...any) -> ())
			listeners[fn] = true
			return {
				Disconnect = function()
					listeners[fn] = nil
				end,
			}
		end,
		Fire = function(_, ... : any)
			for fn in table.clone(listeners) do
				if listeners[fn] then
					fn(...)
				end
			end
		end,
	}
end

local function makeGui(root : any, parent : any?) : any
	return {
		Active = false,
		InputSink = { Value = 0 },
		Destroying = makeSignal(),
		InputBegan = makeSignal(),
		InputChanged = makeSignal(),
		InputEnded = makeSignal(),
		MouseEnter = makeSignal(),
		MouseLeave = makeSignal(),
		FindFirstAncestorWhichIsA = function(_, className : string)
			return if className == "BasePlayerGui" then root else nil
		end,
		IsDescendantOf = function(_, ancestor : any)
			return parent == ancestor
		end,
	}
end

local function makeEnv()
	local propSignals : { [string] : any } = {
		SelectedObject = makeSignal(),
		MenuIsOpen = makeSignal(),
	}
	local env : any = {}
	env.focusedTextBox = nil
	env.lastInputType = Enum.UserInputType.MouseMovement
	env.mouseLocation = Vector2.new(10, 20)
	env.GuiService = {
		MenuIsOpen = false,
		SelectedObject = nil,
		GetGuiInset = function()
			return Vector2.new(0, 0)
		end,
		GetPropertyChangedSignal = function(_, prop : string)
			return propSignals[prop]
		end,
	}
	env.UserInputService = {
		InputBegan = makeSignal(),
		InputChanged = makeSignal(),
		InputEnded = makeSignal(),
		LastInputTypeChanged = makeSignal(),
		WindowFocusReleased = makeSignal(),
		GetFocusedTextBox = function()
			return env.focusedTextBox
		end,
		GetLastInputType = function()
			return env.lastInputType
		end,
		GetMouseLocation = function()
			return env.mouseLocation
		end,
	}
	env.RunService = {
		Heartbeat = makeSignal(),
	}
	env.propSignals = propSignals
	return env
end

test("interact · pointIn tests inclusive absolute bounds", function()

	local object =
		{ AbsolutePosition = { X = 100, Y = 50 }, AbsoluteSize = { X = 200, Y = 100 } } :: any
	expect(Interact.PointIn(100, 50, object) == true, "top-left corner is inside")
	expect(Interact.PointIn(300, 150, object) == true, "bottom-right corner is inside")
	expect(Interact.PointIn(200, 100, object) == true, "interior point is inside")
	expect(Interact.PointIn(99, 100, object) == false, "left of bounds")
	expect(Interact.PointIn(301, 100, object) == false, "right of bounds")
	expect(Interact.PointIn(200, 49, object) == false, "above bounds")
	expect(Interact.PointIn(200, 151, object) == false, "below bounds")
end)

test("interact · focused tracks TextBox focus and cleans up on Destroy or Destroying", function()
	local isFoc = false
	local tb : any = {
		Focused = makeSignal(),
		FocusLost = makeSignal(),
		Destroying = makeSignal(),
		IsFocused = function()
			return isFoc
		end,
	}
	local node = Interact.Focused(tb)
	expect(node() == false, "initial unfocused state")
	tb.Focused:Fire()
	expect(node() == true, "Focused sets true")
	tb.FocusLost:Fire()
	expect(node() == false, "FocusLost sets false")

	tb.Focused:Fire()
	expect(node() == true, "re-focused")
	tb.Destroying:Fire()
	expect(node() == false, "Destroying settles focused node to false")
	node:Destroy()
end)

test("interact · selected tracks GuiService.SelectedObject changes and cleans up", function()
	local env = makeEnv()
	local root = {
		GetGuiObjectsAtPosition = function()
			return {}
		end,
	}
	local btnA = makeGui(root)
	local btnB = makeGui(root)
	env.GuiService.SelectedObject = btnA

	local selA = InteractModule.SelectedWith(btnA, env)
	local selB = InteractModule.SelectedWith(btnB, env)
	expect(selA() == true and selB() == false, "seeded from current SelectedObject")

	env.GuiService.SelectedObject = btnB
	env.propSignals.SelectedObject:Fire()
	expect(selA() == false and selB() == true, "SelectedObject transition updates both nodes")

	btnB.Destroying:Fire()
	expect(selB() == false, "Destroying settles selected node to false")
	selB:Destroy()
	selA:Destroy()
end)

test(
	"interact · press handles mouse, touch, gamepad/keyboard activation, occlusion, and MenuIsOpen",
	function()
		local hitList : { any } = {}
		local root = {
			GetGuiObjectsAtPosition = function()
				return hitList
			end,
		}
		local env = makeEnv()
		local btn = makeGui(root)
		local blocker = makeGui(root)
		blocker.Active = true
		hitList = { btn }

		local pressed = InteractModule.PressWith(btn, env)
		expect(pressed() == false, "initially not pressed")

		local mouseInput = {
			UserInputType = Enum.UserInputType.MouseButton1,
			KeyCode = Enum.KeyCode.Unknown,
			Position = { X = 10, Y = 10 },
		}
		btn.InputBegan:Fire(mouseInput)
		expect(pressed() == true, "MouseButton1 begins press")

		env.UserInputService.InputEnded:Fire({
			UserInputType = Enum.UserInputType.MouseButton1,
			KeyCode = Enum.KeyCode.Unknown,
		})
		expect(pressed() == false, "MouseButton1 release ends press")

		hitList = { blocker, btn }
		local tokenInput = {
			UserInputType = Enum.UserInputType.MouseButton1,
			KeyCode = Enum.KeyCode.Unknown,
			Position = { X = 10, Y = 10 },
		}
		btn.InputBegan:Fire(tokenInput)
		expect(pressed() == false, "press blocked when Active gui is above")

		hitList = { btn }
		env.GuiService.SelectedObject = btn
		local keyInput = {
			UserInputType = Enum.UserInputType.Keyboard,
			KeyCode = Enum.KeyCode.Return,
		}
		env.UserInputService.InputBegan:Fire(keyInput)
		expect(pressed() == true, "Return key activates press on SelectedObject")

		env.GuiService.MenuIsOpen = true
		env.propSignals.MenuIsOpen:Fire()
		expect(pressed() == false, "MenuIsOpen releases active press")
		env.GuiService.MenuIsOpen = false

		local touch1 = {
			UserInputType = Enum.UserInputType.Touch,
			KeyCode = Enum.KeyCode.Unknown,
			Position = { X = 5, Y = 5 },
		}
		local touch2 = {
			UserInputType = Enum.UserInputType.Touch,
			KeyCode = Enum.KeyCode.Unknown,
			Position = { X = 6, Y = 6 },
		}
		btn.InputBegan:Fire(touch1)
		expect(pressed() == true, "touch1 begins press")
		env.UserInputService.InputEnded:Fire(touch2)
		expect(pressed() == true, "different touch ending does not release touch1")
		env.UserInputService.InputEnded:Fire(touch1)
		expect(pressed() == false, "touch1 ending releases press")

		pressed:Destroy()
	end
)

test(
	"interact · hover tracks mouse, touch, within option, frame step occlusion, and focus loss",
	function()
		local hitList : { any } = {}
		local root = {
			GetGuiObjectsAtPosition = function()
				return hitList
			end,
		}
		local env = makeEnv()
		local card = makeGui(root)
		local childBtn = makeGui(root, card)
		childBtn.Active = true
		local modal = makeGui(root)
		modal.InputSink = { Value = 1 }

		local prev = InteractModule.UseHoverServices(env)
		local hovDefault = Interact.Hover(card)
		local hovWithin = Interact.Hover(card, { Within = true })

		hitList = { childBtn, card }
		local moveInput = {
			UserInputType = Enum.UserInputType.MouseMovement,
			Position = { X = 15, Y = 25 },
		}
		card.InputBegan:Fire(moveInput)
		expect(hovDefault() == false, "child Active button sinks default hover")
		expect(hovWithin() == true, "within=true stays hovered over descendant button")

		hitList = { modal, childBtn, card }
		env.RunService.Heartbeat:Fire()
		expect(hovWithin() == false, "external modal covers within=true hover on Heartbeat")

		childBtn.Active = false
		hitList = { childBtn, card }
		env.RunService.Heartbeat:Fire()
		expect(
			hovDefault() == true and hovWithin() == true,
			"Heartbeat restores hover when cover leaves"
		)

		hitList = {}
		env.RunService.Heartbeat:Fire()
		expect(
			hovDefault() == false and hovWithin() == false,
			"disappearing from hit list leaves hover"
		)

		hitList = { card }
		card.MouseEnter:Fire()
		env.RunService.Heartbeat:Fire()
		expect(hovDefault() == true, "MouseEnter + Heartbeat enters hover")
		env.UserInputService.WindowFocusReleased:Fire()
		expect(hovDefault() == false, "WindowFocusReleased clears mouse hover")

		card.MouseEnter:Fire()
		env.RunService.Heartbeat:Fire()
		expect(hovDefault() == true, "re-entered hover")
		env.UserInputService.LastInputTypeChanged:Fire({ Name = "Gamepad1" })
		expect(hovDefault() == false, "switching to Gamepad clears mouse hover")

		local touchInput = {
			UserInputType = Enum.UserInputType.Touch,
			Position = { X = 15, Y = 25 },
		}
		card.InputBegan:Fire(touchInput)
		expect(hovDefault() == true, "touch begins hover")
		env.UserInputService.InputEnded:Fire(touchInput)
		expect(hovDefault() == false, "touch InputEnded settles touch hover")

		card.InputBegan:Fire(touchInput)
		expect(hovDefault() == true, "touch begins hover again")
		env.GuiService.MenuIsOpen = true
		env.RunService.Heartbeat:Fire()
		expect(hovDefault() == false, "MenuIsOpen on Heartbeat clears touch and mouse hover")
		env.GuiService.MenuIsOpen = false

		card.InputBegan:Fire(moveInput)
		expect(hovDefault() == true, "mouse move enters")
		card.MouseLeave:Fire()
		expect(hovDefault() == false, "MouseLeave clears hover")

		hovDefault:Destroy()
		hovWithin:Destroy()
		InteractModule.UseHoverServices(prev)
	end
)

rtest("interact · sunk and covered yield false outside a player gui", function()

	local orphan = Flux.New("Frame")({ Size = UDim2.fromOffset(100, 100) })
	expect(Interact.Sunk(0, 0, orphan) == false, "an object outside a player gui is never sunk")
	expect(
		Interact.Covered(0, 0, orphan) == false,
		"an object outside a player gui is never covered"
	)
	orphan:Destroy()
end)

ctest("interact · sunk detects an input-claiming gui above the object", function()
	local run = game:GetService("RunService")
	local player = game:GetService("Players").LocalPlayer
	local gui = Flux.New("ScreenGui")({
		DisplayOrder = 1000,
		ScreenInsets = Enum.ScreenInsets.None,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local position = UDim2.new(0.5, -50, 0.5, -50)
	local under =
		Flux.New("Frame")({ Parent = gui, Position = position, Size = UDim2.fromOffset(100, 100) })
	local over = Flux.New("Frame")({
		Parent = gui,
		Position = position,
		Size = UDim2.fromOffset(100, 100),
		Active = true,
		ZIndex = 2,
	})

	run.RenderStepped:Wait()
	run.Heartbeat:Wait()
	local corner = under.AbsolutePosition
	local x, y = corner.X + 10, corner.Y + 10
	expect(Interact.Sunk(x, y, under) == true, "an Active frame above sinks the point")

	over.Active = false
	expect(Interact.Sunk(x, y, under) == false, "an inactive frame above does not sink")
	expect(Interact.Sunk(x, y, over) == false, "the topmost gui itself is never sunk")

	gui:Destroy()
end)

return {}
