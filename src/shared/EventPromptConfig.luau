local EventPromptConfig = {}

-- Set this to the current Roblox experience event ID. Changing the ID makes
-- every player eligible for the one-time native RSVP prompt again.
EventPromptConfig.ActiveEventId = "537724258487501381"

function EventPromptConfig.GetActiveEventId()
	local value = EventPromptConfig.ActiveEventId
	if type(value) ~= "string" then
		return nil
	end
	value = string.match(value, "^%s*(.-)%s*$")
	return value ~= "" and value or nil
end

return EventPromptConfig
