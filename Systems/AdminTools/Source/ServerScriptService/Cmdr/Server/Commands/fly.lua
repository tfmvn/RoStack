--!strict
--!native
--[[
	/fly
	Toggle flight for the executor. Admin-only dev tool. Uses
	a BodyPosition + BodyGyro on the HRP while flight is on,
	which is the textbook approach for legacy Humanoid characters.
	When flight is off, the BodyMovers are destroyed and the
	character falls back to default Humanoid physics.

	The toggle is per-character: respawning does NOT re-enable
	fly. The /fly command must be re-run after each CharacterAdded.
	That keeps /fly from "sticking" between sessions.

	Cleanup: BodyMovers live on the HRP, so when the character
	is destroyed (on death or PlayerRemoving) the BodyMovers
	go with it. The flight table only tracks the active state
	by character reference, so a dead character's entry becomes
	harmless garbage.
]]

return {
	Name = 'fly',
	Aliases = {},
	Description = 'Toggle flight for yourself (admin-only).',
	Group = 'Admin',
	Args = {},
}
