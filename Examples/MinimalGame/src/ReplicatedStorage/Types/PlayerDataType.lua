--!strict
--[[
	PlayerDataType
	=============
	The persisted shape stored under ProfileService.

	Spec §26-§28. Phase 1 keeps the schema tiny: identity, cash, and
	which base is assigned. Future phases can extend without breaking
	older saves by following the migration pattern documented in
	Docs/decisions/0001-persistence.md (added in this phase).
]]

export type PlayerData = {
	UserId: number,
	Cash: number,
	BaseId: string?, -- nil until assigned
	Loaded: boolean,
}
