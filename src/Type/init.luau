--!strict

const Graph = require("./Graph")
const Instances = require("@self/Instances")

type Consumer = (...any) -> ()

export type Map<ValueType> = { [ValueType] : any }

export type Symbol = { read type : "Symbol" }

type AttributesDirective = "__ATTR"
type CleanupDirective = "__CLEAN"
type EventsDirective = "__EVENT"
type ReferenceDirective = "__REF"
type TagsDirective = "__TAG"

type GraphNode = Graph.Node<any>

export type Child = Instance | GraphNode | ((InstanceType : Instance) -> ()) | { [any] : any }
export type Children = { Child }

export type function Properties(InstanceType : type?)
	local IndexType = types.unionof(types.number, types.string)
	local Result =
		types.newtable(nil, { index = IndexType, readresult = types.any, writeresult = types.any })

	local Events = types.newtable(
		nil,
		{ index = types.number, readresult = types.never, writeresult = types.never }
	)
	local ConnectKey = types.singleton("Connect")

	while InstanceType do
		for IndexValue, ValueItem in InstanceType:properties() do
			local Connector = ValueItem.read
				and ValueItem.read:is("table")
				and ValueItem.read:readproperty(ConnectKey)
			if Connector then
				local Parameters = Connector:parameters().head
				if not Parameters then
					continue
				end
				local Listener = Parameters[2]
				if not Listener then
					continue
				end
				Result:setproperty(IndexValue, types.optional(Listener))
			else
				if ValueItem.read then
					local ChangedListener =
						types.optional(types.newfunction({ head = { ValueItem.read } }))
					Events:setproperty(IndexValue, ChangedListener)
					local PropertyName = IndexValue:value()
					if type(PropertyName) == "string" then
						Result:setproperty(types.singleton("_" .. PropertyName), ChangedListener)
					end
				end
				if ValueItem.write then
					local PropertyValueType = types.optional(
						types.unionof(
							ValueItem.write,
							types.newfunction({}, { head = { ValueItem.write } }),
							GraphNode
						)
					)
					Result:setproperty(IndexValue, PropertyValueType)
				end
			end
		end

		InstanceType = InstanceType:readparent()
	end

	local AttributeListener = types.newfunction({ head = { types.any } })
	local AttributeEventIndexer =
		{ index = types.string, readresult = AttributeListener, writeresult = AttributeListener }
	Events:setproperty(
		AttributesDirective,
		types.optional(types.newtable(nil, AttributeEventIndexer))
	)
	local TagListener = types.newfunction({ head = { types.boolean } })
	local TagEventIndexer =
		{ index = types.string, readresult = TagListener, writeresult = TagListener }
	Events:setproperty(TagsDirective, types.optional(types.newtable(nil, TagEventIndexer)))

	Result:setproperty(types.singleton("_attr_"), types.optional(types.any))
	Result:setproperty(
		types.singleton("_tag_"),
		types.optional(
			types.unionof(types.boolean, GraphNode, types.newfunction({}, { head = { types.any } }))
		)
	)
	Result:setproperty(types.singleton("__attr_"), types.optional(AttributeListener))
	Result:setproperty(types.singleton("__tag_"), types.optional(TagListener))

	Result:setproperty(
		AttributesDirective,
		types.optional(
			types.newtable(
				nil,
				{ index = types.string, readresult = types.any, writeresult = types.any }
			)
		)
	)
	local Tag =
		types.unionof(types.string, GraphNode, types.newfunction({}, { head = { types.any } }))
	local TagList =
		types.newtable(nil, { index = types.number, readresult = Tag, writeresult = Tag })
	Result:setproperty(TagsDirective, types.optional(types.unionof(Tag, TagList)))
	Result:setproperty(
		CleanupDirective,
		types.optional(
			types.newtable(
				nil,
				{ index = types.number, readresult = types.any, writeresult = types.any }
			)
		)
	)
	Result:setproperty(EventsDirective, types.optional(Events))
	Result:setproperty(ReferenceDirective, types.optional(types.unionof(Consumer, GraphNode)))

	return Result
end

export type function Merge(Base : type, Extra : type)
	local Result = types.newtable()
	local function Add(Source : type)
		if Source:is("intersection") then
			for _, Part in Source:components() do
				Add(Part)
			end
			return
		elseif not Source:is("table") then
			return
		end
		for Key, Property in Source:properties() do
			local Value = Property.read or Property.write
			if Value then
				Result:setproperty(Key, Value)
			end
		end
		local Indexer = Source:indexer()
		if Indexer then
			Result:setindexer(Indexer.index, Indexer.readresult)
		end
	end
	Add(Base)
	Add(Extra)
	return Result
end

export type function MergeTables(First : type, Second : type, Third : type, Fourth : type) : type
	local Result = types.newtable()

	local function CanBeNil(SourceType : type) : boolean
		if SourceType:is("nil") then
			return true
		elseif SourceType:is("union") then
			for _, Part in SourceType:components() do
				if Part:is("nil") then
					return true
				end
			end
		end
		return false
	end

	local function StripNil(SourceType : type) : type
		if SourceType:is("nil") then
			return types.never
		elseif not SourceType:is("union") then
			return SourceType
		end
		local Parts = {}
		for _, Part in SourceType:components() do
			if not Part:is("nil") then
				table.insert(Parts, Part)
			end
		end
		return if #Parts == 0 then types.never elseif #Parts == 1 then Parts[1] else types.unionof(table.unpack(Parts))
	end

	local function Combine(FirstType : type, SecondType : type) : type
		local Parts : { type } = {}
		local function Add(ValueType : type)
			if ValueType:is("never") then
				return
			elseif ValueType:is("union") then
				for _, Part in ValueType:components() do
					Add(Part)
				end
			elseif not table.find(Parts, ValueType) then
				table.insert(Parts, ValueType)
			end
		end
		Add(FirstType)
		Add(SecondType)
		return if #Parts == 0 then types.never elseif #Parts == 1 then Parts[1] else types.unionof(table.unpack(Parts))
	end

	local function MergeProperty(PreviousType : type?, NextType : type, SourceOptional : boolean) : type
		if PreviousType == nil then
			return if SourceOptional then types.optional(NextType) else NextType
		elseif not SourceOptional and not CanBeNil(NextType) then
			return NextType
		end
		return Combine(PreviousType, StripNil(NextType))
	end

	local function MergeInto(Target : type, Source : type, SourceOptional : boolean)
		if Source:is("nil") then
			return
		elseif Source:is("union") then
			local NonNil = {}
			local HasNil = false
			for _, Part in Source:components() do
				if Part:is("nil") then
					HasNil = true
				else
					table.insert(NonNil, Part)
				end
			end
			local BranchOptional = SourceOptional or HasNil
			if #NonNil == 0 then
				return
			elseif #NonNil == 1 then
				MergeInto(Target, NonNil[1], BranchOptional)
				return
			end
			local BranchTables : { type } = {}
			local KeysByName : { [any] : type } = {}
			for _, Part in NonNil do
				local Branch = types.newtable()
				MergeInto(Branch, Part, false)
				table.insert(BranchTables, Branch)
				for Key in Branch:properties() do
					local Name = Key:value()
					if Name ~= nil and KeysByName[Name] == nil then
						KeysByName[Name] = Key
					end
				end
			end
			for _, Key in KeysByName do
				local CombinedType : type? = nil
				local AllPresentAndNonNil = true
				for _, Branch in BranchTables do
					local Value = Branch:readproperty(Key)
					if Value == nil then
						AllPresentAndNonNil = false
					else
						if CanBeNil(Value) then
							AllPresentAndNonNil = false
						end
						local StrippedType = StripNil(Value)
						CombinedType = if CombinedType == nil then StrippedType else Combine(CombinedType, StrippedType)
					end
				end
				if CombinedType ~= nil then
					local PropertyOptional = BranchOptional or not AllPresentAndNonNil
					Target:setreadproperty(Key, MergeProperty(Target:readproperty(Key), CombinedType, PropertyOptional))
				end
			end
			local IndexerKey : type? = nil
			local IndexerValue : type? = nil
			local AllHaveIndexer = true
			for _, Branch in BranchTables do
				local BranchIndexer = Branch:indexer()
				if BranchIndexer == nil then
					AllHaveIndexer = false
				else
					IndexerKey = if IndexerKey == nil then BranchIndexer.index else Combine(IndexerKey, BranchIndexer.index)
					IndexerValue = if IndexerValue == nil then BranchIndexer.readresult else Combine(IndexerValue, BranchIndexer.readresult)
				end
			end
			if IndexerKey ~= nil and IndexerValue ~= nil then
				local FinalValueType = if BranchOptional or not AllHaveIndexer then types.optional(IndexerValue) else IndexerValue
				Target:setindexer(IndexerKey, FinalValueType)
			end
			return
		elseif Source:is("intersection") then
			for _, Part in Source:components() do
				MergeInto(Target, Part, SourceOptional)
			end
			return
		elseif not Source:is("table") then
			return
		end
		for Key, Property in Source:properties() do
			local Value = Property.read or Property.write
			if Value then
				Target:setreadproperty(Key, MergeProperty(Target:readproperty(Key), Value, SourceOptional))
			end
		end
		local Indexer = Source:indexer()
		if Indexer then
			local IndexerValue = if SourceOptional then types.optional(Indexer.readresult) else Indexer.readresult
			local CurrentIndexer = Target:indexer()
			if CurrentIndexer then
				Target:setindexer(Combine(CurrentIndexer.index, Indexer.index), Combine(CurrentIndexer.readresult, IndexerValue))
			else
				Target:setindexer(Indexer.index, IndexerValue)
			end
		end
	end

	MergeInto(Result, First, false)
	MergeInto(Result, Second, false)
	MergeInto(Result, Third, false)
	MergeInto(Result, Fourth, false)
	if Result:indexer() == nil then
		Result:setindexer(types.number, types.any)
	end
	return Result
end

export type function EditProperties(InstanceType : type?)
	return Properties(InstanceType)
end

export type function PropertyType(InstanceType : type, Key : type)
	if not Key:is("singleton") then
		return types.any
	end
	local ClassName = Key:value()
	if type(ClassName) ~= "string" then
		return types.any
	end
	local Prefix = string.sub(ClassName, 1, 1)
	if Prefix == "$" then
		return types.any
	elseif Prefix == "#" then
		return types.boolean
	elseif Prefix == "_" then
		if string.sub(ClassName, 1, 6) == "_attr_" then
			return types.any
		elseif string.sub(ClassName, 1, 5) == "_tag_" then
			return types.boolean
		end
	end

	local Classes = if InstanceType:is("intersection")
		then InstanceType:components()
		else { InstanceType }
	for _, Component in Classes do
		local Class : type? = Component
		while Class and Class:is("extern") do
			for PropertyKey, Property in Class:properties() do
				if PropertyKey:value() == ClassName then
					local Value = Property.read
					if
						Value == nil
						or (Value:is("table") and Value:readproperty(types.singleton("Connect")))
					then
						return types.any
					end
					return Value
				end
			end
			Class = Class:readparent()
		end
	end
	return types.any
end

export type Creatable = Instances.Creatable

export type Editable = Instances.Editable

export type Resolve<Name> = index<Creatable, Name>

return nil
