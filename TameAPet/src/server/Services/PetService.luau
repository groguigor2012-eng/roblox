-- Equipping tamed pets and the cosmetic companion that follows the player around while not
-- riding. Only Tamed pets can be equipped (enforced in Data/Transactions.equipPet). The
-- companion is purely visual: it carries a server-built rarity billboard and has no effect
-- on gameplay, so its physics may be owned by the player for smooth following.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PetConfig = require(ReplicatedStorage.Config.PetConfig)
local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)
local Transactions = require(ServerScriptService.Data.Transactions)
local Validate = require(ServerScriptService.Security.Validate)
local AssetLibrary = require(ServerScriptService.World.AssetLibrary)
local RarityBillboard = require(ServerScriptService.World.RarityBillboard)

local Codes = RemoteNames.Codes

local PetService = {}
PetService.Name = "PetService"

local Services
local companions: { [Player]: Model } = {}
local companionsFolder: Folder

-- The equipped pet's record and species config, or nil.
function PetService.getEquipped(player: Player)
	local data = Services.DataService.getData(player)
	if not data or data.equippedPetId == "" then
		return nil, nil
	end
	local pet = data.pets[data.equippedPetId]
	if not pet or pet.status ~= "Tamed" then
		return nil, nil
	end
	local species = PetConfig.Species[pet.species]
	if not species then
		return nil, nil
	end
	return pet, species
end

function PetService.despawnCompanion(player: Player)
	local model = companions[player]
	companions[player] = nil
	if model then
		model:Destroy()
	end
end

function PetService.spawnCompanion(player: Player)
	PetService.despawnCompanion(player)
	if Services.MountService.isMounted(player) then
		return
	end
	local pet, species = PetService.getEquipped(player)
	local root = Services.PlayerStateService.getRoot(player)
	if not pet or not species or not root then
		return
	end
	local model = AssetLibrary.pet(pet.species, false)
	if not model then
		return
	end
	model.Name = `Companion_{player.UserId}`
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("Species", pet.species)

	local body = model.PrimaryPart :: BasePart
	-- Shrink the companion a little so it doesn't block the player.
	model:ScaleTo(0.7)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Massless = true
			descendant.CanCollide = false
		end
	end

	local petAttachment = Instance.new("Attachment")
	petAttachment.Name = "FollowAttachment"
	petAttachment.Parent = body
	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "CompanionAnchor"
	anchorAttachment.Position = Vector3.new(4, 0, 3)
	anchorAttachment.Parent = root

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Attachment0 = petAttachment
	alignPosition.Attachment1 = anchorAttachment
	alignPosition.Responsiveness = 18
	alignPosition.MaxForce = 1e5
	alignPosition.Parent = body
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Attachment0 = petAttachment
	alignOrientation.Attachment1 = anchorAttachment
	alignOrientation.Responsiveness = 15
	alignOrientation.MaxTorque = 1e5
	alignOrientation.Parent = body
	-- Destroying the companion also removes the anchor attachment on the character.
	model.Destroying:Connect(function()
		anchorAttachment:Destroy()
	end)

	model:PivotTo(root.CFrame * CFrame.new(4, 0, 3))
	RarityBillboard.attach(model, {
		displayName = species.displayName,
		rarity = pet.rarity,
		oddsText = Services.DataService.oddsText(pet.eggTier, pet.species),
		ownerName = player.DisplayName,
	})
	model.Parent = companionsFolder
	pcall(function()
		body:SetNetworkOwner(player)
	end)
	companions[player] = model
end

local function equipPet(player: Player, petId: string)
	local Security = Services.RemoteSecurityService
	local data = Services.DataService.getData(player)
	if not data then
		return Security.fail(Codes.NotReady)
	end
	local previous = data.equippedPetId
	local ok, code = Transactions.equipPet(data, Services.DataService.context(), petId)
	if not ok then
		if code == Codes.NotOwned then
			Security.report(player, "EquipPet", `pet {petId} not owned`)
			return Security.fail(code, "That pet isn't yours.")
		elseif code == Codes.NotTamed then
			return Security.fail(code, "Tame this pet before equipping it.")
		end
		return Security.fail(code, "You can't equip that pet.")
	end
	Services.DataService.markDirty(player)
	if previous ~= data.equippedPetId then
		-- Riding a pet that is no longer equipped is not allowed.
		if Services.MountService.isMounted(player) then
			Services.MountService.dismount(player, "PetChanged") -- respawns the companion
		else
			PetService.spawnCompanion(player)
		end
	end
	return Security.ok()
end

function PetService.init(services)
	Services = services
	companionsFolder = AssetLibrary.workspaceFolder("ActivePets")
end

function PetService.start()
	Services.RemoteSecurityService.bindFunction(
		"EquipPet",
		{ action = "EquipPet", args = { Validate.optionalId(64) } },
		equipPet
	)

	local function hookCharacter(player: Player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("HumanoidRootPart", 10)
			if Services.PlayerStateService.isReady(player) then
				PetService.spawnCompanion(player)
			end
		end)
		player.CharacterRemoving:Connect(function()
			PetService.despawnCompanion(player)
		end)
	end
	Players.PlayerAdded:Connect(hookCharacter)
	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end
	Services.PlayerStateService.Ready:Connect(function(player)
		PetService.spawnCompanion(player)
	end)
	Players.PlayerRemoving:Connect(PetService.despawnCompanion)
end

return PetService
