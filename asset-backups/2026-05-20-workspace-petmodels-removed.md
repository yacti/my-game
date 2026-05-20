# Workspace Pet Model Cleanup Backup

 The 52 animal models that were duplicated from `Workspace` into
 `ReplicatedStorage.PetModels` were removed from `Workspace` on 2026-05-20.

 Instead of destroying the original Studio instances, they were moved to:

 ```text
 ServerStorage.AssetBackups.WorkspacePetModelsRemoved_2026_05_20
 ```

 The backup folder contains:

 ```text
 Pigeon, Parrot, Hamster, Ostrich, Kangaroo, Bat, Owl,
 GuiennaPig, Lion, GoldenRetriver, Horse, Llama, Goat, Kitsune,
 Capybara, Bunny, Koala, Turtle, Lizard, Cat, Wolf, Pony, Unicorn,
 Zebra, Polar Bear, Gorilla, Bear, Bull, Cow, Tiger, Giraffee,
 Elephant, Mamoth, Crocodile, Ankylosaurus, Brachiosaurus,
 Triceratops, Whale, Seal, Shark, Swordfish, Mosasaurus, Goldfish,
 Velicoraptor, Gallimimus, T-Rex, Spinosaurus, TripleCobra, Cobra,
 Snake, Snail, Crab
 ```

 Verification after the move:

 - `Workspace` no longer contains the 52 listed animal models.
 - `ReplicatedStorage.PetModels` still contains the active pet templates.
 - `AssetValidator.validate()` passed in Studio.
