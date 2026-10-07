--!strict
--[[
	Result
	Path: ReplicatedStorage.Shared.Utilities.Result

	Constructors for the uniform RemoteFunction response { Ok, Code, Data }.

	API:
		Result.Ok(data?) -> Result
		Result.Fail(code, data?) -> Result
]]

local ResultCode = require(script.Parent.Parent.Constants.ResultCode)

export type Result = { Ok: boolean, Code: string, Data: any? }

local Result = {}

function Result.Ok(data: any?): Result
	return { Ok = true, Code = ResultCode.Ok, Data = data }
end

function Result.Fail(code: string, data: any?): Result
	return { Ok = false, Code = code, Data = data }
end

return Result
