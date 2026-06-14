local PetNicknames = {}

local NICKNAMES = {
	"Maya",
	"Marc",
	"Daire",
	"Maja",
	"Kuba",
	"Marty",
	"Seb",
	"Aidan",
	"Daniel",
	"Greg",
	"Will",
	"Leo",
	"Victor",
	"Peter",
	"Max",
	"Tim",
	"Tom",
	"Milo",
	"Leo",
	"Oscar",
	"Max",
	"Archie",
	"Teddy",
	"Bruno",
	"Jasper",
	"Finn",
	"Toby",
	"Loki",
	"Zeus",
	"Rex",
	"Bailey",
	"Rocky",
	"Cooper",
	"Bentley",
	"Murphy",
	"Hugo",
	"Luna",
	"Bella",
	"Daisy",
	"Ruby",
	"Lola",
	"Nala",
	"Willow",
	"Coco",
	"Rosie",
	"Millie",
	"Poppy",
	"Cleo",
	"Stella",
	"Winnie",
	"Ivy",
	"Honey",
	"Pepper",
	"Mia",
	"Olive",
	"Mabel",
	"Molly",
	"Chloe",
	"Maisie",
	"Skye",
	"Roxy",
	"Bonnie",
	"Phoebe",
	"Sasha",
	"Gracie",
	"Tilly",
	"Butter Chicken",
	"Nessie",
	"Dorito",
	"Taco",
	"Noodle",
	"Heatwave",
	"Ramen",
	"Chip",
	"Thor",
	"Kebab",
	"Zeus",
	"Tila",
	"Tikka",
	"Masala",
	"Nala",
	"Loki",
	"Medusa",
	"Aphrodite",
	"Venus",
	"Poseidon",
	"Athena",
	"Aries",
	"Hermes",
	




}

local COLOR_OVERRIDES = {
	Marc = Color3.fromRGB(34, 139, 34), -- Forest green
	Maja = Color3.fromRGB(219, 64, 255), -- Purple
}

function PetNicknames.Pick(random)
	local rng = random or Random.new()
	return NICKNAMES[rng:NextInteger(1, #NICKNAMES)]
end

function PetNicknames.ColorFor(nickname)
	return COLOR_OVERRIDES[nickname]
end

return PetNicknames
