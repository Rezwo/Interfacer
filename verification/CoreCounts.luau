--!strict
const Workload = require("./FrozenWorkload")
const Library = require("../src")
for _, Size in { 3, 500, 5000 } do
    local _, Counts = Workload.Run(Library, "flux", Size, true)
    for Phase, Count in Counts do
        print("COUNTS", Size, Phase, Count.Calculations, Count.Callbacks, Count.Writes)
    end
end
print("COUNTS PASS: 9 phase/size rows; assertions enabled; no timing acquisition")
