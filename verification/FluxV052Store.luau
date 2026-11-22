--!strict

const Interfacer = require("../src")

local Cases : { { Name : string, Run : () -> () } } = {
	{
		Name = "shared branch remains reactive after one parent drops it",
		Run = function()
			local Leaf = { Count = 1 }
			local Root = Interfacer.CreateStore({ Left = { Item = Leaf }, Right = { Item = Leaf } }) :: any
			local Retained = Root.Left.Item
			assert(Root.Right.Item == Retained, "shared leaf must have one proxy")
			local Observed = Interfacer.Computed(function()
				return (Root.Right.Item :: { Count : number }).Count
			end)
			assert(Observed:Get() == 1)
			Root.Left.Item = nil
			assert(Root.Right.Item == Retained, "dropping one parent must not replace the surviving proxy")
			Retained.Count = 4
			Interfacer.Flush()
			assert(Observed:Get() == 4, "surviving alias stays reactive")
			Root.Right.Item = nil
			assert(getmetatable(Retained) == nil, "last link tears down the proxy")
			Observed:Destroy()
			Interfacer.Store.Destroy(Root)
		end,
	},
	{
		Name = "orphan cycle disposes both proxies",
		Run = function()
			local First, Second : any, any = { Count = 1 }, { Count = 2 }
			First.Peer, Second.Peer = Second, First
			local Root = Interfacer.CreateStore({ First = First, Second = Second }) :: any
			local FirstProxy, SecondProxy = Root.First, Root.Second
			assert(FirstProxy.Peer == SecondProxy and SecondProxy.Peer == FirstProxy)
			Root.First = nil
			assert(Root.Second.Peer == FirstProxy and getmetatable(FirstProxy) ~= nil, "cycle remains reachable")
			Root.Second = nil
			assert(getmetatable(FirstProxy) == nil and getmetatable(SecondProxy) == nil, "orphan cycle is released")
			Interfacer.Store.Destroy(Root)
		end,
	},
	{
		Name = "reconcile terminates on cyclic snapshots",
		Run = function()
			local Original : any = { Count = 1 }
			Original.Self = Original
			local Updated : any = { Count = 7 }
			Updated.Self = Updated
			local Root = Interfacer.CreateStore(Original)
			assert(Root.Self == Root)
			local Count = Interfacer.Computed(function()
				return (Root.Self :: { Count : number }).Count
			end)
			assert(Count:Get() == 1)
			Interfacer.Store.Reconcile(Root, Updated)
			assert(Root.Self == Root and Count:Get() == 7, "cyclic reconcile preserves proxy and publishes")
			Count:Destroy()
			Interfacer.Store.Destroy(Root)
		end,
	},
	{
		Name = "Destroy data does not intercept scoped teardown",
		Run = function()
			local Called = false
			local Root : { Destroy : () -> () }?
			local Owner = Interfacer.Scope(function()
				Root = Interfacer.CreateStore({ Destroy = function()
					Called = true
				end })
			end)
			local Retained = assert(Root)
			assert(type(Retained.Destroy) == "function")
			Interfacer.Dispose(Owner)
			assert(not Called and getmetatable(Retained) == nil, "registry overrides the data field")
		end,
	},
	{
		Name = "array insert keeps an existing proxy alive across roots",
		Run = function()
			local Leaf = { Count = 1 }
			local Source = Interfacer.CreateStore({ Item = Leaf }) :: any
			local Target = Interfacer.CreateStore({} :: { { Count : number } })
			local Retained = Source.Item
			Interfacer.Store.Insert(Target, Interfacer.Store.Unwrap(Retained))
			Interfacer.Store.Destroy(Source)
			assert(Target[1] == Retained and getmetatable(Retained) ~= nil, "inserted alias survived removal of its original root")
			Interfacer.Store.Remove(Target)
			assert(getmetatable(Retained) == nil, "final array removal releases proxy")
			Interfacer.Store.Destroy(Target)
		end,
	},
	{
		Name = "keyed reconcile supports NaN keys and leaves frozen values alone",
		Run = function()
			local Root = Interfacer.CreateStore({ { Identifier = 0 / 0, Count = 1 } })
			local Item = Root[1]
			Interfacer.Store.Reconcile(Root, { { Identifier = 0 / 0, Count = 3 } }, "Identifier")
			assert(Root[1] == Item and Item.Count == 3, "NaN key keeps item identity")
			local Frozen = table.freeze({ Count = 4 })
			local Container = Interfacer.CreateStore({ Item = Frozen })
			assert(Container.Item == Frozen, "frozen data is not proxied")
			Interfacer.Store.Reconcile(Container, { Item = { Count = 5 } })
			assert(Container.Item.Count == 5 and Frozen.Count == 4, "reconcile replaces rather than mutates frozen data")
			Interfacer.Store.Destroy(Root)
			Interfacer.Store.Destroy(Container)
		end,
	},
}

local Failures = 0
for _, Case in Cases do
	local Passed, Result = pcall(Case.Run)
	if Passed then
		print("PASS " .. Case.Name)
	else
		Failures += 1
		print("FAIL " .. Case.Name .. ": " .. tostring(Result))
	end
end
assert(Failures == 0, tostring(Failures) .. " store cases failed")
print("FLUX V052 STORE PASS")
