local Vector3 = require("@lune/roblox").Vector3
return function(H)
	local Janitor = H.Module("Shared.Classes.Janitor")
	local Signal = H.Module("Shared.Classes.Signal")
	local StateMachine = H.Module("Shared.Classes.StateMachine")
	local TokenBucket = H.Module("Shared.Classes.TokenBucket")
	local TableUtil = H.Module("Shared.Utilities.TableUtil")
	local Validate = H.Module("Shared.Utilities.Validate")
	local WeightedRandom = H.Module("Shared.Utilities.WeightedRandom")
	local Format = H.Module("Shared.Utilities.Format")
	local MathUtil = H.Module("Shared.Utilities.MathUtil")

	H.test("Janitor cleans in reverse order and handles keyed tasks", function()
		local order = {}
		local janitor = Janitor.new()
		janitor:Add(function() table.insert(order, "a") end)
		janitor:Add(function() table.insert(order, "b") end)
		janitor:AddKeyed("k", function() table.insert(order, "k1") end)
		janitor:AddKeyed("k", function() table.insert(order, "k2") end) -- replaces and cleans k1
		H.eq(order[1], "k1")
		janitor:Cleanup()
		H.eq(table.concat(order, ","), "k1,k2,b,a")
	end)

	H.test("Janitor cleans tasks added after destruction immediately", function()
		local janitor = Janitor.new()
		janitor:Destroy()
		local cleaned = false
		janitor:Add(function() cleaned = true end)
		H.ok(cleaned, "late task must be cleaned")
	end)

	H.test("Janitor:Detach releases ownership without cleaning", function()
		local janitor = Janitor.new()
		local cleaned = false
		janitor:AddKeyed("model", function() cleaned = true end)
		H.ok(janitor:Detach("model") ~= nil)
		janitor:Destroy()
		H.ok(not cleaned, "detached task must survive")
	end)

	H.test("Janitor calls Destroy on objects and survives failing tasks", function()
		local janitor = Janitor.new()
		local destroyed = false
		janitor:Add({ Destroy = function() destroyed = true end })
		janitor:Add(function() error("boom") end)
		janitor:Destroy()
		H.ok(destroyed)
	end)

	H.test("Signal fires synchronously and supports disconnect during fire", function()
		local signal = Signal.new()
		local hits = 0
		local connection
		connection = signal:Connect(function()
			hits += 1
			connection:Disconnect()
		end)
		signal:Connect(function() hits += 10 end)
		signal:Fire()
		signal:Fire()
		H.eq(hits, 21)
	end)

	H.test("Signal isolates handler errors", function()
		local signal = Signal.new()
		local reached = false
		signal:Connect(function() error("bad") end)
		signal:Connect(function() reached = true end)
		signal:Fire()
		H.ok(reached)
	end)

	H.test("StateMachine enforces transitions and queues nested ones", function()
		local log = {}
		local machine = StateMachine.new({
			Name = "Test",
			Initial = "A",
			States = {
				A = { Exit = function() table.insert(log, "exitA") end },
				B = {
					Enter = function(m)
						table.insert(log, "enterB")
						m:Transition("C")
					end,
				},
				C = { Enter = function() table.insert(log, "enterC") end },
			},
			Transitions = { A = { "B" }, B = { "C" }, C = {} },
		})
		machine:Start()
		H.ok(not machine:CanTransition("C"), "A -> C must be illegal")
		H.ok(not machine:Transition("C"))
		H.ok(machine:Transition("B"))
		H.eq(machine:GetState(), "C")
		H.eq(table.concat(log, ","), "exitA,enterB,enterC")
	end)

	H.test("StateMachine wildcard transitions", function()
		local machine = StateMachine.new({
			Name = "Wild",
			Initial = "A",
			States = { A = {}, B = {}, Dying = {} },
			Transitions = { A = { "B" }, B = {}, ["*"] = { "Dying" } },
		})
		machine:Start()
		machine:Transition("B")
		H.ok(machine:Transition("Dying"))
	end)

	H.test("TokenBucket limits bursts and refills over time", function()
		local bucket = TokenBucket.new(3, 1, 0)
		H.ok(bucket:TryConsume(0) and bucket:TryConsume(0) and bucket:TryConsume(0))
		H.ok(not bucket:TryConsume(0), "4th request in a burst must fail")
		H.ok(bucket:TryConsume(1.01), "a token refills after 1 s")
		H.ok(not bucket:TryConsume(1.02))
		H.near(bucket:GetTokens(100), 3, 1e-6, "never exceeds capacity")
	end)

	H.test("TableUtil.Reconcile fills missing keys without overwriting", function()
		local data = { A = 5, Nested = { X = 1 }, Wrong = "keep" }
		local added = TableUtil.Reconcile(data, { A = 0, B = 2, Nested = { X = 0, Y = 3 }, Wrong = 0 })
		H.eq(data.A, 5)
		H.eq(data.B, 2)
		H.eq(data.Nested.Y, 3)
		H.eq(data.Wrong, "keep", "type mismatch must not destroy data")
		H.eq(added, 2)
	end)

	H.test("TableUtil.DeepCopy breaks references and DeepFreeze freezes nested", function()
		local original = { Inner = { 1, 2 } }
		local copy = TableUtil.DeepCopy(original)
		copy.Inner[1] = 9
		H.eq(original.Inner[1], 1)
		local frozen = TableUtil.DeepFreeze({ Inner = { 1 } })
		H.ok(not pcall(function() frozen.Inner[1] = 2 end), "nested table must be frozen")
	end)

	H.test("Validate rejects malformed payloads", function()
		local ID = { Kind = "string", MaxLength = 10, Pattern = "^[%w_]+$" }
		H.ok(Validate.CheckArgs({ "Neon_1" }, 1, { ID }))
		H.ok(not Validate.CheckArgs({ "bad id!" }, 1, { ID }), "pattern")
		H.ok(not Validate.CheckArgs({ string.rep("a", 11) }, 1, { ID }), "length")
		H.ok(not Validate.CheckArgs({ "a", "extra" }, 2, { ID }), "extra args")
		H.ok(not Validate.CheckArgs({ 0 / 0 }, 1, { { Kind = "number" } }), "NaN")
		H.ok(not Validate.CheckArgs({ math.huge }, 1, { { Kind = "number" } }), "inf")
		H.ok(not Validate.CheckArgs({ 1.5 }, 1, { { Kind = "integer" } }), "integer")
		H.ok(not Validate.CheckArgs({ 5 }, 1, { { Kind = "integer", Max = 4 } }), "max")
		H.ok(not Validate.CheckArgs({ Vector3.new(0 / 0, 0, 0) }, 1, { { Kind = "Vector3" } }), "NaN vector")
		H.ok(not Validate.CheckArgs({ Vector3.new(1e6, 0, 0) }, 1, { { Kind = "Vector3", MaxMagnitude = 10 } }), "vector magnitude")
		H.ok(not Validate.CheckArgs({ "Other" }, 1, { { Kind = "enum", Values = { "A" } } }), "enum")
		H.ok(not Validate.CheckArgs({ {} }, 1, { ID }), "table instead of string")
		H.ok(Validate.CheckArgs({}, 0, { { Kind = "boolean", Optional = true } }), "optional")
	end)

	H.test("WeightedRandom is deterministic and respects zero weights", function()
		local items = { "a", "b", "c" }
		local weights = { a = 1, b = 0, c = 3 }
		local function weightOf(item) return weights[item] end
		local first, second = H.Random.new(42), H.Random.new(42)
		for _ = 1, 50 do
			local x, y = WeightedRandom.Pick(items, weightOf, first), WeightedRandom.Pick(items, weightOf, second)
			H.eq(x, y, "same seed, same sequence")
			H.ok(x ~= "b", "zero weight must never be picked")
		end
		local unique = WeightedRandom.PickManyUnique(items, 3, weightOf, H.Random.new(1))
		H.eq(#unique, 2, "only positive-weight items can be picked")
	end)

	H.test("Format helpers", function()
		H.eq(Format.Commas(1234567), "1,234,567")
		H.eq(Format.Commas(999), "999")
		H.eq(Format.Countdown(75), "1:15")
		H.eq(Format.Countdown(-3), "0:00")
		H.eq(Format.Roman(4), "IV")
		H.eq(Format.Percent(0.426), "43%")
	end)

	H.test("MathUtil.BallisticVelocity lands on target", function()
		local from, to, t, g = Vector3.new(0, 5, 0), Vector3.new(30, 0, -12), 0.9, 196.2
		local velocity = MathUtil.BallisticVelocity(from, to, t, g)
		local landed = MathUtil.SampleBallistic(from, velocity, g, t)
		H.near((landed - to).Magnitude, 0, 1e-3)
	end)
end
