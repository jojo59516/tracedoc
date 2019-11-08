local next = next
local setmetatable = setmetatable
local getmetatable = getmetatable
local type = type
local rawset = rawset
local table = table
local compat = require("compat")
local pairs = compat.pairs
local ipairs = compat.ipairs
local table_len = compat.len
local load = compat.load

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

	if recursively then
		doc_change_recursively(doc, k, v)
	elseif doc[k] ~= v then
		doc_change_value(doc, k, v)
	end
end

-- refer to table.insert()
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

-- refer to table.remove()
local function doc_remove(doc, index)
	local len = tracedoc.len(doc)
	index = index or len

	local v = doc[index]
	doc[index] = nil -- trig a clone of doc._lastversion[index] in doc_change()

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

local function _commit(is_keep_dirty, doc, result, prefix)
	if doc._ignore then
		return result
	end
	if not is_keep_dirty then
		doc._dirty = false
	end
	local changed_keys = doc._changed_keys
	local changed_values = doc._changed_values
	local stage = doc._stage
	local dirty = false
	if next(changed_keys) ~= nil then
		dirty = true
		for k in next, changed_keys do
			local v, lv = stage[k], changed_values[k]
			if not is_keep_dirty then
				changed_keys[k] = nil
				changed_values[k] = nil
			end
			if result then
				local key = prefix and prefix .. k or tostring(k)
				result[key] = v == nil and NULL or v
				result._n = (result._n or 0) + 1
			end
		end
	end
	for k, v in pairs(stage) do
		if getmetatable(v) == tracedoc_type and v._dirty then
			if result then
				local key = prefix and prefix .. k or tostring(k)
				local change
				if v._opaque then
					change = _commit(is_keep_dirty, v)
				else
					local n = result._n
					_commit(is_keep_dirty, v, result, key .. ".")
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
				local change = _commit(is_keep_dirty, v)
				dirty = dirty or change
			end
		end
	end
	return result or dirty
end

function tracedoc.commit(doc, result, prefix)
	return _commit(false, doc, result, prefix)
end

function tracedoc.get_changes(doc, result, prefix)
	return _commit(true, doc, result, prefix)
end

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
	local v = doc[k]
	assert(not tracedoc.check_type(v), "do not mark a tracedoc as changed!")

	doc_change_value(doc, k, v, true)
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

local function insert_tag(tags, tag, item, n)
	local v = { table.unpack(item, n, table_len(item)) }
	local t = tags[tag]
	if not t then
		tags[tag] = { v }
	else
		table.insert(t, v)
	end
	return v
end

function tracedoc.changeset(map)
	local set = {
		watching_n = 0,
		watching = {},
		root_watching = {},
		mapping = {},
		keys = {},
		tags = {},
	}
	for _,v in ipairs(map) do
		for i, k in ipairs(v) do
			if type(k) == "string" then
				v[i] = buildkey(k)
			end
		end
		
		local tag = v[1]
		if type(tag) == "string" then
			v = insert_tag(set.tags, tag, v, 2)
		else
			v = insert_tag(set.tags, "", v, 1)
		end

		local n = table_len(v)
		assert(n >= 1 and type(v[1]) == "function")
		if n == 1 then
			local f = v[1]
			table.insert(set.root_watching, f)
		elseif n == 2 then
			local f = v[1]
			local k = v[2]
			local tq = type(set.watching[k])
			genkey(set.keys, k)
			if tq == "nil" then
				set.watching[k] = f
				set.watching_n = set.watching_n + 1
			elseif tq == "function" then
				local q = { set.watching[k], f }
				set.watching[k] = q
			else
				assert (tq == "table")
				table.insert(set.watching[k], f)
			end
		else
			table.insert(set.mapping, { table.unpack(v) })
			for i = 2, table_len(v) do
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

local function do_mapping(doc, mapping, changes, keys, args)
	local n = table_len(mapping)
	for i=2,n do
		local key = mapping[i]
		local v = changes[key]
		if v == nil then
			v = keys[key](doc)
		elseif v == NULL then
			v = nil
		end
		args[i-1] = v
	end
	mapping[1](doc, table.unpack(args,1,n-1))
end

local function _mapchange(doc, set, c, skip_commit)
	local changes = c or {}
	if not skip_commit then
		changes = tracedoc.commit(doc, changes)
	end
	local changes_n = changes._n or 0
	if changes_n == 0 then
		return changes
	end
	if changes_n > set.watching_n then
		-- a lot of changes
		for key, funcs in pairs(set.watching) do
			local v = changes[key]
			if v ~= nil then
				do_funcs(doc, funcs, v)
			end
		end
	else
		-- a lot of watching funcs
		local watching_func = set.watching
		for key, v in pairs(changes) do
			local funcs = watching_func[key]
			if funcs then
				do_funcs(doc, funcs, v)
			end
		end
	end
	-- mapping
	local keys = set.keys
	local tmp = {}
	for _, mapping in ipairs(set.mapping) do
		for i=2,table_len(mapping) do
			local key = mapping[i]
			if changes[key] ~= nil then
				do_mapping(doc, mapping, changes, keys, tmp)
				break
			end
		end
	end
	-- root watching
	do_funcs(doc, set.root_watching)
	return changes
end

function tracedoc.mapchange(doc, set, c)
	return _mapchange(doc, set, c)
end

function tracedoc.mapchange_without_commit(doc, set, changes)
	return _mapchange(doc, set, changes, true)
end

function tracedoc.mapupdate(doc, set, filter_tag)
	local args = {}
	local keys = set.keys
	for tag, items in pairs(set.tags) do
		if tag == filter_tag or filter_tag == nil then
			for _, mapping in ipairs(items) do
				local n = table_len(mapping)
				for i=2,n do
					local key = mapping[i]
					local v = keys[key](doc)
					args[i-1] = v
				end
				mapping[1](doc, table.unpack(args,1,n-1))
			end
		end
	end
end

function tracedoc.check_type(doc)
	if type(doc) ~= "table" then return false end
	local mt = getmetatable(doc)
	return mt == tracedoc_type
end

return tracedoc
