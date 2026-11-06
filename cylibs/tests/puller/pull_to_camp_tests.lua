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
    function values:length() return #self end
    function values:indexOf(value)
        for index, candidate in ipairs(self) do
            if candidate == value then return index end
        end
        return -1
    end
    function values:random() return self[#self] end
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
    is_enabled = function() return true end,
    get_priority = function() return 0 end,
    get_action_identifier = function() return 'puller_action' end,
    is_gambit_satisfied = function() return true, 'target' end,
}
local original_require = require
local modules = {
    ['cylibs/trust/roles/gambiter'] = Gambiter,
    ['cylibs/conditions/party_claimed'] = { new = function() return { kind = 'claimed' } end },
    ['cylibs/conditions/target_names'] = { new = function(names) return { kind = 'names', names = names } end },
    ['cylibs/conditions/conditional'] = { new = function(conditions, operator)
        return { conditions = conditions, operator = operator }
    end },
    ['cylibs/gambits/gambit'] = { new = function() return {} end },
    ['cylibs/gambits/gambit_target'] = { TargetType = { Enemy = 'Enemy', Self = 'Self' } },
    ['cylibs/battle/approach'] = { new = function() return {} end },
    ['cylibs/battle/engage'] = { new = function() return {} end },
    ['cylibs/conditions/cooldown'] = { set_timestamp = function() end },
    ['cylibs/util/pull_target_util'] = { get_id = function(value) return value end },
    ['cylibs/battle/monsters/mob_filter'] = { Type = { PartyClaimed = 'claimed', Unclaimed = 'unclaimed' }, new = function()
        return { set_center_position = function(self, position) self.position = position end }
    end },
    ['cylibs/actions/runtolocation'] = {
        new = function(x, y, z, distance)
            return { x = x, y = y, z = z, distance = distance }
        end,
    },
    ['cylibs/actions/runto'] = { new = function(target_index, distance)
        return { target_index = target_index, distance = distance }
    end },
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
function tests.targets_follow_name_priority_then_distance_without_random_selection()
    local puller = fixture()
    puller.check_delay = function() return true end
    puller.is_valid_target = function() return true end
    puller.target_names = L{ 'Bat', 'Crab' }
    puller.target_ids = L{}
    puller.max_num_targets = 6
    local fresh = L{
        { id = 1, name = 'Crab', distance = 4 },
        { id = 3, name = 'Bat', distance = 100 },
        { id = 2, name = 'Bat', distance = 25 },
    }
    puller.mob_filter = {
        get_aggroed_mobs = function() return L{} end,
        get_nearby_mobs = function() return fresh end,
    }
    Monster = { new = function(id) return { id = id } end }
    local target = puller:get_next_target()
    assert(target.id == 2, 'must choose closest Bat before a closer lower-priority Crab, ignoring randomization')
    state.PullActionMode.value = 'Target'
    assert(puller:get_next_target().id == 2, 'Target mode must use the same deterministic ordering')
end

function tests.claimed_aggroed_targets_still_precede_fresh_pulls()
    local puller = fixture()
    puller.check_delay = function() return true end
    puller.is_valid_target = function() return true end
    puller.target_names = L{ 'Bat', 'Crab' }
    puller.target_ids = L{}
    local claimed = { id = 1, name = 'Crab', distance = 1600 }
    puller.mob_filter = {
        get_aggroed_mobs = function(_, filters)
            return filters[1] == 'claimed' and L{ claimed } or L{}
        end,
        get_nearby_mobs = function() return L{ { id = 2, name = 'Bat', distance = 4 } } end,
    }
    Monster = { new = function(id) return { id = id } end }
    assert(puller:get_next_target().id == 1, 'claimed aggro must precede even a closer preferred-name fresh pull')
end

local function distant_pull_fixture(distance)
    local puller, player, queue, ended = fixture()
    local mob = { id = 1, index = 1, distance = distance * distance }
    puller.target = { get_mob = function() return mob end }
    puller.check_delay = function() return true end
    puller.is_valid_target = function() return true end
    puller.pull_abilities = { Auto = L{ {
        isEnabled = function() return true end,
        getAbility = function() return { get_range = function() return 20 end } end,
    } } }
    player.current_distance = 1
    UnclaimedCondition = { new = function() return {} end }
    Condition = { check_conditions = function() return true end }
    return puller, player, queue, ended, mob
end

function tests.distant_auto_pull_moves_into_attack_range_without_engaging_or_returning()
    local puller, _, queue, ended = distant_pull_fixture(24)
    local camp = puller:get_camp_position()
    assert(puller:approach_pull_target(), 'an auto-pull target at 24 yalms must trigger movement into 20-yalm attack range')
    assert(#queue.actions == 1 and queue.actions[1].target_index == 1, 'movement must target the selected mob')
    assert(queue.actions[1].distance < 20, 'movement must stop just inside pull ability range')
    assert(queue.actions[1].identifier == 'Approach pull target', 'approaching must be distinct from the actual pull action')
    ended:trigger({ getidentifier = function() return 'Approach pull target' end }, true)
    assert(not puller.returning_to_camp, 'movement completion must not trigger return before the pull action fires')
    assert(puller:get_camp_position() == camp, 'approaching must not reset camp')
end

function tests.auto_pull_movement_respects_range_modes_and_pending_actions()
    local puller, player, queue, _, mob = distant_pull_fixture(19)
    assert(not puller:approach_pull_target(), 'must pull directly when already in range')
    mob.distance = 24 * 24
    state.PullActionMode.value = 'Target'
    assert(not puller:approach_pull_target(), 'Target mode must remain unchanged')
    state.PullActionMode.value = 'Auto'
    player.get_status = function() return 'Engaged' end
    assert(not puller:approach_pull_target(), 'must not abandon an existing fight')
    player.get_status = function() return 'Idle' end
    puller.returning_to_camp = true
    assert(not puller:approach_pull_target(), 'must not approach while returning to camp')
    puller.returning_to_camp = false
    queue.pending = 'Approach pull target'
    assert(puller:approach_pull_target() and #queue.actions == 0, 'must not queue duplicate movement')
    queue.pending = 'puller_action'
    assert(not puller:approach_pull_target(), 'must not approach during an actual pull')
end

function tests.auto_pull_does_not_run_into_short_range_abilities()
    local puller, _, queue = distant_pull_fixture(24)
    puller.pull_abilities.Auto[1].getAbility = function()
        return { get_range = function() return 3 end }
    end
    assert(not puller:approach_pull_target(), 'camp pull must not close to melee range for a short-range ability')
    assert(#queue.actions == 0, 'short-range pull actions must not cause automatic body pulling')
end

function tests.running_approach_revalidates_before_sending_movement()
    local callback
    local stopped = false
    local completed
    local base_action = {
        new = function() return {} end,
        is_cancelled = function() return false end,
        complete = function(_, success) completed = success end,
    }
    local dependencies = {
        ['cylibs/actions/action'] = base_action,
        ['cylibs/events/dispose_bag'] = { new = function() return { add = function() end } end },
        ['cylibs/ui/views/render'] = { shared = function() return {
            onPrerender = function() return { addAction = function(_, action) callback = action end } end,
        } end },
    }
    local environment = setmetatable({
        require = function(name) return dependencies[name] end,
        windower = { ffxi = {
            get_player = function() return { target_locked = false } end,
            get_mob_by_index = function() return {} end,
            run = function(value) stopped = value == false end,
        } },
    }, { __index = _G })
    local RunTo = assert(loadfile('cylibs/actions/runto.lua', 't', environment))()
    local action = RunTo.new(1, 20)
    action.revalidate_while_running = true
    action.validate = function() return false end
    action:perform()
    callback()
    assert(stopped and completed == false, 'invalidated active approach must stop before moving toward the mob')
end

function tests.detection_range_is_independent_of_pull_ability_range()
    local puller = fixture()
    puller.distance = 50
    puller.blacklist = L{}
    puller.max_num_targets = 1
    puller.pull_abilities = { Auto = L{ { getAbility = function()
        return { get_range = function() return 20 end }
    end } } }
    local mob = { id = 2, index = 2, name = 'Bat', hpp = 100, status = 0, distance = 40 }
    MinHitPointsPercentCondition = { new = function(value) return { kind = 'hp', value = value } end }
    UnclaimedCondition = { new = function() return { kind = 'unclaimed' } end }
    MaxDistanceCondition = { new = function(value) return { kind = 'distance', value = value } end }
    NotCondition = { new = function(conditions) return { kind = 'not', conditions = conditions } end }
    Condition = { LogicalOperator = { And = 'And', Or = 'Or' } }
    local function check(condition)
        if condition.kind == 'not' then return not check(condition.conditions[1]) end
        if condition.conditions then
            for _, child in ipairs(condition.conditions) do
                local success = check(child)
                if condition.operator == 'Or' and success then return true end
                if condition.operator == 'And' and not success then return false end
            end
            return condition.operator == 'And'
        end
        if condition.kind == 'hp' then return mob.hpp >= condition.value end
        if condition.kind == 'distance' then return mob.distance <= condition.value end
        if condition.kind == 'unclaimed' then return not mob.claimed end
        if condition.kind == 'claimed' then return mob.claimed == true end
        if condition.kind == 'names' then return condition.names:contains(mob.name) end
        error('Unexpected condition')
    end
    Condition.check_conditions = function(conditions)
        for _, condition in ipairs(conditions) do
            if not check(condition) then return false end
        end
        return true
    end
    puller.check_delay = function() return true end
    puller.get_all_targets = function() return L{ mob } end
    Monster = { new = function(id) return { id = id } end }
    local target = puller:get_next_target()
    assert(target and target.id == mob.id, 'bat at 40 yalms must be detectable with detection range 50 and attack range 20')
    mob.distance = 51
    assert(not puller:get_next_target(), 'mobs outside the detection radius must remain excluded')
    mob.distance = 40
    puller.blacklist = L{ 'Bat' }
    assert(not puller:get_next_target(), 'detection must continue respecting the blacklist')
end

function tests.manual_departure_after_arriving_at_camp_does_not_restart_return()
    for _, mode in ipairs({ 'Auto', 'Pull' }) do
        local puller, player, queue = fixture()
        state.AutoCampMode.value = mode
        logger = { notice = function() end }
        puller.get_next_target = function() return nil end
        puller.set_pull_target = function(self, target) self.target = target end
        local camp = puller:get_camp_position()
        puller.returning_to_camp = true
        player.current_distance = 1
        puller:tic()
        player.current_distance = 10
        puller:tic()
        puller:tic()
        assert(#queue.actions == 0, mode..' camp mode must allow manual departure after arrival even without pull targets')
        assert(puller:get_camp_position() == camp, 'manual departure must not move the saved camp')
    end
end

function tests.after_battle_return_is_armed_by_kill_and_finished_by_arrival()
    local puller, player, queue, ended = fixture()
    state.AutoCampMode.value = 'Auto'
    logger = { notice = function() end }
    puller.target = {
        get_id = function() return 1 end,
        get_mob = function() return { name = 'Bat', hpp = 0 } end,
    }
    puller.get_target = function(self) return self.target end
    puller.get_next_target = function() return nil end
    puller.set_pull_target = function(self, target) self.target = target end
    WindowerEvents.MobKO:trigger(1, 'Bat', 2)
    assert(puller.returning_to_camp and #queue.actions == 1, 'a kill must still trigger the configured after-battle return')
    player.current_distance = 1
    ended:trigger({ getidentifier = function() return 'Return to camp' end }, true)
    assert(not puller.returning_to_camp, 'arrival must release the return phase immediately')
    player.current_distance = 10
    puller:tic()
    assert(#queue.actions == 1, 'manual departure after battle return must not trigger another return')
end

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