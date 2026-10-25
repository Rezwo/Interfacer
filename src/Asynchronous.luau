--!strict

const Compatibility = require("./Compatibility")
const Graph = require("./Graph")

local CreateEffect = Graph.Effect
local ReadRawValue = Graph.Raw
local ReadReactiveValue = Graph.Read
local CreateState = Graph.State
local RunUntracked = Graph.Untrack
local RunRetracked = Graph.Retrack
local TaskLibrary = Compatibility.Task

const function GatedOff(ReactiveSource : any, Input : any) : boolean
	return ReactiveSource ~= nil and (Input == nil or Input == false)
end

export type AsynchronousState = "Unresolved" | "Pending" | "Ready" | "Refreshing" | "Errored"

export type Asynchronous<ValueType> = {
	Data : Graph.Node<ValueType?>,
	Error : Graph.Node<string?>,
	Loading : Graph.Node<boolean>,
	State : Graph.Node<AsynchronousState>,

	Destroy : (Self : any) -> (),

	Refetch : (Self : any, Refetching : any?) -> (),

	Mutate : (Self : any, Value : ValueType) -> (),
}

type Data = {
	Data : Graph.Node<any>,
	Error : Graph.Node<string?>,
	Loading : Graph.Node<boolean>,
	State : Graph.Node<AsynchronousState>,
	HasResolved : boolean,
	Effect : Graph.Node<any>,
	Source : any,
	Fetcher : any,
	FetchIdentifier : number,
}

const function RunFetcher(Self : Data, Input : any, CurrentIdentifier : number, Refetching : any)
	local Passed, Result = pcall(Self.Fetcher, Input, ReadRawValue(Self.Data), Refetching)
	if CurrentIdentifier == Self.FetchIdentifier then
		Self.Loading:Set(false)
		if Passed then
			Self.HasResolved = true
			Self.Data:Set(Result)
			Self.State:Set("Ready")
		else
			Self.Error:Set(tostring(Result))
			Self.State:Set("Errored")
		end
	end
end

const function Trigger(Self : Data, Input : any, Refetching : any)
	Self.FetchIdentifier += 1
	local CurrentIdentifier = Self.FetchIdentifier
	Self.Loading:Set(true)
	Self.Error:Set(nil)
	Self.State:Set(if Self.HasResolved then "Refreshing" else "Pending")
	RunUntracked()
	TaskLibrary.spawn(RunFetcher, Self, Input, CurrentIdentifier, Refetching)
	RunRetracked()
end

local Asynchronous = {}
Asynchronous.__index = Asynchronous

const function Create(Source : any, Fetcher : any, InitialValue : any) : Asynchronous<any>
	local ReactiveSource : any = Source
	local Fetch : any = Fetcher
	local InitialData : any = InitialValue
	if type(Fetch) ~= "function" then
		ReactiveSource, Fetch, InitialData = nil, Source, Fetcher
	end

	local Self : any = setmetatable({
		Data = CreateState(InitialData),
		Error = CreateState(nil :: string?),
		Loading = CreateState(false),
		State = CreateState("Unresolved" :: AsynchronousState),
		HasResolved = false,
		Effect = nil :: any,
		Source = ReactiveSource,
		Fetcher = Fetch,
		FetchIdentifier = 0,
	}, Asynchronous)

	Self.Effect = CreateEffect(function()
		local Input = ReadReactiveValue(ReactiveSource)
		if GatedOff(ReactiveSource, Input) then
			Self.FetchIdentifier += 1
			Self.Loading:Set(false)
			Self.Error:Set(nil)
			Self.State:Set(if Self.HasResolved then "Ready" else "Unresolved")
			return
		end
		Trigger(Self, Input, false)
	end)

	if Graph.GetOwner() then
		Graph.Cleanup(Self)
	end

	return Self
end

function Asynchronous.Destroy(Self : Data)
	if Self.Effect == nil then
		return
	end
	Self.State:Destroy()
	Self.Data:Destroy()
	Self.Error:Destroy()
	Self.Loading:Destroy()
	Self.Effect:Destroy()
	local NextIdentifier = Self.FetchIdentifier + 1
	table.clear(Self :: any)
	Self.FetchIdentifier = NextIdentifier
end

function Asynchronous.Mutate(Self : Data, Value : any)
	if Self.Effect == nil then
		return
	end
	Self.FetchIdentifier += 1
	Self.HasResolved = true
	Self.Loading:Set(false)
	Self.Error:Set(nil)
	Self.Data:Set(Value)
	Self.State:Set("Ready")
end

function Asynchronous.Refetch(Self : Data, Refetching : any?)
	if Self.Effect == nil then
		return
	end
	local ReactiveSource = Self.Source
	local Input = ReadRawValue(ReactiveSource)
	if GatedOff(ReactiveSource, Input) then
		return
	end
	Trigger(Self, Input, if Refetching == nil then true else Refetching)
end

Asynchronous.New = Create :: (<SourceType, ValueType>(
	Source : SourceType,
	Fetcher : (
		Value : Graph.Unwrap<SourceType>,
		PreviousResult : ValueType?,
		Refetching : any
	) -> ValueType,
	InitialValue : ValueType?
) -> Asynchronous<ValueType>) & (<ValueType>(
	Fetcher : (Value : nil, PreviousResult : ValueType?, Refetching : any) -> ValueType,
	InitialValue : ValueType?
) -> Asynchronous<ValueType>)

return table.freeze(Asynchronous)
