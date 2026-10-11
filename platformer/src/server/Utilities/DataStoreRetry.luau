--!strict
-- Bounded retries with exponential backoff and jitter for DataStore calls.
--
--   delay(attempt) = min(MaxDelay, BaseDelay * 2^(attempt - 1)) * (1 + JitterFraction * r),  r in [0, 1)
--
-- Only thrown errors are retried. Errors with a non-retryable DataStore code
-- (bad key, value can't be stored, value too large, access denied) fail
-- immediately. A successful call returns whatever fn returned; the caller
-- still validates that value.

local DataStoreRetry = {}

export type Options = {
	MaxAttempts: number,
	BaseDelay: number,
	MaxDelay: number,
	JitterFraction: number,
	-- Injected for tests; default task.wait and math.random.
	Sleep: ((seconds: number) -> ())?,
	Random: (() -> number)?,
	-- Called before every attempt (e.g. to wait for request budget).
	BeforeAttempt: (() -> ())?,
	-- Called after each failed attempt that will be retried.
	OnRetry: ((attempt: number, message: string, delay: number) -> ())?,
}

-- 101-106: key/value problems. 401-406: place/API access problems
-- (e.g. Studio API access disabled). Retrying cannot fix either.
local NON_RETRYABLE_CODES: { [number]: boolean } = {
	[101] = true,
	[102] = true,
	[103] = true,
	[104] = true,
	[105] = true,
	[106] = true,
	[401] = true,
	[402] = true,
	[403] = true,
	[404] = true,
	[405] = true,
	[406] = true,
}

-- Reads the leading "NNN:" code Roblox puts on DataStore errors.
function DataStoreRetry.GetErrorCode(message: string): number?
	local code = string.match(message, "^%s*(%d%d%d)%s*:")
	return if code then tonumber(code) else nil
end

function DataStoreRetry.IsRetryable(message: string): boolean
	if string.find(message, "StudioAccessToApisNotAllowed", 1, true) then
		return false
	end
	local code = DataStoreRetry.GetErrorCode(message)
	return not (code and NON_RETRYABLE_CODES[code])
end

function DataStoreRetry.ComputeDelay(attempt: number, options: Options, randomValue: number): number
	local exponential = options.BaseDelay * 2 ^ math.max(attempt - 1, 0)
	local capped = math.min(options.MaxDelay, exponential)
	return capped * (1 + options.JitterFraction * math.clamp(randomValue, 0, 1))
end

-- Runs fn up to MaxAttempts times.
-- Returns (true, value, attempts) on success, (false, errorMessage, attempts) on failure.
function DataStoreRetry.Run(operation: string, fn: () -> any, options: Options): (boolean, any, number)
	local sleep: (number) -> () = options.Sleep or function(seconds: number)
		task.wait(seconds)
	end
	local random: () -> number = options.Random or function(): number
		return math.random()
	end
	local maxAttempts = math.max(1, math.floor(options.MaxAttempts))
	local lastError = "no attempt made"
	for attempt = 1, maxAttempts do
		if options.BeforeAttempt then
			options.BeforeAttempt()
		end
		local ok, result = pcall(fn)
		if ok then
			return true, result, attempt
		end
		lastError = `{operation}: {tostring(result)}`
		if not DataStoreRetry.IsRetryable(tostring(result)) or attempt == maxAttempts then
			return false, lastError, attempt
		end
		local delay = DataStoreRetry.ComputeDelay(attempt, options, random())
		if options.OnRetry then
			options.OnRetry(attempt, lastError, delay)
		end
		sleep(delay)
	end
	return false, lastError, maxAttempts
end

return DataStoreRetry
