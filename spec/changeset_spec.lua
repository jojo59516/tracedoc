local tracedoc = require("tracedoc")

describe("changeset tests", function()
    local match = require("luassert.match")
    local plain_data = {
        [-1] = {
            name = "-1",
        },
        [1] = {
            name = "1"
        },
        array = {1, 2, 3},
        level = 10,
        name = "Player",
        title = "",
        hp = 100,
        hp_max = 100,
    }
    local doc = nil

    local print_buf = {}
    local function _print(...)
        -- print(...)
        table.insert(print_buf, table.concat({...}, "\t"))
    end

    local function get_print_content()
        return table.concat(print_buf, "\n")
    end

    local function clear_print_buf()
        print_buf = {}
    end

    local function trim_lines(str)
        return str:gsub("^%s+", ""):gsub("\n%s+", "\n")
    end

    local spies = {}
    local function create_spy(name, func)
        local s = spy.new(func)
        spies[name] = s
        return function(...)
            return s(...)
        end
    end

    local function clear_spies()
        spies = {}
    end

    local function reset_spies()
        for k, v in pairs(spies) do
            v:clear()
        end
    end

    before_each(function()
        doc = tracedoc.new(plain_data) 
        clear_print_buf()
        clear_spies()
    end)

    after_each(function()
        doc = nil
    end)

    test("test mapchange/mapupdate", function()
        local mapping = tracedoc.changeset {
            {
                create_spy("level", function(doc, level)
                    _print("level = " .. level)
                end),
                "level",
            },
            {
                create_spy("hp", function(doc, hp)
                    _print("hp = " .. hp)
                end),
                "hp",
            },
            {
                create_spy("hp_max", function(doc, hp_max, buff)
                    local hp_max_modify = buff and buff.hp_max_modify or 0
                    hp_max_modify = hp_max_modify or 0
                    _print("hp_max = " .. hp_max + hp_max_modify)
                end),
                "hp_max",
                "buff",
            },
            {
                create_spy("item", function(doc, items)
                    _print("items count = " .. tracedoc.len(items))
                end),
                "items",
            },
            {
                create_spy("name", function(doc, name, title)
                    local full_name = name
                    if title and #title > 0 then
                        full_name = full_name .. " - " .. title
                    end
                    _print("name = " .. full_name)
                end),
                "name",
                "title",
            },
            {
                create_spy("no_tag", function(doc, hp)
                end),
                "hp",
            },
            {
                create_spy(-1, function (doc, name)
                    _print("name = " .. name)
                end),
                "[-1].name",
            }, 
            {
                create_spy(1, function (doc, name)
                    _print("name = " .. name)
                end),
                "[1].name",
            }, 
            {
                create_spy("array", function (doc, array)
                    local str = {}
                    for i, v in tracedoc.ipairs(array) do
                        str[#str + 1] = tostring(v)
                    end
                    str = table.concat(str, ", ")
                    _print("array = " .. str)
                end),
                "array",
            }, 
            {
                create_spy("numbers", function(doc, name1, name_1)
                    _print("doc[1].name = "..name1..", doc[-1].name = "..name_1)
                end),
                "[1].name",
                "[-1].name",
            },
        }

        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.level).was_called_with(doc, plain_data.level)
        assert.spy(spies.hp).was_called_with(doc, plain_data.hp)
        assert.spy(spies.hp_max).was_called_with(doc, plain_data.hp_max, nil)
        assert.spy(spies.name).was_called_with(doc, plain_data.name, plain_data.title)
        assert.spy(spies[-1]).was_called_with(doc, plain_data[-1].name)
        assert.spy(spies[1]).was_called_with(doc, plain_data[1].name)
        assert.spy(spies.numbers).was_called_with(doc, plain_data[1].name, plain_data[-1].name)

        clear_print_buf()
        reset_spies()

        doc.array[4] = 4
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.array).was.called()
        assert.are.same(trim_lines([[array = 1, 2, 3, 4]]), get_print_content())
        clear_print_buf()
        reset_spies()

        doc.hp = doc.hp + 10
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.hp).was_called_with(doc, plain_data.hp + 10)
        assert.are.same(get_print_content(), trim_lines(
            [[hp = 110]]))
        clear_print_buf()
        reset_spies()

        doc.title = "Super Man"
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.name).was_called_with(doc, plain_data.name, "Super Man")
        assert.are.same(get_print_content(), trim_lines(
            [[name = Player - Super Man]]))
        clear_print_buf() 
        reset_spies()

        doc.items = {1, 2, 3}
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.item).was_called()
        assert.are.same(get_print_content(), trim_lines(
            [[items count = 3]]))
        clear_print_buf()
        reset_spies()

        doc.buff = { hp_max_modify = 100}
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.hp_max).was_called()
        assert.are.same(get_print_content(), trim_lines(
            [[hp_max = 200]]))
        clear_print_buf()
        reset_spies()

        -- filter all tag
        tracedoc.mapupdate(doc, mapping)
        assert.spy(spies.level).was_called()
        assert.spy(spies.hp).was_called()
        assert.spy(spies.item).was_called()
        assert.spy(spies.name).was_called()
    end)
    
    test("support for reading a non-exist field", function()
        local mapping = tracedoc.changeset {
            {
                create_spy("hp_max", function(doc, hp_max, hp_max_modify)
                    hp_max_modify = hp_max_modify or 0
                    _print("hp_max = " .. hp_max + hp_max_modify)
                end),
                "hp_max",
                "buff.hp_max_modify",   -- not exist yet
            },
        }

        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.hp_max).was_called()
        assert.are.same(get_print_content(), trim_lines(
            [[hp_max = 100]]))
        clear_print_buf()
        reset_spies()

        doc.buff = { hp_max_modify = 100 }  -- buff.hp_max_modify added
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies.hp_max).was_called()
        assert.are.same(get_print_content(), trim_lines(
            [[hp_max = 200]]))
        clear_print_buf()
        reset_spies()
    end)

    test("for issue #4", function()
        local doc = tracedoc.new {d = true, e = 1}
        tracedoc.commit(doc)
        local mapping = tracedoc.changeset {
            { create_spy("issue#4", function(doc, d, e) _print("changed") end), "d", "e" }
        }
        doc.d = false
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies["issue#4"]).was_called()
    end)

    test("mapchange should trigger the handler when assign a field to false", function()
        doc.is_dead = false

        local mapping = tracedoc.changeset {
            { create_spy("assign_false", function(doc, d, e) _print("changed") end), "is_dead" }
        }
        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies["assign_false"]).was_called()
    end)

    test("support for mapchange on root tracedoc", function()
        local mapping = tracedoc.changeset {
            {
                create_spy("root1", function(root)
                    assert.are.equals(root, doc)
                end),
            },
            {
                create_spy("root2", function(root)
                    assert.are.equals(root, doc)
                end),
            },
            {
                create_spy("root3", function(root)
                    assert.are.equals(root, doc)
                end),
            },
        }

        tracedoc.mapchange(doc, mapping, tracedoc.commit(doc, {}))
        assert.spy(spies["root1"]).was_called()
        assert.spy(spies["root2"]).was_called()
        assert.spy(spies["root3"]).was_called()
        reset_spies()

        tracedoc.mapupdate(doc, mapping)
        assert.spy(spies["root1"]).was_called()
        assert.spy(spies["root2"]).was_called()
        assert.spy(spies["root3"]).was_called()
    end)

    test("mapupdate support for non-tracedoc table", function()
        local mapping = tracedoc.changeset {
            {
                create_spy("level", function(doc, level)
                end),
                "level",
            },
            {
                create_spy("hp", function(doc, hp)
                end),
                "hp",
            },
            {
                create_spy("pet", function(doc, name)
                    _print("name = " .. tostring(name))
                end),
                "pet.name",
            },
        }

        local data = {
            level = 100,
            hp = 500,
            pet = {
                name = "dog",
            }
        }

        -- test for plain table
        tracedoc.mapupdate(data, mapping)
        assert.spy(spies["level"]).was_called()
        assert.spy(spies["hp"]).was_called()
        assert.spy(spies["pet"]).was_called()
        assert.are.same(get_print_content(), trim_lines(
            [[name = dog]]))
        reset_spies()
        clear_print_buf()

        -- test for empty table
        tracedoc.mapupdate({}, mapping)
        assert.spy(spies["level"]).was_called()
        assert.spy(spies["hp"]).was_called()
        assert.spy(spies["pet"]).was_called()
        assert.are.same(get_print_content(), trim_lines(
            [[name = nil]]))
        reset_spies()
        clear_print_buf()

        -- test for nil
        tracedoc.mapupdate(nil, mapping)
        assert.spy(spies["level"]).was_called()
        assert.spy(spies["hp"]).was_called()
        assert.spy(spies["pet"]).was_called()
        assert.are.same(get_print_content(), trim_lines(
            [[name = nil]]))
        reset_spies()
        clear_print_buf()
    end)
end)
