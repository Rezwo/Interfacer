--!strict
const Interfacer = require("../src")
const Count = Interfacer.State(2)
const Label = Interfacer.State("items")
const Sources : { Interfacer.Node<number> | Interfacer.Node<string> } = { Count, Label }
local Calls = 0
const Read = Interfacer.On(Sources, function(Input : { number | string }, Previous : { number | string }?, PreviousResult : string?) : string
	Calls += 1
	local Number, Word = Input[1], Input[2]
	assert(type(Number) == "number" and type(Word) == "string")
	if Calls == 2 then
		assert(Previous and Previous[1] == 2 and Previous[2] == "items" and PreviousResult == "2 items")
	end
	return tostring(Number) .. " " .. Word
end)
assert(Read(nil) == "2 items")
Count:Set(3)
assert(Read("2 items") == "3 items")

const Scalar = Interfacer.On(Count, function(Value : number, Previous : number?) : number
	return Value + (Previous or 0)
end, nil)
assert(Scalar(nil) == 3)
Count:Set(4)
assert(Scalar(3) == 7, "single input and previous value remain scalar")
const Configuration = { Name = "raw record" }
const ReadName = Interfacer.On(Configuration, function(Value : { Name : string }) : string
	return Value.Name
end)
assert(ReadName(nil) == "raw record", "a plain keyed record is a single source")

const Shared = { Leaf = { Count = 1 } }
const Schema = Interfacer.Own({ Enabled = Interfacer.Prop(true) }, {
	Options = Interfacer.Prop({ First = Shared, Second = Shared }),
	Name = Interfacer.Prop(),
})
const Owned, Rest = Interfacer.Split({ Enabled = false, Name = "label", Extra = 9 }, Schema)
assert(Owned.Enabled == false and Owned.Name == "label" and Rest.Extra == 9)
const Defaults = Interfacer.Split({}, Schema)
Owned.Options.First.Leaf.Count = 7
assert(Owned.Options.Second.Leaf.Count == 7 and Defaults.Options.First.Leaf.Count == 1 and Shared.Leaf.Count == 1)
const First, Second = Interfacer.Split({}, { Value = Interfacer.Prop(1) }, { Value = Interfacer.Prop(2) })
assert((First :: any).Value == 1 and (Second :: any).Value == nil, "first split group owns the default")
type CyclicDefault = { Next : CyclicDefault? }
const Cycle : CyclicDefault = {}
Cycle.Next = Cycle
const FromNil = Interfacer.Split(nil, { Cycle = Interfacer.Prop(Cycle), Off = Interfacer.Prop(false) })
assert(FromNil.Off == false and FromNil.Cycle ~= Cycle and FromNil.Cycle.Next == FromNil.Cycle, "defaults apply to nil props and clone cycles")
print("FLUX V052 TYPED UI PASS")
