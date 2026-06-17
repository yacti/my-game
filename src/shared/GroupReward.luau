local GroupReward = {}

GroupReward.GroupId = 11603322

GroupReward.ModelName = "JoinGroup"
GroupReward.TouchPartName = "TouchPart"
GroupReward.VisualName = "Watermelon Seed"

GroupReward.NotInGroupMessage = "Like the game and join the group to collect!"
GroupReward.SuccessMessage = "Collected group reward!"

GroupReward.RewardTypes = {
	Seed = "Seed",
}

GroupReward.Reward = {
	Type = GroupReward.RewardTypes.Seed,
	Id = "WatermelonSeed",
	Quantity = 1,
}

GroupReward.Prompt = {
	ActionText = "Collect",
	ObjectText = "Group Reward",
	MaxActivationDistance = 10,
}

return GroupReward
