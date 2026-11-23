--!strict

const Compatibility = require("./Compatibility")
const Graph = require("./Graph")

local CreateEffect = Graph.Effect
local ReadRawValue = Graph.Raw
local ReadReactiveValue = Graph.Read
local CreateState = Graph.State
local RunUntracked = Graph.Untrack
local RunWithOwner = Graph.WithOwner
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
	FirstEffectRan : boolean,
	HandledBeforeFirstEffect : boolean,
	InputBeforeFirstEffect : any,
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
	RunUntracked(function()
		RunWithOwner(nil, function()
			TaskLibrary.spawn(RunFetcher, Self, Input, CurrentIdentifier, Refetching)
		end)
	end)
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
		FirstEffectRan = false,
		HandledBeforeFirstEffect = false,
		InputBeforeFirstEffect = nil,
	}, Asynchronous)

	Self.Effect = CreateEffect(function()
		local Input = ReadReactiveValue(ReactiveSource)
		if not Self.FirstEffectRan then
			Self.FirstEffectRan = true
			local PreviousInput = Self.InputBeforeFirstEffect
			local AlreadyHandled = Self.HandledBeforeFirstEffect
			Self.InputBeforeFirstEffect = nil
			Self.HandledBeforeFirstEffect = false
			if AlreadyHandled and (ReactiveSource == nil or rawequal(Input, PreviousInput)
				or (type(Input) == "number" and type(PreviousInput) == "number"
					and Input ~= Input and PreviousInput ~= PreviousInput)) then
				return
			end
		end
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

const function RememberInitialInput(Self : Data, Input : any)
	if not Self.FirstEffectRan then
		Self.HandledBeforeFirstEffect = true
		Self.InputBeforeFirstEffect = Input
	end
end

function Asynchronous.Mutate(Self : Data, Value : any)
	if Self.Effect == nil then
		return
	end
	if not Self.FirstEffectRan then
		RememberInitialInput(Self, ReadRawValue(Self.Source))
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
	RememberInitialInput(Self, Input)
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
