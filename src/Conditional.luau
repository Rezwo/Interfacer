--!strict

const Compatibility = require("./Compatibility")
const Graph = require("./Graph")

local ReportWarning = Compatibility.Warn
local CreateComputed = Graph.Computed
local DisposeResource = Graph.Dispose
local CreateEffect = Graph.Effect
local CreateState = Graph.State
local ReadRawValue = Graph.Raw
local ReadReactiveValue = Graph.Read
local ReadNodeValue = Graph.Node.Get
local SetNodeValue = Graph.Node.Set
local DestroyNode = Graph.Node.Destroy
local RunUntracked = Graph.Untrack
local RunRetracked = Graph.Retrack
local CreateScope = Graph.Scope
local RunWithOwner = Graph.WithOwner
local IsTrackingCalculation = Graph.IsReactive
local IsComputationStale = Graph.IsStale
local HasObservers = Graph.IsObserved

type Node<ValueType> = Graph.Node<ValueType>

type Item<ListType> = index<Graph.Unwrap<ListType>, number>

type function NonNil(TemporaryValue : type) : type
	if TemporaryValue:is("nil") then
		return types.never
	elseif not TemporaryValue:is("union") then
		return TemporaryValue
	end
	local Parts = {}
	for _, Part in TemporaryValue:components() do
		if not Part:is("nil") then
			table.insert(Parts, Part)
		end
	end
	return if #Parts == 0
		then types.never
		elseif #Parts == 1 then Parts[1]
		else types.unionof(table.unpack(Parts))
end

local OtherwiseBranch = table.freeze({ type = "SwitchOtherwise" }) :: any
local UnsetValue = table.freeze({})

const function BindLifetime(Output : Node<any>)
	if Graph.GetOwner() ~= nil then
		Graph.Cleanup(Output)
	end
end

const function MountBranch(Callback : any, FirstValue : any, SecondValue : any) : (boolean, any, any)
	local Branch, Result
	local Passed, Failure = pcall(RunWithOwner, nil :: any, function()
		Branch, Result = CreateScope(function() : any
			return Callback(FirstValue, SecondValue)
		end)
	end)
	if Passed then
		return true, Branch, Result
	end
	return false, Failure, nil
end

const function Mount(
	Source : any,
	SelectBranch : (
		Value : any,
		FirstValue : any,
		SecondValue : any,
		Child : any
	) -> (any, ((Value : () -> any) -> any)?),
	FirstArgument : any,
	SecondArgument : any,
	ThirdArgument : any
) : Node<any>
	local ActiveKey : any = UnsetValue
	local ActiveBranch : Node<any>? = nil
	local Output = CreateState(nil :: any)

	local function ValueOf()
		return ReadReactiveValue(Source)
	end

	local Driver = CreateEffect(function()
		local Value = ReadReactiveValue(Source)
		local Key, Factory = SelectBranch(Value, FirstArgument, SecondArgument, ThirdArgument)

		if Key == ActiveKey then
			return
		end
		ActiveKey = Key

		RunUntracked()
		local Previous = ActiveBranch
		ActiveBranch = nil
		if Previous ~= nil then
			Previous:Destroy()
		end

		if Factory ~= nil then
			local Passed, Branch, Result = MountBranch(Factory, ValueOf)
			if Passed then
				ActiveBranch = Branch
				SetNodeValue(Output, Result)
			else
				SetNodeValue(Output, nil)
				ActiveKey = UnsetValue
				RunRetracked()
				error(Branch, 0)
			end
		else
			SetNodeValue(Output, nil)
		end
		RunRetracked()
	end)

	Output:OnDestroy(function()
		Driver:Destroy()
		local Branch = ActiveBranch
		ActiveBranch = nil
		if Branch ~= nil then
			Branch:Destroy()
		end
	end)
	BindLifetime(Output)

	return Output
end

const function ShowSelect(Value : any, Component : any, ResolveFallback : any, Keyed : any) : (any, any)
	local Factory = if Value then Component else ResolveFallback
	return (if Keyed then Value else not not Value), Factory
end

const function SwitchSelect(Value : any, Map : { [any] : any }) : (any, any)
	local Factory = Map[Value]
	if Factory == nil then
		local DefaultBranchSymbol = Map[OtherwiseBranch]
		if DefaultBranchSymbol ~= nil then
			return OtherwiseBranch, DefaultBranchSymbol
		end
	end
	return Value, Factory
end

const function CreateConditional<ValueType, FallbackType>(
	Condition : unknown,
	Component : (Value : () -> any) -> ValueType,
	ResolveFallback : ((Value : () -> any) -> FallbackType)?
) : Node<ValueType | FallbackType>
	return Mount(Condition, ShowSelect, Component, ResolveFallback, false)
end

const function CreateKeyedConditional<ValueType, FallbackType>(
	Condition : unknown,
	Component : (Value : () -> any) -> ValueType,
	ResolveFallback : ((
		Value : () -> any
	) -> FallbackType)?
) : Node<ValueType | FallbackType>
	return Mount(Condition, ShowSelect, Component, ResolveFallback, true)
end

const function CreateSwitch<SourceType>(Source : SourceType)
	return function<ValueType>(Map : {
		[Graph.Unwrap<SourceType>] : (Value : () -> Graph.Unwrap<SourceType>) -> ValueType,
	}) : Node<ValueType?>
		return Mount(Source, SwitchSelect, Map, nil, nil) :: any
	end
end

const function CreatePresence<ValueType>(
	Condition : unknown,
	Component : (
		Exiting : Node<boolean>,
		Done : () -> ()
	) -> ValueType
) : Node<ValueType?>
	local Output = CreateState(nil :: any)
	local Branch : Node<any>? = nil
	local Exiting : Node<boolean>? = nil
	local Finished = CreateState(0)
	local Handled = 0

	local function Done()
		local Leaving = Exiting
		if Leaving ~= nil and Leaving:Peek() then
			SetNodeValue(Finished, Finished:Peek() + 1)
		end
	end

	local Driver = CreateEffect(function()
		local Present = ReadReactiveValue(Condition)
		local Finishes = ReadNodeValue(Finished)

		RunUntracked()
		local Current, Leaving = Branch, Exiting
		if Present then
			Handled = Finishes
			if Current == nil then
				local Exit = CreateState(false)
				local Passed, Mounted, Result = MountBranch(Component, Exit, Done)
				if not Passed then
					DestroyNode(Exit)
					SetNodeValue(Output, nil)
					RunRetracked()
					error(Mounted, 0)
				end
				Branch, Exiting = Mounted, Exit
				SetNodeValue(Output, Result)
			elseif Leaving ~= nil and Leaving:Peek() then
				SetNodeValue(Leaving, false)
			end
		elseif Current ~= nil and Leaving ~= nil then
			if not Leaving:Peek() then
				Handled = Finishes
				SetNodeValue(Leaving, true)
			elseif Finishes ~= Handled then
				Branch, Exiting = nil, nil
				Current:Destroy()
				DestroyNode(Leaving)
				SetNodeValue(Output, nil)
			end
		end
		RunRetracked()
	end)

	Output:OnDestroy(function()
		Driver:Destroy()
		local Current, Leaving = Branch, Exiting
		Branch, Exiting = nil, nil
		if Leaving ~= nil then
			DestroyNode(Leaving)
		end
		DestroyNode(Finished)
		if Current ~= nil then
			Current:Destroy()
		end
	end)
	BindLifetime(Output)

	return Output :: any
end

local SelectValue = function(Condition : unknown, WhenTrue : any, WhenFalse : any?) : Node<any>
	return CreateComputed(function() : any
		return if ReadReactiveValue(Condition)
			then ReadReactiveValue(WhenTrue)
			else ReadReactiveValue(WhenFalse)
	end)
end :: (<FirstValueType, SecondValueType>(
	Condition : unknown,
	WhenTrue : FirstValueType,
	WhenFalse : SecondValueType
) -> Node<Graph.Unwrap<FirstValueType> | Graph.Unwrap<SecondValueType>>) & (<FirstValueType>(
	Condition : unknown,
	WhenTrue : FirstValueType
) -> Node<Graph.Unwrap<FirstValueType>?>)

const function ResolveFallback<ItemType, DependencyType>(
	Value : ItemType,
	Default : DependencyType
) : Node<
	NonNil<Graph.Unwrap<ItemType>> | Graph.Unwrap<DependencyType>
>
	return CreateComputed(function() : any
		local Current = ReadReactiveValue(Value)
		return if Current == nil then ReadReactiveValue(Default) else Current
	end)
end

const function CreateMapper(List : any, MappingCallback : any, KeyedByValue : boolean) : Node<any>
	local Cache : { [any] : any } = {}
	local Nodes : { [any] : Node<any> } = {}
	local CurrentKeys : { [any] : boolean } = {}
	local CachedItemCount = 0
	local RebuildAborted = false
	local FirstMappingArgument : any, SecondMappingArgument : any

	local function Build()
		local FirstValue, SecondValue = FirstMappingArgument, SecondMappingArgument
		FirstMappingArgument, SecondMappingArgument = nil, nil
		return MappingCallback(FirstValue, SecondValue)
	end

	local Self = CreateComputed(function()
		local Current = ReadReactiveValue(List) :: { any }
		if type(Current) ~= "table" then
			return {}
		end

		table.clear(CurrentKeys)
		local Output = table.create(#Current)

		local MustScan = RebuildAborted
		RebuildAborted = true
		RunUntracked()

		local Seen, Added = 0, 0
		for Index, Value in Current do
			local Key : any, Held : any = Index, Value
			if KeyedByValue then
				Key, Held = Value, Index
				if CurrentKeys[Key] ~= nil then
					ReportWarning(
						"[Flux] Flux.forValue: duplicate values share one mapped instance (the value is the cache key); use Flux.forIndex"
					)
					Seen -= 1
				end
			end
			CurrentKeys[Key] = true
			Seen += 1
			local Record = Nodes[Key]
			if Record ~= nil then
				SetNodeValue(Record, Held)
				Output[Index] = Cache[Key]
			else
				Record = CreateState(Held)
				if KeyedByValue then
					FirstMappingArgument, SecondMappingArgument = Record, Value
				else
					FirstMappingArgument, SecondMappingArgument = Index, Record
				end
				local Mapped = RunWithOwner(Record, Build)
				Cache[Key] = Mapped
				Nodes[Key] = Record
				Added += 1
				Output[Index] = Mapped
			end
		end

		RebuildAborted = false

		if MustScan or Seen ~= CachedItemCount + Added then
			local LiveItemCount = 0
			for Key, Record in Nodes do
				if CurrentKeys[Key] == nil then
					Record:Destroy()
					Nodes[Key] = nil
					DisposeResource(Cache[Key])
					Cache[Key] = nil
				else
					LiveItemCount += 1
				end
			end
			CachedItemCount = LiveItemCount
		else
			CachedItemCount += Added
		end

		return Output
	end)

	Self:OnDestroy(function()
		for Key, Record in Nodes do
			Record:Destroy()
			DisposeResource(Cache[Key])
		end
		table.clear(Nodes)
		table.clear(Cache)
		table.clear(CurrentKeys)
	end)

	return Self
end

const function MapByIndex<ListType, OutputType>(
	List : ListType,
	MappingCallback : (
		Index : number,
		ItemValue : Node<Item<ListType>>
	) -> OutputType
) : Node<{ OutputType }>
	return CreateMapper(List, MappingCallback, false)
end

const function MapByValue<ListType, OutputType>(
	List : ListType,
	MappingCallback : (
		Index : Node<number>,
		Value : Item<ListType>
	) -> OutputType
) : Node<{ OutputType }>
	return CreateMapper(List, MappingCallback, true)
end

const MinimumSweepCount = 32
const SweepRequestedSymbol = math.huge

export type Selector<KeyType> = setmetatable<{

	Get : (Self : any, Key : KeyType) -> boolean,

	Destroy : (Self : any) -> (),
}, { __call : (Self : any, Key : KeyType) -> boolean }>

type SelectorData = {
	Nodes : { [any] : Graph.Node<boolean> },
	Count : number,
	NextSweepCount : number,
	Watcher : Graph.Node<any>,
	SweepSignal : Graph.State<boolean>,
	Equals : ((SourceValue : any, Key : any) -> boolean)?,
	ActiveKey : any,
}

local SelectorMetatable = {}
SelectorMetatable.__index = SelectorMetatable

const function Sweep(Self : SelectorData)
	local Nodes = Self.Nodes
	local Count = 0
	for Key, Record in Nodes do
		if HasObservers(Record) then
			Count += 1
		else
			Nodes[Key] = nil
			DestroyNode(Record)
		end
	end
	Self.Count = Count
	Self.NextSweepCount = math.max(MinimumSweepCount, 2 * Count)
end

function SelectorMetatable.Get(Self : SelectorData, Key : any) : boolean
	if IsComputationStale(Self.Watcher) then
		ReadRawValue(Self.Watcher)
	end
	local Nodes = Self.Nodes
	local Record = Nodes[Key]
	if Record ~= nil then
		return ReadNodeValue(Record :: Graph.Node<boolean>)
	end

	local Equals = Self.Equals
	local Selected = if Equals ~= nil then Equals(Self.ActiveKey, Key) else Self.ActiveKey == Key
	if not IsTrackingCalculation() then
		return Selected
	end

	if Self.Count >= Self.NextSweepCount then
		Self.NextSweepCount = SweepRequestedSymbol
		SetNodeValue(Self.SweepSignal, true, true)
	end
	Record = CreateState(Selected)
	Nodes[Key] = Record
	Self.Count += 1
	return ReadNodeValue(Record)
end

SelectorMetatable.__call = SelectorMetatable.Get

function SelectorMetatable.Destroy(Self : SelectorData)
	if Self.Watcher ~= nil then
		Self.Watcher:Destroy()
	end
end

const function CreateSelector<SourceType, KeyType>(
	Source : SourceType,
	Equals : ((
		SourceValue : Graph.Unwrap<SourceType>,
		Key : KeyType
	) -> boolean)?
) : Selector<KeyType>
	local SweepSignal = CreateState(false)
	local Nodes : { [any] : Graph.Node<boolean> } = {}
	local Self : any = setmetatable({
		Nodes = Nodes,
		Count = 0,
		NextSweepCount = MinimumSweepCount,
		Equals = Equals,
		ActiveKey = UnsetValue,
		Watcher = nil :: any,
		SweepSignal = SweepSignal,
	}, SelectorMetatable)

	Self.Watcher = CreateEffect(function()
		local Value = ReadReactiveValue(Source)
		local PreviousRecord = Self.ActiveKey
		if Equals == nil and PreviousRecord == Value then
			return
		end
		Self.ActiveKey = Value
		if Self.Count == 0 then
			return
		end

		RunUntracked()
		if Equals == nil then
			local PreviousSource = if PreviousRecord ~= nil then Nodes[PreviousRecord] else nil
			if PreviousSource ~= nil then
				SetNodeValue(PreviousSource, false)
			end
			local NextNode = if Value ~= nil then Nodes[Value] else nil
			if NextNode ~= nil then
				SetNodeValue(NextNode, true)
			end
		else
			for Key, Record in Nodes do
				SetNodeValue(Record, Equals(Value, Key))
			end
		end
		RunRetracked()
	end)

	local Sweeper = CreateEffect(function()
		ReadNodeValue(SweepSignal)
		if Self.NextSweepCount == SweepRequestedSymbol then
			Sweep(Self)
		end
	end)

	Self.Watcher:OnDestroy(function()
		for _, Record in Nodes do
			DestroyNode(Record)
		end
		Sweeper:Destroy()
		DestroyNode(SweepSignal)
		table.clear(Self)
	end)

	return Self
end

return table.freeze({

	Otherwise = OtherwiseBranch,

	Show = CreateConditional :: (<ValueType>(
		Condition : unknown,
		Component : (Value : () -> any) -> ValueType
	) -> Node<ValueType?>) & (<ValueType, FallbackType>(
		Condition : unknown,
		Component : (Value : () -> any) -> ValueType,
		ResolveFallback : (Value : () -> any) -> FallbackType
	) -> Node<(ValueType | FallbackType)?>),

	ShowKeyed = CreateKeyedConditional :: (<ValueType>(
		Condition : unknown,
		Component : (Value : () -> any) -> ValueType
	) -> Node<ValueType?>) & (<ValueType, FallbackType>(
		Condition : unknown,
		Component : (Value : () -> any) -> ValueType,
		ResolveFallback : (Value : () -> any) -> FallbackType
	) -> Node<(ValueType | FallbackType)?>),
	Switch = CreateSwitch,
	Presence = CreatePresence,
	Pick = SelectValue,
	Fallback = ResolveFallback,
	ForIndex = MapByIndex,
	ForValue = MapByValue,
	Selector = CreateSelector,
})
