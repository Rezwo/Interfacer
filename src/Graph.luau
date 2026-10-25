--!strict

const Compatibility = require("./Compatibility")

local IsRoblox = Compatibility.IsRoblox
local CompatibleTypeOf = Compatibility.TypeOf
local TaskLibrary = Compatibility.Task
local FormatTraceback = Compatibility.Traceback
local ReportWarning = Compatibility.Warn

export type Destroyable =
	{ Destroy : (Self : any) -> () }
	| { destroy : (Self : any) -> () }
	| { Disconnect : (Self : any) -> () }
	| { disconnect : (Self : any) -> () }

export type Cleanable =
	(() -> ())
	| ((OldValue : any) -> ())
	| ((OldValue : any, Destroyed : boolean) -> ())
	| thread
	| Instance
	| RBXScriptConnection
	| { read Destroy : (Self : any) -> () }
	| { read destroy : (Self : any) -> () }
	| { read Disconnect : (Self : any) -> () }
	| { read disconnect : (Self : any) -> () }
	| { read [number] : Cleanable }

const function KindOf(Value : any) : string
	local Kind = typeof(Value)
	if Kind == "table" and not IsRoblox then
		return CompatibleTypeOf(Value)
	end
	return Kind
end

local DestroyInstance : (SourceHandle : Instance) -> () = if IsRoblox
	then (game :: any).Destroy
	else function(SourceHandle : Instance)
		SourceHandle:Destroy()
	end

local DisposeTable : (Object : any) -> ()

local Registry : { [any] : (Object : any) -> () } = setmetatable({}, { __mode = "k" }) :: any

const function RegisterCleanupStrategy(Object : { [any] : any }, Teardown : ((Object : any) -> ())?)
	Registry[Object] = Teardown
end

const function TeardownOf(Object : any) : ((Object : any) -> ())?
	return if type(Object.Destroy) == "function"
		then Object.Destroy
		elseif type(Object.destroy) == "function" then Object.destroy
		elseif type(Object.Disconnect) == "function" then Object.Disconnect
		elseif type(Object.disconnect) == "function" then Object.disconnect
		else nil
end

const function Protect(Kind : string, Callback : (...any) -> ...any, ... : any) : boolean
	local Passed, Failure = xpcall(Callback, FormatTraceback, ...)
	if not Passed then
		ReportWarning(`[Flux] {Kind} error:\n{Failure}`)
	end
	return Passed
end

const function DisposeCleanable(Object : any)
	local Kind = KindOf(Object)
	if Kind == "function" then
		Protect("cleanup", Object :: any)
	elseif Kind == "table" then
		local Teardown : (Object : any) -> () = Registry[Object] or DisposeTable
		Protect("cleanup", Teardown, Object)
	elseif Kind == "Instance" then
		pcall(DestroyInstance, Object :: Instance)
	elseif Kind == "RBXScriptConnection" then
		local Connection = Object :: RBXScriptConnection
		if Connection.Connected then
			Connection:Disconnect()
		end
	elseif Kind == "thread" then
		if coroutine.status(Object :: thread) == "suspended" then
			pcall(TaskLibrary.cancel, Object :: thread)
		end
	end
end

function DisposeTable(Object : any)
	local Method = TeardownOf(Object)
	if Method ~= nil then
		Method(Object)
	elseif Object[1] ~= nil then
		for _, Item in Object do
			DisposeCleanable(Item)
		end
	end
end

const function IsCleanupValue(Object : any) : boolean
	local Kind = KindOf(Object)
	if Kind == "table" then
		return Registry[Object] ~= nil
			or TeardownOf(Object) ~= nil
			or Object[1] ~= nil
			or next(Object) == nil
	end
	return Kind == "function"
		or Kind == "Instance"
		or Kind == "RBXScriptConnection"
		or Kind == "thread"
end

type GraphRecord = any

const ValueSlot = 1
const ObserversSlot = 2
const SeenSlot = 3
const ChangedSlot = 4
const HeightSlot = 5
const StampSlot = 6
const CalculationSlot = 7
const SourceEndSlot = 8
const NextSlot = 9
const ChildrenSlot = 10
const FirstSourceSlot = 11
const SignalObserverOffset = 5

const EffectSourceEndSlot = 2
const EffectCalculationSlot = 3
const EffectChildrenSlot = 4
const EffectFirstSourceSlot = 7

const Infinity = math.huge
const ScopeHeight = -1
const DeferredStamp = -1
const StaleStamp = -2
const ErroredStamp = -3
const IdleLiveHeight = -4
const LiveStampBase = -1073741824

local Epoch = 1

local Failed : { [any] : true } = setmetatable({}, { __mode = "k" }) :: any
local FailedCount = 0

local Heap : { any } = table.create(64, false)
local MinimumHeapHeight = Infinity
local MaximumLiveHeightLimit = IdleLiveHeight
local MaximumHeapHeight = 0

local Queue : { any } = {}
local QueueHead = 1
local QueueTail = 0
local Flushing = false

const RerunLimit = 100
const GuardPasses = 32
local Passes = 0
local Counted = 0
local Reruns : { [any] : number } = {}
local Cycles : { [any] : number } = {}
local AnyReruns = false

local CurrentComputationRecord : any = nil
local CurrentDependencyCursor = 0
local CurrentNewDependencies : { any }? = nil
const DivergedIndex = 5
const DisposedSourceEnd = 2 ^ 30
local CurrentEvaluationRun = 0
local RunIdentifierCounter = 0

local CurrentOwnerRecord : any = nil
local OwnerSet = false

local SuspendedComputationRecord : any = nil
local SuspendedEvaluationRun = 0

local EvaluatingComputationRecord : any = nil
local RunningEffect : any = nil

type ContextFrame = { Parent : ContextFrame?, Key : any, Value : any }
local CurrentContextFrame : ContextFrame? = nil

local AnyHooks = false
local AnyDestroys = false
local AnyCleanups = false
local AnySigEquals = false
local OwnExtra = false

const function IsTrackingComputation() : boolean
	return CurrentComputationRecord ~= nil
end

const function HasObservers(GraphRecord : any) : boolean
	local Inner = GraphRecord[1]
	local HeightValue = Inner[HeightSlot]
	if HeightValue == nil then
		local Count = Inner[ObserversSlot]
		return Count ~= nil and Count > 0
	elseif HeightValue == Infinity or HeightValue == ScopeHeight then
		return false
	end
	local Observer = Inner[ObserversSlot]
	return Observer ~= nil and Observer ~= false
end

const function InsertIntoCalculationHeap(GraphRecord : any)
	if not GraphRecord[NextSlot] then
		local HeightValue = GraphRecord[HeightSlot]
		GraphRecord[NextSlot] = Heap[HeightValue] or true
		Heap[HeightValue] = GraphRecord
		if HeightValue < MinimumHeapHeight then
			MinimumHeapHeight = HeightValue
			MaximumLiveHeightLimit = HeightValue + LiveStampBase
		end
		if HeightValue > MaximumHeapHeight then
			MaximumHeapHeight = HeightValue
		end
	end
end

const function WasSourceReadThisRun(ReactionRecord : any, SourceRecord : any) : boolean
	if SourceRecord[SeenSlot] == CurrentEvaluationRun then
		return true
	end
	local Base = if ReactionRecord[HeightSlot] == Infinity
		then EffectFirstSourceSlot
		else FirstSourceSlot
	local Last = if CurrentDependencyCursor == DivergedIndex
		then (CurrentNewDependencies :: any)[1]
		else CurrentDependencyCursor
	for IndexValue = Base, Last - 2, 2 do
		if ReactionRecord[IndexValue] == SourceRecord then
			return true
		end
	end
	return false
end

const function MarkObserver(ObserverRecord : any)
	if ObserverRecord[StampSlot] ~= 0 then
		ObserverRecord[StampSlot] = 0
		local HeightValue = ObserverRecord[HeightSlot]
		if HeightValue == Infinity then
			QueueTail += 1
			Queue[QueueTail] = ObserverRecord
		elseif not ObserverRecord[NextSlot] then
			ObserverRecord[NextSlot] = Heap[HeightValue] or true
			Heap[HeightValue] = ObserverRecord
			if HeightValue < MinimumHeapHeight then
				MinimumHeapHeight = HeightValue
				MaximumLiveHeightLimit = HeightValue + LiveStampBase
			end
			if HeightValue > MaximumHeapHeight then
				MaximumHeapHeight = HeightValue
			end
		end
	end
end

local SelfWritten : any = nil

const function DeferActiveComputation(Entry : any, SourceRecord : any)
	if CurrentComputationRecord == nil and not WasSourceReadThisRun(Entry, SourceRecord) then
		return
	end
	SelfWritten = Entry
end

const function MarkObservers(StateValue : any, Count : number)
	local ReactionRecord = CurrentComputationRecord
	for IndexValue = 6, Count + SignalObserverOffset do
		local ObserverRecord = StateValue[IndexValue]
		if ObserverRecord ~= ReactionRecord then
			if ObserverRecord == RunningEffect then
				DeferActiveComputation(ObserverRecord, StateValue)
			else
				MarkObserver(ObserverRecord)
			end
		end
	end
end

const function MarkObserverList(GraphRecord : any, Observer : any)
	local ReactionRecord = CurrentComputationRecord
	if type(Observer[HeightSlot]) == "number" then
		if Observer ~= ReactionRecord then
			if Observer == RunningEffect then
				DeferActiveComputation(Observer, GraphRecord)
			else
				MarkObserver(Observer)
			end
		end
		return
	end
	for IndexValue = 2, Observer[1] do
		local ObserverRecord = Observer[IndexValue]
		if ObserverRecord ~= ReactionRecord then
			if ObserverRecord == RunningEffect then
				DeferActiveComputation(ObserverRecord, GraphRecord)
			else
				MarkObserver(ObserverRecord)
			end
		end
	end
end

const function MarkActiveComputation(GraphRecord : any)
	local ReactionRecord = CurrentComputationRecord
	if ReactionRecord and WasSourceReadThisRun(ReactionRecord, GraphRecord) then
		if ReactionRecord[HeightSlot] == Infinity then
			SelfWritten = ReactionRecord
		else
			MarkObserver(ReactionRecord)
		end
	end
end

const function RaiseComputationHeight(GraphRecord : any, HeightValue : number)
	GraphRecord[HeightSlot] = HeightValue
	if GraphRecord[StampSlot] <= IdleLiveHeight then
		GraphRecord[StampSlot] = HeightValue + LiveStampBase
	end
	local Observer = GraphRecord[ObserversSlot]
	if Observer then
		local ObserverHeight = Observer[HeightSlot]
		if type(ObserverHeight) == "number" then
			if ObserverHeight <= HeightValue then
				RaiseComputationHeight(Observer, HeightValue + 1)
			end
			return
		end
		for IndexValue = 2, Observer[1] do
			local ObserverRecord = Observer[IndexValue]
			if ObserverRecord[HeightSlot] <= HeightValue then
				RaiseComputationHeight(ObserverRecord, HeightValue + 1)
			end
		end
	end
end

const function FireHook(Count : any, Which : number)
	local HeightValue = Count.Hooks
	local FunctionValue = HeightValue and HeightValue[Which]
	if FunctionValue then
		Protect(if Which == 1 then "onObserved" else "onUnobserved", FunctionValue)
	end
end

const function RepairObserverBacklink(
	Moved : any,
	SourceRecord : any,
	PreviousConnectionIndex : number,
	OtherIndex : number
)
	local Base, SourceCountSlot = FirstSourceSlot, SourceEndSlot
	if Moved[HeightSlot] == Infinity then
		Base, SourceCountSlot = EffectFirstSourceSlot, EffectSourceEndSlot
	end
	for IndexValue = Base, Moved[SourceCountSlot] - 2, 2 do
		if
			Moved[IndexValue] == SourceRecord
			and Moved[IndexValue + 1] == PreviousConnectionIndex
		then
			Moved[IndexValue + 1] = OtherIndex
			return
		end
	end
end

local OldTail : { any } = {}
local TailBusy = false
local FreeNew : { any }? = {}

local ActivateComputation : (any, any) -> ()
local DeactivateComputation : (any) -> ()

const function SubscribeObserver(SourceRecord : any, ObserverRecord : any) : number
	local SourceHeight = SourceRecord[HeightSlot]
	if not SourceHeight then
		local InitialCount = SourceRecord[ObserversSlot]
		if InitialCount == nil then
			return 0
		end
		local Count = InitialCount + 1
		SourceRecord[ObserversSlot] = Count
		SourceRecord[Count + SignalObserverOffset] = ObserverRecord
		if AnyHooks and Count == 1 then
			FireHook(SourceRecord, 1)
		end
		return Count
	end
	local List = SourceRecord[ObserversSlot]
	local Count
	if List == nil then
		return 0
	elseif not List then
		Count = 2
		ActivateComputation(SourceRecord, ObserverRecord)
		SourceHeight = SourceRecord[HeightSlot]
	elseif type(List[HeightSlot]) == "number" then
		SourceRecord[ObserversSlot] = { 3, List, ObserverRecord }
		Count = 3
	else
		Count = List[1] + 1
		List[1] = Count
		List[Count] = ObserverRecord
	end
	if SourceHeight >= ObserverRecord[HeightSlot] then
		if ObserverRecord[ObserversSlot] then
			RaiseComputationHeight(ObserverRecord, SourceHeight + 1)
		else
			ObserverRecord[HeightSlot] = SourceHeight + 1
		end
	end
	return Count
end

const function UnsubscribeObserver(SourceRecord : any, ObserverRecord : any, OtherIndex : number)
	local HeightValue = SourceRecord[HeightSlot]
	if not HeightValue then
		local Count = SourceRecord[ObserversSlot]
		if Count == nil then
			return
		end
		local Last = Count + SignalObserverOffset
		if OtherIndex ~= Count then
			local Moved = SourceRecord[Last]
			SourceRecord[OtherIndex + SignalObserverOffset] = Moved
			RepairObserverBacklink(Moved, SourceRecord, Count, OtherIndex)
		end
		SourceRecord[Last] = nil
		SourceRecord[ObserversSlot] = Count - 1
		if AnyHooks and Count == 1 then
			FireHook(SourceRecord, 2)
		end
		return
	end
	local List = SourceRecord[ObserversSlot]
	if List == ObserverRecord then
		SourceRecord[ObserversSlot] = false
		DeactivateComputation(SourceRecord)
		return
	elseif not List or type(List[HeightSlot]) == "number" then
		return
	end
	local Count = List[1]
	if OtherIndex ~= Count then
		local Moved = List[Count]
		List[OtherIndex] = Moved
		RepairObserverBacklink(Moved, SourceRecord, Count, OtherIndex)
	end
	List[Count] = nil
	if Count == 2 then
		SourceRecord[ObserversSlot] = false
		DeactivateComputation(SourceRecord)
	else
		List[1] = Count - 1
	end
end

function ActivateComputation(GraphRecord : any, ObserverRecord : any)
	if AnyHooks then
		GraphRecord[ObserversSlot] = ObserverRecord
	end
	local Last = GraphRecord[SourceEndSlot] - 2
	for IndexValue = FirstSourceSlot, Last, 2 do
		local SourceRecord = GraphRecord[IndexValue]
		if not SourceRecord[HeightSlot] then
			local InitialCount = SourceRecord[ObserversSlot]
			if InitialCount then
				local Count = InitialCount + 1
				SourceRecord[ObserversSlot] = Count
				SourceRecord[Count + SignalObserverOffset] = GraphRecord
				GraphRecord[IndexValue + 1] = Count
				if AnyHooks and Count == 1 then
					FireHook(SourceRecord, 1)
				end
			else
				GraphRecord[IndexValue + 1] = 0
			end
		else
			GraphRecord[IndexValue + 1] = SubscribeObserver(SourceRecord, GraphRecord)
		end
	end
	GraphRecord[ObserversSlot] = ObserverRecord
	local StampValue = GraphRecord[StampSlot]
	if StampValue == Epoch then
		GraphRecord[StampSlot] = GraphRecord[HeightSlot] + LiveStampBase
	elseif StampValue ~= StaleStamp and StampValue ~= ErroredStamp then
		local Dirty = StampValue == 0 or StampValue == DeferredStamp
		if not Dirty then
			for IndexValue = FirstSourceSlot, Last, 2 do
				local ChildRecord = GraphRecord[IndexValue][ChangedSlot]
				if ChildRecord == nil or ChildRecord > StampValue then
					Dirty = true
					break
				end
			end
		end
		if Dirty then
			GraphRecord[StampSlot] = 0
			Epoch += 1
			InsertIntoCalculationHeap(GraphRecord)
		end
	end
	if AnyHooks then
		FireHook(GraphRecord, 1)
	end
end

function DeactivateComputation(GraphRecord : any)
	for IndexValue = GraphRecord[SourceEndSlot] - 2, FirstSourceSlot, -2 do
		local SourceRecord, OtherIndex = GraphRecord[IndexValue], GraphRecord[IndexValue + 1]
		local Observer = SourceRecord[ObserversSlot]
		if Observer == OtherIndex and not AnyHooks then
			SourceRecord[OtherIndex + SignalObserverOffset] = nil
			SourceRecord[ObserversSlot] = OtherIndex - 1
		elseif Observer == GraphRecord then
			SourceRecord[ObserversSlot] = false
			DeactivateComputation(SourceRecord)
		else
			UnsubscribeObserver(SourceRecord, GraphRecord, OtherIndex)
		end
	end
	local StampValue = GraphRecord[StampSlot]
	if
		StampValue <= MaximumLiveHeightLimit or (StampValue > 0 and MinimumHeapHeight == Infinity)
	then
		GraphRecord[StampSlot] = Epoch
	elseif StampValue <= IdleLiveHeight then
		Epoch += 1
		GraphRecord[StampSlot] = Epoch - 1
	elseif StampValue == DeferredStamp then
		GraphRecord[StampSlot] = 0
	elseif StampValue == ErroredStamp then
		GraphRecord[StampSlot] = StaleStamp
	end
	if AnyHooks then
		FireHook(GraphRecord, 2)
	end
end

const function ReconcileDependencies(
	GraphRecord : any,
	SourceCountSlot : number,
	Last : number,
	Index : number,
	NewList : any,
	Live : boolean
)
	if NewList then
		local NewCount = NewList[2]
		if not Live then
			local Key = Index
			for IndexValue = 3, NewCount do
				GraphRecord[Key] = NewList[IndexValue]
				NewList[IndexValue] = nil
				GraphRecord[Key + 1] = 0
				Key += 2
			end
			FreeNew = NewList
			for IndexValue = Key, Last - 1 do
				GraphRecord[IndexValue] = nil
			end
			GraphRecord[SourceCountSlot] = Key
			return
		end
		local OldCount = Last - Index
		if OldCount == 2 and NewCount == 3 then
			local OldSource = GraphRecord[Index]
			local OldBack = GraphRecord[Index + 1]
			local SourceRecord = NewList[3]
			NewList[3] = nil
			FreeNew = NewList
			GraphRecord[Index] = SourceRecord
			GraphRecord[Index + 1] = SubscribeObserver(SourceRecord, GraphRecord)
			UnsubscribeObserver(OldSource, GraphRecord, OldBack)
			if OldSource[ChildrenSlot] == false then
				OldSource[ChildrenSlot] = nil
			end
			return
		end
		local Tail : { any } = if TailBusy then {} else OldTail
		local WasBusy = TailBusy
		TailBusy = true
		table.move(GraphRecord, Index, Last - 1, 1, Tail)
		local Key = Index
		local PreviousSourceIndex = 1
		for IndexValue = 3, NewCount do
			local SourceRecord = NewList[IndexValue]
			NewList[IndexValue] = nil
			GraphRecord[Key] = SourceRecord
			local Back = 0
			local Hint = PreviousSourceIndex + 2
			if Hint <= OldCount and Tail[Hint] == SourceRecord then
				Back = Tail[Hint + 1]
				Tail[Hint] = false
				PreviousSourceIndex = Hint
			else
				for OtherIndex = 1, OldCount, 2 do
					if Tail[OtherIndex] == SourceRecord then
						Back = Tail[OtherIndex + 1]
						Tail[OtherIndex] = false
						PreviousSourceIndex = OtherIndex
						break
					end
				end
				if Back == 0 then
					Back = SubscribeObserver(SourceRecord, GraphRecord)
					if PreviousSourceIndex == 1 then
						PreviousSourceIndex = -1
					end
				end
			end
			GraphRecord[Key + 1] = Back
			Key += 2
		end
		FreeNew = NewList
		GraphRecord[SourceCountSlot] = Key
		for IndexValue = Key, Last - 1 do
			GraphRecord[IndexValue] = nil
		end
		for OtherIndex = OldCount - 1, 1, -2 do
			local SourceRecord = Tail[OtherIndex]
			if SourceRecord then
				Tail[OtherIndex] = false
				UnsubscribeObserver(SourceRecord, GraphRecord, Tail[OtherIndex + 1])
				if SourceRecord[ChildrenSlot] == false then
					SourceRecord[ChildrenSlot] = nil
				end
			end
		end
		TailBusy = WasBusy
	elseif Index > Last then
		if Live then
			for IndexValue = Last, Index - 2, 2 do
				GraphRecord[IndexValue + 1] =
					SubscribeObserver(GraphRecord[IndexValue], GraphRecord)
			end
		end
		GraphRecord[SourceCountSlot] = Index
	else
		for IndexValue = Last - 2, Index, -2 do
			local SourceRecord = GraphRecord[IndexValue]
			if Live then
				UnsubscribeObserver(SourceRecord, GraphRecord, GraphRecord[IndexValue + 1])
				if SourceRecord[ChildrenSlot] == false then
					SourceRecord[ChildrenSlot] = nil
				end
			end
			GraphRecord[IndexValue] = nil
			GraphRecord[IndexValue + 1] = nil
		end
		GraphRecord[SourceCountSlot] = Index
	end
end

local DisposedValue = {}

const function RemoveSource(ObserverRecord : any, SourceHandleValue : any)
	local Base, SourceCountSlot = FirstSourceSlot, SourceEndSlot
	if ObserverRecord[HeightSlot] == Infinity then
		Base, SourceCountSlot = EffectFirstSourceSlot, EffectSourceEndSlot
	end
	for IndexValue = Base, ObserverRecord[SourceCountSlot] - 2, 2 do
		if ObserverRecord[IndexValue] == SourceHandleValue then
			ObserverRecord[IndexValue] = DisposedValue
			return
		end
	end
end

local CallbackIndex = 0

const function RunCallbacks(Callbacks : { any }, From : number, OldValue : any, Destroyed : boolean)
	for IndexValue = From, #Callbacks do
		CallbackIndex = IndexValue
		local CallbackFunction = Callbacks[IndexValue]
		if type(CallbackFunction) == "function" then
			(CallbackFunction :: any)(OldValue, Destroyed)
		else
			DisposeCleanable(CallbackFunction)
		end
	end
end

const function RunProtected(Callbacks : { any }, OldValue : any, Destroyed : boolean, Kind : string)
	local PreviousEvaluatingNode, PreviousSuspended, PreviousOwner, PreviousOwnerSet, PreviousDependencyCursor =
		CurrentComputationRecord,
		SuspendedComputationRecord,
		CurrentOwnerRecord,
		OwnerSet,
		CallbackIndex
	local PreviousSuspendedRun = SuspendedEvaluationRun
	CurrentComputationRecord, SuspendedComputationRecord = nil, nil
	local From = 1
	while true do
		local Passed, Failure = (xpcall :: any)(
			RunCallbacks,
			FormatTraceback,
			Callbacks,
			From,
			OldValue,
			Destroyed
		)
		if Passed then
			break
		end
		ReportWarning(`[Flux] {Kind} error:\n{Failure}`)
		From = CallbackIndex + 1
	end
	CurrentComputationRecord, SuspendedComputationRecord, CurrentOwnerRecord, OwnerSet, CallbackIndex =
		PreviousEvaluatingNode,
		PreviousSuspended,
		PreviousOwner,
		PreviousOwnerSet,
		PreviousDependencyCursor
	SuspendedEvaluationRun = PreviousSuspendedRun
end

local DisposeOne : (any) -> ()

const function DisposeChildren(OwnerHandle : any, Slot : number, Value : any, Destroyed : boolean)
	local ChildRecord = OwnerHandle[Slot]
	OwnerHandle[Slot] = false
	if not AnyDestroys and not AnyHooks then
		for Key = ChildRecord[1], 2, -1 do
			local GraphRecord = ChildRecord[Key]
			if not GraphRecord[ObserversSlot] then
				if not GraphRecord[ChildrenSlot] and GraphRecord[CalculationSlot] then
					GraphRecord[CalculationSlot] = nil
					GraphRecord[SourceEndSlot] = DisposedSourceEnd
					GraphRecord[StampSlot] = IdleLiveHeight
					GraphRecord[ValueSlot] = nil
					GraphRecord[ObserversSlot] = nil
				else
					DisposeOne(GraphRecord)
				end
			elseif GraphRecord[HeightSlot] == Infinity and GraphRecord[EffectCalculationSlot] then
				GraphRecord[EffectCalculationSlot] = nil
				GraphRecord[StampSlot] = Infinity
				if GraphRecord[EffectChildrenSlot] then
					DisposeChildren(GraphRecord, EffectChildrenSlot, nil, true)
				end
				for IndexValue = GraphRecord[EffectSourceEndSlot] - 2, EffectFirstSourceSlot, -2 do
					local SourceRecord, OtherIndex =
						GraphRecord[IndexValue], GraphRecord[IndexValue + 1]
					local Observer = SourceRecord[ObserversSlot]
					if Observer == OtherIndex then
						SourceRecord[OtherIndex + SignalObserverOffset] = nil
						SourceRecord[ObserversSlot] = OtherIndex - 1
					elseif Observer == GraphRecord then
						SourceRecord[ObserversSlot] = false
						DeactivateComputation(SourceRecord)
					else
						UnsubscribeObserver(SourceRecord, GraphRecord, OtherIndex)
					end
				end
				GraphRecord[EffectSourceEndSlot] = DisposedSourceEnd
			else
				DisposeOne(GraphRecord)
			end
		end
	else
		for Key = ChildRecord[1], 2, -1 do
			DisposeOne(ChildRecord[Key])
		end
	end
	if AnyCleanups then
		local CleanupCallbacks = ChildRecord.CleanupCallbacks
		if CleanupCallbacks then
			RunProtected(CleanupCallbacks, Value, Destroyed, "cleanup")
		end
	end
end

function DisposeOne(GraphRecord : any)
	local HeightValue = GraphRecord[HeightSlot]
	if HeightValue == nil then
		local Count = GraphRecord[ObserversSlot]
		if Count == nil then
			return
		end
		for IndexValue = 6, Count + SignalObserverOffset do
			RemoveSource(GraphRecord[IndexValue], GraphRecord)
		end
		local Destroys = AnyDestroys and GraphRecord.DestructionCallbacks
		local Value = GraphRecord[ValueSlot]
		local Owned = GraphRecord.OwnedReaction
		if Owned then
			GraphRecord.OwnedReaction = nil
			DisposeChildren({ Owned }, 1, Value, true)
		end
		table.clear(GraphRecord)
		if Destroys then
			RunProtected(Destroys, Value, true, "onDestroy")
		end
		return
	end
	local Value
	if HeightValue == Infinity then
		if GraphRecord[EffectCalculationSlot] == nil then
			return
		end
		GraphRecord[EffectCalculationSlot] = nil
		GraphRecord[StampSlot] = Infinity
		if GraphRecord[EffectChildrenSlot] then
			DisposeChildren(GraphRecord, EffectChildrenSlot, nil, true)
		end
		for IndexValue = GraphRecord[EffectSourceEndSlot] - 2, EffectFirstSourceSlot, -2 do
			UnsubscribeObserver(GraphRecord[IndexValue], GraphRecord, GraphRecord[IndexValue + 1])
		end
		GraphRecord[EffectSourceEndSlot] = DisposedSourceEnd
	elseif HeightValue == ScopeHeight then
		if GraphRecord[CalculationSlot] == false then
			return
		end
		GraphRecord[CalculationSlot] = false
		if GraphRecord[ChildrenSlot] then
			DisposeChildren(GraphRecord, ChildrenSlot, nil, true)
		end
	else
		if GraphRecord[CalculationSlot] == nil then
			return
		end
		GraphRecord[CalculationSlot] = nil
		GraphRecord[StampSlot] = IdleLiveHeight
		Value = GraphRecord[ValueSlot]
		if GraphRecord[ChildrenSlot] then
			DisposeChildren(GraphRecord, ChildrenSlot, Value, true)
		end
		local Observer = GraphRecord[ObserversSlot]
		if Observer then
			if type(Observer[HeightSlot]) == "number" then
				RemoveSource(Observer, GraphRecord)
			else
				for IndexValue = 2, Observer[1] do
					RemoveSource(Observer[IndexValue], GraphRecord)
				end
			end
			GraphRecord[ObserversSlot] = false
			for IndexValue = GraphRecord[SourceEndSlot] - 2, FirstSourceSlot, -2 do
				UnsubscribeObserver(
					GraphRecord[IndexValue],
					GraphRecord,
					GraphRecord[IndexValue + 1]
				)
			end
			if AnyHooks then
				FireHook(GraphRecord, 2)
			end
		end
		GraphRecord[SourceEndSlot] = DisposedSourceEnd
		GraphRecord[ValueSlot] = nil
		GraphRecord[ObserversSlot] = nil
	end
	if AnyDestroys then
		local Destroys = GraphRecord.DestructionCallbacks
		if Destroys then
			RunProtected(Destroys, Value, true, "onDestroy")
		end
	end
end

const function DrainPendingDisposals(ObserverRecord : any)
	local HeightValue = ObserverRecord[HeightSlot]
	if HeightValue == nil then
		local Owned = ObserverRecord.OwnedReaction
		if Owned then
			ObserverRecord.OwnedReaction = nil
			DisposeChildren({ Owned }, 1, nil, true)
		end
		return
	end
	local Slot = if HeightValue == Infinity then EffectChildrenSlot else ChildrenSlot
	if ObserverRecord[Slot] then
		DisposeChildren(ObserverRecord, Slot, nil, true)
	end
end

const function NotifyObservers(Observer : any)
	local ActiveComputation, EvaluatingComputation, ActiveEffect =
		CurrentComputationRecord, EvaluatingComputationRecord, RunningEffect
	if type(Observer[HeightSlot]) == "number" then
		if
			Observer ~= ActiveComputation
			and Observer ~= EvaluatingComputation
			and Observer ~= ActiveEffect
		then
			MarkObserver(Observer)
		end
	else
		for IndexValue = 2, Observer[1] do
			local ObserverRecord = Observer[IndexValue]
			if
				ObserverRecord ~= ActiveComputation
				and ObserverRecord ~= EvaluatingComputation
				and ObserverRecord ~= ActiveEffect
			then
				MarkObserver(ObserverRecord)
			end
		end
	end
end

const function MarkChanged(GraphRecord : any)
	Epoch += 1
	GraphRecord[ChangedSlot] = Epoch
	local Observer = GraphRecord[ObserversSlot]
	if Observer then
		NotifyObservers(Observer)
	end
end

const function FinishErrored(GraphRecord : any, Index : number, NewList : any, Failure : any)
	if NewList then
		Index = NewList[1]
	end
	local HeightValue = GraphRecord[HeightSlot]
	if HeightValue == Infinity then
		if GraphRecord[EffectCalculationSlot] then
			local Last = GraphRecord[EffectSourceEndSlot]
			if NewList or Index ~= Last then
				ReconcileDependencies(GraphRecord, EffectSourceEndSlot, Last, Index, NewList, true)
			end
		else
			DrainPendingDisposals(GraphRecord)
		end
		return
	end
	if not GraphRecord[CalculationSlot] then
		DrainPendingDisposals(GraphRecord)
		return
	end
	local Live = GraphRecord[ObserversSlot] ~= false
	local Last = GraphRecord[SourceEndSlot]
	if NewList or Index ~= Last then
		ReconcileDependencies(GraphRecord, SourceEndSlot, Last, Index, NewList, Live)
	end
	GraphRecord.Failure = Failure
	GraphRecord[StampSlot] = if GraphRecord[ObserversSlot] then ErroredStamp else StaleStamp
	MarkChanged(GraphRecord)
	if not Failed[GraphRecord] then
		FailedCount += 1
	end
	Failed[GraphRecord] = GraphRecord[ChangedSlot]
end

const function Unfail(GraphRecord : any) : boolean
	local At = Failed[GraphRecord]
	if At == nil then
		return false
	end
	Failed[GraphRecord] = nil
	FailedCount -= 1
	return At == GraphRecord[ChangedSlot]
end

const function Healed(GraphRecord : any)
	MarkChanged(GraphRecord)
	GraphRecord[StampSlot] = Epoch
end

const function RunComputed(GraphRecord : any)
	local Deferred = GraphRecord[StampSlot] == DeferredStamp
	GraphRecord[StampSlot] = Epoch
	if GraphRecord[ChildrenSlot] then
		DisposeChildren(GraphRecord, ChildrenSlot, GraphRecord[ValueSlot], false)
	end
	local PreviousEvaluatingNode, PreviousDependencyIndex, PreviousNewSources, PreviousRun, PreviousEvaluatingRecord =
		CurrentComputationRecord,
		CurrentDependencyCursor,
		CurrentNewDependencies,
		CurrentEvaluationRun,
		EvaluatingComputationRecord
	local HadExtra = OwnExtra
	local PreviousSuspended, PreviousSuspendedRun, PreviousContext, PreviousOwnerSet
	if HadExtra then
		PreviousSuspended, PreviousSuspendedRun, PreviousContext, PreviousOwnerSet =
			SuspendedComputationRecord, SuspendedEvaluationRun, CurrentContextFrame, OwnerSet
		SuspendedComputationRecord, OwnerSet = nil, false
	end
	EvaluatingComputationRecord = GraphRecord
	do
		local RunIdentifier = RunIdentifierCounter + 1
		RunIdentifierCounter, CurrentEvaluationRun = RunIdentifier, RunIdentifier
	end
	CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies =
		GraphRecord, FirstSourceSlot, nil
	local PreviousDependency = GraphRecord[ValueSlot]
	local CreateNode = GraphRecord[CalculationSlot](PreviousDependency)
	local Index, NewList = CurrentDependencyCursor, CurrentNewDependencies
	CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies, CurrentEvaluationRun, EvaluatingComputationRecord =
		PreviousEvaluatingNode,
		PreviousDependencyIndex,
		PreviousNewSources,
		PreviousRun,
		PreviousEvaluatingRecord
	if HadExtra then
		SuspendedComputationRecord, SuspendedEvaluationRun, CurrentContextFrame, OwnerSet =
			PreviousSuspended, PreviousSuspendedRun, PreviousContext, PreviousOwnerSet
	elseif SuspendedComputationRecord then
		SuspendedComputationRecord = nil
		OwnExtra = CurrentContextFrame ~= nil
	end
	local Observer = GraphRecord[ObserversSlot]
	local Last = GraphRecord[SourceEndSlot]
	if Index ~= Last then
		if not Observer and Index > Last then
			GraphRecord[SourceEndSlot] = Index
		else
			if not GraphRecord[CalculationSlot] then
				GraphRecord[ValueSlot] = nil
				DrainPendingDisposals(GraphRecord)
				return
			end
			if NewList then
				Index = NewList[1]
			end
			ReconcileDependencies(
				GraphRecord,
				SourceEndSlot,
				Last,
				Index,
				NewList,
				Observer ~= false
			)
			Observer = GraphRecord[ObserversSlot]
		end
	end
	local SelfDirty = GraphRecord[StampSlot] == 0
	GraphRecord[StampSlot] = if Observer and GraphRecord[HeightSlot] <= MinimumHeapHeight
		then GraphRecord[HeightSlot] + LiveStampBase
		else Epoch
	if CreateNode ~= PreviousDependency then
		GraphRecord[ValueSlot] = CreateNode
		GraphRecord[ChangedSlot] = Epoch
		if Observer and not Deferred then
			NotifyObservers(Observer)
		end
	elseif FailedCount > 0 and Unfail(GraphRecord) then
		Healed(GraphRecord)
	end
	if SelfDirty then
		RunComputed(GraphRecord)
	end
end

const function Settle(GraphRecord : any)
	for IndexValue = FirstSourceSlot, GraphRecord[SourceEndSlot] - 2, 2 do
		local SourceRecord = GraphRecord[IndexValue]
		local HeightValue = SourceRecord[HeightSlot]
		if HeightValue and HeightValue >= MinimumHeapHeight then
			local StampValue = SourceRecord[StampSlot]
			if
				StampValue > MaximumLiveHeightLimit
				and StampValue ~= Epoch
				and StampValue ~= StaleStamp
				and StampValue ~= ErroredStamp
			then
				Settle(SourceRecord)
			end
		end
	end
	local StampValue = GraphRecord[StampSlot]
	if StampValue <= 0 and StampValue >= StaleStamp then
		RunComputed(GraphRecord)
	elseif StampValue ~= ErroredStamp then
		local HeightValue = GraphRecord[HeightSlot]
		GraphRecord[StampSlot] = if HeightValue <= MinimumHeapHeight
			then HeightValue + LiveStampBase
			else Epoch
	end
end

local Refresh : (any) -> ()

const function RefreshDormantComputation(GraphRecord : any)
	local Stamp = GraphRecord[StampSlot]
	local Dirty = Stamp <= 0
	if not Dirty then
		for IndexValue = FirstSourceSlot, GraphRecord[SourceEndSlot] - 2, 2 do
			local SourceRecord = GraphRecord[IndexValue]
			local StampValue = SourceRecord[StampSlot]
			if StampValue == StaleStamp then
				Refresh(SourceRecord)
				Dirty = true
				break
			elseif
				SourceRecord[HeightSlot]
				and StampValue > MaximumLiveHeightLimit
				and StampValue ~= Epoch
				and StampValue ~= ErroredStamp
			then
				Refresh(SourceRecord)
			end
			local ChildRecord = SourceRecord[ChangedSlot]
			if ChildRecord == nil or ChildRecord > Stamp then
				Dirty = true
				break
			end
		end
	end
	if Dirty then
		RunComputed(GraphRecord)
	else
		GraphRecord[StampSlot] = Epoch
	end
end

function Refresh(GraphRecord : any)
	if GraphRecord[ObserversSlot] then
		local StampValue = GraphRecord[StampSlot]
		if StampValue == DeferredStamp then
			if GraphRecord[ChildrenSlot] == nil then
				GraphRecord[ChildrenSlot] = false
			end
			RunComputed(GraphRecord)
		elseif StampValue >= ErroredStamp or GraphRecord[HeightSlot] > MinimumHeapHeight then
			Settle(GraphRecord)
		else
			GraphRecord[StampSlot] = GraphRecord[HeightSlot] + LiveStampBase
		end
	elseif GraphRecord[CalculationSlot] then
		RefreshDormantComputation(GraphRecord)
	end
end

const function RunComputedProtected(GraphRecord : any)
	local InitialStamp = GraphRecord[StampSlot]
	GraphRecord[StampSlot] = Epoch
	if GraphRecord[ChildrenSlot] then
		DisposeChildren(GraphRecord, ChildrenSlot, GraphRecord[ValueSlot], false)
	end
	local PreviousEvaluatingNode, PreviousDependencyIndex, PreviousNewSources, PreviousRun, PreviousEvaluatingRecord =
		CurrentComputationRecord,
		CurrentDependencyCursor,
		CurrentNewDependencies,
		CurrentEvaluationRun,
		EvaluatingComputationRecord
	local HadExtra = OwnExtra
	local PreviousSuspended, PreviousSuspendedRun, PreviousContext, PreviousOwner, PreviousOwnerSet, PreviousRunning
	if HadExtra then
		PreviousSuspended, PreviousSuspendedRun, PreviousContext, PreviousOwner, PreviousOwnerSet, PreviousRunning =
			SuspendedComputationRecord,
			SuspendedEvaluationRun,
			CurrentContextFrame,
			CurrentOwnerRecord,
			OwnerSet,
			RunningEffect
		SuspendedComputationRecord, OwnerSet = nil, false
	end
	EvaluatingComputationRecord = GraphRecord
	do
		local RunIdentifier = RunIdentifierCounter + 1
		RunIdentifierCounter, CurrentEvaluationRun = RunIdentifier, RunIdentifier
	end
	CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies =
		GraphRecord, FirstSourceSlot, nil
	local PreviousDependency = GraphRecord[ValueSlot]
	local Passed, CreateNode = pcall(GraphRecord[CalculationSlot], PreviousDependency)
	local Index, NewList = CurrentDependencyCursor, CurrentNewDependencies
	CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies, CurrentEvaluationRun, EvaluatingComputationRecord =
		PreviousEvaluatingNode,
		PreviousDependencyIndex,
		PreviousNewSources,
		PreviousRun,
		PreviousEvaluatingRecord
	if HadExtra then
		SuspendedComputationRecord, SuspendedEvaluationRun, CurrentContextFrame, CurrentOwnerRecord, OwnerSet, RunningEffect =
			PreviousSuspended,
			PreviousSuspendedRun,
			PreviousContext,
			PreviousOwner,
			PreviousOwnerSet,
			PreviousRunning
	elseif SuspendedComputationRecord then
		SuspendedComputationRecord = nil
		OwnExtra = CurrentContextFrame ~= nil
	end
	if not Passed then
		FinishErrored(GraphRecord, Index, NewList, CreateNode)
		error(CreateNode, 0)
	end
	local Observer = GraphRecord[ObserversSlot]
	local Last = GraphRecord[SourceEndSlot]
	if Index ~= Last then
		if not Observer and Index > Last then
			GraphRecord[SourceEndSlot] = Index
		else
			if not GraphRecord[CalculationSlot] then
				GraphRecord[ValueSlot] = nil
				DrainPendingDisposals(GraphRecord)
				return
			end
			if NewList then
				Index = NewList[1]
			end
			ReconcileDependencies(
				GraphRecord,
				SourceEndSlot,
				Last,
				Index,
				NewList,
				Observer ~= false
			)
			Observer = GraphRecord[ObserversSlot]
		end
	end
	local SelfDirty = GraphRecord[StampSlot] == 0
	GraphRecord[StampSlot] = if Observer and GraphRecord[HeightSlot] <= MinimumHeapHeight
		then GraphRecord[HeightSlot] + LiveStampBase
		else Epoch
	if CreateNode ~= PreviousDependency then
		GraphRecord[ValueSlot] = CreateNode
		GraphRecord[ChangedSlot] = Epoch
		if Observer and InitialStamp ~= DeferredStamp then
			NotifyObservers(Observer)
		end
	elseif FailedCount > 0 and Unfail(GraphRecord) then
		Healed(GraphRecord)
	end
	if SelfDirty then
		RunComputedProtected(GraphRecord)
	end
end

const function Guarded(FunctionValue : (any) -> (), GraphRecord : any, Check : number?)
	local PreviousEvaluatingNode, PreviousDependencyIndex, PreviousNewSources, PreviousRun, PreviousEvaluatingRecord =
		CurrentComputationRecord,
		CurrentDependencyCursor,
		CurrentNewDependencies,
		CurrentEvaluationRun,
		EvaluatingComputationRecord
	local HadExtra = OwnExtra
	local PreviousContext, PreviousSuspended, PreviousSuspendedRun, PreviousOwner, PreviousOwnerSet, PreviousRunning
	if HadExtra then
		PreviousContext, PreviousSuspended, PreviousSuspendedRun, PreviousOwner, PreviousOwnerSet, PreviousRunning =
			CurrentContextFrame,
			SuspendedComputationRecord,
			SuspendedEvaluationRun,
			CurrentOwnerRecord,
			OwnerSet,
			RunningEffect
	end
	local Passed, Failure = pcall(FunctionValue, GraphRecord)
	if not Passed then
		local Entry, Index, CreateNode =
			EvaluatingComputationRecord, CurrentDependencyCursor, CurrentNewDependencies
		CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies, CurrentEvaluationRun, EvaluatingComputationRecord =
			PreviousEvaluatingNode,
			PreviousDependencyIndex,
			PreviousNewSources,
			PreviousRun,
			PreviousEvaluatingRecord
		if HadExtra then
			CurrentContextFrame, SuspendedComputationRecord, SuspendedEvaluationRun, CurrentOwnerRecord, OwnerSet, RunningEffect =
				PreviousContext,
				PreviousSuspended,
				PreviousSuspendedRun,
				PreviousOwner,
				PreviousOwnerSet,
				PreviousRunning
		elseif SuspendedComputationRecord then
			SuspendedComputationRecord = nil
			OwnExtra = CurrentContextFrame ~= nil
		end
		if Entry ~= PreviousEvaluatingRecord and Entry then
			FinishErrored(Entry, Index, CreateNode, Failure)
		end
		local StampValue = Entry and Entry[StampSlot]
		if
			Check
			and Check < 64
			and Entry ~= GraphRecord
			and (StampValue == StaleStamp or StampValue == ErroredStamp)
			and GraphRecord[CalculationSlot]
		then
			local Held = StampValue == StaleStamp
			if Held then
				Entry[StampSlot] = ErroredStamp
			end
			Passed, Failure = pcall(Guarded, FunctionValue, GraphRecord, Check + 1)
			if Held and Entry[StampSlot] == ErroredStamp then
				Entry[StampSlot] = StaleStamp
			end
			if Passed then
				return
			end
		end
		error(Failure, 0)
	end
end

const function Pull(GraphRecord : any)
	local StampValue = GraphRecord[StampSlot]
	if StampValue == 0 then
		if GraphRecord[ObserversSlot] then
			Guarded(Settle, GraphRecord, 1)
		else
			RunComputedProtected(GraphRecord)
		end
		return
	end
	if StampValue == ErroredStamp and GraphRecord[CalculationSlot] then
		local Live = GraphRecord[ObserversSlot]
		if Live and CurrentComputationRecord == nil then
			GraphRecord[StampSlot] = 0
			Guarded(Settle, GraphRecord, 1)
			return
		elseif Live and GraphRecord[HeightSlot] > MinimumHeapHeight then
			Guarded(Settle, GraphRecord, 1)
		end
		if GraphRecord[StampSlot] == ErroredStamp then
			error(GraphRecord.Failure, 0)
		end
		return
	end
	if GraphRecord[ObserversSlot] then
		if StampValue == DeferredStamp then
			if GraphRecord[ChildrenSlot] == nil then
				GraphRecord[ChildrenSlot] = false
			end
			RunComputedProtected(GraphRecord)
		elseif StampValue >= StaleStamp or GraphRecord[HeightSlot] > MinimumHeapHeight then
			Guarded(Settle, GraphRecord, 1)
		else
			GraphRecord[StampSlot] = GraphRecord[HeightSlot] + LiveStampBase
		end
	elseif GraphRecord[CalculationSlot] then
		if StampValue > 0 then
			local Dirty = false
			for IndexValue = FirstSourceSlot, GraphRecord[SourceEndSlot] - 2, 2 do
				local SourceRecord = GraphRecord[IndexValue]
				local SourceStamp = SourceRecord[StampSlot]
				if
					SourceStamp == StaleStamp
					or (
						SourceRecord[HeightSlot]
						and SourceStamp > MaximumLiveHeightLimit
						and SourceStamp ~= Epoch
						and SourceStamp ~= ErroredStamp
					)
				then
					Guarded(RefreshDormantComputation, GraphRecord, 1)
					return
				end
				local ChildRecord = SourceRecord[ChangedSlot]
				if ChildRecord == nil or ChildRecord > StampValue then
					Dirty = true
					break
				end
			end
			if Dirty then
				RunComputedProtected(GraphRecord)
			else
				GraphRecord[StampSlot] = Epoch
			end
			return
		end
		Guarded(RefreshDormantComputation, GraphRecord, 1)
	end
end

const function Runaway(Entry : any, DidRun : string)
	local Source, Line = (debug.info :: any)(Entry[EffectCalculationSlot], "sl")
	ReportWarning(
		`[Flux] an effect ({Source}:{Line}) {DidRun} in one flush and was disposed: does it write what it reads?`
	)
	DisposeOne(Entry)
end

const function Requeue(Entry : any)
	local Count = (Reruns[Entry] or 1) + 1
	if Count > RerunLimit then
		Runaway(Entry, `ran {RerunLimit} times`)
	else
		Reruns[Entry] = Count
		AnyReruns = true
		MarkObserver(Entry)
	end
end

const function RunEffectNow(Entry : any)
	for IndexValue = EffectFirstSourceSlot, Entry[EffectSourceEndSlot] - 2, 2 do
		local SourceRecord = Entry[IndexValue]
		if
			SourceRecord[HeightSlot]
			and SourceRecord[StampSlot] > MaximumLiveHeightLimit
			and SourceRecord[StampSlot] ~= Epoch
		then
			Refresh(SourceRecord)
		end
	end
	if Entry[StampSlot] ~= 0 or not Entry[EffectCalculationSlot] then
		return
	end
	local PreviousEvaluatingNode, PreviousDependencyIndex, PreviousNewSources, PreviousRun, PreviousEvaluatingRecord, PreviousSuspended, PreviousContext =
		CurrentComputationRecord,
		CurrentDependencyCursor,
		CurrentNewDependencies,
		CurrentEvaluationRun,
		EvaluatingComputationRecord,
		SuspendedComputationRecord,
		CurrentContextFrame
	local PreviousSuspendedRun = SuspendedEvaluationRun
	local PreviousOwnerSet = OwnerSet
	SuspendedComputationRecord, OwnerSet = nil, false
	if Entry[EffectChildrenSlot] then
		DisposeChildren(Entry, EffectChildrenSlot, nil, false)
	end
	Entry[StampSlot] = Infinity
	EvaluatingComputationRecord = Entry
	RunIdentifierCounter += 1
	local PreviousRunning, PreviousReaction = RunningEffect, SelfWritten
	RunningEffect, SelfWritten = Entry, nil
	CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies, CurrentEvaluationRun =
		Entry, EffectFirstSourceSlot, nil, RunIdentifierCounter
	Entry[EffectCalculationSlot]()
	RunningEffect = PreviousRunning
	if SelfWritten == Entry then
		SelfWritten = PreviousReaction
		Requeue(Entry)
	elseif SelfWritten == nil then
		SelfWritten = PreviousReaction
	end
	if Entry[EffectCalculationSlot] then
		local Index = CurrentDependencyCursor
		local Last = Entry[EffectSourceEndSlot]
		if Index ~= Last then
			local NewList = CurrentNewDependencies
			if NewList then
				Index = NewList[1]
			end
			ReconcileDependencies(Entry, EffectSourceEndSlot, Last, Index, NewList, true)
		end
	end
	CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies, CurrentEvaluationRun, EvaluatingComputationRecord, SuspendedComputationRecord, CurrentContextFrame =
		PreviousEvaluatingNode,
		PreviousDependencyIndex,
		PreviousNewSources,
		PreviousRun,
		PreviousEvaluatingRecord,
		PreviousSuspended,
		PreviousContext
	SuspendedEvaluationRun = PreviousSuspendedRun
	OwnerSet = PreviousOwnerSet
	if not Entry[EffectCalculationSlot] then
		DrainPendingDisposals(Entry)
	end
end

const function Stabilize()
	local HeapPosition, QueuedRecord = Heap, Queue
	CurrentNewDependencies = nil
	local HeightValue = MinimumHeapHeight
	while HeightValue <= MaximumHeapHeight do
		local GraphRecord = HeapPosition[HeightValue]
		if GraphRecord then
			local MaximumLiveHeight = HeightValue + LiveStampBase
			MaximumLiveHeightLimit = MaximumLiveHeight
			repeat
				local NextRecord = GraphRecord[NextSlot]
				if NextRecord == true then
					HeapPosition[HeightValue] = false
					MinimumHeapHeight = HeightValue + 1
				else
					HeapPosition[HeightValue] = NextRecord
				end
				GraphRecord[NextSlot] = false
				if GraphRecord[StampSlot] == 0 then
					if GraphRecord[HeightSlot] ~= HeightValue then
						InsertIntoCalculationHeap(GraphRecord)
					else
						while true do
							local Observer = GraphRecord[ObserversSlot]
							if not Observer then
								break
							end
							local Children = GraphRecord[ChildrenSlot]
							if Children ~= false then
								if not Children then
									local List = type(Observer[HeightSlot]) ~= "number"
									local FirstObserver = if List then Observer[2] else Observer
									local FinalStamp = FirstObserver[StampSlot]
									if
										(FinalStamp == 0 or FinalStamp == DeferredStamp)
										and FirstObserver[HeightSlot] ~= Infinity
									then
										local Defer = true
										if List then
											for IndexValue = 3, Observer[1] do
												local ObserverRecord = Observer[IndexValue]
												local ObserverStamp = ObserverRecord[StampSlot]
												if
													(
														ObserverStamp ~= 0
														and ObserverStamp ~= DeferredStamp
													)
													or ObserverRecord[HeightSlot] == Infinity
												then
													Defer = false
													break
												end
											end
										end
										if Defer then
											GraphRecord[StampSlot] = DeferredStamp
											break
										end
									end
								else
									DisposeChildren(
										GraphRecord,
										ChildrenSlot,
										GraphRecord[ValueSlot],
										false
									)
								end
							end
							GraphRecord[StampSlot] = MaximumLiveHeight
							do
								local RunIdentifier = RunIdentifierCounter + 1
								RunIdentifierCounter, CurrentEvaluationRun =
									RunIdentifier, RunIdentifier
							end
							CurrentComputationRecord, CurrentDependencyCursor =
								GraphRecord, FirstSourceSlot
							local PreviousDependency = GraphRecord[ValueSlot]
							local CreateNode = GraphRecord[CalculationSlot](PreviousDependency)
							local Index = CurrentDependencyCursor
							local Last = GraphRecord[SourceEndSlot]
							if Index ~= Last then
								if not GraphRecord[CalculationSlot] then
									CurrentNewDependencies = nil
									CurrentComputationRecord, EvaluatingComputationRecord = nil, nil
									GraphRecord[ValueSlot] = nil
									DrainPendingDisposals(GraphRecord)
									break
								end
								local NewList = CurrentNewDependencies
								if NewList then
									Index = NewList[1]
									CurrentNewDependencies = nil
								end
								local Live = GraphRecord[ObserversSlot] ~= false
								ReconcileDependencies(
									GraphRecord,
									SourceEndSlot,
									Last,
									Index,
									NewList,
									Live
								)
								if GraphRecord[StampSlot] ~= 0 then
									GraphRecord[StampSlot] = if Live
										then GraphRecord[HeightSlot] + LiveStampBase
										else Epoch
								end
							end
							if CreateNode ~= PreviousDependency then
								GraphRecord[ValueSlot] = CreateNode
								GraphRecord[ChangedSlot] = Epoch
								local ObserverHeight = Observer[HeightSlot]
								if type(ObserverHeight) == "number" then
									local ObserverRecord = Observer
									if ObserverRecord[StampSlot] ~= 0 then
										if ObserverHeight == Infinity then
											ObserverRecord[StampSlot] = 0
											local QueueTailIndex = QueueTail + 1
											QueueTail = QueueTailIndex
											QueuedRecord[QueueTailIndex] = ObserverRecord
										elseif
											ObserverHeight <= MinimumHeapHeight
											and ObserverRecord[ChildrenSlot] ~= nil
										then
											HeightValue = ObserverHeight
											if not HeapPosition[ObserverHeight] then
												MinimumHeapHeight = ObserverHeight + 1
											end
											MaximumLiveHeight = ObserverHeight + LiveStampBase
											MaximumLiveHeightLimit = MaximumLiveHeight
											GraphRecord = ObserverRecord
											continue
										else
											ObserverRecord[StampSlot] = 0
											if not ObserverRecord[NextSlot] then
												ObserverRecord[NextSlot] = HeapPosition[ObserverHeight]
													or true
												HeapPosition[ObserverHeight] = ObserverRecord
												if ObserverHeight > MaximumHeapHeight then
													MaximumHeapHeight = ObserverHeight
												end
											end
										end
									end
								else
									local QueueTailIndex, MaximumHeight =
										QueueTail, MaximumHeapHeight
									for IndexValue = 2, Observer[1] do
										local ObserverRecord = Observer[IndexValue]
										if ObserverRecord[StampSlot] ~= 0 then
											ObserverRecord[StampSlot] = 0
											local ObserverHeightValue = ObserverRecord[HeightSlot]
											if ObserverHeightValue == Infinity then
												QueueTailIndex += 1
												QueuedRecord[QueueTailIndex] = ObserverRecord
											elseif not ObserverRecord[NextSlot] then
												ObserverRecord[NextSlot] = HeapPosition[ObserverHeightValue]
													or true
												HeapPosition[ObserverHeightValue] = ObserverRecord
												if ObserverHeightValue > MaximumHeight then
													MaximumHeight = ObserverHeightValue
												end
											end
										end
									end
									QueueTail, MaximumHeapHeight = QueueTailIndex, MaximumHeight
								end
							elseif FailedCount > 0 and Unfail(GraphRecord) then
								Healed(GraphRecord)
							end
							break
						end
					end
				end
				if MinimumHeapHeight ~= HeightValue then
					break
				end
				GraphRecord = HeapPosition[HeightValue]
			until false
			HeightValue = MinimumHeapHeight
		else
			HeightValue += 1
			MinimumHeapHeight = HeightValue
		end
	end
	MinimumHeapHeight = Infinity
	MaximumLiveHeightLimit = IdleLiveHeight
	MaximumHeapHeight = 0
end

local FlushUpdates : () -> ()
do
	local function Guard(Tail : number)
		for IndexValue = math.max(QueueHead, Counted + 1), Tail do
			local Entry = Queue[IndexValue]
			if Entry[StampSlot] == 0 and Entry[EffectCalculationSlot] then
				local Count = (Cycles[Entry] or 0) + 1
				if Count > RerunLimit then
					Runaway(Entry, "kept re-running")
				else
					Cycles[Entry] = Count
				end
			end
		end
		Counted = Tail
		AnyReruns = true
	end

	local function Drain()
		while true do
			if MinimumHeapHeight ~= Infinity then
				Stabilize()
			end
			local Tail = QueueTail
			if QueueHead > Tail then
				break
			end
			Passes += 1
			if Passes > GuardPasses then
				Guard(Tail)
			end
			CurrentNewDependencies = nil
			local QueuedRecord = Queue
			for IndexValue = QueueHead, Tail do
				local Entry = QueuedRecord[IndexValue]
				QueuedRecord[IndexValue] = nil
				QueueHead = IndexValue + 1
				if Entry[StampSlot] == 0 then
					local Callback : any = Entry[EffectCalculationSlot]
					if Callback then
						if Entry[EffectChildrenSlot] then
							DisposeChildren(Entry, EffectChildrenSlot, nil, false)
						end
						Entry[StampSlot] = Infinity
						do
							local RunIdentifier = RunIdentifierCounter + 1
							RunIdentifierCounter, CurrentEvaluationRun =
								RunIdentifier, RunIdentifier
						end
						RunningEffect, CurrentComputationRecord, CurrentDependencyCursor =
							Entry, Entry, EffectFirstSourceSlot;
						(Callback :: any)()
						RunningEffect = nil
						local Index = CurrentDependencyCursor
						if SelfWritten == Entry then
							SelfWritten = nil
							Requeue(Entry)
						end
						local Last = Entry[EffectSourceEndSlot]
						if Index ~= Last then
							if Index > Last then
								for OtherIndex = Last, Index - 2, 2 do
									local SourceRecord = Entry[OtherIndex]
									if not SourceRecord[HeightSlot] then
										local Count = SourceRecord[ObserversSlot] + 1
										SourceRecord[ObserversSlot] = Count
										SourceRecord[Count + SignalObserverOffset] = Entry
										Entry[OtherIndex + 1] = Count
										if AnyHooks and Count == 1 then
											FireHook(SourceRecord, 1)
										end
									else
										Entry[OtherIndex + 1] =
											SubscribeObserver(SourceRecord, Entry)
									end
								end
								Entry[EffectSourceEndSlot] = Index
							elseif Entry[EffectCalculationSlot] then
								local NewList = CurrentNewDependencies
								if NewList then
									Index = NewList[1]
									CurrentNewDependencies = nil
								end
								ReconcileDependencies(
									Entry,
									EffectSourceEndSlot,
									Last,
									Index,
									NewList,
									true
								)
							else
								CurrentNewDependencies = nil
								CurrentComputationRecord, EvaluatingComputationRecord = nil, nil
								DrainPendingDisposals(Entry)
							end
						end
					end
					if MinimumHeapHeight ~= Infinity then
						break
					end
				end
			end
			if QueueHead > QueueTail then
				if QueueTail > 4096 then
					Queue = {}
				end
				QueueHead, QueueTail = 1, 0
				Counted = 0
			end
		end
	end

	local RawError : any = nil
	local function DrainTraceback(Failure : any) : any
		RawError = Failure
		return FormatTraceback(Failure)
	end

	local function Recover(Failure : any, PreviousContext : any?, PreviousExtraOwnership : boolean?)
		repeat
			local Entry = CurrentComputationRecord or EvaluatingComputationRecord
			local ReadRawValue = RawError
			CurrentComputationRecord, EvaluatingComputationRecord, RawError, CurrentContextFrame =
				nil, nil, nil, PreviousContext
			OwnExtra = PreviousExtraOwnership == true
			RunningEffect = nil
			if Entry then
				FinishErrored(Entry, CurrentDependencyCursor, CurrentNewDependencies, ReadRawValue)
				CurrentNewDependencies = nil
				local HeightValue = Entry[HeightSlot]
				if
					(HeightValue == Infinity and Entry[EffectCalculationSlot])
					or (
						HeightValue
						and HeightValue ~= ScopeHeight
						and Entry[CalculationSlot]
						and not Entry[ObserversSlot]
					)
				then
					ReportWarning(`[Flux] suppressed effect error:\n{Failure}`)
				end
			end
			local Passed
			Passed, Failure = (xpcall :: any)(Drain, DrainTraceback)
		until Passed
		RawError = nil
	end

	function FlushUpdates()
		if Flushing or (MinimumHeapHeight == Infinity and QueueHead > QueueTail) then
			return
		end
		Flushing = true
		if CurrentComputationRecord == nil and not OwnExtra then
			local Passed, Failure = (xpcall :: any)(Drain, DrainTraceback)
			if not Passed then
				Recover(Failure)
			end
			if AnyReruns then
				table.clear(Reruns)
				table.clear(Cycles)
				AnyReruns = false
			end
			Passes = 0
			CurrentComputationRecord, EvaluatingComputationRecord = nil, nil
			if SuspendedComputationRecord then
				SuspendedComputationRecord = nil
				OwnExtra = CurrentContextFrame ~= nil
			end
			Flushing = false
			return
		end
		local PreviousEvaluatingNode, PreviousDependencyIndex, PreviousNewSources, PreviousRun, PreviousContext, PreviousEvaluatingRecord, PreviousSuspended =
			CurrentComputationRecord,
			CurrentDependencyCursor,
			CurrentNewDependencies,
			CurrentEvaluationRun,
			CurrentContextFrame,
			EvaluatingComputationRecord,
			SuspendedComputationRecord
		local PreviousSuspendedRun = SuspendedEvaluationRun
		local PreviousOwnerSet, PreviousExtraOwnership = OwnerSet, OwnExtra
		OwnerSet = false
		local Passed, Failure = (xpcall :: any)(Drain, DrainTraceback)
		if not Passed then
			Recover(Failure, PreviousContext, PreviousExtraOwnership)
		end
		if AnyReruns then
			table.clear(Reruns)
			table.clear(Cycles)
			AnyReruns = false
		end
		Passes = 0
		CurrentComputationRecord, CurrentDependencyCursor, CurrentNewDependencies, CurrentEvaluationRun, CurrentContextFrame, EvaluatingComputationRecord, SuspendedComputationRecord =
			PreviousEvaluatingNode,
			PreviousDependencyIndex,
			PreviousNewSources,
			PreviousRun,
			PreviousContext,
			PreviousEvaluatingRecord,
			PreviousSuspended
		SuspendedEvaluationRun = PreviousSuspendedRun
		OwnerSet, OwnExtra = PreviousOwnerSet, PreviousExtraOwnership
		Flushing = false
	end
end

const function GetCurrentOwnerRecord() : any
	if OwnerSet then
		return CurrentOwnerRecord
	end
	local ObserverRecord = CurrentComputationRecord
	if not ObserverRecord then
		if SuspendedComputationRecord and SuspendedEvaluationRun == CurrentEvaluationRun then
			ObserverRecord = SuspendedComputationRecord
		else
			ObserverRecord = CurrentOwnerRecord
		end
	end
	return ObserverRecord
end

const function ChildrenOf(ObserverRecord : any) : any
	local HeightValue = ObserverRecord[HeightSlot]
	if HeightValue == nil then
		local ChildRecord = ObserverRecord.OwnedReaction
		if not ChildRecord then
			ChildRecord = { 1 }
			ObserverRecord.OwnedReaction = ChildRecord
		end
		return ChildRecord
	end
	local Slot = if HeightValue == Infinity then EffectChildrenSlot else ChildrenSlot
	local ChildRecord = ObserverRecord[Slot]
	if not ChildRecord then
		ChildRecord = { 1 }
		ObserverRecord[Slot] = ChildRecord
	end
	return ChildRecord
end

const function OwnSlow(GraphRecord : any)
	local ObserverRecord = GetCurrentOwnerRecord()
	if ObserverRecord then
		local ChildRecord = ChildrenOf(ObserverRecord)
		local Count = ChildRecord[1] + 1
		ChildRecord[1] = Count
		ChildRecord[Count] = GraphRecord
	end
	local ContextValue = CurrentContextFrame
	if ContextValue then
		GraphRecord.Context = ContextValue
		local HeightValue = GraphRecord[HeightSlot]
		if HeightValue == Infinity then
			local Callback = GraphRecord[EffectCalculationSlot]
			GraphRecord[EffectCalculationSlot] = function()
				local PreviousValue, PreviousExtraOwnership = CurrentContextFrame, OwnExtra
				CurrentContextFrame, OwnExtra = ContextValue, true
				Callback()
				CurrentContextFrame, OwnExtra = PreviousValue, PreviousExtraOwnership
			end
		elseif HeightValue and HeightValue ~= ScopeHeight then
			local Callback = GraphRecord[CalculationSlot]
			GraphRecord[CalculationSlot] = function(PreviousRecord : any)
				local PreviousValue, PreviousExtraOwnership = CurrentContextFrame, OwnExtra
				CurrentContextFrame, OwnExtra = ContextValue, true
				local ValueItem = Callback(PreviousRecord)
				CurrentContextFrame, OwnExtra = PreviousValue, PreviousExtraOwnership
				return ValueItem
			end
		end
	end
end

local StampedRun, StampedTo = 0, 0

const function TrackDependency(GraphRecord : any)
	local ReactionRecord = CurrentComputationRecord
	if GraphRecord[ObserversSlot] == nil or GraphRecord == ReactionRecord then
		return
	end
	local EvaluationRun = CurrentEvaluationRun
	local CreateNode = CurrentNewDependencies
	if CreateNode then
		GraphRecord[SeenSlot] = EvaluationRun
		local Count = CreateNode[2] + 1
		CreateNode[2] = Count
		CreateNode[Count] = GraphRecord
		return
	end
	local Index = CurrentDependencyCursor
	local PreviousDependency = ReactionRecord[Index]
	local StampValue = StampedTo
	if StampedRun ~= EvaluationRun then
		StampedRun = EvaluationRun
		StampValue = if Index < FirstSourceSlot or ReactionRecord[HeightSlot] == Infinity
			then EffectFirstSourceSlot
			else FirstSourceSlot
	end
	if StampValue < Index then
		for IndexValue = StampValue, Index - 2, 2 do
			ReactionRecord[IndexValue][SeenSlot] = EvaluationRun
		end
		if GraphRecord[SeenSlot] == EvaluationRun then
			StampedTo = Index
			if PreviousDependency == nil then
				ReactionRecord[Index] = false
				ReactionRecord[Index] = nil
			end
			return
		end
	end
	GraphRecord[SeenSlot] = EvaluationRun
	if PreviousDependency == nil then
		ReactionRecord[Index] = GraphRecord
		ReactionRecord[Index + 1] = 0
		local NextSourceIndex = Index + 2
		CurrentDependencyCursor = NextSourceIndex
		StampedTo = NextSourceIndex
	else
		StampedTo = Index
		local FunctionValue = FreeNew
		if FunctionValue then
			FreeNew = nil
			FunctionValue[1] = Index
			FunctionValue[2] = 3
			FunctionValue[3] = GraphRecord
			CurrentNewDependencies = FunctionValue
		else
			CurrentNewDependencies = { Index, 3, GraphRecord }
		end
		CurrentDependencyCursor = DivergedIndex
	end
end

const function PullValue(GraphRecord : any, HeightValue : number) : any
	local StampValue = GraphRecord[StampSlot]
	if HeightValue == Infinity then
		if
			GraphRecord[EffectCalculationSlot]
			and (StampValue == 0 or MinimumHeapHeight ~= Infinity)
		then
			Guarded(RunEffectNow, GraphRecord)
		end
		return nil
	elseif
		HeightValue ~= ScopeHeight
		and StampValue > MaximumLiveHeightLimit
		and StampValue ~= Epoch
	then
		Pull(GraphRecord)
	end
	return GraphRecord[ValueSlot]
end

const function GetRecordValue(GraphRecord : any) : any
	local HeightValue = GraphRecord[HeightSlot]
	local ReactionRecord = CurrentComputationRecord
	if ReactionRecord then
		local IndexValue = CurrentDependencyCursor
		if ReactionRecord[IndexValue] == GraphRecord then
			CurrentDependencyCursor = IndexValue + 2
		elseif
			GraphRecord[SeenSlot] ~= CurrentEvaluationRun
			and HeightValue ~= Infinity
			and HeightValue ~= ScopeHeight
		then
			TrackDependency(GraphRecord)
		end
	end
	if HeightValue then
		return PullValue(GraphRecord, HeightValue)
	end
	return GraphRecord[ValueSlot]
end

const function GetStateValue(GraphRecord : any) : any
	local ReactionRecord = CurrentComputationRecord
	if ReactionRecord then
		local IndexValue = CurrentDependencyCursor
		if ReactionRecord[IndexValue] == GraphRecord then
			CurrentDependencyCursor = IndexValue + 2
			return GraphRecord[ValueSlot]
		elseif GraphRecord[SeenSlot] ~= CurrentEvaluationRun then
			TrackDependency(GraphRecord)
		end
	end
	return GraphRecord[ValueSlot]
end

const function GetComputedValue(GraphRecord : any) : any
	local ReactionRecord = CurrentComputationRecord
	if ReactionRecord then
		local IndexValue = CurrentDependencyCursor
		if ReactionRecord[IndexValue] == GraphRecord then
			CurrentDependencyCursor = IndexValue + 2
		elseif GraphRecord[SeenSlot] ~= CurrentEvaluationRun then
			TrackDependency(GraphRecord)
		end
	end
	local StampValue = GraphRecord[StampSlot]
	if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
		Pull(GraphRecord)
	end
	return GraphRecord[ValueSlot]
end

const function PeekRecordValue(GraphRecord : any) : any
	local HeightValue = GraphRecord[HeightSlot]
	if HeightValue then
		return PullValue(GraphRecord, HeightValue)
	end
	return GraphRecord[ValueSlot]
end

const function WriteComputed(GraphRecord : any, Value : any, Force : boolean?)
	if GraphRecord[CalculationSlot] == nil then
		return
	end
	local StampValue = GraphRecord[StampSlot]
	if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
		local Count = CurrentComputationRecord
		CurrentComputationRecord = nil
		Pull(GraphRecord)
		CurrentComputationRecord = Count
	end
	local PreviousDependency = GraphRecord[ValueSlot]
	if not Force then
		local Equals : any = GraphRecord.Equals
		if
			if Equals
				then (Equals :: any)(PreviousDependency, Value)
				else PreviousDependency == Value
		then
			return
		end
	end
	GraphRecord[ValueSlot] = Value
	Epoch += 1
	GraphRecord[ChangedSlot] = Epoch
	local Observer = GraphRecord[ObserversSlot]
	GraphRecord[StampSlot] = if Observer and GraphRecord[HeightSlot] <= MinimumHeapHeight
		then GraphRecord[HeightSlot] + LiveStampBase
		else Epoch
	if Observer then
		MarkObserverList(GraphRecord, Observer)
	end
	if CurrentComputationRecord then
		MarkActiveComputation(GraphRecord)
	end
end

const function SetStateValue(GraphRecord : any, Value : any, Force : boolean?) : any
	if not AnySigEquals then
		if GraphRecord[ValueSlot] == Value and not Force then
			return Value
		end
	elseif not Force then
		local Equals : any = GraphRecord.Equals
		if
			if Equals
				then (Equals :: any)(GraphRecord[ValueSlot], Value)
				else GraphRecord[ValueSlot] == Value
		then
			return Value
		end
	end
	local Count = GraphRecord[ObserversSlot]
	if not Count then
		return Value
	end
	GraphRecord[ValueSlot] = Value
	local EndpointRecord = Epoch + 1
	Epoch = EndpointRecord
	GraphRecord[ChangedSlot] = EndpointRecord
	local ReactionRecord = CurrentComputationRecord
	if Count > 0 then
		if Count == 1 then
			local ObserverRecord = GraphRecord[6]
			if ObserverRecord[StampSlot] ~= 0 and ObserverRecord ~= ReactionRecord then
				local HeightValue = ObserverRecord[HeightSlot]
				if HeightValue == Infinity then
					if ObserverRecord == RunningEffect then
						DeferActiveComputation(ObserverRecord, GraphRecord)
					else
						ObserverRecord[StampSlot] = 0
						local QueueTailIndex = QueueTail + 1
						QueueTail = QueueTailIndex
						Queue[QueueTailIndex] = ObserverRecord
					end
				else
					ObserverRecord[StampSlot] = 0
					if not ObserverRecord[NextSlot] then
						local HeapPosition = Heap
						ObserverRecord[NextSlot] = HeapPosition[HeightValue] or true
						HeapPosition[HeightValue] = ObserverRecord
						if HeightValue < MinimumHeapHeight then
							MinimumHeapHeight = HeightValue
							MaximumLiveHeightLimit = HeightValue + LiveStampBase
						end
						if HeightValue > MaximumHeapHeight then
							MaximumHeapHeight = HeightValue
						end
					end
				end
			end
		else
			local RecoveredFailure = RunningEffect
			local HeapPosition = Heap
			local QueuedRecord = Queue
			local QueueTailIndex = QueueTail
			local MinimumHeight = MinimumHeapHeight
			local MaximumHeight = MaximumHeapHeight
			for IndexValue = 6, Count + SignalObserverOffset do
				local ObserverRecord = GraphRecord[IndexValue]
				if ObserverRecord[StampSlot] ~= 0 and ObserverRecord ~= ReactionRecord then
					local HeightValue = ObserverRecord[HeightSlot]
					if HeightValue == Infinity then
						if ObserverRecord == RecoveredFailure then
							DeferActiveComputation(ObserverRecord, GraphRecord)
						else
							ObserverRecord[StampSlot] = 0
							QueueTailIndex += 1
							QueuedRecord[QueueTailIndex] = ObserverRecord
						end
					else
						ObserverRecord[StampSlot] = 0
						if not ObserverRecord[NextSlot] then
							ObserverRecord[NextSlot] = HeapPosition[HeightValue] or true
							HeapPosition[HeightValue] = ObserverRecord
							if HeightValue < MinimumHeight then
								MinimumHeight = HeightValue
							end
							if HeightValue > MaximumHeight then
								MaximumHeight = HeightValue
							end
						end
					end
				end
			end
			QueueTail = QueueTailIndex
			if MinimumHeight < MinimumHeapHeight then
				MinimumHeapHeight = MinimumHeight
				MaximumLiveHeightLimit = MinimumHeight + LiveStampBase
			end
			if MaximumHeight > MaximumHeapHeight then
				MaximumHeapHeight = MaximumHeight
			end
		end
	end
	if ReactionRecord then
		MarkActiveComputation(GraphRecord)
	end
	return Value
end

const function SetRecordValue(GraphRecord : any, Value : any, Force : boolean?) : any
	local HeightValue = GraphRecord[HeightSlot]
	if HeightValue == nil then
		return SetStateValue(GraphRecord, Value, Force)
	elseif HeightValue ~= Infinity and HeightValue ~= ScopeHeight then
		WriteComputed(GraphRecord, Value, Force)
	end
	return Value
end

const function UpdateNode(GraphRecord : any)
	local HeightValue = GraphRecord[HeightSlot]
	if HeightValue == nil then
		local Count = GraphRecord[ObserversSlot]
		if Count == nil then
			return
		end
		Epoch += 1
		GraphRecord[ChangedSlot] = Epoch
		if Count > 0 then
			MarkObservers(GraphRecord, Count)
		end
		if CurrentComputationRecord then
			MarkActiveComputation(GraphRecord)
		end
	elseif
		HeightValue ~= Infinity
		and HeightValue ~= ScopeHeight
		and GraphRecord[CalculationSlot]
	then
		Epoch += 1
		GraphRecord[ChangedSlot] = Epoch
		local Observer = GraphRecord[ObserversSlot]
		GraphRecord[StampSlot] = if Observer and HeightValue <= MinimumHeapHeight
			then HeightValue + LiveStampBase
			else Epoch
		if Observer then
			MarkObserverList(GraphRecord, Observer)
		end
		if CurrentComputationRecord then
			MarkActiveComputation(GraphRecord)
		end
	end
end

const function RegisterDestructionCallback(
	GraphRecord : GraphRecord,
	Callback : (OldValue : any) -> ()
)
	AnyDestroys = true
	local Destroys = GraphRecord.DestructionCallbacks
	if Destroys then
		table.insert(Destroys, Callback)
	else
		GraphRecord.DestructionCallbacks = { Callback }
	end
end

const function OnHook(GraphRecord : GraphRecord, Which : number, Callback : () -> ())
	local HeightValue = GraphRecord.Hooks
	if not HeightValue then
		HeightValue = {}
		GraphRecord.Hooks = HeightValue
	end
	local PreviousRecord : any = HeightValue[Which]
	if PreviousRecord then
		HeightValue[Which] = function()
			(PreviousRecord :: any)()
			Callback()
		end
	else
		HeightValue[Which] = Callback
	end
	AnyHooks = true
end

local Node : any = {
	__call = function(Self : any, Value : any?, Force : boolean?) : any
		local GraphRecord = Self[1]
		if Value == nil and not Force then
			return GetRecordValue(GraphRecord)
		end
		return SetRecordValue(GraphRecord, Value, Force)
	end,
	__tostring = function(FirstValue : any) : string
		return tostring(GetRecordValue(FirstValue[1]))
	end,
	__unm = function(FirstValue : any) : number
		return -GetRecordValue(FirstValue[1])
	end,
	__lt = function(FirstValue : any, SecondValue : any) : boolean
		return GetRecordValue(FirstValue[1]) < GetRecordValue(SecondValue[1])
	end,
	__le = function(FirstValue : any, SecondValue : any) : boolean
		return GetRecordValue(FirstValue[1]) <= GetRecordValue(SecondValue[1])
	end,

	Peek = function(Self : any) : any
		return PeekRecordValue(Self[1])
	end,

	Get = function(Self : any) : any
		return GetRecordValue(Self[1])
	end,

	Set = function(Self : any, Value : any, Force : boolean?) : any
		return SetRecordValue(Self[1], Value, Force)
	end,

	Update = function(Self : any) : any
		UpdateNode(Self[1])
		return Self
	end,

	Destroy = function(Self : any)
		DisposeOne(Self[1])
	end,

	OnDestroy = function(Self : any, Callback : (OldValue : any) -> ())
		RegisterDestructionCallback(Self[1], Callback)
	end,

	OnObserved = function(Self : any, Callback : () -> ())
		OnHook(Self[1], 1, Callback)
	end,

	OnUnobserved = function(Self : any, Callback : () -> ())
		OnHook(Self[1], 2, Callback)
	end,
}
Node.__type = Node
Node.__index = Node

do
	local function Data(FirstValue : any) : any
		local Metatable = getmetatable(FirstValue)
		return if Metatable ~= nil
				and type(Metatable) == "table"
				and Metatable.__type == Node
			then GetRecordValue(FirstValue[1])
			else FirstValue
	end

	Node.__concat = function(FirstValue : any, SecondValue : any) : string
		return Data(FirstValue) .. Data(SecondValue)
	end
	Node.__add = function(FirstValue : any, SecondValue : any) : number
		return Data(FirstValue) + Data(SecondValue)
	end
	Node.__sub = function(FirstValue : any, SecondValue : any) : number
		return Data(FirstValue) - Data(SecondValue)
	end
	Node.__mul = function(FirstValue : any, SecondValue : any) : number
		return Data(FirstValue) * Data(SecondValue)
	end
	Node.__div = function(FirstValue : any, SecondValue : any) : number
		return Data(FirstValue) / Data(SecondValue)
	end
	Node.__idiv = function(FirstValue : any, SecondValue : any) : number
		return Data(FirstValue) // Data(SecondValue)
	end
	Node.__mod = function(FirstValue : any, SecondValue : any) : number
		return Data(FirstValue) % Data(SecondValue)
	end
	Node.__pow = function(FirstValue : any, SecondValue : any) : number
		return Data(FirstValue) ^ Data(SecondValue)
	end
end

local StateMetatable : any = {
	__call = function(Self : any, Value : any?, Force : boolean?) : any
		local GraphRecord = Self[1]
		if Value == nil and not Force then
			local ReactionRecord = CurrentComputationRecord
			if ReactionRecord then
				local IndexValue = CurrentDependencyCursor
				if ReactionRecord[IndexValue] == GraphRecord then
					CurrentDependencyCursor = IndexValue + 2
					return GraphRecord[ValueSlot]
				elseif GraphRecord[SeenSlot] ~= CurrentEvaluationRun then
					TrackDependency(GraphRecord)
				end
			end
			return GraphRecord[ValueSlot]
		end
		return SetStateValue(GraphRecord, Value, Force)
	end,
	__concat = Node.__concat,
	__tostring = Node.__tostring,
	__unm = Node.__unm,
	__add = Node.__add,
	__sub = Node.__sub,
	__mul = Node.__mul,
	__div = Node.__div,
	__idiv = Node.__idiv,
	__mod = Node.__mod,
	__pow = Node.__pow,
	__lt = Node.__lt,
	__le = Node.__le,
	__type = Node,
	Peek = function(Self : any) : any
		return Self[1][ValueSlot]
	end,
	Get = function(Self : any) : any
		local GraphRecord = Self[1]
		local ReactionRecord = CurrentComputationRecord
		if ReactionRecord then
			local IndexValue = CurrentDependencyCursor
			if ReactionRecord[IndexValue] == GraphRecord then
				CurrentDependencyCursor = IndexValue + 2
				return GraphRecord[ValueSlot]
			elseif GraphRecord[SeenSlot] ~= CurrentEvaluationRun then
				TrackDependency(GraphRecord)
			end
		end
		return GraphRecord[ValueSlot]
	end,
	Set = function(Self : any, Value : any, Force : boolean?) : any
		return SetStateValue(Self[1], Value, Force)
	end,
	Update = Node.Update,
	Destroy = Node.Destroy,
	OnDestroy = Node.OnDestroy,
	OnObserved = Node.OnObserved,
	OnUnobserved = Node.OnUnobserved,
}

local ComputedMetatable : any = {
	__call = function(Self : any, Value : any?, Force : boolean?) : any
		local GraphRecord = Self[1]
		if Value == nil and not Force then
			local ReactionRecord = CurrentComputationRecord
			if ReactionRecord then
				local IndexValue = CurrentDependencyCursor
				if ReactionRecord[IndexValue] == GraphRecord then
					CurrentDependencyCursor = IndexValue + 2
					local StampValue = GraphRecord[StampSlot]
					if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
						Pull(GraphRecord)
					end
					return GraphRecord[ValueSlot]
				elseif GraphRecord[SeenSlot] ~= CurrentEvaluationRun then
					TrackDependency(GraphRecord)
				end
			end
			local StampValue = GraphRecord[StampSlot]
			if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
				Pull(GraphRecord)
			end
			return GraphRecord[ValueSlot]
		end
		WriteComputed(GraphRecord, Value, Force)
		return Value
	end,
	__concat = Node.__concat,
	__tostring = Node.__tostring,
	__unm = Node.__unm,
	__add = Node.__add,
	__sub = Node.__sub,
	__mul = Node.__mul,
	__div = Node.__div,
	__idiv = Node.__idiv,
	__mod = Node.__mod,
	__pow = Node.__pow,
	__lt = Node.__lt,
	__le = Node.__le,
	__type = Node,
	Peek = function(Self : any) : any
		local GraphRecord = Self[1]
		local StampValue = GraphRecord[StampSlot]
		if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
			Pull(GraphRecord)
		end
		return GraphRecord[ValueSlot]
	end,
	Get = function(Self : any) : any
		local GraphRecord = Self[1]
		local ReactionRecord = CurrentComputationRecord
		if ReactionRecord then
			local IndexValue = CurrentDependencyCursor
			if ReactionRecord[IndexValue] == GraphRecord then
				CurrentDependencyCursor = IndexValue + 2
				local StampValue = GraphRecord[StampSlot]
				if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
					Pull(GraphRecord)
				end
				return GraphRecord[ValueSlot]
			elseif GraphRecord[SeenSlot] ~= CurrentEvaluationRun then
				TrackDependency(GraphRecord)
			end
		end
		local StampValue = GraphRecord[StampSlot]
		if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
			Pull(GraphRecord)
		end
		return GraphRecord[ValueSlot]
	end,
	Set = function(Self : any, Value : any, Force : boolean?) : any
		WriteComputed(Self[1], Value, Force)
		return Value
	end,
	Update = Node.Update,
	Destroy = Node.Destroy,
	OnDestroy = Node.OnDestroy,
	OnObserved = Node.OnObserved,
	OnUnobserved = Node.OnUnobserved,
}

for _, Metatable in { StateMetatable, ComputedMetatable } do
	Metatable.__index = Metatable
	table.freeze(Metatable)
end

const function IsReactiveHandle(OwnedObject : any) : boolean
	local Metatable = getmetatable(OwnedObject)
	return Metatable ~= nil
		and (
			Metatable == StateMetatable
			or Metatable == ComputedMetatable
			or Metatable == Node
			or (type(Metatable) == "table" and Metatable.__type == Node)
		)
end

const function IsDynamicValue(OwnedObject : any) : boolean
	return type(OwnedObject) == "function" or IsReactiveHandle(OwnedObject)
end

local function ReadRawValue(OwnedObject : any) : any
	local Metatable = getmetatable(OwnedObject)
	if Metatable ~= nil then
		if Metatable == StateMetatable then
			return OwnedObject[1][ValueSlot]
		elseif Metatable == ComputedMetatable then
			local GraphRecord = OwnedObject[1]
			local StampValue = GraphRecord[StampSlot]
			if StampValue > MaximumLiveHeightLimit and StampValue ~= Epoch then
				Pull(GraphRecord)
			end
			return GraphRecord[ValueSlot]
		elseif Metatable == Node or (type(Metatable) == "table" and Metatable.__type == Node) then
			return PeekRecordValue(OwnedObject[1])
		end
		return OwnedObject
	elseif type(OwnedObject) == "function" then
		local Count, SourceRecord = CurrentComputationRecord, SuspendedComputationRecord
		if Count == nil and SourceRecord == nil then
			return (OwnedObject :: any)()
		end
		local PreviousSuspendedRun = SuspendedEvaluationRun
		CurrentComputationRecord, SuspendedComputationRecord = nil, nil
		local Passed, Result = pcall(OwnedObject)
		CurrentComputationRecord, SuspendedComputationRecord = Count, SourceRecord
		SuspendedEvaluationRun = PreviousSuspendedRun
		if not Passed then
			error(Result, 0)
		end
		return Result
	end
	return OwnedObject
end

const function ReadReactiveValue(OwnedObject : any) : any
	local Metatable = getmetatable(OwnedObject)
	if Metatable ~= nil then
		if Metatable == StateMetatable then
			return GetStateValue(OwnedObject[1])
		elseif Metatable == ComputedMetatable then
			return GetComputedValue(OwnedObject[1])
		elseif Metatable == Node or (type(Metatable) == "table" and Metatable.__type == Node) then
			return GetRecordValue(OwnedObject[1])
		end
		return OwnedObject
	elseif type(OwnedObject) == "function" then
		return (OwnedObject :: any)()
	end
	return OwnedObject
end

const function RegisterCleanup(Object : Cleanable)
	local OwnerHandle = GetCurrentOwnerRecord()
	if not OwnerHandle then
		error("cannot cleanup outside a reactive owner", 2)
	elseif type(Object) ~= "function" and not IsCleanupValue(Object) then
		error(`cannot cleanup given object: {typeof(Object)}`, 2)
	end
	AnyCleanups = true
	local ChildRecord = ChildrenOf(OwnerHandle)
	local CleanupCallbacks = ChildRecord.CleanupCallbacks
	if CleanupCallbacks then
		table.insert(CleanupCallbacks, Object)
	else
		ChildRecord.CleanupCallbacks = { Object }
	end
end

const function GetOwnerRecord() : Owner?
	return GetCurrentOwnerRecord()
end

const function IsDisposed(ObserverRecord : any) : boolean
	local HeightValue = ObserverRecord[HeightSlot]
	if HeightValue == nil then
		return ObserverRecord[ObserversSlot] == nil
	end
	return not ObserverRecord[if HeightValue == Infinity
		then EffectCalculationSlot
		else CalculationSlot]
end

const function RunWithOwner<ValueType>(
	GraphRecord : Node<any> | Owner | nil,
	Callback : () -> ...ValueType
) : ValueType
	local OwnerHandle : GraphRecord? = if GraphRecord == nil
		then nil
		elseif IsReactiveHandle(GraphRecord) then (GraphRecord :: any)[1]
		else GraphRecord :: any
	local PreviousOwner, PreviousOwnerSet, PreviousSuspended, PreviousContext, PreviousExtraOwnership =
		CurrentOwnerRecord, OwnerSet, SuspendedComputationRecord, CurrentContextFrame, OwnExtra
	local PreviousSuspendedRun = SuspendedEvaluationRun
	local Root = nil
	if OwnerHandle then
		CurrentContextFrame = OwnerHandle.Context or PreviousContext
		if IsDisposed(OwnerHandle) then
			Root =
				{ nil, true, false, false, ScopeHeight, Infinity, true, false, false, false } :: any
			OwnerHandle = Root
		end
	end
	CurrentOwnerRecord, OwnerSet, SuspendedComputationRecord, OwnExtra =
		OwnerHandle, true, nil, true
	local Passed, Result = xpcall(Callback, FormatTraceback :: any)
	CurrentOwnerRecord, OwnerSet, SuspendedComputationRecord, CurrentContextFrame, OwnExtra =
		PreviousOwner, PreviousOwnerSet, PreviousSuspended, PreviousContext, PreviousExtraOwnership
	SuspendedEvaluationRun = PreviousSuspendedRun
	if Root then
		DisposeOne(Root)
	elseif OwnerHandle and IsDisposed(OwnerHandle) then
		DrainPendingDisposals(OwnerHandle)
	end
	if not Passed then
		error(
			if type(Result) == "string"
				then `error while running withOwner():\n{Result}`
				else Result,
			0
		)
	end
	return Result
end

const function FinishUntrack(
	Count : any,
	PreviousSuspended : any,
	PreviousOwner : any,
	PreviousOwnerSet : boolean,
	PreviousExtraOwnership : boolean,
	PreviousSuspendedRun : number,
	Passed : boolean,
	... : any
) : ...any
	CurrentComputationRecord, SuspendedComputationRecord, CurrentOwnerRecord, OwnerSet, OwnExtra =
		Count, PreviousSuspended, PreviousOwner, PreviousOwnerSet, PreviousExtraOwnership
	SuspendedEvaluationRun = PreviousSuspendedRun
	if not Passed then
		local Failure = ...
		error(
			if type(Failure) == "string"
				then `error while running untrack():\n{Failure}`
				else Failure,
			0
		)
	end
	return ...
end

const function RunUntracked<ValueType>(Callback : (() -> ...ValueType)?) : ...ValueType
	local Count = CurrentComputationRecord
	if not Callback then
		if Count then
			SuspendedComputationRecord, SuspendedEvaluationRun, EvaluatingComputationRecord =
				Count, CurrentEvaluationRun, Count
			CurrentComputationRecord = nil
			OwnExtra = true
		end
		return nil :: any
	end
	local PreviousSuspended, PreviousOwner, PreviousOwnerSet, PreviousExtraOwnership =
		SuspendedComputationRecord, CurrentOwnerRecord, OwnerSet, OwnExtra
	local PreviousSuspendedRun = SuspendedEvaluationRun
	CurrentComputationRecord, SuspendedComputationRecord = nil, nil
	if Count and not OwnerSet then
		CurrentOwnerRecord, OwnerSet, OwnExtra = Count, true, true
	end
	return FinishUntrack(
		Count,
		PreviousSuspended,
		PreviousOwner,
		PreviousOwnerSet,
		PreviousExtraOwnership,
		PreviousSuspendedRun,
		xpcall(Callback, FormatTraceback :: any)
	)
end

const function RunRetracked()
	if
		CurrentComputationRecord == nil
		and SuspendedComputationRecord
		and SuspendedEvaluationRun == CurrentEvaluationRun
	then
		CurrentComputationRecord = SuspendedComputationRecord
		SuspendedComputationRecord = nil
		OwnExtra = CurrentContextFrame ~= nil or OwnerSet
	end
end

const function DisposeValue(Object : Cleanable?)
	local Count, PreviousSuspended = CurrentComputationRecord, SuspendedComputationRecord
	local PreviousSuspendedRun = SuspendedEvaluationRun
	CurrentComputationRecord, SuspendedComputationRecord = nil, nil
	DisposeCleanable(Object)
	CurrentComputationRecord, SuspendedComputationRecord = Count, PreviousSuspended
	SuspendedEvaluationRun = PreviousSuspendedRun
end

export type Context<ValueType> = {
	read Default : ValueType,

	Get : (Self : any) -> ValueType,

	Provide : <ResultType>(Self : any, Value : ValueType, Callback : () -> ResultType) -> ResultType,
}

type ContextData<ValueType> = { Default : ValueType }

local CreateContext : <ValueType>(Default : ValueType) -> Context<ValueType>
do
	local Context = {}
	Context.__index = Context

	function Context.Get<ValueType>(Self : ContextData<ValueType>) : ValueType
		local Frame = CurrentContextFrame
		while Frame do
			if Frame.Key == Self then
				return Frame.Value
			end
			Frame = Frame.Parent
		end
		return Self.Default
	end

	function Context.Provide<ValueType, ResultType>(
		Self : ContextData<ValueType>,
		Value : ValueType,
		Callback : () -> ResultType
	) : ResultType
		if type(Callback) ~= "function" then
			error("Context:provide() expects a function as its second argument", 2)
		end
		local PreviousContextFrame, PreviousOwnershipMode = CurrentContextFrame, OwnExtra
		OwnExtra = true
		CurrentContextFrame = { Parent = PreviousContextFrame, Key = Self, Value = Value }
		local Passed, Result = xpcall(Callback, FormatTraceback)
		CurrentContextFrame, OwnExtra = PreviousContextFrame, PreviousOwnershipMode
		if not Passed then
			error(Result, 0)
		end
		return Result
	end

	function CreateContext<ValueType>(Default : ValueType) : Context<ValueType>
		return setmetatable({ Default = Default }, Context) :: any
	end
end

const function FinishBindContext(
	PreviousContextFrame : any,
	PreviousOwnershipMode : boolean,
	Passed : boolean,
	... : any
) : ...any
	CurrentContextFrame, OwnExtra = PreviousContextFrame, PreviousOwnershipMode
	if not Passed then
		error((...), 0)
	end
	return ...
end

const function CaptureContext<ArgumentType..., ResultType...>(
	Callback : (
		ArgumentType...
	) -> ResultType...
) : (ArgumentType...) -> ResultType...
	if type(Callback) ~= "function" then
		error("bindContext expects a function", 2)
	end
	local ContextValue = CurrentContextFrame
	if ContextValue == nil then
		return Callback
	end
	return function(... : ArgumentType...) : ResultType...
		local PreviousContextFrame, PreviousOwnershipMode = CurrentContextFrame, OwnExtra
		CurrentContextFrame, OwnExtra = ContextValue, true
		return FinishBindContext(
			PreviousContextFrame,
			PreviousOwnershipMode,
			xpcall(Callback :: any, FormatTraceback, ...)
		)
	end
end

const function CreateScope<ValueType>(Callback : (CreateScope : Node<any>) -> ValueType) : (Node<any>, ValueType)
	local Inner = { nil, true, false, false, ScopeHeight, Infinity, true, false, false, false }
	if OwnExtra then
		OwnSlow(Inner)
	else
		local ObserverRecord = CurrentComputationRecord or CurrentOwnerRecord
		if ObserverRecord then
			if ObserverRecord[HeightSlot] == Infinity then
				local ChildRecord = ObserverRecord[EffectChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = Inner
				else
					ObserverRecord[EffectChildrenSlot] = { 2, Inner }
				end
			else
				local ChildRecord = ObserverRecord[ChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = Inner
				else
					ObserverRecord[ChildrenSlot] = { 2, Inner }
				end
			end
		end
	end
	local GraphRecord : any = setmetatable({ Inner }, Node)
	local PreviousEvaluatingNode, PreviousOwner, PreviousOwnerSet, PreviousSuspended, PreviousDependencyIndex, PreviousNewSources =
		CurrentComputationRecord,
		CurrentOwnerRecord,
		OwnerSet,
		SuspendedComputationRecord,
		CurrentDependencyCursor,
		CurrentNewDependencies
	local PreviousSuspendedRun = SuspendedEvaluationRun
	CurrentComputationRecord, CurrentOwnerRecord, OwnerSet, SuspendedComputationRecord =
		nil, Inner, false, nil
	local Passed, Result = xpcall(Callback, FormatTraceback, GraphRecord)
	CurrentComputationRecord, CurrentOwnerRecord, OwnerSet, SuspendedComputationRecord, CurrentDependencyCursor, CurrentNewDependencies =
		PreviousEvaluatingNode,
		PreviousOwner,
		PreviousOwnerSet,
		PreviousSuspended,
		PreviousDependencyIndex,
		PreviousNewSources
	SuspendedEvaluationRun = PreviousSuspendedRun
	if Inner[CalculationSlot] == false then
		DrainPendingDisposals(Inner)
	end
	if not Passed then
		DisposeOne(Inner)
		error(
			if type(Result) == "string" then `error while running scope():\n{Result}` else Result,
			0
		)
	end
	return GraphRecord, Result
end

const function CreateState<ValueType>(
	Initial : ValueType,
	Equality : ((ValueType, ValueType : any) -> boolean)?
) : State<ValueType>
	local GraphRecord = { Initial, 0, 0, 0, nil, nil }
	if Equality then
		GraphRecord.Equals = Equality
		AnySigEquals = true
	end
	return setmetatable({ GraphRecord }, StateMetatable) :: any
end

const function WrapComputedEquals(
	GraphRecord : any,
	Callback : (any) -> any,
	Equality : (any, any) -> boolean
)
	GraphRecord.Equals = Equality
	GraphRecord[CalculationSlot] = function(PreviousRecord : any)
		local ValueItem = Callback(PreviousRecord)
		if
			ValueItem ~= PreviousRecord
			and GraphRecord[ChangedSlot] ~= 0
			and Equality(PreviousRecord, ValueItem)
		then
			GraphRecord[ValueSlot] = ValueItem
			return PreviousRecord
		end
		return ValueItem
	end
end

const function CreateComputed<ValueType>(
	Callback : () -> ValueType,
	Equality : ((ValueType, ValueType) -> boolean)?
) : Node<ValueType>
	local GraphRecord =
		{ nil, false, 0, 0, 1, 0, Callback, FirstSourceSlot, false, false, nil, nil }
	if Equality then
		WrapComputedEquals(GraphRecord, Callback :: any, Equality :: any)
	end
	if OwnExtra then
		OwnSlow(GraphRecord)
	else
		local ObserverRecord = CurrentComputationRecord or CurrentOwnerRecord
		if ObserverRecord then
			if ObserverRecord[HeightSlot] == Infinity then
				local ChildRecord = ObserverRecord[EffectChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[EffectChildrenSlot] = { 2, GraphRecord }
				end
			else
				local ChildRecord = ObserverRecord[ChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[ChildrenSlot] = { 2, GraphRecord }
				end
			end
		end
	end
	return setmetatable({ GraphRecord }, ComputedMetatable) :: any
end

const function CreateEffect(Callback : (...any) -> ...any)
	local GraphRecord : any = { nil, EffectFirstSourceSlot, Callback, false, Infinity, 0, nil, nil }
	if OwnExtra then
		OwnSlow(GraphRecord)
	else
		local ObserverRecord = CurrentComputationRecord or CurrentOwnerRecord
		if ObserverRecord then
			if ObserverRecord[HeightSlot] == Infinity then
				local ChildRecord = ObserverRecord[EffectChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[EffectChildrenSlot] = { 2, GraphRecord }
				end
			else
				local ChildRecord = ObserverRecord[ChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[ChildrenSlot] = { 2, GraphRecord }
				end
			end
		end
	end
	local QueueTailIndex = QueueTail + 1
	QueueTail = QueueTailIndex
	Queue[QueueTailIndex] = GraphRecord
end

const function CreateEffectHandle(Callback : (...any) -> ...any) : Node<any>
	local GraphRecord : any = { nil, EffectFirstSourceSlot, Callback, false, Infinity, 0, nil, nil }
	if OwnExtra then
		OwnSlow(GraphRecord)
	else
		local ObserverRecord = CurrentComputationRecord or CurrentOwnerRecord
		if ObserverRecord then
			if ObserverRecord[HeightSlot] == Infinity then
				local ChildRecord = ObserverRecord[EffectChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[EffectChildrenSlot] = { 2, GraphRecord }
				end
			else
				local ChildRecord = ObserverRecord[ChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[ChildrenSlot] = { 2, GraphRecord }
				end
			end
		end
	end
	local QueueTailIndex = QueueTail + 1
	QueueTail = QueueTailIndex
	Queue[QueueTailIndex] = GraphRecord
	return setmetatable({ GraphRecord }, Node) :: any
end

const function ExtractGetter<ArgumentType>(GraphRecord : ArgumentType) : () -> Unwrap<ArgumentType>
	local Metatable = getmetatable(GraphRecord :: any)
	if Metatable == StateMetatable then
		local Inner = (GraphRecord :: any)[1]
		return (function() : any
			return GetStateValue(Inner)
		end) :: any
	elseif Metatable == ComputedMetatable then
		local Inner = (GraphRecord :: any)[1]
		return (function() : any
			return GetComputedValue(Inner)
		end) :: any
	elseif
		Metatable == Node
		or (Metatable ~= nil and type(Metatable) == "table" and Metatable.__type == Node)
	then
		local Inner = (GraphRecord :: any)[1]
		return (function() : any
			return GetRecordValue(Inner)
		end) :: any
	end
	error(`Flux.getter expects a node, got {typeof(GraphRecord)}`, 2)
end

const function ExtractSetter<ValueType>(
	GraphRecord : State<ValueType>
) : (Value : ValueType, Force : boolean?) -> ValueType
	local Metatable = getmetatable(GraphRecord :: any)
	if Metatable == StateMetatable then
		local Inner = (GraphRecord :: any)[1]
		return function(Value : any, Force : boolean?) : any
			return SetStateValue(Inner, Value, Force)
		end
	elseif
		Metatable == ComputedMetatable
		or Metatable == Node
		or (Metatable ~= nil and type(Metatable) == "table" and Metatable.__type == Node)
	then
		local Inner = (GraphRecord :: any)[1]
		return function(Value : any, Force : boolean?) : any
			return SetRecordValue(Inner, Value, Force)
		end
	end
	error(`Flux.setter expects a node, got {typeof(GraphRecord)}`, 2)
end

const function CreateSignal<ValueType>(
	Initial : ValueType,
	Equality : ((ValueType, ValueType : any) -> boolean)?
) : (() -> ValueType, (
	Value : ValueType,
	Force : boolean?
) -> ValueType)
	local GraphRecord = { Initial, 0, 0, 0, nil, nil }
	if Equality then
		GraphRecord.Equals = Equality
		AnySigEquals = true
	end
	return function() : any
		return GetStateValue(GraphRecord)
	end, function(Value : any, Force : boolean?) : any
		return SetStateValue(GraphRecord, Value, Force)
	end
end

const function CreateMemo<ValueType>(
	Callback : () -> ValueType,
	Equality : ((ValueType, ValueType) -> boolean)?
) : () -> ValueType
	local GraphRecord =
		{ nil, false, 0, 0, 1, 0, Callback, FirstSourceSlot, false, false, nil, nil }
	if Equality then
		WrapComputedEquals(GraphRecord, Callback :: any, Equality :: any)
	end
	if OwnExtra then
		OwnSlow(GraphRecord)
	else
		local ObserverRecord = CurrentComputationRecord
		if ObserverRecord then
			if ObserverRecord[HeightSlot] == Infinity then
				local ChildRecord = ObserverRecord[EffectChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[EffectChildrenSlot] = { 2, GraphRecord }
				end
			else
				local ChildRecord = ObserverRecord[ChildrenSlot]
				if ChildRecord then
					local Count = ChildRecord[1] + 1
					ChildRecord[1] = Count
					ChildRecord[Count] = GraphRecord
				else
					ObserverRecord[ChildrenSlot] = { 2, GraphRecord }
				end
			end
		end
	end
	return function() : any
		return GetComputedValue(GraphRecord)
	end
end

local function CreateNode<ValueType>(
	Object : ValueType,
	IsEffect : boolean?,
	Equality : ((ValueType, ValueType : any) -> boolean)?
) : Node<ValueType>
	if IsReactiveHandle(Object) then
		return Object :: any
	end
	if type(Object) == "function" then
		if IsEffect then
			return CreateEffectHandle(Object :: any)
		end
		return CreateComputed(Object :: any, Equality :: any)
	end
	return CreateState(Object, Equality)
end

local RunSafely : <ValueType>(
	AttemptCallback : () -> ValueType,
	Fallback : ValueType | (Failure : unknown) -> ValueType,
	Equality : ((FirstValue : ValueType, SecondValue : ValueType) -> boolean)?
) -> Node<ValueType>
do
	local function RecoverSafe<ValueType>(
		Handler : (Failure : unknown) -> ValueType,
		Failure : unknown
	) : ValueType
		local Count, SourceRecord, SourceRun =
			CurrentComputationRecord, SuspendedComputationRecord, SuspendedEvaluationRun
		CurrentComputationRecord, SuspendedComputationRecord = nil, nil
		local Passed, Result = pcall(Handler, Failure)
		CurrentComputationRecord, SuspendedComputationRecord, SuspendedEvaluationRun =
			Count, SourceRecord, SourceRun
		if not Passed then
			error(Result, 0)
		end
		return Result
	end

	function RunSafely<ValueType>(
		AttemptCallback : () -> ValueType,
		Fallback : ValueType | (Failure : unknown) -> ValueType,
		Equality : ((FirstValue : ValueType, SecondValue : ValueType) -> boolean)?
	) : Node<ValueType>
		return CreateComputed(function()
			local Passed, Result = pcall(AttemptCallback)
			if Passed then
				return Result
			end
			if type(Fallback) == "function" then
				return RecoverSafe(Fallback :: any, Result)
			end
			return Fallback
		end, Equality)
	end
end

const function IsComputationStale(GraphRecord : any) : boolean
	return GraphRecord[1][StampSlot] == 0 or MinimumHeapHeight ~= Infinity
end

type Hooks = {

	read OnObserved : (Self : any, Callback : () -> ()) -> (),

	read OnUnobserved : (Self : any, Callback : () -> ()) -> (),
}

type Operators<ValueType> = {
	read __call : (Self : any, Value : any, Force : boolean?) -> ValueType,
	read __concat : (FirstValue : any, SecondValue : any) -> string,
	read __tostring : (Self : any) -> string,
	read __unm : (Self : any) -> number,
	read __add : (FirstValue : any, SecondValue : any) -> number,
	read __sub : (FirstValue : any, SecondValue : any) -> number,
	read __mul : (FirstValue : any, SecondValue : any) -> number,
	read __div : (FirstValue : any, SecondValue : any) -> number,
	read __idiv : (FirstValue : any, SecondValue : any) -> number,
	read __mod : (FirstValue : any, SecondValue : any) -> number,
	read __pow : (FirstValue : any, SecondValue : any) -> number,
	read __lt : (FirstValue : any, SecondValue : any) -> boolean,
	read __le : (FirstValue : any, SecondValue : any) -> boolean,
	read __index : Hooks,
}

export type Node<ValueType = any> = setmetatable<{

	read Peek : (Self : any) -> ValueType,

	read Get : (Self : any) -> ValueType,

	read Set : (Self : any, Value : any, Force : boolean?) -> ValueType,

	read Update : <NodeType>(Self : NodeType) -> NodeType,

	read Destroy : (Self : any) -> (),

	read OnDestroy : (Self : any, Callback : (OldValue : ValueType) -> ()) -> (),
}, Operators<ValueType>>

export type State<ValueType = any> = setmetatable<{

	read Peek : (Self : any) -> ValueType,

	read Get : (Self : any) -> ValueType,

	read Set : (Self : any, Value : ValueType, Force : boolean?) -> ValueType,

	read Update : <NodeType>(Self : NodeType) -> NodeType,

	read Destroy : (Self : any) -> (),

	read OnDestroy : (Self : any, Callback : (OldValue : ValueType) -> ()) -> (),
}, Operators<ValueType>>

export type Reactive<ValueType> = ValueType | Node<ValueType> | (() -> ValueType)

export type function Unwrap(Value : type) : type
	local function Returned(Callback : type) : type
		local Head = Callback:returns().head
		return if Head and Head[1] then Head[1] else types.singleton(nil)
	end

	local function NodeValue(ValueType : type) : type?
		if not ValueType:is("table") then
			return nil
		end
		local ReadHandle = ValueType:readproperty(types.singleton("Get"))
		if
			ReadHandle
			and ReadHandle:is("function")
			and ValueType:readproperty(types.singleton("Peek"))
		then
			return Returned(ReadHandle)
		end
		return nil
	end

	local function UnwrapSource(ValueType : type) : type
		if ValueType:is("union") then
			local Parts : { type } = {}
			local function Add(Part : type)
				if Part:is("union") then
					for _, Member in Part:components() do
						Add(Member)
					end
				elseif not table.find(Parts, Part) then
					table.insert(Parts, Part)
				end
			end
			for _, Part in ValueType:components() do
				Add(UnwrapSource(Part))
			end
			return if #Parts == 1 then Parts[1] else types.unionof(table.unpack(Parts))
		elseif ValueType:is("intersection") then
			for _, Part in ValueType:components() do
				local Found = NodeValue(Part)
				if Found then
					return Found
				end
			end
			return ValueType
		elseif ValueType:is("function") then
			return Returned(ValueType)
		end
		return NodeValue(ValueType) or ValueType
	end

	return UnwrapSource(Value)
end

export type Owner = { any }

local Graph = {

	New = CreateNode,

	State = CreateState,

	Computed = CreateComputed,

	Effect = CreateEffectHandle,

	Getter = ExtractGetter,

	Setter = ExtractSetter,

	CreateSignal = CreateSignal,

	CreateMemo = CreateMemo,

	CreateEffect = CreateEffect,

	Flush = FlushUpdates,

	Scope = CreateScope :: ((Callback : (CreateScope : Node<any>) -> ()) -> Node<any>) & (<ValueType>(
		Callback : (CreateScope : Node<any>) -> ValueType
	) -> (Node<any>, ValueType)),

	Cleanup = RegisterCleanup,

	Dispose = DisposeValue,

	GetOwner = GetOwnerRecord,

	WithOwner = RunWithOwner,

	Untrack = RunUntracked,

	Retrack = RunRetracked,

	Raw = ReadRawValue :: <ValueType>(OwnedObject : ValueType) -> Unwrap<ValueType>,

	Read = ReadReactiveValue :: <ValueType>(OwnedObject : ValueType) -> Unwrap<ValueType>,

	Safe = RunSafely,

	Context = CreateContext,

	BindContext = CaptureContext,

	IsNode = IsReactiveHandle,

	IsDynamic = IsDynamicValue,

	IsReactive = IsTrackingComputation,

	IsStale = IsComputationStale,

	IsObserved = HasObservers,

	Clean = DisposeCleanable,

	IsCleanable = IsCleanupValue,

	Register = RegisterCleanupStrategy,
	Node = table.freeze(Node),
}

return table.freeze(Graph)
