--!strict

type Invocation = {
	Callback : (any) -> any,
	Argument : any,
}

const InvocationMetatable = table.freeze({
	__index = function(Entry : Invocation, _Name : string) : any
		return Entry.Callback(Entry.Argument)
	end,
})

const function Invoke(Entry : any) : any
	return Entry.Result
end

const function Run<ArgumentType, ResultType>(
	Callback : (ArgumentType) -> ResultType,
	Argument : ArgumentType
) : (boolean, any)
	local Entry = setmetatable({ Callback = Callback :: any, Argument = Argument }, InvocationMetatable)
	local Passed, Result = pcall(Invoke, Entry)
	table.clear(Entry)
	return Passed, Result
end

return table.freeze({ Run = Run })
