-- Looks up art in ServerStorage and falls back to generated placeholders. Missing assets
-- produce one actionable warning each instead of a script error.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Config.GameConfig)
local PetConfig = require(ReplicatedStorage.Config.PetConfig)
local ItemConfig = require(ReplicatedStorage.Config.ItemConfig)
local EggConfig = require(ReplicatedStorage.Config.EggConfig)
local RarityConfig = require(ReplicatedStorage.Config.RarityConfig)
local PlaceholderModels = require(ReplicatedStorage.Shared.PlaceholderModels)

local AssetLibrary = {}

local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if not warned[key] then
		warned[key] = true
		warn(message)
	end
end

local function findModel(folderName: string, id: string): Model?
	local folder = ServerStorage:FindFirstChild(folderName)
	local found = folder and folder:FindFirstChild(id)
	if found and found:IsA("Model") then
		if not found.PrimaryPart then
			warnOnce(`{folderName}/{id}/primary`, `[Assets] ServerStorage.{folderName}.{id} has no PrimaryPart; using a placeholder`)
			return nil
		end
		return found:Clone()
	end
	return nil
end

-- Prepares a cloned art model: unanchored, welded to its PrimaryPart, non-colliding.
local function prepare(model: Model): Model
	local root = model.PrimaryPart :: BasePart
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			if descendant ~= root and not descendant:FindFirstChildWhichIsA("WeldConstraint") then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = descendant
				weld.Parent = descendant
			end
		end
	end
	return model
end

local function placeholdersAllowed(key: string, label: string): boolean
	if GameConfig.Assets.AllowPlaceholders then
		warnOnce(key, `[Assets] No model for {label}; using a generated placeholder (add one to ServerStorage to replace it).`)
		return true
	end
	warnOnce(key, `[Assets] No model for {label} and placeholders are disabled; it will not spawn.`)
	return false
end

function AssetLibrary.pet(speciesId: string, forMount: boolean): Model?
	local species = PetConfig.Species[speciesId]
	if not species then
		warnOnce(`pet/{speciesId}`, `[Assets] Unknown species "{speciesId}"`)
		return nil
	end
	local model = (if forMount then findModel("MountModels", speciesId) else nil) or findModel("PetModels", speciesId)
	if model then
		return prepare(model)
	end
	if not placeholdersAllowed(`pet/{speciesId}`, `pet "{speciesId}" (ServerStorage.PetModels.{speciesId})`) then
		return nil
	end
	return PlaceholderModels.buildPet(speciesId, species.look, species.mountType == "Flying")
end

function AssetLibrary.egg(tierId: string): Model?
	local tier = EggConfig.Tiers[tierId]
	if not tier then
		return nil
	end
	local model = findModel("EggModels", tierId)
	if model then
		return prepare(model)
	end
	if not placeholdersAllowed(`egg/{tierId}`, `egg tier "{tierId}" (ServerStorage.EggModels.{tierId})`) then
		return nil
	end
	return PlaceholderModels.buildEgg(tierId, tier.color, RarityConfig.rank(tierId))
end

function AssetLibrary.item(itemId: string): Model?
	local item = ItemConfig.Items[itemId]
	if not item then
		return nil
	end
	local model = findModel("ItemModels", itemId)
	if model then
		return prepare(model)
	end
	if not placeholdersAllowed(`item/{itemId}`, `item "{itemId}" (ServerStorage.ItemModels.{itemId})`) then
		return nil
	end
	return PlaceholderModels.buildItem(itemId, item.shape, item.color, item.spawn.hidden)
end

-- Moves a model so the bottom of its bounding box rests on `groundPosition`, rotated by `yaw`.
function AssetLibrary.placeOnGround(model: Model, groundPosition: Vector3, yaw: number)
	local boxCFrame, size = model:GetBoundingBox()
	local boxRelativeToPivot = model:GetPivot():ToObjectSpace(boxCFrame)
	local targetBox = CFrame.new(groundPosition + Vector3.new(0, size.Y / 2 + 0.05, 0)) * CFrame.Angles(0, yaw, 0)
	model:PivotTo(targetBox * boxRelativeToPivot:Inverse())
end

-- A top-level Workspace folder, created if a place file is missing it.
function AssetLibrary.workspaceFolder(name: string): Folder
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = workspace
	return created
end

AssetLibrary.warnOnce = warnOnce

return AssetLibrary
