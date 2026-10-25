--!strict
const Compatibility = require("./Compatibility")
const Graph = require("./Graph")
const Type = require("./Type")

local IsRoblox = Compatibility.IsRoblox
local CompatibleTypeOf = Compatibility.TypeOf
local ReportWarning = Compatibility.Warn

local CreateEffect = Graph.Effect
local ReadNodeValue = Graph.Node.Get
local CreateNode = Graph.New
local CreateState = Graph.State
local ReadRawValue = Graph.Raw
local ReadReactiveValue = Graph.Read
local RunUntracked = Graph.Untrack
local IsReactiveNode = Graph.IsNode
local IsTrackingCalculation = Graph.IsReactive
local RunWithOwner = Graph.WithOwner

local ModelSymbol = table.freeze({ type = "Model" }) :: any
local NoOperation = function() end

type BindingData = {
	InstanceBindings : { [Instance] : { { [string] : any }? } },
	Children : {
		CleanupConnection : RBXScriptConnection?,
		List : { Instance },
		Parent : Instance?,
		Order : number?,
		Token : number?,
	}?,
}

local BindingsByNode : { [Graph.Node<any>] : BindingData } = setmetatable({}, { __mode = "k" }) :: any
local BindingGeneration = 0
local PinnedOrder : { [Instance] : boolean } = setmetatable({}, { __mode = "k" }) :: any
local ParentWrites : { [Instance] : number } = setmetatable({}, { __mode = "k" }) :: any
local PendingDestruction : { [Instance] : boolean } = setmetatable({}, { __mode = "k" }) :: any
local PendingDetachment : { [Instance] : boolean } = setmetatable({}, { __mode = "k" }) :: any
local RevokedInstances : { [Instance] : boolean } = setmetatable({}, { __mode = "k" }) :: any
type PropertyDisconnections = { [string] : () -> () }
local InstanceDisconnections : { [Instance] : { PropertyDisconnections? } } =
	setmetatable({}, { __mode = "k" }) :: any

const function DisconnectProperty(TargetInstance : Instance, Property : string, IsAttribute : boolean?)
	local Buckets = InstanceDisconnections[TargetInstance]
	local Bucket = if Buckets then Buckets[if IsAttribute then 1 else 2] else nil
	local Disconnect = if Bucket then Bucket[Property] else nil
	if Disconnect then
		Disconnect()
	end
end

const function RevokeInstance(TargetInstance : Instance)
	RevokedInstances[TargetInstance] = true
	local Buckets = InstanceDisconnections[TargetInstance]
	if Buckets then
		for _, Bucket in Buckets do
			if Bucket then
				for _, Disconnect in Bucket do
					Disconnect()
				end
			end
		end
	end
end

const function DestroyInstance(TargetInstance : Instance)
	RevokeInstance(TargetInstance)
	if ParentWrites[TargetInstance] then
		PendingDestruction[TargetInstance] = true
	else
		TargetInstance:Destroy()
	end
end

local SetProperty : (Instance, string, any) -> ()

const function DetachChild(Child : Instance)
	if ParentWrites[Child] then
		PendingDetachment[Child] = true
	else
		SetProperty(Child, "Parent", nil)
	end
end

const function AssignDefaultLayoutOrder(Child : Instance, Order : number) : number
	if
		Child:IsA("GuiObject")
		and (Child :: GuiObject).LayoutOrder == 0
		and not PinnedOrder[Child]
	then
		(Child :: GuiObject).LayoutOrder = Order
		return Order + 1
	end
	return Order
end

local function KindOf(Value : any) : string
	local Kind = typeof(Value)
	if Kind == "table" and not IsRoblox then
		return CompatibleTypeOf(Value)
	end
	return Kind
end

local function IsInstance(Value : any) : boolean
	return KindOf(Value) == "Instance"
end

const function CollectChildren(Value : any, DestinationChildren : { Instance }) : { Instance }
	if IsInstance(Value) then
		table.insert(DestinationChildren, Value)
	elseif IsReactiveNode(Value) then
		CollectChildren(ReadNodeValue(Value), DestinationChildren)
	elseif type(Value) == "table" then
		for _, Child in Value do
			CollectChildren(Child, DestinationChildren)
		end
	end
	return DestinationChildren
end

const function ApplyChildren(BindingDataRecord : BindingData, Value : any)
	local Data = BindingDataRecord.Children
	if Data == nil then
		return
	end
	local List = Data.List
	local ParentInstance = Data.Parent
	local NextLayoutOrder = Data.Order or 1

	while IsReactiveNode(Value) do
		Value = ReadNodeValue(Value)
	end

	if type(Value) == "table" and not IsInstance(Value) then
		local IncomingChildren = CollectChildren(Value, {})
		if List[1] ~= nil then
			if IncomingChildren[2] == nil then
				local First = IncomingChildren[1]
				for _, Child in List do
					if Child.Parent == ParentInstance and Child ~= First then
						DetachChild(Child)
					end
				end
			else
				local Incoming : { [Instance] : true } = {}
				for _, Child in IncomingChildren do
					Incoming[Child] = true
				end
				for _, Child in List do
					if Child.Parent == ParentInstance and Incoming[Child] == nil then
						DetachChild(Child)
					end
				end
			end
			table.clear(List)
		end
		for Count, Child in IncomingChildren do
			if BindingDataRecord.Children ~= Data then
				return
			end
			NextLayoutOrder = AssignDefaultLayoutOrder(Child, NextLayoutOrder)
			List[Count] = Child
			SetProperty(Child, "Parent", ParentInstance)
		end
	else
		for _, Child in List do
			if Child.Parent == ParentInstance and Child ~= Value then
				DetachChild(Child)
			end
		end
		table.clear(List)
		if Value ~= nil and IsInstance(Value) then
			local Child = Value :: Instance
			AssignDefaultLayoutOrder(Child, NextLayoutOrder)
			List[1] = Child
			SetProperty(Child, "Parent", ParentInstance)
		end
	end
end

const function AssignAttribute(TargetInstance : Instance, AttributeName : string, Value : any)
	if not RevokedInstances[TargetInstance] then
		TargetInstance:SetAttribute(AttributeName, Value)
	end
end

const function AssignProperty(TargetInstance : Instance, Property : string, Value : any)
	(TargetInstance :: any)[Property] = Value
end

function SetProperty(TargetInstance : Instance, Property : string, Value : any)
	if RevokedInstances[TargetInstance] then
		return
	elseif Property ~= "Parent" then
		AssignProperty(TargetInstance, Property, Value)
		return
	end
	ParentWrites[TargetInstance] = (ParentWrites[TargetInstance] or 0) + 1
	local Passed, Failure = pcall(AssignProperty, TargetInstance, Property, Value)
	local Depth = ParentWrites[TargetInstance] - 1
	ParentWrites[TargetInstance] = if Depth > 0 then Depth else nil
	local DestroyPassed, DestroyFailure = true, nil :: any
	if Depth == 0 and PendingDestruction[TargetInstance] then
		PendingDestruction[TargetInstance] = nil
		PendingDetachment[TargetInstance] = nil
		DestroyPassed, DestroyFailure = pcall(TargetInstance.Destroy, TargetInstance)
	elseif Depth == 0 and PendingDetachment[TargetInstance] then
		PendingDetachment[TargetInstance] = nil
		DestroyPassed, DestroyFailure = pcall(AssignProperty, TargetInstance, "Parent", nil)
	end
	if not Passed then
		error(Failure, 0)
	elseif not DestroyPassed then
		error(DestroyFailure, 0)
	end
end

const function ResolveKey(Name : string, IsAttribute : boolean?) : (string, boolean, boolean)
	if IsAttribute == nil then
		local First = string.byte(Name)
		if First == 36 then
			local AttributeName = string.sub(Name, 2)
			if AttributeName == "" then
				error('attribute name after "$" cannot be empty', 4)
			end
			return AttributeName, true, false
		elseif First == 35 then
			local Tag = string.sub(Name, 2)
			if Tag == "" then
				error('tag name after "#" cannot be empty', 4)
			end
			return Tag, false, true
		elseif First == 95 then
			if string.sub(Name, 1, 6) == "_attr_" then
				local AttributeName = string.sub(Name, 7)
				if AttributeName == "" then
					error('attribute name after "_attr_" cannot be empty', 4)
				end
				return AttributeName, true, false
			elseif string.sub(Name, 1, 5) == "_tag_" then
				local Tag = string.sub(Name, 6)
				if Tag == "" then
					error('tag name after "_tag_" cannot be empty', 4)
				end
				return Tag, false, true
			end
		end
		return Name, false, false
	end
	return Name, IsAttribute, false
end

local function OnTagChanged(
	TargetInstance : Instance,
	Tag : string,
	Callback : (ContainsTag : boolean) -> ()
) : () -> ()
	local CollectionService = Compatibility.GetService("CollectionService")
	if CollectionService == nil then
		return NoOperation
	end
	local Last = TargetInstance:HasTag(Tag)
	local function Check(Inst : Instance)
		if Inst == TargetInstance then
			local Current = TargetInstance:HasTag(Tag)
			if Current ~= Last then
				Last = Current
				Callback(Current)
			end
		end
	end
	local Added = CollectionService:GetInstanceAddedSignal(Tag):Connect(Check)
	local Removed = CollectionService:GetInstanceRemovedSignal(Tag):Connect(Check)
	local Ancestry = TargetInstance.AncestryChanged:Connect(function()
		Check(TargetInstance)
	end)
	return function()
		Added:Disconnect()
		Removed:Disconnect()
		Ancestry:Disconnect()
	end
end

local function OnChanged(
	TargetInstance : Instance,
	Name : string,
	IsAttribute : boolean?,
	Callback : (Value : any) -> ()
) : RBXScriptConnection
	if IsAttribute then
		return TargetInstance:GetAttributeChangedSignal(Name):Connect(function()
			Callback(TargetInstance:GetAttribute(Name))
		end)
	end
	return TargetInstance:GetPropertyChangedSignal(Name):Connect(function()
		Callback((TargetInstance :: any)[Name])
	end)
end

const function WriteInstance(BindingDataRecord : BindingData, Value : any)
	for TargetInstance, SynchronizationTarget in BindingDataRecord.InstanceBindings do
		local AttributeValues = SynchronizationTarget[1]
		if AttributeValues then
			for AttributeName in AttributeValues do
				AssignAttribute(TargetInstance, AttributeName, Value)
			end
		end
		local Properties = SynchronizationTarget[2]
		if Properties then
			for Property in Properties do
				SetProperty(TargetInstance, Property, Value)
			end
		end
	end
end

const function ProcessBinds(BindingDataRecord : BindingData, Value : any)
	if
		next(BindingDataRecord.InstanceBindings) ~= nil
		and not pcall(WriteInstance, BindingDataRecord, Value)
	then
		for TargetInstance, SynchronizationTarget in BindingDataRecord.InstanceBindings do
			local AttributeValues = SynchronizationTarget[1]
			if AttributeValues then
				for AttributeName in AttributeValues do
					local Passed, Result = pcall(AssignAttribute, TargetInstance, AttributeName, Value)
					if not Passed then
						ReportWarning(
							`[Flux] failed to set attribute "{AttributeName}" of {TargetInstance:GetFullName()}: {Result}`
						)
					end
				end
			end
			local Properties = SynchronizationTarget[2]
			if Properties then
				for Property in Properties do
					local Passed, Result = pcall(SetProperty, TargetInstance, Property, Value)
					if not Passed then
						ReportWarning(
							`[Flux] failed to set property "{Property}" of {TargetInstance:GetFullName()}: {Result}`
						)
					end
				end
			end
		end
	end
	ApplyChildren(BindingDataRecord, Value)
end

const function CleanupChildrenBind<ValueType>(Record : Graph.Node<ValueType>, ParentInstance : Instance?)
	local Data = BindingsByNode[Record]
	if Data and Data.Children then
		local IncomingChildren = Data.Children
		Data.Children = nil
		IncomingChildren.Token = nil
		IncomingChildren.Parent = nil
		if IncomingChildren.CleanupConnection then
			IncomingChildren.CleanupConnection:Disconnect()
		end
		for _, Child in IncomingChildren.List do
			local Current = Child and Child.Parent
			if Current ~= nil and (ParentInstance == nil or Current == ParentInstance) then
				DetachChild(Child)
			end
		end
		table.clear(IncomingChildren.List)
		table.clear(IncomingChildren)
	end
end

const function GetBindData<ValueType>(Record : Graph.Node<ValueType>)
	local Data : any = BindingsByNode[Record]
	if Data == nil then
		Data = { InstanceBindings = {}, Children = nil :: any }
		BindingsByNode[Record] = Data
		local EffectRegistration = RunWithOwner(nil :: any, function()
			return CreateEffect(function()
				ProcessBinds(Data, ReadNodeValue(Record))
			end)
		end)
		Record:OnDestroy(function()
			EffectRegistration:Destroy()
			for TargetInstance, Buckets in Data.InstanceBindings do
				for Index, Bucket in Buckets do
					if Bucket then
						for Property in Bucket do
							DisconnectProperty(TargetInstance, Property, Index == 1)
						end
					end
				end
			end
			table.clear(Data.InstanceBindings)
			CleanupChildrenBind(Record)
			BindingsByNode[Record] = nil
		end)
	end
	return Data
end

local Bind = {

	PinOrder = function(TargetInstance : Instance)
		PinnedOrder[TargetInstance] = true
	end,

	ApplyLayoutOrder = AssignDefaultLayoutOrder,

	ModelSymbol = ModelSymbol,

	KindOf = KindOf,

	IsInstance = IsInstance,

	SetAttribute = AssignAttribute,

	SetProperty = SetProperty,

	DisconnectProperty = DisconnectProperty,

	DestroyInstance = DestroyInstance,

	RevokeInstance = RevokeInstance,
	IsRevoked = function(TargetInstance : Instance) : boolean
		return RevokedInstances[TargetInstance] == true
	end,

	OnChanged = OnChanged,

	OnTagChanged = OnTagChanged,
}

function Bind.Model<NodeType>(Record : NodeType) : Graph.Unwrap<NodeType>
	if not IsReactiveNode(Record) then
		error("Flux.model expects a reactive node", 2)
	end
	return table.freeze({ ModelSymbol, Record }) :: any
end

function Bind.IsModel(Value : unknown) : boolean
	return type(Value) == "table" and (Value :: any)[1] == ModelSymbol
end

function Bind.ModelNode(Value : unknown) : Graph.Node<any>?
	return if Bind.IsModel(Value) then (Value :: any)[2] else nil
end

function Bind.Children<ValueType>(
	Record : Graph.Node<ValueType>,
	ParentInstance : Instance,
	NextLayoutOrder : number?,
	CleanupValues : { any }?
) : () -> ()
	local Data = GetBindData(Record)
	BindingGeneration += 1
	local Token = BindingGeneration
	local function DisconnectBind()
		local Current = Data.Children
		if Current ~= nil and Current.Token == Token then
			CleanupChildrenBind(Record, ParentInstance)
		end
	end

	local IncomingChildren = Data.Children
	if IncomingChildren == nil then
		IncomingChildren = { List = {} }
		Data.Children = IncomingChildren
	else
		if IncomingChildren.CleanupConnection then
			IncomingChildren.CleanupConnection:Disconnect()
		end
		local OldParent = IncomingChildren.Parent
		if OldParent ~= nil and OldParent ~= ParentInstance then
			for _, Child in IncomingChildren.List do
				if Child and Child.Parent == OldParent then
					DetachChild(Child)
				end
			end
			table.clear(IncomingChildren.List)
		end
	end
	IncomingChildren.CleanupConnection = ParentInstance.Destroying:Once(DisconnectBind)
	IncomingChildren.Order = NextLayoutOrder or 1
	IncomingChildren.Parent = ParentInstance
	IncomingChildren.Token = Token
	if CleanupValues then
		table.insert(CleanupValues, DisconnectBind)
	end

	if IsTrackingCalculation() then
		RunUntracked(function()
			ApplyChildren(Data, ReadRawValue(Record))
		end)
	else
		ApplyChildren(Data, ReadRawValue(Record))
	end
	return DisconnectBind
end

function Bind.From<ValueType>(
	Record : Graph.Node<ValueType>,
	TargetInstance : Instance,
	PropertyName : string,
	IsAttribute : boolean?
) : (Graph.Node<ValueType>, () -> ())
	local Name, Attribute, IsTag = ResolveKey(PropertyName, IsAttribute)
	local DisconnectBinding : (...any) -> ()
	if IsTag then
		Record:Set(TargetInstance:HasTag(Name) :: any)
		DisconnectBinding = OnTagChanged(TargetInstance, Name, function(ContainsTag)
			Record:Set(ContainsTag :: any)
		end)
	else
		Record:Set(
			if Attribute then TargetInstance:GetAttribute(Name) else (TargetInstance :: any)[Name]
		)
		local Connection = if Attribute
			then TargetInstance:GetAttributeChangedSignal(Name):Connect(function()
				Record:Set(TargetInstance:GetAttribute(Name) :: any)
			end)
			else TargetInstance:GetPropertyChangedSignal(Name):Connect(function()
				Record:Set((TargetInstance :: any)[Name])
			end)
		DisconnectBinding = function()
			Connection:Disconnect()
		end
	end
	Record:OnDestroy(DisconnectBinding :: (ValueType) -> ())
	return Record, DisconnectBinding
end

const function Follow(TargetInstance : Instance, PropertyName : string) : Graph.Node<any>
	return (Bind.From(CreateState(nil :: any), TargetInstance, PropertyName))
end

function Bind.Property<InstanceType, KeyType>(
	TargetInstance : InstanceType & Instance,
	PropertyName : KeyType | "Name"
) : Graph.Node<Type.PropertyType<InstanceType, KeyType>>
	if not IsInstance(TargetInstance) then
		error(`Flux.property expects an Instance, got {CompatibleTypeOf(TargetInstance)}`, 2)
	elseif type(PropertyName) ~= "string" then
		error(
			`Flux.property expects a property, "$Attribute", or "#Tag" name, got {CompatibleTypeOf(
				PropertyName
			)}`,
			2
		)
	end
	return Follow(TargetInstance, PropertyName)
end

function Bind.Node(Object : any, Second : string?) : Graph.Node<any>
	if IsInstance(Object) then
		if type(Second) ~= "string" then
			error(
				`Flux(instance, property) expects a property, "$Attribute", or "#Tag" name, got {CompatibleTypeOf(
					Second
				)}`,
				3
			)
		end
		return Follow(Object, Second)
	elseif Second ~= nil then
		error(`Flux(value) takes a single argument; only an Instance takes a property name`, 3)
	end
	return CreateNode(Object)
end

function Bind.On<DependencyType, ResultType>(
	Dependencies : any,
	Callback : (
		Input : any,
		PreviousInput : any?,
		PreviousResult : ResultType?
	) -> ResultType,
	Defer : boolean?
) : (PreviousResult : ResultType?) -> ResultType?
	local IsArray = type(Dependencies) == "table" and not IsReactiveNode(Dependencies)
	local Count = if IsArray then #(Dependencies :: { any }) else 0
	local PreviousInput : any = nil

	return function(PreviousResult : ResultType?) : ResultType?
		local Input
		if IsArray then
			Input = table.create(Count)
			for Index = 1, Count do
				Input[Index] = ReadReactiveValue(Dependencies[Index])
			end
		else
			Input = ReadReactiveValue(Dependencies)
		end

		if Defer then
			Defer = false
			PreviousInput = Input
			return PreviousResult
		end

		local Result
		RunUntracked(function()
			Result = Callback(Input, PreviousInput, PreviousResult)
		end)
		PreviousInput = Input
		return Result
	end
end

function Bind.To<ValueType>(
	Record : Graph.Node<ValueType>,
	TargetInstance : Instance,
	PropertyName : string,
	IsAttribute : boolean?,
	CleanupValues : { any }?,
	OnRevoked : (() -> ())?
)
	if RevokedInstances[TargetInstance] then
		return NoOperation, false
	end
	local Data = GetBindData(Record)
	local Attribute = IsAttribute == true
	local BindingBucketIndex = if Attribute then 1 else 2
	DisconnectProperty(TargetInstance, PropertyName, Attribute)

	local InstanceBindingBuckets = Data.InstanceBindings[TargetInstance]
	if InstanceBindingBuckets == nil then
		InstanceBindingBuckets = {}
		Data.InstanceBindings[TargetInstance] = InstanceBindingBuckets
	end
	local Bucket = InstanceBindingBuckets[BindingBucketIndex]
	if Bucket == nil then
		Bucket = {}
		InstanceBindingBuckets[BindingBucketIndex] = Bucket
	end

	BindingGeneration += 1
	local Token = BindingGeneration
	Bucket[PropertyName] = Token
	local TargetBuckets : { PropertyDisconnections? }? = InstanceDisconnections[TargetInstance]
	if not TargetBuckets then
		TargetBuckets = {}
		InstanceDisconnections[TargetInstance] = TargetBuckets
	end
	local TargetBucket : PropertyDisconnections? = (TargetBuckets :: { PropertyDisconnections? })[BindingBucketIndex]
	if not TargetBucket then
		TargetBucket = {}
		(TargetBuckets :: { PropertyDisconnections? })[BindingBucketIndex] = TargetBucket
	end
	local RegisteredTarget : Instance? = TargetInstance
	local function DisconnectBinding()
		local Target = RegisteredTarget
		local ActiveTargetBuckets = TargetBuckets
		local ActiveTargetBucket = TargetBucket
		if not Target or not ActiveTargetBuckets or not ActiveTargetBucket then
			return
		end
		RegisteredTarget = nil
		if Bucket[PropertyName] == Token then
			Bucket[PropertyName] = nil
			ActiveTargetBucket[PropertyName] = nil
		end
		if
			(InstanceBindingBuckets[1] == nil or next(InstanceBindingBuckets[1]) == nil)
			and (InstanceBindingBuckets[2] == nil or next(InstanceBindingBuckets[2]) == nil)
		then
			Data.InstanceBindings[Target] = nil
		end
		local AttributeDisconnections = ActiveTargetBuckets[1]
		local PropertyDisconnections = ActiveTargetBuckets[2]
		if
			(AttributeDisconnections == nil or next(AttributeDisconnections) == nil)
			and (PropertyDisconnections == nil or next(PropertyDisconnections) == nil)
		then
			InstanceDisconnections[Target] = nil
		end
		Data, Bucket, InstanceBindingBuckets, TargetBucket, TargetBuckets = nil, nil, nil, nil, nil
		local Release = OnRevoked
		OnRevoked = nil
		if Release then
			Release()
		end
	end
	(TargetBucket :: PropertyDisconnections)[PropertyName] = DisconnectBinding
	if CleanupValues then
		table.insert(CleanupValues, DisconnectBinding)
	end
	local Passed, Failure = pcall(ReadRawValue :: (Graph.Node<ValueType>) -> ValueType, Record)
	if Passed and RegisteredTarget then
		Passed, Failure = pcall(if Attribute then AssignAttribute else SetProperty, TargetInstance, PropertyName, Failure)
	end
	if not Passed then
		DisconnectBinding()
		error(Failure, 0)
	end
	return DisconnectBinding, RegisteredTarget ~= nil
end

return table.freeze(Bind)
