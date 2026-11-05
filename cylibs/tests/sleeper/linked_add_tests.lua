local list_methods = {}
function list_methods:it()
    local index = 0
    return function() index = index + 1; return self[index] end
end
function list_methods:append(value) table.insert(self, value) end
function list_methods:length() return #self end
function list_methods:filter(predicate)
    local result = L{}
    for _, value in ipairs(self) do
        if predicate(value) then result:append(value) end
    end
    return result
end
function L(values) return setmetatable(values or {}, { __index = list_methods }) end
function M(values) return { value = values[1], set_description = function() end } end
state = {}
Role = { new = function(queue) return { action_queue = queue } end }

local mobs, castable, known
local function check(condition, mob)
    if condition.kind == 'not' then return not check(condition.conditions[1], mob) end
    if condition.conditions then
        for _, child in ipairs(condition.conditions) do
            local satisfied = check(child, mob)
            if condition.operator == 'Or' and satisfied then return true end
            if condition.operator == 'And' and not satisfied then return false end
        end
        return condition.operator == 'And'
    end
    if condition.kind == 'claimed' then return mob.claimed == true end
    if condition.kind == 'unclaimed' then return not mob.claimed and not mob.other_claimed end
    if condition.kind == 'aggroed' then return mob.aggroed == true end
    if condition.kind == 'sleep' then return mob.sleeping == true end
    error('Unexpected condition')
end
Condition = { LogicalOperator = { Or = 'Or', And = 'And' } }
Condition.check_conditions = function(conditions, index)
    for _, condition in ipairs(conditions) do
        if not check(condition, mobs[index]) then return false end
    end
    return true
end
NotCondition = { new = function(conditions) return { kind = 'not', conditions = conditions } end }
HasDebuffCondition = { new = function() return { kind = 'sleep' } end }
local filters = {
    Aggroed = L{ { kind = 'aggroed' } },
    Unclaimed = L{ { kind = 'unclaimed' } },
}
local modules = {
    ['cylibs/events/dispose_bag'] = { new = function() return {} end },
    ['cylibs/battle/monsters/mob_filter'] = { Type = filters },
    ['cylibs/conditions/conditional'] = { new = function(conditions, operator)
        return { conditions = conditions, operator = operator }
    end },
    ['cylibs/conditions/party_claimed'] = { new = function() return { kind = 'claimed' } end },
    ['cylibs/conditions/unclaimed'] = { new = function() return { kind = 'unclaimed' } end },
    ['cylibs/util/monster_util'] = { immune_to_debuff = function(name) return name == 'Immune' end },
    ['cylibs/util/spell_util'] = {
        knows_spell = function(id) return known[id] end,
        can_cast_spell = function(id) return castable[id] end,
    },
}
for name, module in pairs(modules) do package.loaded[name] = module end
local Sleeper = require('cylibs/trust/roles/sleeper')
SpellAction = { new = function(_, _, _, id, target_index)
    return { spell_id = id, target_index = target_index }
end }
WaitAction = { new = function() return {} end }
SequenceAction = { new = function(actions, identifier) return { actions = actions, identifier = identifier } end }
ActionPriority = { highest = 100 }
windower = { ffxi = { get_player = function() return { index = 99 } end } }

local function fixture(min_mobs, adds_only)
    mobs = {
        [1] = { id = 1, index = 1, name = 'Fight', hpp = 100, aggroed = true, claimed = true },
        [2] = { id = 2, index = 2, name = 'Add', hpp = 100, aggroed = true },
    }
    castable, known = { [10] = true, [11] = true }, { [10] = true, [11] = true }
    local spells = L{}
    for _, definition in ipairs({ { 10, 'Horde Lullaby II' }, { 11, 'Horde Lullaby' } }) do
        local id, name = definition[1], definition[2]
        spells:append({ get_spell = function() return { id = id, en = name } end,
            get_conditions = function() return L{} end })
    end
    local queue = { actions = {}, push_action = function(self, action) table.insert(self.actions, action) end }
    local sleeper = Sleeper.new(queue, spells, min_mobs or 1, adds_only ~= false)
    local player = { is_moving = function() return false end }
    sleeper.get_player = function() return player end
    sleeper.get_target = function() return { get_id = function() return 1 end } end
    sleeper.get_alliance = function() return { get_target_by_index = function(_, index) return mobs[index] end } end
    sleeper.get_party = function() return { get_player = function() return player end, add_to_chat = function() end } end
    sleeper.mob_filter = { get_nearby_mobs = function(_, conditions)
        local result = L{}
        for _, mob in ipairs(mobs) do
            local satisfied = mob.hpp > 0 and not mob.other_claimed
            for _, condition in ipairs(conditions) do
                if condition.kind or condition.conditions then
                    satisfied = satisfied and check(condition, mob)
                else
                    for _, child in ipairs(condition) do satisfied = satisfied and check(child, mob) end
                end
            end
            if satisfied then result:append(mob) end
        end
        return result
    end }
    state.AutoSleepMode.value = 'Auto'
    sleeper.last_sleep_time = os.time() - 3
    return sleeper, queue
end

local tests = {}
function tests.single_unclaimed_link_uses_horde_lullaby_ii()
    local sleeper, queue = fixture()
    sleeper:tic()
    assert(#queue.actions == 1 and queue.actions[1].actions[1].spell_id == 10, 'one linked add must trigger Horde Lullaby II')
    assert(queue.actions[1].actions[1].target_index == 2, 'sleep must target the add, not the current fight')
end
function tests.party_claimed_link_is_slept()
    local sleeper, queue = fixture()
    mobs[2].claimed = true
    sleeper:tic()
    assert(#queue.actions == 1 and queue.actions[1].actions[1].target_index == 2, 'party-claimed add must be eligible')
end
function tests.main_target_and_ineligible_mobs_are_not_slept()
    for _, flag in ipairs({ 'sleeping', 'other_claimed', 'dead', 'immune', 'not_aggroed' }) do
        local sleeper, queue = fixture()
        mobs[1].claimed = false
        if flag == 'dead' then mobs[2].hpp = 0
        elseif flag == 'immune' then mobs[2].name = 'Immune'
        elseif flag == 'not_aggroed' then mobs[2].aggroed = false
        else mobs[2][flag] = true end
        sleeper:tic()
        assert(#queue.actions == 0, flag..' add must not trigger sleep on itself or the main target')
    end
end
function tests.unavailable_horde_ii_falls_back_to_horde_i()
    local sleeper, queue = fixture()
    castable[10] = false
    sleeper:tic()
    assert(#queue.actions == 1 and queue.actions[1].actions[1].spell_id == 11, 'unavailable Horde II must fall back to Horde I')
end
function tests.no_castable_spells_do_not_queue_actions()
    local sleeper, queue = fixture()
    castable[10], castable[11] = false, false
    sleeper:tic()
    assert(#queue.actions == 0, 'no ready sleep spell must not queue actions')
end
function tests.unlearned_horde_ii_uses_known_horde_i()
    local sleeper, queue = fixture()
    known[10] = false
    sleeper:set_sleep_spells(sleeper.sleep_spells)
    sleeper:tic()
    assert(#queue.actions == 1 and queue.actions[1].actions[1].spell_id == 11, 'unlearned Horde II must not prevent using known Horde I')
end
function tests.off_mode_movement_and_cooldown_are_respected()
    for _, reason in ipairs({ 'off', 'moving', 'cooldown' }) do
        local sleeper, queue = fixture()
        if reason == 'off' then state.AutoSleepMode.value = 'Off'
        elseif reason == 'moving' then sleeper.get_player = function() return { is_moving = function() return true end } end
        else sleeper.last_sleep_time = os.time() end
        sleeper:tic()
        assert(#queue.actions == 0, reason..' must prevent sleeping')
    end
end
function tests.black_mage_group_threshold_is_unchanged()
    local sleeper, queue = fixture(4, false)
    sleeper:tic()
    assert(#queue.actions == 0, 'a single add must not bypass the black mage group threshold')
end

local failures = 0
for name, test in pairs(tests) do
    local success, message = pcall(test)
    print((success and 'PASS ' or 'FAIL ')..name..(success and '' or ': '..tostring(message)))
    if not success then failures = failures + 1 end
end
assert(failures == 0, tostring(failures)..' linked-add tests failed')