-- Resolves configured zones to parts in Workspace.MapZones (creating any that are missing)
-- and answers "which zone is this point in" / "may this player use this zone".

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Config.ZoneConfig)

local ZoneRegistry = {}

local zoneParts: { [string]: BasePart } = {}

local function zonesFolder(): Folder
	local folder = workspace:FindFirstChild("MapZones")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "MapZones"
		folder.Parent = workspace
	end
	return folder
end

function ZoneRegistry.init()
	local folder = zonesFolder()
	for _, zone in ZoneConfig.Zones do
		local part = folder:FindFirstChild(zone.id)
		if part and not part:IsA("BasePart") then
			warn(`[Zones] Workspace.MapZones.{zone.id} is not a BasePart; ignoring it`)
			part = nil
		end
		if not part then
			local region = zone.region
			local created = Instance.new("Part")
			created.Name = zone.id
			created.Size = region.size
			created.CFrame = CFrame.new(region.center) * CFrame.Angles(0, math.rad(region.rotationY), 0)
			part = created
		end
		local zonePart = part :: BasePart
		zonePart.Anchored = true
		zonePart.CanCollide = false
		zonePart.CanQuery = false
		zonePart.CanTouch = false
		zonePart.Transparency = 1
		zonePart.Parent = folder
		zonePart:SetAttribute("DisplayName", zone.displayName)
		zoneParts[zone.id] = zonePart
	end
end

function ZoneRegistry.getPart(zoneId: string): BasePart?
	local part = zoneParts[zoneId]
	if part and part.Parent then
		return part
	end
	return nil
end

function ZoneRegistry.contains(part: BasePart, position: Vector3): boolean
	local localPoint = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

function ZoneRegistry.getZoneAt(position: Vector3): ZoneConfig.ZoneDefinition?
	for _, zone in ZoneConfig.Zones do
		local part = ZoneRegistry.getPart(zone.id)
		if part and ZoneRegistry.contains(part, position) then
			return zone
		end
	end
	return nil
end

-- Ignores the vertical extent: used for flight rules, where altitude has its own limit.
function ZoneRegistry.getZoneAtFlat(position: Vector3): ZoneConfig.ZoneDefinition?
	for _, zone in ZoneConfig.Zones do
		local part = ZoneRegistry.getPart(zone.id)
		if part then
			local localPoint = part.CFrame:PointToObjectSpace(position)
			local half = part.Size / 2
			if math.abs(localPoint.X) <= half.X and math.abs(localPoint.Z) <= half.Z then
				return zone
			end
		end
	end
	return nil
end

function ZoneRegistry.isUnlocked(data: any, zoneId: string): boolean
	local zone = ZoneConfig.get(zoneId)
	if not zone then
		return false
	end
	return zone.unlock == nil or data.unlockedZones[zone.unlock] == true
end

return ZoneRegistry
