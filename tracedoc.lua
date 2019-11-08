local next = next
local setmetatable = setmetatable
local getmetatable = getmetatable
local type = type
local rawset = rawset
local table = table
local unpack = unpack
local tostring = tostring
local assert = assert
local compat = require("compat")
local pairs = compat.pairs
local ipairs = compat.ipairs
local table_len = compat.len
local load = compat.load

---@class tracedoc
local tracedoc = {}
local NULL = setmetatable({} , { __tostring = function() return "NULL" end })	-- nil
tracedoc.null = NULL
local tracedoc_type = setmetatable({}, { __tostring = function() return "TRACEDOC" end })
local tracedoc_len = setmetatable({} , { __mode = "kv" })

local function doc_len(doc)
	return #doc._stage
end

local function doc_next(doc, k)
	return next(doc._stage, k)
end

local function doc_pairs(doc)
	return pairs(doc._stage)
end

local function doc_ipairs(doc)
	return ipairs(doc._stage)
end

local function doc_unpack(doc, i, j)
	return table.unpack(doc._stage, i, j)
end

local function doc_concat(doc, sep, i, j)
	return table.concat(doc._stage, sep, i, j)
end

local function mark_dirty(doc)
	if not doc._dirty then
		doc._dirty = true
		local parent = doc._parent
		while parent do
			if parent._dirty then
				break
			end
			parent._dirty = true
			parent = parent._parent
		end
	end
end

local function doc_change_value(doc, k, v, force)
	if v ~= doc[k] or force then
		doc._changed_keys[k] = true -- mark changed (even nil)
		doc._changed_values[k] = doc._stage[k] -- lastversion value
		doc._stage[k] = v -- current value
		mark_dirty(doc)
	end
end

local function doc_change_recursively(doc, k, v)
	local lv = doc._stage[k]
	if getmetatable(lv) ~= tracedoc_type then
		lv = doc._changed_values[k]
		if getmetatable(lv) ~= tracedoc_type then
			-- last version is not a table, new a empty one
			lv = tracedoc.new()
			lv._parent = doc
			doc._stage[k] = lv
		else
			-- this version is clear first (not a tracedoc), deepcopy lastversion one
			lv = tracedoc.new(lv)
			lv._parent = doc
			doc._stage[k] = lv
		end
	end
	local keys = {}
	for k in pairs(lv) do
		keys[k] = true
	end
	-- deepcopy v
	for k,v in pairs(v) do
		lv[k] = v
		keys[k] = nil
	end
	-- clear keys not exist in v
	for k in pairs(keys) do
		lv[k] = nil
	end
	-- don't cache sub table into changed fields
	doc._changed_values[k] = nil
	doc._changed_keys[k] = nil
end

local function doc_change(doc, k, v)
	local recursively = false
	if type(v) == "table" then
		local vt = getmetatable(v)
		recursively = vt == nil or vt == tracedoc_type
	end

	if v ~= doc[k] then
		if recursively then
			doc_change_recursively(doc, k, v)
		else
			doc_change_value(doc, k, v)
		end
	end
end

local function doc_insert(doc, index, v)
	local len = tracedoc.len(doc)
	if v == nil then
		v = index
		index = len + 1
	end

	for i = len, index, -1 do
		doc[i + 1] = doc[i]
	end
	doc[index] = v
end

local function doc_remove(doc, index)
	local len = tracedoc.len(doc)
	index = index or len

	local v = doc[index]
	doc[index] = nil -- trig a clone of doc._stage[index] in doc_change()

	for i = index + 1, len do
		doc[i - 1] = doc[i]
	end	
	doc[len] = nil

	return v
end

tracedoc.len = doc_len
tracedoc.next = doc_next
tracedoc.pairs = doc_pairs
tracedoc.ipairs = doc_ipairs
tracedoc.unpack = doc_unpack
tracedoc.concat = doc_concat
tracedoc.insert = doc_insert
tracedoc.remove = doc_remove

function tracedoc.new(init)
	local doc_stage = {}
	local doc = {
		_dirty = false,
		_parent = false,
		_changed_keys = {},
		_changed_values = {},
		_stage = doc_stage,
	}
	setmetatable(doc, {
		__index = doc_stage, 
		__newindex = doc_change,
		__pairs = doc_pairs,
		__ipairs = doc_ipairs,
		__len = doc_len,
		__metatable = tracedoc_type,	-- avoid copy by ref
	})
	if init then
		for k,v in pairs(init) do
			-- deepcopy v
			if getmetatable(v) == tracedoc_type then
				doc[k] = tracedoc.new(v)
			else
				doc[k] = v
			end
		end
	end
	return doc
end

function tracedoc.dump(doc)
	local stage = {}
	for k,v in pairs(doc._stage) do
		table.insert(stage, string.format("%s:%s",k,v))
	end
	local changed = {}
	for k in pairs(doc._changed_keys) do
		table.insert(changed, string.format("%s:%s",k,doc._changed_values[k]))
	end
	return string.format("content [%s]\nchanges [%s]",table.concat(stage, " "), table.concat(changed," "))
end

local function _commit(doc, result, prefix)
	if doc._ignore then
		return result
	end

	doc._dirty = false

	local changed_keys = doc._changed_keys
	local changed_values = doc._changed_values
	local stage = doc._stage
	local dirty = false
	
	if next(changed_keys) ~= nil then
		dirty = true
		for k in pairs(changed_keys) do
			local v, lv = stage[k], changed_values[k]
			changed_keys[k] = nil
			changed_values[k] = nil
			if result then
				local key = prefix and prefix .. "." .. k or tostring(k)
				result[key] = v == nil and NULL or v
				result._n = (result._n or 0) + 1
			end
		end
	end
	for k, v in pairs(stage) do
		if getmetatable(v) == tracedoc_type and v._dirty then
			if result then
				local key = prefix and prefix .. "." .. k or tostring(k)
				local change
				if v._opaque then
					change = _commit(v)
				else
					local n = result._n
					_commit(v, result, key)
					if n ~= result._n then
						change = true
					end
				end
				if change then
					if result[key] == nil then
						result[key] = v
						result._n = (result._n or 0) + 1
					end
					dirty = true
				end
			else
				local change = _commit(v)
				dirty = dirty or change
			end
		end
	end
	return result or dirty
end

tracedoc.commit = _commit

function tracedoc.ignore(doc, enable)
	rawset(doc, "_ignore", enable)	-- ignore it during commit when enable
	if not enable then -- when disable ignore, we need remark dirty for doc's parents if needed
		if doc._dirty and doc._parent then
			mark_dirty(doc._parent)
		end
	end
end

function tracedoc.opaque(doc, enable)
	rawset(doc, "_opaque", enable)
end

function tracedoc.mark_changed(doc, k)
	if doc._changed_keys[k] then return end
	doc_change_value(doc, k, doc[k], true)
end

----- change set

local function buildkey(key)
	return key:gsub("%[(-?%d+)%]", ".%1"):gsub("^%.+", "")
end

local function genkey(keys, key)
	if keys[key] then
		return
	end

	local code = [[return function(doc)
		local success, ret = pcall(function(doc)
			return doc%s
		end, doc)
		if success then
			return ret
		end
	end]]
	local path = ("."..key):gsub("%.(-?%d+)","[%1]")
	keys[key] = assert(load(code:format(path)))()
end

function tracedoc.changeset(map)
	local set = {
		watching = { n = 0 },
		root_watching = {},
		mapping = {},
		keys = {},
		map = map,
	}
	for _, v in ipairs(map) do
		assert(type(v[1]) == "function")
		local n = table_len(v)
		v.n = n
		for i = 2, n do
			v[i] = buildkey(v[i])
		end
		
		if n == 1 then
			local f = v[1]
			table.insert(set.root_watching, f)
		elseif n == 2 then
			local watching = set.watching
			local f = v[1]
			local k = v[2]
			local tq = type(watching[k])
			genkey(set.keys, k)
			if tq == "nil" then
				watching[k] = f
				watching.n = watching.n + 1
			elseif tq == "function" then
				local q = { watching[k], f }
				watching[k] = q
			else
				assert (tq == "table")
				table.insert(watching[k], f)
			end
		else
			table.insert(set.mapping, v)
			for i = 2, n do
				genkey(set.keys, v[i])
			end
		end
	end
	return set
end

local function do_funcs(doc, funcs, v)
	if v == NULL then
		v = nil
	end
	if type(funcs) == "function" then
		funcs(doc, v)
	else
		for _, func in ipairs(funcs) do
			func(doc, v)
		end
	end
end

local argv = setmetatable({}, {__mode = "v"})
local function do_mapping(doc, mapping, changes, keys)
	local NULL, argv = NULL, argv
	local n = mapping.n
	argv[1] = doc
	for i=2,n do
		local key = mapping[i]
		local v = changes[key]
		if v == nil then
			v = keys[key](doc)
		elseif v == NULL then
			v = nil
		end
		argv[i] = v
	end
	mapping[1](unpack(argv, 1, n))
end

function tracedoc.mapchange(doc, set, c)
	local changes = c or {}
	local changes_n = changes._n or 0
	if changes_n == 0 then
		return changes
	end
	local watching = set.watching
	if changes_n > watching.n then
		-- a lot of changes
		for key, funcs in pairs(watching) do
			local v = changes[key]
			if v ~= nil then
				do_funcs(doc, funcs, v)
			end
		end
	else
		-- a lot of watching funcs
		for key, v in pairs(changes) do
			local funcs = watching[key]
			if funcs then
				do_funcs(doc, funcs, v)
			end
		end
	end
	-- mapping
	local keys = set.keys
	for _, mapping in ipairs(set.mapping) do
		for i=2,table_len(mapping) do
			local key = mapping[i]
			if changes[key] ~= nil then
				do_mapping(doc, mapping, changes, keys)
				break
			end
		end
	end
	-- root watching
	do_funcs(doc, set.root_watching)
	return changes
end

function tracedoc.mapupdate(doc, set, ...)
	local argc, argv = select('#', ...), {doc, ...}
	local keys = set.keys
	for _, v in ipairs(set.map) do
		local n = v.n
		for i = 2, n do
			argv[argc + i] = keys[v[i]](doc)
		end
		v[1](unpack(argv, 1, argc + n))
	end
end

function tracedoc.check_type(doc)
	return getmetatable(doc) == tracedoc_type
end

return tracedoc
