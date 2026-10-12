-- ViewportFrame previews of pets for UI (inventory details, hatch reveal). Uses
-- ReplicatedStorage.UIAssets.PetPreviews.<species> if present, else a placeholder rig.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PetConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PetConfig"))
local PlaceholderModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlaceholderModels"))

local PetPreview = {}

local function buildModel(speciesId: string): Model?
	local previews = ReplicatedStorage:FindFirstChild("UIAssets")
	previews = previews and previews:FindFirstChild("PetPreviews")
	local custom = previews and previews:FindFirstChild(speciesId)
	if custom and custom:IsA("Model") then
		return custom:Clone()
	end
	local species = PetConfig.Species[speciesId]
	if not species then
		return nil
	end
	return PlaceholderModels.buildPet(speciesId, species.look, species.mountType == "Flying")
end

export type Preview = { frame: ViewportFrame, destroy: () -> () }

-- Fills `parent` with a slowly spinning preview. Call destroy() (or destroy the parent) to stop.
function PetPreview.create(parent: GuiObject, speciesId: string, spin: boolean): Preview
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "PetPreview"
	viewport.BackgroundTransparency = 1
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.Ambient = Color3.fromRGB(170, 170, 190)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-1, -1.5, -1)

	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewport
	local model = buildModel(speciesId)
	local connection: RBXScriptConnection? = nil
	if model then
		model:PivotTo(CFrame.new())
		model.Parent = worldModel
		local angle = math.rad(200)
		PlaceholderModels.frameModel(model, camera, angle)
		if spin then
			connection = RunService.RenderStepped:Connect(function(dt)
				angle += dt * 0.8
				PlaceholderModels.frameModel(model, camera, angle)
			end)
		end
	end
	viewport.Parent = parent

	local function destroy()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		viewport:Destroy()
	end
	viewport.Destroying:Connect(function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end)
	return { frame = viewport, destroy = destroy }
end

return PetPreview
