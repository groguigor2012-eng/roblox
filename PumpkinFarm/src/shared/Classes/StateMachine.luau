--!strict
--[[
	StateMachine
	Path: ReplicatedStorage.Shared.Classes.StateMachine

	Finite state machine with an explicit transition table. Used by Match (match
	lifecycle) and by AI that has real phases (Zombie Mole, Blighted Scarecrow,
	Plague Crow, Cursed Harvester). Replaces scattered booleans with one
	authoritative state and rejects illegal transitions loudly.

	Transitions requested from inside Enter/Exit handlers are queued and applied
	after the current transition finishes, so handlers can chain states safely.

	Dependencies: Shared.Classes.Signal

	API:
		StateMachine.new(definition) -> StateMachine
			definition = {
				Name: string,                        -- used in warnings
				Initial: string,
				States: { [state]: { Enter?, Exit?, Update? } },
				Transitions: { [fromState]: { toState } },  -- "*" key = allowed from any state
			}
			Enter(machine, fromState, data), Exit(machine, toState), Update(machine, dt)
		:Start(data?)
		:Transition(toState, data?) -> boolean
		:CanTransition(toState) -> boolean
		:Update(dt)
		:GetState() -> string?
		:Is(state) -> boolean
		:TimeInState() -> number
		.StateChanged : Signal(newState, oldState)
		:Destroy()
]]

local Signal = require(script.Parent.Signal)

export type StateHandlers = {
	Enter: ((machine: any, fromState: string?, data: any?) -> ())?,
	Exit: ((machine: any, toState: string) -> ())?,
	Update: ((machine: any, dt: number) -> ())?,
}

export type Definition = {
	Name: string,
	Initial: string,
	States: { [string]: StateHandlers },
	Transitions: { [string]: { string } },
}

local StateMachine = {}
StateMachine.__index = StateMachine

export type StateMachine = typeof(setmetatable(
	{} :: {
		Name: string,
		StateChanged: Signal.Signal,
		_definition: Definition,
		_state: string?,
		_enteredAt: number,
		_transitioning: boolean,
		_pending: { { To: string, Data: any? } },
		_destroyed: boolean,
	},
	StateMachine
))

function StateMachine.new(definition: Definition): StateMachine
	assert(definition.States[definition.Initial], `[StateMachine:{definition.Name}] initial state is not defined`)
	for from, targets in definition.Transitions do
		assert(from == "*" or definition.States[from], `[StateMachine:{definition.Name}] unknown state {from}`)
		for _, target in targets do
			assert(definition.States[target], `[StateMachine:{definition.Name}] unknown target {target}`)
		end
	end
	return setmetatable({
		Name = definition.Name,
		StateChanged = Signal.new(),
		_definition = definition,
		_state = nil,
		_enteredAt = os.clock(),
		_transitioning = false,
		_pending = {},
		_destroyed = false,
	}, StateMachine)
end

function StateMachine.Start(self: StateMachine, data: any?)
	assert(self._state == nil, `[StateMachine:{self.Name}] already started`)
	self:_apply(self._definition.Initial, data)
end

function StateMachine.CanTransition(self: StateMachine, toState: string): boolean
	if self._destroyed or self._definition.States[toState] == nil then
		return false
	end
	local current = self._state
	if current == nil then
		return false
	end
	local allowed = self._definition.Transitions[current]
	if allowed and table.find(allowed, toState) then
		return true
	end
	local wildcard = self._definition.Transitions["*"]
	return wildcard ~= nil and table.find(wildcard, toState) ~= nil
end

function StateMachine.Transition(self: StateMachine, toState: string, data: any?): boolean
	if self._destroyed then
		return false
	end
	if self._transitioning then
		table.insert(self._pending, { To = toState, Data = data })
		return true
	end
	if not self:CanTransition(toState) then
		warn(`[StateMachine:{self.Name}] rejected transition {tostring(self._state)} -> {toState}`)
		return false
	end
	self:_apply(toState, data)
	return true
end

function StateMachine._apply(self: StateMachine, toState: string, data: any?)
	self._transitioning = true
	local fromState = self._state
	local states = self._definition.States

	if fromState then
		local exit = states[fromState].Exit
		if exit then
			local ok, err = xpcall(exit, debug.traceback, self, toState)
			if not ok then
				warn(`[StateMachine:{self.Name}] Exit({fromState}) failed: {err}`)
			end
		end
	end

	self._state = toState
	self._enteredAt = os.clock()

	local enter = states[toState].Enter
	if enter then
		local ok, err = xpcall(enter, debug.traceback, self, fromState, data)
		if not ok then
			warn(`[StateMachine:{self.Name}] Enter({toState}) failed: {err}`)
		end
	end

	self._transitioning = false
	self.StateChanged:Fire(toState, fromState)

	-- Apply transitions queued by handlers (validated against the new state).
	if #self._pending > 0 and not self._destroyed then
		local nextRequest = table.remove(self._pending, 1) :: { To: string, Data: any? }
		self:Transition(nextRequest.To, nextRequest.Data)
	end
end

function StateMachine.Update(self: StateMachine, dt: number)
	local current = self._state
	if self._destroyed or current == nil or self._transitioning then
		return
	end
	local update = self._definition.States[current].Update
	if update then
		update(self, dt)
	end
end

function StateMachine.GetState(self: StateMachine): string?
	return self._state
end

function StateMachine.Is(self: StateMachine, state: string): boolean
	return self._state == state
end

function StateMachine.TimeInState(self: StateMachine): number
	return os.clock() - self._enteredAt
end

function StateMachine.Destroy(self: StateMachine)
	self._destroyed = true
	table.clear(self._pending)
	self.StateChanged:Destroy()
end

return StateMachine
