--!strict
local Workload = {}
function Workload.Run(UI : any, _Framework : string, Size : number, Counted : boolean) : (any, any)
 local Repetitions = if Counted then 1 elseif Size == 500 then 100 else 10
 local Values = { Construction = 0, Changed = 0, Equal = 0, Disposal = 0, Complete = 0 }
 local Counts : any = {}
 for _ = 1, Repetitions do
  local Sources : {any} = {}
  local Targets : {any} = {}
  local Calculations, Callbacks, Writes = 0, 0, 0
  local Start = if Counted then 0 else os.clock()
  local Owner = UI.Scope(function()
   for Index = 1, Size do
    local Source = UI.State(0); Sources[Index] = Source; UI.Cleanup(Source)
    local Target : any = if Counted then setmetatable({}, { __newindex = function(_Self, _Key, _Value) Writes += 1 end }) else {}
    Targets[Index] = Target
    local Memo = UI.Computed(function() if Counted then Calculations += 1 end; return tostring((Source() + Index) % 2) end)
    UI.Effect(function() if Counted then Callbacks += 1 end; Target.Text = Memo() end)
    UI.Flush()
   end
  end)
  local Constructed = if Counted then 0 else os.clock()
  if Counted then assert(Calculations == Size and Callbacks == Size and Writes == Size, "initial counts");Counts.Initial={Calculations=Calculations,Callbacks=Callbacks,Writes=Writes} end
  Calculations, Callbacks, Writes = 0, 0, 0
  for _, Source in Sources do Source:Set(1) end
  UI.Flush()
  local Changed = if Counted then 0 else os.clock()
  if Counted then assert(Calculations == Size and Callbacks == Size and Writes == Size, "changed counts");Counts.Changed={Calculations=Calculations,Callbacks=Callbacks,Writes=Writes} end
  Calculations, Callbacks, Writes = 0, 0, 0
  for _, Source in Sources do Source:Set(3) end
  UI.Flush()
  local Equal = if Counted then 0 else os.clock()
  if Counted then assert(Calculations == Size and Callbacks == 0 and Writes == 0, "equal counts");Counts.Equal={Calculations=Calculations,Callbacks=Callbacks,Writes=Writes} end
  Owner:Destroy()
  local Disposed = if Counted then 0 else os.clock()
  Values.Construction += Constructed-Start; Values.Changed += Changed-Constructed; Values.Equal += Equal-Changed; Values.Disposal += Disposed-Equal; Values.Complete += Disposed-Start
 end
 return Values, Counts
end
return Workload
