--!strict
--[[
	ResultCode
	Path: ReplicatedStorage.Shared.Constants.ResultCode

	Machine-readable outcome codes returned by every RemoteFunction handler as
	{ Ok = boolean, Code = ResultCode, Data = any? }. Clients map codes to friendly
	text with ResultCode.Messages; servers never send free-form error strings.
]]

local ResultCode = {
	Ok = "Ok",
	RateLimited = "RateLimited",
	InvalidPayload = "InvalidPayload",
	ServerError = "ServerError",
	DataNotLoaded = "DataNotLoaded",
	NotInMatch = "NotInMatch",
	AlreadyInMatch = "AlreadyInMatch",
	InvalidState = "InvalidState",
	NotFound = "NotFound",
	NotAllowed = "NotAllowed",
	NotOwned = "NotOwned",
	AlreadyOwned = "AlreadyOwned",
	InsufficientFunds = "InsufficientFunds",
	OutOfStock = "OutOfStock",
	StockChanged = "StockChanged",
	PurchaseLimit = "PurchaseLimit",
	LimitReached = "LimitReached",
	OutOfRange = "OutOfRange",
	Blocked = "Blocked",
	Occupied = "Occupied",
	NotReady = "NotReady",
	AlreadyDone = "AlreadyDone",
	Cooldown = "Cooldown",
	Dead = "Dead",
	Stunned = "Stunned",
	MaxLevel = "MaxLevel",
	QueueFull = "QueueFull",
	NotYourPlot = "NotYourPlot",
	ChestFull = "ChestFull",
}

ResultCode.Messages = {
	Ok = "Done!",
	RateLimited = "Slow down a little!",
	InvalidPayload = "That request was invalid.",
	ServerError = "Something went wrong. Please try again.",
	DataNotLoaded = "Your save data is not loaded, so this is disabled.",
	NotInMatch = "You need to be in a match for that.",
	AlreadyInMatch = "You are already in a match.",
	InvalidState = "You can't do that right now.",
	NotFound = "That no longer exists.",
	NotAllowed = "You can't do that.",
	NotOwned = "You don't own that yet.",
	AlreadyOwned = "You already own that.",
	InsufficientFunds = "Not enough currency.",
	OutOfStock = "Sold out!",
	StockChanged = "The shop just restocked. Try again.",
	PurchaseLimit = "You've bought the maximum of that item.",
	LimitReached = "The limit for that has been reached.",
	OutOfRange = "You're too far away.",
	Blocked = "That spot is blocked.",
	Occupied = "Something is already planted there.",
	NotReady = "It isn't ready yet.",
	AlreadyDone = "Already done.",
	Cooldown = "Still recharging.",
	Dead = "You're knocked out.",
	Stunned = "You're stunned!",
	MaxLevel = "Already at max level.",
	QueueFull = "All farms are busy. Try again in a moment.",
	NotYourPlot = "That plot belongs to another farmer. Plant on yours or a shared plot.",
	ChestFull = "The Harvest Chest is full! Escape to cash it in.",
}

table.freeze(ResultCode.Messages)
return table.freeze(ResultCode)
