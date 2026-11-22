--!strict

const Interfacer = require("../src")
const Defaults = { Width = 8, Visible = true }
const Overrides = { Width = 12, Visible = false }
const Merged = Interfacer.Merge(Defaults, Overrides)
assert(Merged.Width == 12 and Merged.Visible == false, "rightmost values override, including false")
Overrides.Width = 20
assert(Merged.Width == 20, "view reads current values")
local Count = 0
for _, _ in Merged do
	Count += 1
end
assert(Count == 2, "iteration visits one entry per key")
const Passed = pcall(function()
	(Merged :: any).Width = 30
end)
assert(not Passed and Overrides.Width == 20, "merged view is read-only")
print("FLUX V052 MERGE PASS")
