local function event()
    local callbacks = {}
    return {
        addAction = function(_, callback)
            table.insert(callbacks, callback)
            return callback
        end,
        trigger = function(_, ...)
            for _, callback in ipairs(callbacks) do
                callback(...)
            end
        end,
    }
end

function L(values)
    values = values or {}
    function values:it()
        local index = 0
        return function()
            index = index + 1
            return self[index]
        end
    end
    function values:map(transform)
        local result = L{}
        for _, value in ipairs(self) do table.insert(result, transform(value)) end
        return result
    end
    function values:filter(predicate)
        local result = L{}
        for _, value in ipairs(self) do
            if predicate(value) then table.insert(result, value) end
        end
        return result
    end
    function values:add(value)
        if not self:contains(value) then table.insert(self, value) end
    end
    function values:contains(value)
        for _, candidate in ipairs(self) do
            if candidate == value then return true end
        end
        return false
    end
    return setmetatable(values, { __add = function(left, right)
        local result = L{}
        for _, value in ipairs(left) do table.insert(result, value) end
        for _, value in ipairs(right) do table.insert(result, value) end
        return result
    end })
end

state = {}
function M(values)
    return { value = values[1], set_description = function() end }
end

local Gambiter = {
    on_add = function() end,
    get_action_identifier = function() return 'puller_action' end,
    is_gambit_satisfied = function() return true, 'target' end,
}
local original_require = require
local modules = {
    ['cylibs/trust/roles/gambiter'] = Gambiter,
    ['cylibs/gambits/gambit'] = { new = function() return {} end },
    ['cylibs/gambits/gambit_target'] = { TargetType = { Enemy = 'Enemy', Self = 'Self' } },
    ['cylibs/battle/approach'] = { new = function() return {} end },
    ['cylibs/battle/engage'] = { new = function() return {} end },
    ['cylibs/conditions/cooldown'] = { set_timestamp = function() end },
    ['cylibs/util/pull_target_util'] = { get_id = function(value) return value end },
    ['cylibs/battle/monsters/mob_filter'] = { new = function()
        return { set_center_position = function(self, position) self.position = position end }
    end },
    ['cylibs/actions/runtolocation'] = {
        new = function(x, y, z, distance)
            return { x = x, y = y, z = z, distance = distance }
        end,
    },
}
function require(name)
    if name == 'cylibs/trust/roles/puller' or name == 'cylibs/trust/roles/attacker'
            or name == 'commands/PullCommands' or name == 'cylibs/trust/trust' then
        return original_require(name)
    end
    return modules[name] or {}
end

local Puller = require('cylibs/trust/roles/puller')
local Attacker = require('cylibs/trust/roles/attacker')
local PullCommands = require('commands/PullCommands')
local Trust = require('cylibs/trust/trust')

local function fixture()
    state.AutoPullMode.value = 'Auto'
    state.AutoCampMode.value = 'Pull'
    state.PullActionMode.value = 'Auto'
    local ended = event()
    local mode_changed = event()
    local status_changed = event()
    state.AutoPullMode.on_state_change = function() return mode_changed end
    WindowerEvents = { MobKO = event() }
    windower = { send_command = function() end, ffxi = { run = function() end } }
    local player = {
        current_distance = 15,
        get_status = function() return 'Idle' end,
        get_target_index = function() return nil end,
        on_status_change = function() return status_changed end,
        distance = function(self) return self.current_distance end,
    }
    local party = {
        get_player = function() return player end,
        set_should_ignore_assist_target = function() end,
        set_assist_target = function() end,
        add_to_chat = function() end,
    }
    local queue = {
        actions = {},
        on_action_end = function() return ended end,
        has_action = function(self, identifier) return self.pending == identifier end,
        push_action = function(self, action) table.insert(self.actions, action) end,
    }
    local puller = setmetatable({
        action_queue = queue,
        dispose_bag = { add = function() end },
        mob_filter = {
            set_center_position = function(self, position) self.position = position end,
            get_center_position = function(self) return self.position end,
        },
        get_party = function() return party end,
        get_alliance = function() return { get_target_by_index = function() end } end,
        get_pull_target = function(self) return self.target end,
        set_pull_settings = function() end,
    }, Puller)
    puller:set_camp_position({ 10, 20, 0 })
    puller:on_add()
    return puller, player, queue, ended
end

local tests = {}
function tests.successful_pull_returns_with_target_and_keeps_camp()
    local puller, _, queue, ended = fixture()
    local camp = puller:get_camp_position()
    puller.target = {}
    ended:trigger({ getidentifier = function() return 'puller_action' end }, true)
    assert(#queue.actions == 1, 'successful pull must queue a return with a target retained')
    assert(queue.actions[1].x == 10 and queue.actions[1].y == 20, 'return must use saved camp')
    assert(puller:get_camp_position() == camp, 'pull must not overwrite camp')
    ended:trigger({ getidentifier = function() return 'puller_action' end }, true)
    assert(puller:get_camp_position() == camp, 'subsequent pulls must keep the same camp')
end

function tests.engagement_waits_for_camp_even_after_return_timeout()
    local puller, player, queue = fixture()
    local attacker = setmetatable({}, Attacker)
    attacker:set_puller(puller)
    assert(not attacker:is_gambit_satisfied({}), 'must not engage away from camp')
    queue.pending = nil
    assert(not attacker:is_gambit_satisfied({}), 'a missing or timed-out return must not allow engagement')
    player.current_distance = 1
    queue.pending = 'puller_action'
    assert(not attacker:is_gambit_satisfied({}), 'must wait for the pull action to finish even at camp')
    queue.pending = nil
    local success, target = attacker:is_gambit_satisfied({})
    assert(success and target == 'target', 'normal engagement must resume at camp')
end

function tests.failed_pulls_and_other_actions_do_not_start_return()
    local _, _, queue, ended = fixture()
    ended:trigger({ getidentifier = function() return 'puller_action' end }, false)
    ended:trigger({ getidentifier = function() return 'other_action' end }, true)
    assert(#queue.actions == 0, 'only a successful pull should start returning')
end

function tests.return_is_retried_without_repulling_until_arrival()
    local puller, player, queue, ended = fixture()
    puller.target = {}
    ended:trigger({ getidentifier = function() return 'puller_action' end }, true)
    assert(not puller:is_gambit_satisfied({}), 'must not pull again while returning')
    logger = { notice = function() end }
    puller.check_target = function() end
    puller:tic()
    assert(#queue.actions == 2, 'must retry an interrupted return on the next tick')
    player.current_distance = 1
    puller:tic()
    assert(not puller.returning_to_camp, 'arrival must finish the return phase')
    assert(puller:is_gambit_satisfied({}), 'normal pull checks must resume after arrival')
end

function tests.camp_survives_settings_refresh()
    local puller = fixture()
    local camp = puller:get_camp_position()
    local previous_filter = puller.mob_filter
    puller.get_default_conditions = function() return L{} end
    puller.set_gambit_settings = function() end
    GambitCondition = { new = function() return {} end }
    ModeCondition = { new = function() return {} end }
    MaxDistanceCondition = { new = function() return {} end }
    Puller.set_pull_settings(puller, { Distance = 25, Blacklist = L{}, Gambits = L{} })
    assert(puller.mob_filter ~= previous_filter, 'test must replace the filter')
    assert(puller:get_camp_position() == camp, 'settings refresh must retain saved camp')
    assert(puller.mob_filter.position == camp, 'new filter must use the saved camp')
end

function tests.role_changes_wire_and_unwire_the_engagement_guard()
    local trust = setmetatable({
        roles = L{}, role_blacklist = L{},
        on_trust_roles_changed = function() return event() end,
    }, Trust)
    local attacker = {
        get_type = function() return 'attacker' end,
        set_puller = Attacker.set_puller,
    }
    local puller = { get_type = function() return 'puller' end }
    trust:add_role(attacker)
    trust:add_role(puller)
    assert(attacker.puller == puller, 'adding the puller must connect it to the attacker')
    trust:remove_role(puller)
    assert(attacker.puller == nil, 'removing the puller must remove the engagement guard')
    trust:add_role(puller)
    assert(attacker.puller == puller, 'a replacement puller must be connected')
end

function tests.existing_modes_do_not_block_engagement_or_return_with_a_target()
    local puller, _, queue, ended = fixture()
    local attacker = setmetatable({}, Attacker)
    attacker:set_puller(puller)
    puller.target = {}
    state.AutoCampMode.value = 'Auto'
    assert(attacker:is_gambit_satisfied({}), 'existing camp mode must not defer engagement')
    ended:trigger({ getidentifier = function() return 'puller_action' end }, true)
    assert(#queue.actions == 0, 'existing camp mode must not return with a target')
    state.AutoCampMode.value = 'Pull'
    state.PullActionMode.value = 'Target'
    assert(attacker:is_gambit_satisfied({}), 'target pulling must be unchanged')
    state.PullActionMode.value = 'Approach'
    assert(attacker:is_gambit_satisfied({}), 'approach pulling must be unchanged')
    state.PullActionMode.value = 'Auto'
    state.AutoPullMode.value = 'Off'
    assert(attacker:is_gambit_satisfied({}), 'disabled pulling must not block engagement')
end

function tests.camp_command_selects_mode_and_saves_position_only_when_invoked()
    local puller = fixture()
    local commands = setmetatable({ get_puller = function() return puller end }, PullCommands)
    handle_set = function(name, value) state[name].value = value end
    V = function(value) return value end
    ffxi_util = { get_mob_position = function() return { 30, 40, 5 } end }
    windower.ffxi.get_player = function() return { name = 'Player' } end
    assert(commands:handle_camp(nil, 'pull'))
    assert(state.AutoCampMode.value == 'Pull', 'camp pull must enable Pull mode')
    assert(puller:get_camp_position()[1] == 30, 'explicit camp command must save current position')
    assert(commands:handle_camp(nil))
    assert(state.AutoCampMode.value == 'Auto', 'plain camp command must retain existing mode')
    assert(not commands:handle_camp(nil, 'invalid'), 'unknown camp modes must be rejected')
end

local failures = 0
for name, test in pairs(tests) do
    local success, message = pcall(test)
    if success then
        print('PASS '..name)
    else
        failures = failures + 1
        print('FAIL '..name..': '..tostring(message))
    end
end
assert(failures == 0, tostring(failures)..' pull-to-camp tests failed')