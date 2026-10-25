--!strict

local Asynchronous = require("@self/Asynchronous")
const Bind = require("@self/Bind")
local Clock = require("@self/Clock")
const Conditional = require("@self/Conditional")
const Edit = require("@self/Edit")
const Graph = require("@self/Graph")
local Interact = require("@self/Interact")
const Layout = require("@self/Layout")
local Motion = require("@self/Motion")
local Responsive = require("@self/Responsive")
local Store = require("@self/Store")
const Overlay = require("@self/Overlay")
const Dialog = require("@self/Dialog")
const VirtualCollection = require("@self/VirtualCollection")
const Type = require("@self/Type")
const ReusableVirtualCollection = require("@self/ReusableVirtualCollection")

export type Node<ValueType> = Graph.Node<ValueType>
export type State<ValueType> = Graph.State<ValueType>
export type Reactive<ValueType> = Graph.Reactive<ValueType>
export type Unwrap<ValueType> = Graph.Unwrap<ValueType>
export type Dialog = Dialog.Dialog
export type VirtualCollection = VirtualCollection.Collection
export type VirtualRow<ItemType> = VirtualCollection.Row<ItemType>
export type VirtualCollectionOptions<ItemType> = VirtualCollection.Options<ItemType>
export type ReusableCollection = ReusableVirtualCollection.Collection
export type ReusableCell<ItemType> = ReusableVirtualCollection.Cell<ItemType>
export type CellAssignment<ItemType> = ReusableVirtualCollection.Assignment<ItemType>
export type CellDefinition<ItemType> = ReusableVirtualCollection.Definition<ItemType>
export type ReusableCollectionOptions<ItemType> = ReusableVirtualCollection.Options<ItemType>
export type VirtualLayout = VirtualCollection.Layout
export type DialogOptions = Dialog.DialogOptions
export type DialogFactory = Dialog.DialogFactory
export type DismissReason = Dialog.DismissReason
export type Portal = Overlay.Portal
export type Modal = Overlay.Modal
export type ModalStack = Overlay.ModalStack
export type Owner = Graph.Owner
export type Cleanable = Graph.Cleanable

export type Properties<ClassName, Extra = {}> = Type.Merge<
	Type.Properties<Type.Resolve<ClassName>>,
	Extra
>
export type Child = Type.Child
export type Children = Type.Children

export type Component<PropertiesType, InstanceType = Instance> = (
	Properties : PropertiesType
) -> InstanceType
export type Partial<ValueType> = Edit.Partial<ValueType>
export type Pick<ValueType, PropertyGroupType> = Edit.Pick<ValueType, PropertyGroupType>
export type Omit<ValueType, PropertyGroupType> = Edit.Omit<ValueType, PropertyGroupType>

export type Asynchronous<ValueType> = Asynchronous.Asynchronous<ValueType>
export type AsynchronousState = Asynchronous.AsynchronousState
export type Context<ValueType> = Graph.Context<ValueType>
export type Selector<KeyType> = Conditional.Selector<KeyType>
export type Spring<ValueType> = Motion.Spring<ValueType>
export type HoverOptions = Interact.HoverOptions

export type Breakpoint = Responsive.Breakpoint
export type Input = Responsive.Input
export type Platform = Responsive.Platform
export type TextSize = Responsive.TextSize
export type DisplaySize = Responsive.DisplaySize

export type Length = Layout.Length
export type ReactiveLength = Layout.ReactiveLength
export type Insets = Layout.Insets
export type Align = Layout.Align
export type FlexAlign = Layout.FlexAlign
export type LineAlign = Layout.LineAlign
export type Direction = Layout.Direction
export type FlexMode = Layout.FlexMode
export type PaddingSides = Layout.PaddingSides
export type CornerSides = Layout.CornerSides
export type ListConfiguration = Layout.ListConfiguration
export type GridConfiguration = Layout.GridConfiguration
export type StrokeConfiguration = Layout.StrokeConfiguration
export type GradientConfiguration = Layout.GradientConfiguration
export type SizeConstraintConfiguration = Layout.SizeConstraintConfiguration
export type TextSizeConstraintConfiguration = Layout.TextSizeConstraintConfiguration

local ConstructInstance = Edit.New
local EditInstance = Edit.Edit

local NativeConstructors = setmetatable({}, {
	__index = function(Self : any, Class : string)
		if type(Class) ~= "string" then
			error(`String expected, got {typeof(Class)}`)
		end

		Self[Class] = function(InstanceProperties : Type.Map<any>) : Instance
			return ConstructInstance(Class, InstanceProperties)
		end

		return Self[Class]
	end,
})

local Interfacer = {

	Clock = table.freeze({
		Now = Clock.Now,
		Wall = Clock.Wall,
		Delay = Clock.Delay,
		Wait = Clock.Wait,
		Defer = Clock.Defer,
		Cancel = Clock.Cancel,
		Connect = Clock.Connect,
		Manual = Clock.Manual,
		IsManual = Clock.IsManual,
		Step = Clock.Step,
		Drain = Clock.Drain,
		Reset = Clock.Reset,
	}),

	Color = Motion.Color,

	Defaults = Edit.Defaults,

	Find = Edit.Find,

	Flags = Edit.Flags,

	Interact = table.freeze({
		PointIn = Interact.PointIn,
		Sunk = Interact.Sunk,
		Covered = Interact.Covered,
		Hover = Interact.Hover,
		Press = Interact.Press,
		Selected = Interact.Selected,
		Focused = Interact.Focused,
	}),

	Motion = table.freeze({
		Step = Motion.Step,
	}),

	Responsive = table.freeze({
		Configuration = Responsive.Configuration,
		Platform = Responsive.Platform,
		Viewport = Responsive.Viewport,
		Scale = Responsive.Scale,
		Breakpoint = Responsive.Breakpoint,
		DisplaySize = Responsive.DisplaySize,
		Input = Responsive.Input,
		TextSize = Responsive.TextSize,
		ReducedMotion = Responsive.ReducedMotion,
		PreferredTransparency = Responsive.PreferredTransparency,
		ScaleOf = Responsive.ScaleOf,
		BreakpointOf = Responsive.BreakpointOf,
	}),

	Store = table.freeze({
		Insert = Store.Insert,
		Remove = Store.Remove,
		Move = Store.Move,
		Reconcile = Store.Reconcile,
		Unwrap = Store.Unwrap,
		Destroy = Store.Destroy,
	}),

	Dialog = Dialog.New,
	VirtualCollection = VirtualCollection.New,
	ReusableVirtualCollection = ReusableVirtualCollection.New,
	Portal = Overlay.Portal,
	ModalStack = Overlay.ModalStack,
	State = Graph.State,
	Computed = Graph.Computed,
	Effect = Graph.Effect,
	CreateSignal = Graph.CreateSignal,
	CreateMemo = Graph.CreateMemo,
	CreateEffect = Graph.CreateEffect,
	Getter = Graph.Getter,
	Setter = Graph.Setter,
	Scope = Graph.Scope,
	Flush = Graph.Flush,
	Cleanup = Graph.Cleanup,
	Dispose = Graph.Dispose,
	GetOwner = Graph.GetOwner,
	WithOwner = Graph.WithOwner,
	Read = Graph.Read,
	Raw = Graph.Raw,
	Untrack = Graph.Untrack,
	Retrack = Graph.Retrack,
	IsNode = Graph.IsNode,
	IsReactive = Graph.IsReactive,
	On = Bind.On,

	Context = Graph.Context,
	BindContext = Graph.BindContext,
	Asynchronous = Asynchronous.New,
	Selector = Conditional.Selector,
	CreateStore = Store.New,
	Split = Edit.Split,
	Safe = Graph.Safe,

	Property = Bind.Property,
	Model = Bind.Model,
	IsModel = Bind.IsModel,
	ModelNode = Bind.ModelNode,
	Show = Conditional.Show,
	ShowKeyed = Conditional.ShowKeyed,
	Switch = Conditional.Switch,
	Otherwise = Conditional.Otherwise,
	Presence = Conditional.Presence,
	Pick = Conditional.Pick,
	Fallback = Conditional.Fallback,
	ForValue = Conditional.ForValue,
	ForIndex = Conditional.ForIndex,
	Spring = Motion.Spring,
	Tween = Motion.Tween,

	Padding = Layout.Padding,
	Corner = Layout.Corner,
	Stroke = Layout.Stroke,
	AspectRatio = Layout.AspectRatio,
	List = Layout.List,
	Grid = Layout.Grid,
	Flex = Layout.Flex,
	Gradient = Layout.Gradient,
	SizeConstraint = Layout.SizeConstraint,
	TextSizeConstraint = Layout.TextSizeConstraint,
}

local InterfacerMetatable = {}

local BindReactiveNode = Bind.Node

function InterfacerMetatable.__call(_ : any, Object : any, PropertyName : string?) : Graph.Node<any>
	return BindReactiveNode(Object, PropertyName)
end

function Interfacer.Edit<ValueType>(TargetInstance : ValueType & Instance)
	return function(InstanceProperties : Type.EditProperties<ValueType>) : ValueType
		return EditInstance(TargetInstance, InstanceProperties)
	end
end

function Interfacer.New<ValueType>(ClassName : ValueType | keyof<Type.Creatable>)
	return NativeConstructors[ClassName] :: (
			Type.Properties<Type.Resolve<ValueType>>
		) -> Type.Resolve<ValueType>
end

if game then
	local RunService = game:GetService("RunService")
	local Frame : RBXScriptSignal = if RunService:IsClient() then RunService.PreRender else RunService.Heartbeat
	Frame:Connect(function()
		if not Clock.IsManual() then
			Motion.Step()
			Graph.Flush()
		end
	end)
end

Clock.Internal.SetFrame(function(DeltaTime : number)
	Motion.Step(DeltaTime)
	Graph.Flush()
end)

type FluxCall = {
	__call : (Self : any, Object : any, PropertyName : string?) -> Graph.Node<any>,
}

return table.freeze(setmetatable(Interfacer, table.freeze(InterfacerMetatable) :: FluxCall))
