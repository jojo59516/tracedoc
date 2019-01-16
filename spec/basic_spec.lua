local tracedoc = require("tracedoc")

if jit and type(jit.off) == "function" then
    jit.off()
end

describe("basic tests", function()
    local plain_data = {
        hp = 50,
        hp_max = 100,
        level = 10,
        skills = {
            123,
            456,
            789,
        },
        pet = {
            name = "dog",
            level = 10,
            hp = 100,
        },
        dead = false, 
    }
    local doc = nil

    before_each(function()
        doc = tracedoc.new(plain_data) 
    end)

    after_each(function()
        doc = nil
    end)

    it("should call commit after initialize to get initial state", function()
        local changes = tracedoc.commit(doc, {})
        assert.are_not.same(changes, {})
    end)

    it("should support pairs", function()
        local function dump(doc)
            local data = {}
            for k, v in tracedoc.pairs(doc) do
                if type(v) == "table" then
                    data[k] = dump(v)
                else
                    data[k] = v
                end
            end
            return data
        end

        -- before commit
        local dump_data = dump(doc)
        assert.are.same(dump_data, plain_data)

        -- private data should not be accessed by pairs
        assert.is_nil(dump_data._parent)
        assert.is_nil(dump_data._dirty)
        assert.is_nil(dump_data._changes)

        -- after commit
        tracedoc.commit(doc)
        assert.are.same(dump(doc), plain_data)
    end)

    it("should support ipairs", function()
        local function dump(doc)
            local data = {}
            for i, v in tracedoc.ipairs(doc) do
                if type(v) == "table" then
                    table.insert(data, dump(v))
                else
                    table.insert(data, v)
                end
            end
            return data
        end

        -- before commit
        local dump_data = dump(doc.skills)
        assert.are.equal(tracedoc.len(doc.skills), #dump_data, #plain_data.skills)
        assert.are.same(dump_data, plain_data.skills)

        -- after commit
        tracedoc.commit(doc)
        assert.are.equal(tracedoc.len(doc.skills), #dump_data, #plain_data.skills)
        assert.are.same(dump(doc.skills), plain_data.skills)
    end)

    test("field changes", function()
        tracedoc.commit(doc)

        doc.hp = doc.hp + 20
        doc.level = 11

        local changes = tracedoc.commit(doc, {})
        assert.are.same(changes, {
            _n = 2,
            hp = 70,
            level = 11,
        })

        -- test for no change
        changes = tracedoc.commit(doc, {})
        assert.are.same(changes, {})
    end)

    test("field add/remove", function()
        tracedoc.commit(doc)
        doc.mp = 90
        doc.mp_max = 100
        doc.buff = 123

        local changes = tracedoc.commit(doc, {})
        assert.are.same(changes, {
            _n = 3,
            mp = 90,
            mp_max = 100,
            buff = 123,
        })

        doc.buff = nil
        changes = tracedoc.commit(doc, {})
        assert.are.equal(changes.buff, tracedoc.null)
    end)

    test("no change", function()
        tracedoc.commit(doc)

        local changes = tracedoc.commit(doc, {})
        assert.are.same(changes, {})
    end)

    test("table changes", function()
        tracedoc.commit(doc)

        local skills = {1, 2}
        local pet = {
            name = "cat",
            level = 11,
            hp = 100,
        }
        doc.pet = pet
        doc.skills = skills

        -- table will be copied when assigning to a tracedoc
        -- so the table get from the tracedoc will be different from originals
        assert.are_not.equal(doc.pet, pet)
        assert.are_not.equal(doc.skills, skills)

        local changes = tracedoc.commit(doc, {})

        assert.are.equal(changes["skills.1"], 1)
        assert.are.equal(changes["skills.2"], 2)
        assert.are.equal(changes["skills.3"], tracedoc.null)
        assert.are.equal(changes["pet.name"], changes.pet.name, "cat")
        assert.are.equal(changes["pet.level"], changes.pet.level, 11)
        assert.is_nil(changes["pet.hp"])    -- pet.hp not changed
        
        assert.are.equal(tracedoc.len(changes.skills), 2)
        for i, v in tracedoc.ipairs(changes.skills) do
            assert.are.equal(changes["skills." .. i], v)
        end

        assert.are.equal(tracedoc.len(changes.pet), 0)
    end)

    test("support get_changes() which get changes with keeping a doc dirty", function()
        tracedoc.commit(doc)

        doc.hp = doc.hp + 20
        doc.level = 11

        local changes1 = tracedoc.get_changes(doc, {})
        local changes2 = tracedoc.get_changes(doc, {})
        assert.are.same(changes1, changes2)

        local changes3 = tracedoc.commit(doc, {})
        assert.are.same(changes3, changes2)

        local changes4 = tracedoc.get_changes(doc, {})
        assert.are.same(changes4, {})
        assert.are_not.same(changes4, changes1)
    end)

    test("opaque table", function()
        tracedoc.opaque(doc.pet, true)
        local changes = tracedoc.commit(doc, {})

        -- pet is opaque, no details
        assert.are.equal(changes["pet"], doc.pet)
        assert.are.equal(changes["pet"].name, "dog")
        assert.is_nil(changes["pet.hp"])
        assert.is_nil(changes["pet.name"])
        assert.is_nil(changes["pet.level"])

        doc.pet = {
            name = "cat",
            level = 11,
            hp = 100,
        }
        changes = tracedoc.commit(doc, {})

        assert.are.equal(changes["pet"], doc.pet)
        assert.are.equal(changes["pet"].name, "cat")
    end)

    test("_dirty state", function()
        assert.is_truthy(doc._dirty)

        -- not dirty after commit
        tracedoc.commit(doc)
        assert.is_falsy(doc._dirty)

        -- assigning a same value does not makes doc dirty
        doc.level = 10
        assert.is_falsy(doc._dirty)

        doc.hp = 100
        assert.is_truthy(doc._dirty)
        doc.level = 11
        assert.is_truthy(doc._dirty)

        tracedoc.commit(doc)
        assert.is_falsy(doc._dirty)
    end)

    test("sub tracedoc", function()
        tracedoc.commit(doc)

        doc.sub_doc = {
            name = "test"
        }

        local sub_changes = tracedoc.commit(doc.sub_doc, {})
        assert.are.equal(sub_changes.name, "test")

        -- sub doc changes has been commited. so parent doc changes nothing.
        local changes = tracedoc.commit(doc, {})
        assert.are.same(changes, {})
    end)

    test("table with metadata", function()
        tracedoc.commit(doc)

        local t = {}
        setmetatable(t, {})
        doc.table_with_meta = t

        -- table with metadata kept unchanged after assigned to tracedoc
        local changes = tracedoc.commit(doc, {})
        assert.are.equal(changes.table_with_meta, t)

        -- change inside this table won't be notified
        t.name = "test"
        changes = tracedoc.commit(doc, {})
        assert.are.same(changes, {})

        -- force mark as changed
        tracedoc.mark_changed(doc, "table_with_meta")
        changes = tracedoc.commit(doc, {})
        assert.are.equal(changes.table_with_meta, t)
    end)

    test("assign a tracedoc into a tracedoc", function()
        tracedoc.commit(doc)

        local list = {}
        for i = 1, 5 do
            list[i] = { id = i, name = "name" .. i }
        end
        doc.list = list

        local changes = tracedoc.commit(doc, {})

        doc.list2 = {}
        doc.list2[1] = doc.list[1]  -- doc.list[1] is tracedoc type
        doc.list2[2] = doc.list[3]  -- doc.list[3] is tracedoc type
        changes = tracedoc.commit(doc, {})
        assert.are.equal(changes["list2.1.id"], list[1].id)
        assert.are.equal(changes["list2.1.name"], list[1].name)
        assert.are.equal(changes["list2.2.id"], list[3].id)
        assert.are.equal(changes["list2.2.name"], list[3].name)

        doc.list2[1] = doc.list[2]  -- doc.list[2] is tracedoc type
        doc.list2[2] = doc.list[4]  -- doc.list[4] is tracedoc type
        changes = tracedoc.commit(doc, {})
        assert.are.equal(changes["list2.1.id"], list[2].id)
        assert.are.equal(changes["list2.1.name"], list[2].name)
        assert.are.equal(changes["list2.2.id"], list[4].id)
        assert.are.equal(changes["list2.2.name"], list[4].name)
    end)

    test("support tracedoc.check_type()", function()
        assert.is_truthy(tracedoc.check_type(doc))
        assert.is_truthy(tracedoc.check_type(doc.skills))
        assert.is_truthy(tracedoc.check_type(doc.pet))
        assert.is_falsy(tracedoc.check_type({}))
        assert.is_falsy(tracedoc.check_type(assert))
        assert.is_falsy(tracedoc.check_type(1))
        assert.is_falsy(tracedoc.check_type("test"))
        assert.is_falsy(tracedoc.check_type(nil))
    end)

    test("support tracedoc.unpack()", function()
        tracedoc.commit(doc)

        local function concat(t, start, len)
            local unpack = table.unpack
            if tracedoc.check_type(t) then
                unpack = tracedoc.unpack
            end
            return table.concat({unpack(t, start, len)}, ", ")
        end

        local list = {}
        for i = 1, 5 do
            list[i] = tostring(i)
        end
        doc.list = list

        assert.are.equal(concat(list, 1, 5), concat(doc.list, 1, 5))
        assert.are.equal(concat(list, 2, 4), concat(doc.list, 2, 4))
    end)

    test("support for tracedoc.insert() and tracedoc.remove()", function ()
        local function dump(doc)
            local data = {}
            for i, v in tracedoc.ipairs(doc) do                
                if tracedoc.check_type(v) then
                    data[i] = dump(v)
                else
                    data[i] = v
                end
            end
            return data
        end
        
        local plain_data = {{1}, {2}, {3}, {4}, {5}}
        local doc = tracedoc.new(plain_data)
        tracedoc.commit(doc)
        assert.are.same(plain_data, dump(doc))

        -- push back
        table.insert(plain_data, {6})
        tracedoc.insert(doc, {6})
        assert.is_truthy(doc._dirty)
        assert.are.same(plain_data, dump(doc))
        tracedoc.commit(doc)

        -- insert
        table.insert(plain_data, 3, {7})
        tracedoc.insert(doc, 3, {7})
        assert.is_truthy(doc._dirty)
        assert.are.same(plain_data, dump(doc))
        tracedoc.commit(doc)

        -- pop back
        local pv = table.remove(plain_data)
        local dv = tracedoc.remove(doc)
        assert.are.same(pv, dump(dv))
        assert.is_truthy(doc._dirty)
        assert.are.same(plain_data, dump(doc))
        tracedoc.commit(doc)

        -- remove
        pv = table.remove(plain_data, 3)
        dv = tracedoc.remove(doc, 3)
        assert.are.same(pv, dump(dv))
        assert.is_truthy(doc._dirty)
        assert.are.same(plain_data, dump(doc))
        tracedoc.commit(doc)
    end)
end)