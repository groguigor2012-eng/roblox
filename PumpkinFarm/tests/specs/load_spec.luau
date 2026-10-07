return function(H)
	-- Requiring a module runs its top-level code: config validation, constant tables,
	-- require graphs. Any error here would break the server at start-up.
	for _, rootName in { "Shared", "Server" } do
		for _, node in H.AllModules(rootName) do
			H.test(`{rootName}.{node.Name} loads`, function()
				local ok, result = pcall(H.Require, node)
				H.ok(ok, tostring(result))
				H.ok(result ~= nil, "module returned nil")
			end)
		end
	end
end
