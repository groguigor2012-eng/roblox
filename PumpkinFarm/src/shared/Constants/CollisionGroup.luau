--!strict
--[[
	CollisionGroup
	Path: ReplicatedStorage.Shared.Constants.CollisionGroup

	Collision group names. Registered and wired by Server.Systems.CollisionGroups:
		Players   - player characters (pass through Defenses so you never trap yourself)
		Enemies   - ground enemies (do not collide with each other, which prevents jams)
		Defenses  - barricades and sentries (block Enemies only)
		Ghost     - underground moles, flying crows, effects (collide with nothing)
]]

return table.freeze({
	Players = "PF_Players",
	Enemies = "PF_Enemies",
	Defenses = "PF_Defenses",
	Ghost = "PF_Ghost",
})
