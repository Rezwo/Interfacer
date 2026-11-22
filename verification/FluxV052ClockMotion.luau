--!strict
const Interfacer = require("../src")
const Compatibility = require("../src/Compatibility")
const MotionModule = require("../src/Motion")
const Clock = Interfacer.Clock

local Cases : { { Name : string, Run : () -> () } } = {
	{
		Name = "the latest deferred or timed schedule owns a thread",
		Run = function()
			local Messages : { string } = {}
			local Thread = coroutine.create(function(Message : string)
				table.insert(Messages, Message)
				local LaterMessage = coroutine.yield()
				table.insert(Messages, LaterMessage)
			end)
			Clock.Delay(0.1, Thread, "stale timer")
			Clock.Defer(Thread, "stale defer")
			Clock.Defer(Thread, "latest")
			Clock.Drain()
			Clock.Step(0.1, 0.1)
			assert(#Messages == 1 and Messages[1] == "latest", "older schedules must not resume the thread")
			Clock.Cancel(Thread)
		end,
	},
	{
		Name = "cancellation and equal deadlines preserve FIFO",
		Run = function()
			local Messages : { string } = {}
			local function Record(Message : string)
				table.insert(Messages, Message)
			end
			Clock.Delay(0.1, Record, "first")
			local Cancelled = Clock.Delay(0.1, Record, "cancelled")
			Clock.Delay(0.1, Record, "last")
			Clock.Cancel(Cancelled)
			Clock.Cancel(Cancelled)
			Clock.Step(0.1, 0.1)
			assert(table.concat(Messages, ",") == "first,last", "FIFO or cancellation changed")
		end,
	},
	{
		Name = "new zero-delay timers do not hide already eligible timers",
		Run = function()
			local Messages : { string } = {}
			Clock.Delay(0.1, function()
				table.insert(Messages, "first")
				Clock.Delay(0, function()
					table.insert(Messages, "next frame")
				end)
			end)
			Clock.Delay(0.2 + 3e-10, function()
				table.insert(Messages, "already eligible")
			end)
			Clock.Step(0.2, 0.2)
			assert(table.concat(Messages, ",") == "first,already eligible", "new timer blocked an eligible deadline")
			Clock.Step(0)
			assert(Messages[3] == "next frame", "new timer ran in the next frame")
		end,
	},
	{
		Name = "a tween retargeted from rest honors DelayTime",
		Run = function()
			local Tween = Interfacer.Tween(0, Compatibility.TweenInfo.new(0.25, Compatibility.Enum.EasingStyle.Linear, Compatibility.Enum.EasingDirection.Out, 0, false, 0.125))
			Tween:Set(100)
			Clock.Step(0.0625, 0.0625)
			assert(Tween:Get() == 0, "a resting tween skipped its delay")
			Clock.Step(0.125, 0.125)
			local Flight = Tween:Get()
			assert(Flight > 0 and Flight < 100, "tween must start after delay")
			Tween:Set(200)
			Clock.Step(0.0625, 0.0625)
			assert(Tween:Get() > Flight, "mid-flight retarget progresses without another delay")
			Tween:Destroy()
		end,
	},
	{
		Name = "the tween completes within floating-point deadline tolerance",
		Run = function()
			local Tween = Interfacer.Tween(0, Compatibility.TweenInfo.new(0.125))
			Tween:Set(100)
			Clock.Step(0.125 - 1e-10, 0.125)
			local Record = assert(MotionModule.NodeToMotion[Tween])
			assert(not MotionModule.Engine.IsActive(Record) and Tween:Get() == 100, "tween stayed active at its rounded completion boundary")
			Tween:Destroy()
		end,
	},
	{
		Name = "retargeting a spring preserves position and momentum",
		Run = function()
			local Spring = Interfacer.Spring(0, 2, 0.5)
			Spring:Set(100)
			Clock.Step(0.0625, 0.0625)
			local Position = Spring:Get()
			assert(Position > 0 and Position < 100, "spring should be moving")
			Spring:Set(Position)
			assert(Spring:Get() == Position, "retarget snapped current position")
			Clock.Step(0.001, 0.001)
			assert(Spring:Get() > Position, "retarget discarded velocity")
			Spring:Destroy()
		end,
	},
}

local WasManual = Clock.IsManual()
Clock.Manual(true)
local Failures = 0
for _, Case in Cases do
	Clock.Reset()
	local Passed, Result = pcall(Case.Run)
	if Passed then
		print("PASS " .. Case.Name)
	else
		Failures += 1
		print("FAIL " .. Case.Name .. ": " .. tostring(Result))
	end
end
Clock.Reset()
if not WasManual then
	Clock.Manual(false)
end
assert(Failures == 0, tostring(Failures) .. " clock and motion cases failed")
print("FLUX V052 CLOCK MOTION PASS")
