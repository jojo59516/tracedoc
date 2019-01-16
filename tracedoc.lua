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

local function doc_next(doc, key)
	-- at first, iterate all the keys changed
	local change_keys = doc._keys
	if key == nil or change_keys[key] then
		while true do
			key = next(change_keys, key)
			if key == nil then
				break
			end
			local v = doc[key]
			if v ~= nil then
				return key, v
			end
		end
	end

	-- and then, iterate all the keys in lastversion except keys changed

	local lastversion = doc._lastversion

	while true do
		key = next(lastversion, key)
		if key == nil then
			return
		end
		if not change_keys[key] then
			local v = doc[key]
			if v ~= nil then
				return key, v
			end
		end
	end
end

local function doc_pairs(doc)
	return doc_next, doc
end

local function doc_ipairs(doc)
	local function iter(doc, var)
		var = var + 1
		local val = doc[var]
		if val ~= nil then
		   return var, val
		end
	end
	return iter, doc, 0
end

local function find_length_after(doc, idx)
	local v = doc[idx + 1]
	if v == nil then
		return idx
	end
	repeat
		idx = idx + 1
		v = doc[idx + 1]
	until v == nil
	tracedoc_len[doc] = idx
	return idx
end

local function find_length_before(doc, idx)
	if idx <= 1 then
		tracedoc_len[doc] = nil
		return 0
	end
	repeat
		idx = idx - 1
	until idx <=0 or doc[idx] ~= nil
	tracedoc_len[doc] = idx
	return idx
end

local function doc_len(doc)
	local len = tracedoc_len[doc]
	if len == nil then
		len = table_len(doc._lastversion)
		tracedoc_len[doc] = len
	end
	if len == 0 then
		return find_length_after(doc, 0)
	end
	local v = doc[len]
	if v == nil then
		return find_length_before(doc, len)
	end
	return find_length_after(doc, len)
end

local function doc_read(doc, k)
	if doc._keys[k] then
		return doc._changes[k]
	end
	-- if k is not changed, return lastversion
	return doc._lastversion[k]
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

local function doc_change_value(doc, k, v)
	mark_dirty(doc)
	doc._changes[k] = v
	doc._keys[k] = true
end

local function doc_change_recursively(doc, k, v)
	local lv = doc._lastversion[k]
	if getmetatable(lv) ~= tracedoc_type then
		-- last version is not a table, new a empty one
		lv = tracedoc.new()
		lv._parent = doc
		doc._lastversion[k] = lv
	elseif doc[k] == nil then
		-- this version is clear first, deepcopy lastversion one
		lv = tracedoc.new(lv)
		lv._parent = doc
		doc._lastversion[k] = lv
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
	-- don't cache sub table into doc._changes
	doc._changes[k] = nil
	doc._keys[k] = nil
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

local function doc_unpack(doc, start, len)
	if not tracedoc.check_type(doc) then return table.unpack(doc, start, len) end

	start = start or 1
	len = len or tracedoc.len(doc)
	local t = {}
	for i = start, len do
		t[i - start + 1] = doc[i]
	end
	return table.unpack(t, 1, len - start + 1)
end

local doc_mt = {
	__newindex = doc_change,
	__index = doc_read,
	__pairs = doc_pairs,
	__ipairs = doc_ipairs,
	__len = doc_len,
	__metatable = tracedoc_type,	-- avoid copy by ref
}

tracedoc.next = doc_next
tracedoc.pairs = doc_pairs
tracedoc.ipairs = doc_ipairs
tracedoc.len = doc_len
tracedoc.unpack = doc_unpack
tracedoc.insert = doc_insert
tracedoc.remove = doc_remove

function tracedoc.new(init)
	local doc = {
		_dirty = false,
		_parent = false,
		_changes = {},
		_force_changed = {},
		_keys = {},
		_lastversion = {},
	}
	setmetatable(doc, doc_mt)
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
	local last = {}
	for k,v in pairs(doc._lastversion) do
		table.insert(last, string.format("%s:%s",k,v))
	end
	local changes = {}
	for k,v in pairs(doc._changes) do
		table.insert(changes, string.format("%s:%s",k,v))
	end
	local keys = {}
	for k in pairs(doc._keys) do
		table.insert(keys, k)
	end
	return string.format("last [%s]\nchanges [%s]\nkeys [%s]",table.concat(last, " "), table.concat(changes," "), table.concat(keys," "))
end

local function _commit(is_keep_dirty, doc, result, prefix)
	if doc._ignore then
		return result
	end
	if not is_keep_dirty then
		doc._dirty = false
	end
	local lastversion = doc._lastversion
	local changes = doc._changes
	local force_changed = doc._force_changed
	local keys = doc._keys
	local dirty = false
	if next(keys) ~= nil then
		for k in next, keys do
			local v = changes[k]
			local is_force_change = force_changed[k]
			if not is_keep_dirty then
				keys[k] = nil
				changes[k] = nil
				force_changed[k] = nil
			end
			if lastversion[k] ~= v or is_force_change then
				dirty = true
				if result then
					local key = prefix and prefix .. k or tostring(k)
					result[key] = v == nil and NULL or v
					result._n = (result._n or 0) + 1
				end
				if not is_keep_dirty then
					lastversion[k] = v
				end
			end
		end
	end
	for k,v in pairs(lastversion) do
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
end

function tracedoc.opaque(doc, enable)
	rawset(doc, "_opaque", enable)
end

function tracedoc.mark_changed(doc, k)
	local v = doc[k]
	assert(not tracedoc.check_type(v), "do not mark a tracedoc as changed!")

	doc_change_value(doc, k, v)
	doc._force_changed[k] = true
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
