-- Shared scarecrow jump timing.
--
-- Jumps start on global server-clock boundaries (see server feedMachines/
-- Scarecrow.luau and client ScarecrowJumpEffects.luau). The server delays each
-- tree-shake wave by JumpDuration so fruit drops when the client-rendered hop
-- lands, not at takeoff — both sides must read the same number.
local ScarecrowBalance = {
	-- Seconds a jump animation lasts from takeoff to landing.
	JumpDuration = 0.55,
}

return ScarecrowBalance
