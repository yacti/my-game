-- Social-media code redemption: a Discord bot hands players a 9-character
-- code whose composition (not order) proves it came from the bot. The client
-- pre-validates for instant feedback; the server re-validates and grants the
-- seed once per player.
local MediaReward = {}

-- Master switch: false hides the topbar icon/panel for every player and makes
-- the server refuse redeems, without tearing out the feature.
MediaReward.Enabled = false

MediaReward.PanelName = "SocialMedia"
MediaReward.VisualName = "Watermelon Seed"

MediaReward.SuccessMessage = "Collected Discord reward!"
MediaReward.InvalidCodeMessage = "That code doesn't look right. Type /verify in #bot-commands!"
MediaReward.AlreadyCollectedMessage = "You already collected this reward!"

MediaReward.RewardTypes = {
	Seed = "Seed",
}

MediaReward.Reward = {
	Type = MediaReward.RewardTypes.Seed,
	Id = "WatermelonSeed",
	Quantity = 1,
}

MediaReward.CodeLength = 9
MediaReward.CodeSpecials = "!@#$%^&*"
MediaReward.CodeCounts = {
	Digits = 3,
	Lowercase = 2,
	Uppercase = 2,
	Specials = 2,
}

-- Accepts any ordering: the code is valid iff it is exactly 9 characters made
-- of 3 digits, 2 lowercase, 2 uppercase, and 2 specials from CodeSpecials.
function MediaReward.ValidateCode(code)
	if type(code) ~= "string" or #code ~= MediaReward.CodeLength then
		return false
	end

	local digits, lower, upper, specials = 0, 0, 0, 0
	for index = 1, #code do
		local char = string.sub(code, index, index)
		if string.match(char, "%d") then
			digits += 1
		elseif string.match(char, "^[a-z]$") then
			lower += 1
		elseif string.match(char, "^[A-Z]$") then
			upper += 1
		elseif string.find(MediaReward.CodeSpecials, char, 1, true) then
			specials += 1
		else
			return false
		end
	end

	local counts = MediaReward.CodeCounts
	return digits == counts.Digits
		and lower == counts.Lowercase
		and upper == counts.Uppercase
		and specials == counts.Specials
end

return MediaReward
