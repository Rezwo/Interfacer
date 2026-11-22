--!strict

const Interfacer = require("../src")
const Source = Interfacer.State(1)
local Fetches = 0
const Request = Interfacer.Asynchronous(Source, function(Value : number) : number
	Fetches += 1
	return Value * 10
end)
Request:Refetch()
Interfacer.Flush()
assert(Fetches == 1 and Request.Data:Get() == 10, "refetch before initial settlement must not fetch the same input twice")
Request:Destroy()

const ChangedSource = Interfacer.State(1)
local ChangedFetches = 0
const ChangedRequest = Interfacer.Asynchronous(ChangedSource, function(Value : number) : number
	ChangedFetches += 1
	return Value * 10
end)
ChangedRequest:Mutate(100)
ChangedSource:Set(2)
Interfacer.Flush()
assert(ChangedFetches == 1 and ChangedRequest.Data:Get() == 20, "a different input still fetches after an optimistic pre-flush mutation")
ChangedRequest:Destroy()
local OwnerDuringFetch : unknown
local TrackingDuringFetch = true
local FetchesInOwner = 0
const Scoped = Interfacer.Scope(function()
	local OwnedRequest = Interfacer.Asynchronous(function() : number
		OwnerDuringFetch = Interfacer.GetOwner()
		TrackingDuringFetch = Interfacer.IsReactive()
		FetchesInOwner += 1
		return 42
	end)
	OwnedRequest:Refetch()
end)
Interfacer.Flush()
assert(FetchesInOwner == 1 and OwnerDuringFetch == nil and not TrackingDuringFetch, "fetcher must not inherit caller ownership or tracking")
Interfacer.Dispose(Scoped)
print("FLUX V052 ASYNC PASS")
