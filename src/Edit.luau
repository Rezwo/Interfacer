--!strict
const Bind = require("./Bind")
const Compatibility = require("./Compatibility")
const Graph = require("./Graph")
const Type = require("./Type")

local IsRoblox = Compatibility.IsRoblox
local Color3 = Compatibility.Color3
local Enum = if IsRoblox then Enum else Compatibility.Enum
local CompatibleTypeOf = Compatibility.TypeOf
local TaskLibrary = Compatibility.Task
local ReportWarning = Compatibility.Warn

local DisposeResource = Graph.Dispose
local ReadNodeValue = Graph.Node.Get
local IsReactiveNode = Graph.IsNode
local CreateNode = Graph.New
local CreateEffect = Graph.Effect
local GetCurrentOwner = Graph.GetOwner
local RegisterCleanup = Graph.Cleanup
local CaptureContext = Graph.BindContext

local BindFrom = Bind.From
local BindTo = Bind.To
local IsModelValue = Bind.IsModel
local OnChanged = Bind.OnChanged
local OnTagChanged = Bind.OnTagChanged
local SetAttribute = Bind.SetAttribute
local SetProperty = Bind.SetProperty

local KindOf = Bind.KindOf

local Flags = {

	Defaults = true,
}

local WhiteColor = Color3.new(1, 1, 1)
local BlackColor = Color3.new(0, 0, 0)

const function CreateBaseGuiDefaults(Extra : { [string] : unknown }?) : { [string] : unknown }
	local PropertyValues : { [string] : unknown } = {
		BackgroundColor3 = WhiteColor,
		BorderColor3 = BlackColor,
		BorderSizePixel = 0,
	}
	if Extra then
		for Key, Value in Extra do
			PropertyValues[Key] = Value
		end
	end
	return PropertyValues
end

const function CreateBaseTextDefaults(Extra : { [string] : unknown }?) : { [string] : unknown }
	local PropertyValues = CreateBaseGuiDefaults({
		Font = Enum.Font.SourceSans,
		Text = "",
		TextColor3 = BlackColor,
	})
	if Extra then
		for Key, Value in Extra do
			PropertyValues[Key] = Value
		end
	end
	return PropertyValues
end

local Defaults : { [string] : { [string] : unknown } } = {
	Part = {
		Material = Enum.Material.SmoothPlastic,
		Size = vector.create(1, 1, 1),
		Anchored = true,
	},
	BillboardGui = {
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	},
	ScreenGui = {
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	},
	SurfaceGui = {
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		PixelsPerStud = 50,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
	},
	Frame = CreateBaseGuiDefaults(),
	ImageButton = CreateBaseGuiDefaults(),
	ImageLabel = CreateBaseGuiDefaults(),
	VideoFrame = CreateBaseGuiDefaults(),
	ViewportFrame = CreateBaseGuiDefaults(),
	ScrollingFrame = CreateBaseGuiDefaults({ ScrollBarImageColor3 = BlackColor }),
	TextBox = CreateBaseTextDefaults({ ClearTextOnFocus = false }),
	TextButton = CreateBaseTextDefaults(),
	TextLabel = CreateBaseTextDefaults(),
	UIListLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
	UIGridLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
	UITableLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
	UIPageLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
}

local FindSymbol = table.freeze({ type = "Symbol" }) :: Type.Symbol

const function IndexParent(TargetInstance : Instance) : Instance?
	return TargetInstance.Parent
end

const function FirstDescendant(TargetInstance : Instance, InstanceName : string) : Instance?
	return TargetInstance:FindFirstChild(InstanceName, true)
end

const function FindFirstQueryMatch(TargetInstance : Instance, FindQueryMatches : string) : Instance?
	return TargetInstance:QueryDescendants(FindQueryMatches)[1]
end

const function FindPath(TargetInstance : Instance, PathStr : string) : Instance?
	local CurrentValue : Instance = TargetInstance
	for _, Segment in string.split(PathStr, ".") do
		if Segment == "" then
			continue
		end
		local NextInst = if Segment == "Parent" or Segment == "^"
			then CurrentValue.Parent
			else CurrentValue:FindFirstChild(Segment)
		if not NextInst then
			return nil
		end
		CurrentValue = NextInst
	end
	return CurrentValue
end

const function MakeSelector(FindHelpers : any) : any
	local Callback = if type(FindHelpers) ~= "string"
		then FindHelpers
		elseif IsRoblox then (game :: any)[FindHelpers]
		else function(TargetInstance : any, FindQueryMatches : string) : any
			return TargetInstance[FindHelpers](TargetInstance, FindQueryMatches)
		end
	return function(FindQueryMatches : string)
		return function(Properties : Type.Map<any>)
			return { FindSymbol, Callback, Properties, FindQueryMatches }
		end
	end
end

type Fallback<Name> = index<Type.Editable & { [string] : Instance }, Name>

export type Selection = { any }
export type ClassSelector = <ValueType>(
	ClassName : ValueType | keyof<Type.Editable>
) -> (Type.EditProperties<Fallback<ValueType>>) -> Selection

export type QuerySelector = (FindQueryMatches : string) -> (Type.Map<any>) -> Selection
export type ParentSelector = () -> (Type.Map<any>) -> Selection

const function WarnFind(FindQueryMatches : string?, Value : any)
	local Description = if FindQueryMatches == nil
		then "a Find selector"
		else `query "{FindQueryMatches}"`
	ReportWarning(`[Flux] Instance expected for {Description}, got {CompatibleTypeOf(Value)}`)
end

const function ResolveFind(
	Applied : { any },
	TargetInstance : Instance,
	Apply : (Instance, Type.Map<any>) -> ()
)
	local FindQueryMatches = Applied[4]
	local Result = Applied[2](TargetInstance, FindQueryMatches)
	local Properties = Applied[3]
	local Kind = KindOf(Result)

	if Kind == "Instance" then
		Apply(Result, Properties)
	elseif Kind == "table" then
		for _, Item in Result do
			if KindOf(Item) == "Instance" then
				Apply(Item, Properties)
			else
				WarnFind(FindQueryMatches, Item)
			end
		end
	else
		WarnFind(FindQueryMatches, Result)
	end
end

local Find = table.freeze({

	Symbol = FindSymbol,

	Ancestor = MakeSelector("FindFirstAncestor") :: QuerySelector,

	AncestorClass = MakeSelector("FindFirstAncestorOfClass") :: ClassSelector,

	AncestorIsA = MakeSelector("FindFirstAncestorWhichIsA") :: ClassSelector,

	Child = MakeSelector("FindFirstChild") :: QuerySelector,

	ChildClass = MakeSelector("FindFirstChildOfClass") :: ClassSelector,

	ChildIsA = MakeSelector("FindFirstChildWhichIsA") :: ClassSelector,

	Descendant = MakeSelector(FirstDescendant) :: QuerySelector,

	Parent = MakeSelector(IndexParent) :: ParentSelector,

	Path = MakeSelector(FindPath) :: QuerySelector,

	Query = MakeSelector("QueryDescendants") :: QuerySelector,

	QueryFirst = MakeSelector(FindFirstQueryMatch) :: QuerySelector,

	resolve = ResolveFind,
})

export type function Partial(PropertyValues : type) : type
	if not PropertyValues:is("table") then
		return PropertyValues
	end
	local Result = types.newtable()
	for PropertyKey, Property in PropertyValues:properties() do
		local ValueType = Property.read or Property.write
		if ValueType then
			Result:setproperty(PropertyKey, types.optional(ValueType))
		end
	end
	local Indexer = PropertyValues:indexer()
	if Indexer then
		Result:setindexer(Indexer.index, Indexer.readresult)
	end
	return Result
end

type function GroupKeys(Group : type) : type
	local Keys = types.newtable()
	if Group:is("nil") then
		return Keys
	elseif Group:is("union") or Group:is("intersection") then
		for _, PathSegment in Group:components() do
			local PartKeys = GroupKeys(PathSegment)
			if PartKeys:is("string") then
				return PartKeys
			end
			for PropertyKey in PartKeys:properties() do
				Keys:setproperty(PropertyKey, PropertyKey)
			end
		end
		return Keys
	elseif not Group:is("table") then
		return types.string
	end
	local Indexer = Group:indexer()
	if Indexer then
		local Result = Indexer.readresult
		for _, PathSegment in if Result:is("union") then Result:components() else { Result } do
			local InstanceName = if PathSegment:is("singleton") then PathSegment:value() else nil
			if type(InstanceName) == "string" then
				Keys:setproperty(PathSegment, PathSegment)
			elseif InstanceName ~= true then
				return types.string
			end
		end
	end
	for PropertyKey in Group:properties() do
		Keys:setproperty(PropertyKey, PropertyKey)
	end
	return Keys
end

type function PickWhere(PropertyValues : type, Group : type, Prior : type, InGroup : type) : type
	if not PropertyValues:is("table") then
		return PropertyValues
	end
	local Wanted, Excluded = GroupKeys(Group), GroupKeys(Prior)
	local WantAll = InGroup:is("singleton") and InGroup:value() == false
	if Wanted:is("string") or Excluded:is("string") then
		return Partial(PropertyValues)
	end
	local function Has(Names : type, PropertyKey : type) : boolean
		return Names:readproperty(PropertyKey) ~= nil
	end
	local Result = types.newtable()
	for PropertyKey, Property in PropertyValues:properties() do
		local ValueType = Property.read or Property.write
		local InWanted = Has(Wanted, PropertyKey)
		if ValueType and not Has(Excluded, PropertyKey) and InWanted ~= WantAll then
			Result:setproperty(PropertyKey, ValueType)
		end
	end
	local Indexer = PropertyValues:indexer()
	if Indexer and WantAll then
		Result:setindexer(Indexer.index, Indexer.readresult)
	end
	return Result
end

export type Pick<ValueType, PropertyGroupType> = PickWhere<ValueType, PropertyGroupType, nil, true>

export type Omit<ValueType, PropertyGroupType> = PickWhere<ValueType, nil, PropertyGroupType, false>

const function SplitProperties(Properties : any, Keys : any, ... : any) : ...any
	if select("#", ...) == 0 then
		local Own = {}
		local Rest = {}
		if type(Properties) == "table" then
			if Keys[1] ~= nil then
				for _, PropertyKey in Keys do
					local PropertyValue = Properties[PropertyKey]
					if PropertyValue ~= nil then
						Own[PropertyKey] = PropertyValue
					end
				end
				for PropertyKey, Value in Properties :: any do
					if Own[PropertyKey] == nil then
						Rest[PropertyKey] = Value
					end
				end
			else
				for PropertyKey, Value in Properties :: any do
					local Target = if Keys[PropertyKey] ~= nil then Own else Rest
					Target[PropertyKey] = Value
				end
			end
		end
		return Own, Rest
	end

	local Groups = table.pack(Keys, ...)
	local Count = Groups.n
	local Owners : { [any] : number } = {}
	local Results : { { [any] : any } } = {}

	for index = 1, Count do
		Results[index] = {}
		local Group = Groups[index]
		if Group[1] ~= nil then
			for _, PropertyKey in Group do
				if Owners[PropertyKey] == nil then
					Owners[PropertyKey] = index
				end
			end
		else
			for PropertyKey in Group do
				if Owners[PropertyKey] == nil then
					Owners[PropertyKey] = index
				end
			end
		end
	end

	local Rest = {}
	Results[Count + 1] = Rest
	if type(Properties) == "table" then
		for PropertyKey, Value in Properties :: any do
			local Owner = Owners[PropertyKey]
			local Target = if Owner ~= nil then Results[Owner] else Rest
			Target[PropertyKey] = Value
		end
	end

	return table.unpack(Results :: any, 1, Count + 1)
end

type Split =
	(<ValueType, PropertyGroupType>(
		Properties : ValueType?,
		Keys : PropertyGroupType
	) -> (Pick<ValueType, PropertyGroupType>, Omit<ValueType, PropertyGroupType>))
	& (<ValueType>(
		Properties : ValueType?,
		First : { [any] : any },
		Second : { [any] : any },
		...{ [any] : any }
	) -> ...Partial<ValueType>)

const function BindModel(
	Record : any,
	TargetInstance : Instance,
	Property : string,
	CleanupValues : { any },
	IsAttribute : boolean
)
	local Cancelled = false
	local Disconnect : (() -> ())? = nil
	local function CancelBinding()
		Cancelled = true
		local Release = Disconnect
		Disconnect = nil
		if Release then
			Release()
		end
	end
	table.insert(CleanupValues, CancelBinding)
	local _, Active =
		BindTo(Record, TargetInstance, Property, IsAttribute, CleanupValues, CancelBinding)
	if not Active or Cancelled then
		return
	end
	local _, Release = BindFrom(Record, TargetInstance, Property, IsAttribute)
	if Cancelled then
		Release()
	else
		Disconnect = Release
	end
end

local TagCounts : { [Instance] : { [string] : number } } = setmetatable({}, { __mode = "k" }) :: any

const function AddTagReference(TargetInstance : Instance, Tag : string)
	local Counts = TagCounts[TargetInstance]
	if not Counts then
		Counts = {}
		TagCounts[TargetInstance] = Counts
	end
	local Count = Counts[Tag]
	Counts[Tag] = (Count or 0) + 1
	if not Count then
		TargetInstance:AddTag(Tag)
	end
end

const function RemoveTagReference(TargetInstance : Instance, Tag : string)
	local Counts = TagCounts[TargetInstance]
	local Count = if Counts then Counts[Tag] else nil
	if Count and Count > 1 then
		Counts[Tag] = Count - 1
	else
		if Counts then
			Counts[Tag] = nil
		end
		TargetInstance:RemoveTag(Tag)
	end
end

const function BindTag(TargetInstance : Instance, TagValue : any, CleanupValues : { any })
	if type(TagValue) == "string" then
		AddTagReference(TargetInstance, TagValue)
		return
	elseif type(TagValue) == "function" then
		TagValue = CreateNode(TagValue :: any)
		table.insert(CleanupValues, TagValue)
	end

	if IsReactiveNode(TagValue) then
		local Record = TagValue :: Graph.Node<any>
		local CurrentSet : { [string] : boolean } = {}

		local function UpdateTags(NewTag : string | { string })
			local NewSet : { [string] : boolean } = {}
			if type(NewTag) == "table" then
				for _, Tag in NewTag do
					NewSet[Tag] = true
				end
			elseif type(NewTag) == "string" then
				NewSet[NewTag] = true
			end
			for Tag in NewSet do
				if not CurrentSet[Tag] then
					AddTagReference(TargetInstance, Tag)
				end
			end
			for Tag in CurrentSet do
				if not NewSet[Tag] then
					RemoveTagReference(TargetInstance, Tag)
				end
			end
			CurrentSet = NewSet
		end

		UpdateTags(Record:Peek())
		table.insert(
			CleanupValues,
			CreateEffect(function()
				UpdateTags(ReadNodeValue(Record))
			end)
		)
	elseif type(TagValue) == "table" then
		for _, Value in TagValue do
			BindTag(TargetInstance, Value, CleanupValues)
		end
	end
end

const function StripUnmanagedTag(TargetInstance : Instance, Tag : string)
	local Counts = TagCounts[TargetInstance]
	if (not Counts or not Counts[Tag]) and TargetInstance:HasTag(Tag) then
		TargetInstance:RemoveTag(Tag)
	end
end

const function BindNamedTag(
	TargetInstance : Instance,
	Tag : string,
	TagValue : any,
	CleanupValues : { any }
)
	if IsModelValue(TagValue) then
		local ModelNode = TagValue[2]
		BindNamedTag(TargetInstance, Tag, ModelNode, CleanupValues)
		ModelNode:Set(TargetInstance:HasTag(Tag))
		local Disconnect = OnTagChanged(TargetInstance, Tag, function(ContainsTag)
			ModelNode:Set(ContainsTag)
		end)
		ModelNode:OnDestroy(Disconnect)
		table.insert(CleanupValues, Disconnect)
		return
	elseif type(TagValue) == "function" then
		TagValue = CreateNode(TagValue :: any)
		table.insert(CleanupValues, TagValue)
	end

	if IsReactiveNode(TagValue) then
		local Record = TagValue :: Graph.Node<any>
		local Active = not not Record:Peek()
		if Active then
			AddTagReference(TargetInstance, Tag)
		else
			StripUnmanagedTag(TargetInstance, Tag)
		end
		table.insert(
			CleanupValues,
			CreateEffect(function()
				local ShouldHave = not not ReadNodeValue(Record)
				if ShouldHave ~= Active then
					Active = ShouldHave
					if ShouldHave then
						AddTagReference(TargetInstance, Tag)
					else
						RemoveTagReference(TargetInstance, Tag)
					end
				end
			end)
		)
	elseif TagValue then
		AddTagReference(TargetInstance, Tag)
	else
		StripUnmanagedTag(TargetInstance, Tag)
	end
end

const function ApplyAttribute(
	TargetInstance : Instance,
	AttributeName : string,
	AttributeValue : any,
	AppliedAttributes : { [any] : boolean }?,
	CleanupValues : { any }
)
	if AppliedAttributes then
		if AppliedAttributes[AttributeName] then
			return
		end
		AppliedAttributes[AttributeName] = true
	end
	if IsModelValue(AttributeValue) then
		BindModel(AttributeValue[2], TargetInstance, AttributeName, CleanupValues, true)
	else
		if type(AttributeValue) == "function" then
			AttributeValue = CreateNode(AttributeValue)
			table.insert(CleanupValues, AttributeValue)
		end
		if IsReactiveNode(AttributeValue) then
			BindTo(AttributeValue, TargetInstance, AttributeName, true, CleanupValues)
		else
			Bind.DisconnectProperty(TargetInstance, AttributeName, true)
			SetAttribute(TargetInstance, AttributeName, AttributeValue)
		end
	end
end

const function ConnectChanged(
	TargetInstance : Instance,
	InstanceName : string,
	IsAttribute : boolean,
	IsTag : boolean,
	Value : any,
	Label : string,
	CleanupValues : { any }
)
	if IsReactiveNode(Value) then
		error(
			`{Label} is a node: use Flux.model(node) for two-way binding or Flux.property(instance, prop) to follow a property`,
			0
		)
	elseif type(Value) ~= "function" then
		error(
			`{Label} expects a function called with the new value, got {CompatibleTypeOf(Value)}`,
			0
		)
	end
	if
		not IsAttribute
		and not IsTag
		and KindOf((TargetInstance :: any)[InstanceName]) == "RBXScriptSignal"
	then
		error(
			`{Label} is an event, not a property: connect \`{InstanceName}\` as a top-level key`,
			0
		)
	end
	if IsTag then
		table.insert(
			CleanupValues,
			OnTagChanged(TargetInstance, InstanceName, CaptureContext(Value))
		)
	else
		table.insert(
			CleanupValues,
			OnChanged(TargetInstance, InstanceName, IsAttribute, CaptureContext(Value))
		)
	end
end

const function ApplyInstanceProperties(
	TargetInstance : Instance,
	Properties : Type.Map<any>,
	AppliedAttributes : { [any] : boolean }?,
	AppliedProperties : { [any] : boolean }?,
	InheritedClean : { any }?,
	StartOrder : number?
) : number
	local Actions : { any }? = nil
	local Signals : { any }? = nil
	local ChildKeys : { number }? = nil
	local HasFlatten = false
	local Order = StartOrder or 1

	local Attributes = Properties.__ATTR
	local UserCleanupValues = Properties.__CLEAN
	local CleanupValues = InheritedClean
		or (if UserCleanupValues then table.clone(UserCleanupValues) else {})
	if InheritedClean and UserCleanupValues then
		for _, Item in UserCleanupValues do
			table.insert(CleanupValues, Item)
		end
	end
	local EventHandlers = Properties.__EVENT
	local Tags = Properties.__TAG
	local Reference = Properties.__REF
	local ParentInstance = Properties.Parent
	local Released = false
	if not InheritedClean then
		local function CleanAll()
			if Released then
				return
			end
			Released = true
			DisposeResource(CleanupValues)
			table.clear(CleanupValues)
		end
		if KindOf(TargetInstance) == "Instance" then
			table.insert(
				CleanupValues,
				TargetInstance.Destroying:Once(function()
					Bind.RevokeInstance(TargetInstance)
					CleanAll()
				end)
			)
		end
		if GetCurrentOwner() then
			RegisterCleanup(CleanAll)
		end
	end

	if ParentInstance and AppliedProperties then
		if AppliedProperties.Parent then
			ParentInstance = nil
		else
			AppliedProperties.Parent = true
		end
	end

	for Property, Value in Properties do
		if Released then
			return Order
		end
		if
			Property == "Parent"
			or Property == "__TAG"
			or Property == "__ATTR"
			or Property == "__CLEAN"
			or Property == "__EVENT"
			or Property == "__REF"
		then
			continue
		end

		if type(Property) == "string" and string.byte(Property) == 95 then
			local Second = string.byte(Property, 2)
			if Second == 97 and string.sub(Property, 1, 6) == "_attr_" then
				local AttributeName = string.sub(Property, 7)
				if AttributeName == "" then
					error('attribute name after "_attr_" cannot be empty', 0)
				end
				ApplyAttribute(
					TargetInstance,
					AttributeName,
					Value,
					AppliedAttributes,
					CleanupValues
				)
				continue
			elseif Second == 116 and string.sub(Property, 1, 5) == "_tag_" then
				local TagName = string.sub(Property, 6)
				if TagName == "" then
					error('tag name after "_tag_" cannot be empty', 0)
				end
				if AppliedProperties then
					if AppliedProperties[Property] then
						continue
					end
					AppliedProperties[Property] = true
				end
				BindNamedTag(TargetInstance, TagName, Value, CleanupValues)
				continue
			end

			local InstanceName : string
			local IsAttributeListener = false
			local IsTag = false
			if Second == 95 then
				if string.sub(Property, 1, 7) == "__attr_" then
					InstanceName = string.sub(Property, 8)
					if InstanceName == "" then
						error('attribute name after "__attr_" cannot be empty', 0)
					end
					IsAttributeListener = true
				elseif string.sub(Property, 1, 6) == "__tag_" then
					InstanceName = string.sub(Property, 7)
					if InstanceName == "" then
						error('tag name after "__tag_" cannot be empty', 0)
					end
					IsTag = true
				else
					InstanceName = string.sub(Property, 2)
				end
			else
				if Second == nil then
					error('property name after "_" cannot be empty', 0)
				end
				InstanceName = string.sub(Property, 2)
			end
			if AppliedProperties then
				if AppliedProperties[Property] then
					continue
				end
				AppliedProperties[Property] = true
			end
			ConnectChanged(
				TargetInstance,
				InstanceName,
				IsAttributeListener,
				IsTag,
				Value,
				`"{Property}"`,
				CleanupValues
			)
			continue
		end

		if type(Property) == "number" and Property == math.floor(Property) then
			if KindOf(Value) == "Instance" then
				if not ChildKeys then
					ChildKeys = { Property }
				else
					table.insert(ChildKeys, Property)
				end
			elseif type(Value) == "function" then
				if not Actions then
					Actions = { Value }
				else
					table.insert(Actions, Value)
				end
			elseif type(Value) == "table" then
				if Value[1] == FindSymbol then
					ResolveFind(Value, TargetInstance, ApplyInstanceProperties :: any)
				elseif IsReactiveNode(Value) then
					if not ChildKeys then
						ChildKeys = { Property }
					else
						table.insert(ChildKeys, Property)
					end
				elseif not IsModelValue(Value) then
					HasFlatten = true
					if not ChildKeys then
						ChildKeys = { Property }
					else
						table.insert(ChildKeys, Property)
					end
				end
			end
			continue
		end

		if type(Value) == "function" then
			local CreateState = (TargetInstance :: any)[Property]
			if KindOf(CreateState) == "RBXScriptSignal" then
				if not Signals then
					Signals = { CreateState, Value }
				else
					table.insert(Signals, CreateState)
					table.insert(Signals, Value)
				end
				continue
			end
		end

		if AppliedProperties then
			if AppliedProperties[Property] then
				continue
			end
			AppliedProperties[Property] = true
		end

		if type(Value) == "function" then
			Value = CreateNode(Value)
			table.insert(CleanupValues, Value)
		end

		if IsModelValue(Value) then
			BindModel(Value[2], TargetInstance, Property, CleanupValues, false)
		elseif IsReactiveNode(Value) then
			BindTo(Value, TargetInstance, Property, false, CleanupValues)
		else
			Bind.DisconnectProperty(TargetInstance, Property, false)
			SetProperty(TargetInstance, Property, Value)
			if Property == "LayoutOrder" and Value == 0 then
				Bind.PinOrder(TargetInstance)
			end
		end
	end
	if Released then
		return Order
	end

	if Attributes then
		for AttributeName, AttributeValue in Attributes do
			ApplyAttribute(
				TargetInstance,
				AttributeName,
				AttributeValue,
				AppliedAttributes,
				CleanupValues
			)
		end
	end

	if Tags then
		BindTag(TargetInstance, Tags, CleanupValues)
	end

	if EventHandlers then
		local AttributeEventHandlers = EventHandlers.__ATTR
		local TagEventHandlers = EventHandlers.__TAG
		for Property, Value in EventHandlers do
			if Property == "__ATTR" or Property == "__TAG" then
				continue
			end
			ConnectChanged(
				TargetInstance,
				Property,
				false,
				false,
				Value,
				`__EVENT.{Property}`,
				CleanupValues
			)
		end
		if AttributeEventHandlers then
			for Attribute, Value in AttributeEventHandlers do
				ConnectChanged(
					TargetInstance,
					Attribute,
					true,
					false,
					Value,
					`__EVENT.__ATTR.{Attribute}`,
					CleanupValues
				)
			end
		end
		if TagEventHandlers then
			for Tag, Value in TagEventHandlers do
				ConnectChanged(
					TargetInstance,
					Tag,
					false,
					true,
					Value,
					`__EVENT.__TAG.{Tag}`,
					CleanupValues
				)
			end
		end
	end

	if Reference then
		if type(Reference) == "function" then
			local ReferenceCleanup = (Reference :: any)(TargetInstance)
			if ReferenceCleanup ~= nil then
				if Released then
					DisposeResource(ReferenceCleanup)
				else
					table.insert(CleanupValues, ReferenceCleanup)
				end
			end
		elseif IsReactiveNode(Reference) then
			Reference:Set(TargetInstance)
		end
	end
	if Released then
		return Order
	end

	if HasFlatten and not AppliedAttributes then
		AppliedAttributes = {}
		if Attributes then
			for AttributeName in Attributes do
				AppliedAttributes[AttributeName] = true
			end
		end
		AppliedProperties = {}
		for PropertyKey in Properties do
			if type(PropertyKey) ~= "number" then
				AppliedProperties[PropertyKey] = true
				if type(PropertyKey) == "string" and string.sub(PropertyKey, 1, 6) == "_attr_" then
					AppliedAttributes[string.sub(PropertyKey, 7)] = true
				end
			end
		end
	end

	if ChildKeys then
		if #ChildKeys > 1 then
			table.sort(ChildKeys)
		end
		for _, PropertyKey in ChildKeys do
			local MatchedChild : any = Properties[PropertyKey]
			if KindOf(MatchedChild) == "Instance" then
				Order = Bind.ApplyLayoutOrder(MatchedChild, Order)
				SetProperty(MatchedChild, "Parent", TargetInstance)
			elseif IsReactiveNode(MatchedChild) then
				Bind.Children(MatchedChild :: any, TargetInstance, Order, CleanupValues)
				Order += 1
			else
				Order = ApplyInstanceProperties(
					TargetInstance,
					MatchedChild :: any,
					AppliedAttributes,
					AppliedProperties,
					CleanupValues,
					Order
				)
			end
		end
	end

	if Actions then
		for _, Action in Actions do
			TaskLibrary.defer(CaptureContext(Action), TargetInstance)
		end
	end

	if Signals then
		for index = 1, #Signals, 2 do
			local Callback = CaptureContext(Signals[index + 1])
			table.insert(
				CleanupValues,
				Signals[index]:Connect(function(... : any)
					if not Released and not Bind.IsRevoked(TargetInstance) then
						Callback(...)
					end
				end) :: any
			)
		end
	end

	if type(ParentInstance) == "function" then
		ParentInstance = CreateNode(ParentInstance)
		table.insert(CleanupValues, ParentInstance)
	end
	local ParentIsNode = IsReactiveNode(ParentInstance)

	if ParentInstance then
		if ParentIsNode then
			BindTo(ParentInstance, TargetInstance, "Parent", false, CleanupValues)
		else
			Bind.DisconnectProperty(TargetInstance, "Parent", false)
			SetProperty(TargetInstance, "Parent", ParentInstance)
		end
	end

	return Order
end

const function EditInstance(TargetInstance : Instance, Properties : Type.Map<any>) : Instance
	ApplyInstanceProperties(TargetInstance, Properties)
	return TargetInstance
end

local ALWAYS : { [string] : { [string] : unknown } } = {
	TextButton = { AutoButtonColor = false },
	ImageButton = { AutoButtonColor = false },
}

const function Assign(TargetInstance : Instance, Values : { [string] : unknown }?)
	if Values then
		for PropertyKey, Value in Values do
			(TargetInstance :: any)[PropertyKey] = Value
		end
	end
end

const function ConfigureInstance(
	TargetInstance : Instance,
	ClassName : string,
	Properties : any
) : Instance
	Assign(TargetInstance, ALWAYS[ClassName])
	Assign(TargetInstance, if Flags.Defaults then Defaults[ClassName] else nil)
	return EditInstance(TargetInstance, Properties)
end

const function ConstructInstance(ClassName : string, Properties : any) : Instance
	local TargetInstance = Compatibility.Instance.new(ClassName)
	if GetCurrentOwner() then
		local OwnedInstance : Instance? = TargetInstance
		TargetInstance.Destroying:Once(function()
			OwnedInstance = nil
		end)
		RegisterCleanup(function()
			local Target = OwnedInstance
			OwnedInstance = nil
			if Target then
				Bind.DestroyInstance(Target)
			end
		end)
	end
	local Passed, Result = pcall(ConfigureInstance, TargetInstance, ClassName, Properties)
	if not Passed then
		pcall(Bind.DestroyInstance, TargetInstance)
		error(Result, 0)
	end
	return Result
end

return table.freeze({
	Edit = EditInstance,
	New = ConstructInstance,
	Flags = Flags,
	Defaults = Defaults,
	Find = Find,

	Split = SplitProperties :: Split,
})
