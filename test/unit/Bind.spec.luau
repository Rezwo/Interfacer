--!nonstrict
local IS_ROBLOX = game ~= nil

local Flux
local sert
if IS_ROBLOX then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	Flux = require(ReplicatedStorage:WaitForChild("Flux")) :: any
	sert = require(ReplicatedStorage:WaitForChild("sert")) :: any
else
	Flux = require("../../src") :: any
	sert = require("../sert") :: any
end

local test = sert.test
local rtest = sert.rtest
local expect = sert
local expectError = sert.fails
local flush = Flux.Flush

test("model · wraps a node and isModel / modelNode inspect it", function()
	expectError(function()
		Flux.Model("not a node")
	end, "expects a reactive node")

	local sig = Flux.State("abc")
	local wrapped = Flux.Model(sig)
	expect(Flux.IsModel(wrapped) == true, "isModel recognizes a Flux.model value")
	expect(
		Flux.IsModel(sig) == false and Flux.IsModel("abc") == false,
		"isModel is false for non-model values"
	)
	expect(Flux.ModelNode(wrapped) == sig, "modelNode extracts the underlying node")
	expect(
		Flux.ModelNode(sig) == nil and Flux.ModelNode(nil) == nil,
		"modelNode returns nil for non-model values"
	)
end)

test("property & call · validate non-instance arguments", function()
	expectError(function()
		Flux.Property("not an instance" :: any, "Name")
	end, "Flux.property expects an Instance")
	expectError(function()
		Flux(123, "Name")
	end, "only an Instance takes a property name")
end)

rtest("property · follows an instance property reactively", function()
	local label = Instance.new("TextLabel")
	label.Text = "initial"
	local prop = Flux.Property(label, "Text")
	local viaCall = Flux(label, "Text")
	expect(
		prop:Get() == "initial" and viaCall:Get() == "initial",
		"seeded with initial property value"
	)
	label.Text = "changed"
	task.wait()
	flush()
	expect(prop:Get() == "changed" and viaCall:Get() == "changed", "updates when property changes")
	prop:Destroy()
	viaCall:Destroy()
	label:Destroy()
end)

rtest("property · follows an instance attribute reactively via $ and _attr_ prefixes", function()
	local frame = Instance.new("Frame")
	frame:SetAttribute("Score", 10)
	local attr = Flux.Property(frame, "$Score")
	local attrUnderscore = Flux.Property(frame, "_attr_Score")
	local viaCall = Flux(frame, "$Score")
	expect(
		attr:Get() == 10 and attrUnderscore:Get() == 10 and viaCall:Get() == 10,
		"seeded with initial attribute value"
	)
	frame:SetAttribute("Score", 25)
	task.wait()
	flush()
	expect(
		attr:Get() == 25 and attrUnderscore:Get() == 25 and viaCall:Get() == 25,
		"updates when attribute changes"
	)
	attr:Destroy()
	attrUnderscore:Destroy()
	viaCall:Destroy()
	frame:Destroy()
end)

rtest("property · follows an instance tag reactively via # and _tag_ prefixes", function()
	local frame = Instance.new("Frame")
	local other = Instance.new("Frame")
	frame:AddTag("PreExisting")
	frame.Parent = workspace
	other.Parent = workspace

	local hasEnemy = Flux.Property(frame, "#Enemy")
	local hasEnemyUnderscore = Flux.Property(frame, "_tag_Enemy")
	local viaCall = Flux(frame, "#Enemy")
	local hasPre = Flux.Property(frame, "#PreExisting")
	expect(
		hasEnemy:Get() == false and hasEnemyUnderscore:Get() == false and viaCall:Get() == false,
		"seeded with false when tag is absent"
	)
	expect(hasPre:Get() == true, "seeded with true when tag is already present")

	other:AddTag("Enemy")
	task.wait()
	flush()
	expect(
		hasEnemy:Get() == false and hasEnemyUnderscore:Get() == false,
		"tag added to another instance is ignored"
	)

	frame:AddTag("Enemy")
	task.wait()
	flush()
	expect(
		hasEnemy:Get() == true and hasEnemyUnderscore:Get() == true and viaCall:Get() == true,
		"updates to true when tag is added"
	)

	frame.Parent = nil
	task.wait()
	flush()
	expect(hasEnemy:Get() == true, "unparenting an instance does not falsely clear its #Tag node")
	frame.Parent = workspace

	frame:RemoveTag("Enemy")
	task.wait()
	flush()
	expect(
		hasEnemy:Get() == false and hasEnemyUnderscore:Get() == false and viaCall:Get() == false,
		"updates to false when tag is removed"
	)

	hasEnemy:Destroy()
	hasEnemyUnderscore:Destroy()
	frame:AddTag("Enemy")
	task.wait()
	flush()
	expect(hasEnemy:Get() == nil and viaCall:Get() == true, "destroyed tag node stops following")

	viaCall:Destroy()
	hasPre:Destroy()
	other:Destroy()
	frame:Destroy()
end)

rtest("property & call · reject non-string or empty prefix names on an Instance", function()
	local frame = Instance.new("Frame")
	expectError(function()
		Flux.Property(frame, 123 :: any)
	end, "expects a property")
	expectError(function()
		Flux(frame, 123 :: any)
	end, "expects a property")
	expectError(function()
		Flux.Property(frame, "$")
	end, 'after "$" cannot be empty')
	expectError(function()
		Flux.Property(frame, "#")
	end, 'after "#" cannot be empty')
	expectError(function()
		Flux.Property(frame, "_attr_")
	end, 'after "_attr_" cannot be empty')
	expectError(function()
		Flux.Property(frame, "_tag_")
	end, 'after "_tag_" cannot be empty')
	frame:Destroy()
end)

return {}
