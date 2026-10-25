--!strict

local IsRoblox = game ~= nil

export type Phase = "PreRender" | "RenderStepped" | "Heartbeat"

const UnixEpoch = 1767225600
const TimeTolerance = 1e-9
const DrainLimit = 10000

local ReadSystemClock = os.clock
local EngineTaskLibrary = task
local RunService : RunService = if IsRoblox then game:GetService("RunService") else nil :: any

local IsManualClock = not IsRoblox
local VirtualNow = 0

type Timer = {
	Due : number,
	Sequence : number,
	Thread : thread,
	Start : number?,
	Arguments : { any }?,
	Cancelled : boolean?,
}

type Deferred = {
	Thread : thread,
	Arguments : { any }?,
	Cancelled : boolean?,
}

local Heap : { Timer } = {}
local SequenceNumber = 0
local TimersByThread : { [thread] : Timer } = {}

local Queue : { Deferred } = {}
local Head, Tail = 1, 0
local DeferredByThread : { [thread] : Deferred } = {}

local Render : { (DeltaTime : number) -> () } = {}
local Heartbeat : { (DeltaTime : number) -> () } = {}

local FrameHook : ((DeltaTime : number) -> ())? = nil
local Report : (...any) -> () = if IsRoblox then warn else print

const function Before(FirstValue : Timer, SecondValue : Timer) : boolean
	return FirstValue.Due < SecondValue.Due
		or (FirstValue.Due == SecondValue.Due and FirstValue.Sequence < SecondValue.Sequence)
end

const function Push(TimerRecord : Timer)
	local Index = #Heap + 1
	Heap[Index] = TimerRecord
	while Index > 1 do
		local Parent = Index // 2
		if not Before(Heap[Index], Heap[Parent]) then
			break
		end
		Heap[Index], Heap[Parent] = Heap[Parent], Heap[Index]
		Index = Parent
	end
end

const function Pop() : Timer
	local Top = Heap[1]
	local Last = table.remove(Heap) :: Timer
	local Size = #Heap
	if Size > 0 then
		Heap[1] = Last
		local Index = 1
		while true do
			local Left, Right, Smallest = Index * 2, Index * 2 + 1, Index
			if Left <= Size and Before(Heap[Left], Heap[Smallest]) then
				Smallest = Left
			end
			if Right <= Size and Before(Heap[Right], Heap[Smallest]) then
				Smallest = Right
			end
			if Smallest == Index then
				break
			end
			Heap[Index], Heap[Smallest] = Heap[Smallest], Heap[Index]
			Index = Smallest
		end
	end
	return Top
end

const function Resume(CoroutineThread : thread, ... : any)
	if coroutine.status(CoroutineThread) ~= "suspended" then
		return
	end
	if IsRoblox then
		EngineTaskLibrary.spawn(CoroutineThread, ...)
		return
	end
	local Passed, Failure = coroutine.resume(CoroutineThread, ...)
	if not Passed then
		Report(
			debug.traceback(CoroutineThread, `[Flux] Clock: error in a resumed thread: {Failure}`)
		)
	end
end

const function ResumeWithArguments(CoroutineThread : thread, Arguments : any)
	if Arguments then
		Resume(CoroutineThread, table.unpack(Arguments, 1, Arguments.n))
	else
		Resume(CoroutineThread)
	end
end

const function ToThread(FunctionOrThread : any) : thread
	return if type(FunctionOrThread) == "thread"
		then FunctionOrThread
		else coroutine.create(FunctionOrThread)
end

const function ScheduleTimer(
	Seconds : number?,
	CoroutineThread : thread,
	Start : number?,
	Arguments : { any }?
)
	SequenceNumber += 1
	local TimerRecord : Timer = {
		Due = VirtualNow + math.max(Seconds or 0, 0),
		Sequence = SequenceNumber,
		Thread = CoroutineThread,
		Start = Start,
		Arguments = Arguments,
	}
	TimersByThread[CoroutineThread] = TimerRecord
	Push(TimerRecord)
end

const function CanWait() : boolean
	if not coroutine.isyieldable() then
		return false
	elseif IsRoblox then
		return true
	end
	local Level = 2
	local Bottom : ((...any) -> ...any)? = nil
	while true do
		local Callback = debug.info(Level, "f")
		if Callback == nil then
			break
		end
		Bottom = Callback
		Level += 1
	end
	if Bottom == nil or debug.info(Bottom :: (...any) -> ...any, "s") == "[C]" then
		return true
	end
	local Parameters, Vararg = debug.info(Bottom :: (...any) -> ...any, "a")
	return not (debug.info(Bottom :: (...any) -> ...any, "l") <= 1 and Parameters == 0 and Vararg)
end

local Clock = {}

function Clock.Now() : number
	return if IsManualClock then VirtualNow else ReadSystemClock()
end

function Clock.Wall() : number
	if IsManualClock then
		return UnixEpoch + VirtualNow
	end
	return if IsRoblox then workspace:GetServerTimeNow() else os.time()
end

const function Pack(... : any) : { any }?
	return if select("#", ...) > 0 then table.pack(...) :: any else nil
end

function Clock.Delay<CallbackArguments...>(
	Seconds : number?,
	Callback : ((CallbackArguments...) -> ...any) | thread,
	... : CallbackArguments...
) : thread
	if not IsManualClock then
		return EngineTaskLibrary.delay(Seconds, Callback :: any, ...)
	end
	local CoroutineThread = ToThread(Callback)
	ScheduleTimer(Seconds, CoroutineThread, nil, Pack(...))
	return CoroutineThread
end

function Clock.Wait(Seconds : number?) : number
	if not IsManualClock then
		return EngineTaskLibrary.wait(Seconds)
	end
	local CoroutineThread = coroutine.running()
	if not CanWait() then
		error(
			"Clock.wait on a manual clock needs a yieldable coroutine; run it in a thread a step can resume",
			2
		)
	end
	ScheduleTimer(Seconds, CoroutineThread, VirtualNow, nil)
	return coroutine.yield()
end

function Clock.Defer<CallbackArguments...>(
	Callback : ((CallbackArguments...) -> ...any) | thread,
	... : CallbackArguments...
) : thread
	if not IsManualClock then
		return EngineTaskLibrary.defer(Callback :: any, ...)
	end
	local CoroutineThread = ToThread(Callback)
	local Entry : Deferred = { Thread = CoroutineThread, Arguments = Pack(...) }
	DeferredByThread[CoroutineThread] = Entry
	Tail += 1
	Queue[Tail] = Entry
	return CoroutineThread
end

function Clock.Cancel(CoroutineThread : thread)
	if not IsManualClock then
		EngineTaskLibrary.cancel(CoroutineThread)
		return
	end
	local TimerRecord = TimersByThread[CoroutineThread]
	if TimerRecord then
		TimerRecord.Cancelled = true
		TimerRecord.Arguments = nil
		TimersByThread[CoroutineThread] = nil
	end
	local Entry = DeferredByThread[CoroutineThread]
	if Entry then
		Entry.Cancelled = true
		Entry.Arguments = nil
		DeferredByThread[CoroutineThread] = nil
	end
	if IsRoblox then
		EngineTaskLibrary.cancel(CoroutineThread)
	elseif coroutine.status(CoroutineThread) == "suspended" then
		coroutine.close(CoroutineThread)
	end
end

function Clock.Connect(PhaseName : Phase, Callback : (DeltaTime : number) -> ()) : () -> ()
	local List = if PhaseName == "Heartbeat"
		then Heartbeat
		elseif PhaseName == "PreRender" or PhaseName == "RenderStepped" then Render
		else error(
			`Clock.connect: unknown phase "{PhaseName}" (PreRender, RenderStepped or Heartbeat)`,
			2
		)
	if not IsManualClock then
		local Connection = (RunService :: any)[PhaseName]:Connect(Callback)
		return function()
			Connection:Disconnect()
		end
	end
	local Entry = function(DeltaTime : number)
		Callback(DeltaTime)
	end
	table.insert(List, Entry)
	return function()
		local Index = table.find(List, Entry)
		if Index then
			table.remove(List, Index)
		end
	end
end

function Clock.Manual(On : boolean)
	if not IsRoblox or On == IsManualClock then
		return
	end
	if On then
		VirtualNow = math.max(VirtualNow, ReadSystemClock())
		IsManualClock = true
	else
		Clock.Reset()
		IsManualClock = false
	end
end

function Clock.IsManual() : boolean
	return IsManualClock
end

function Clock.Drain()
	local Count = 0
	while Head <= Tail do
		Count += 1
		if Count > DrainLimit then
			table.clear(Queue)
			table.clear(DeferredByThread)
			Head, Tail = 1, 0
			error(`Clock.drain: deferred work did not settle after {DrainLimit} calls`, 2)
		end
		local Entry = Queue[Head]
		Queue[Head] = nil
		Head += 1
		if not Entry.Cancelled then
			if DeferredByThread[Entry.Thread] == Entry then
				DeferredByThread[Entry.Thread] = nil
			end
			ResumeWithArguments(Entry.Thread, Entry.Arguments)
		end
	end
	Head, Tail = 1, 0
end

const function RunFrame(DeltaTime : number)
	local Last = SequenceNumber
	while
		Heap[1] ~= nil
		and Heap[1].Due <= VirtualNow + TimeTolerance
		and Heap[1].Sequence <= Last
	do
		local TimerRecord = Pop()
		if not TimerRecord.Cancelled then
			if TimersByThread[TimerRecord.Thread] == TimerRecord then
				TimersByThread[TimerRecord.Thread] = nil
			end
			if TimerRecord.Start then
				Resume(TimerRecord.Thread, VirtualNow - TimerRecord.Start)
			else
				ResumeWithArguments(TimerRecord.Thread, TimerRecord.Arguments)
			end
		end
	end
	Clock.Drain()
	if #Render > 0 then
		for _, Subscriber in table.clone(Render) do
			Subscriber(DeltaTime)
		end
		Clock.Drain()
	end
	if FrameHook then
		FrameHook(DeltaTime)
		Clock.Drain()
	end
	if #Heartbeat > 0 then
		for _, Subscriber in table.clone(Heartbeat) do
			Subscriber(DeltaTime)
		end
		Clock.Drain()
	end
end

function Clock.Step(Seconds : number, FrameLength : number?)
	if not IsManualClock then
		error("Clock.step needs a manual clock; call Clock.manual(true) first", 2)
	end
	local Length = FrameLength or 1 / 60
	assert(Seconds >= 0, "Clock.step: seconds must not be negative")
	assert(Length > 0, "Clock.step: the frame length must be positive")
	local Start = VirtualNow
	local Frames = math.max(math.ceil(Seconds / Length - TimeTolerance), 1)
	for Index = 1, Frames do
		local Target = if Index == Frames then Start + Seconds else Start + Index * Length
		local DeltaTime = Target - VirtualNow
		VirtualNow = Target
		RunFrame(DeltaTime)
	end
end

function Clock.Reset()
	table.clear(Heap)
	table.clear(TimersByThread)
	table.clear(Queue)
	table.clear(DeferredByThread)
	Head, Tail = 1, 0
	table.clear(Render)
	table.clear(Heartbeat)
end

Clock.Internal = table.freeze({
	SetFrame = function(Callback : ((DeltaTime : number) -> ())?)
		FrameHook = Callback
	end,
	SetReport = function(Callback : (Message : string) -> ())
		Report = Callback
	end,
	Spawn = function(FunctionOrThread : any, ... : any) : thread
		local CoroutineThread = ToThread(FunctionOrThread)
		Resume(CoroutineThread, ...)
		return CoroutineThread
	end,
})

return table.freeze(Clock)
