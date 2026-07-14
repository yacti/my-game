local MailboxConfig = {}

MailboxConfig.InteractionDistance = 5
MailboxConfig.SignsFolderName = "Signs"
MailboxConfig.MailboxName = "Mailbox"
MailboxConfig.DoorName = "Door"
MailboxConfig.SkipTimeSignName = "SkipTimeSign"
-- Sign distance is measured from the model bounding-box center; the sign is a
-- tall wall board, so it needs more reach than the mailbox for the same feel.
MailboxConfig.SkipTimeSignInteractionDistance = 30

return MailboxConfig
