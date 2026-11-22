--!strict

const Interfacer = require("../src")
local Callback : ((number) -> ())? = nil
local DisconnectCount = 0
const Source = {
	Connect = function(_Source : any, Receive : (number) -> ())
		Callback = Receive
		return {
			Disconnect = function(_Connection : any)
				DisconnectCount += 1
			end,
		}
	end,
}
const Owner = Interfacer.Scope(function()
	const Node = Interfacer.FromSignal(Source, 0)
	local Observations = {}
	const Stop = Interfacer.Listen(Node, function(Value)
		table.insert(Observations, Value)
	end)
	Interfacer.Flush()
	assert(#Observations == 0, "initial value is not delivered to listener")
	const Emit = assert(Callback, "connection callback")
	Emit(2)
	Interfacer.Flush()
	assert(#Observations == 1 and Observations[1] == 2, "changed value is delivered")
	Emit(2)
	Interfacer.Flush()
	assert(#Observations == 1, "equal values are not delivered")
	Stop()
	Stop()
	Emit(3)
	Interfacer.Flush()
	assert(#Observations == 1 and Node:Get() == 3, "unsubscribe is independent of the source")
end)
Interfacer.Dispose(Owner)
assert(DisconnectCount == 1, "owner disposal disconnects exactly once")
assert(Callback, "retained native callback")(4)
Interfacer.Flush()
assert(DisconnectCount == 1, "retained callback cannot reconnect")
print("FLUX V052 SIGNALS PASS")
