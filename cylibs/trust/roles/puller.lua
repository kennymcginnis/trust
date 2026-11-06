local AggroedCondition = require('cylibs/conditions/aggroed')
local Approach = require('cylibs/battle/approach')
local ConditionalCondition = require('cylibs/conditions/conditional')
local CooldownCondition = require('cylibs/conditions/cooldown')
local DisposeBag = require('cylibs/events/dispose_bag')
local Engage = require('cylibs/battle/engage')
local Gambit = require('cylibs/gambits/gambit')
local GambitTarget = require('cylibs/gambits/gambit_target')
local HasMaxNumAlterEgosCondition = require('cylibs/conditions/has_max_num_alter_egos')
local MobFilter = require('cylibs/battle/monsters/mob_filter')
local PartyClaimedCondition = require('cylibs/conditions/party_claimed')
local PartyLeaderCondition = require('cylibs/conditions/party_leader')
local PartyTargetedCondition = require('cylibs/conditions/party_targeted')
local PullTargetUtil = require('cylibs/util/pull_target_util')
local RunToAction = require('cylibs/actions/runto')
local RunToLocationAction = require('cylibs/actions/runtolocation')
local TargetIdsCondition = require('cylibs/conditions/target_ids')
local TargetNamesCondition = require('cylibs/conditions/target_names')
local action_message_util = require('cylibs/util/action_message_util')

local Gambiter = require('cylibs/trust/roles/gambiter')
local Puller = setmetatable({}, {__index = Gambiter })
Puller.__index = Puller
Puller.__class = "Puller"

state.AutoPullMode = M{['description'] = 'Pull Monsters to Fight', 'Off', 'Auto','Aggroed','All'}
state.AutoPullMode:set_description('Auto', "Pull monsters for the party from the target list.")
state.AutoPullMode:set_description('Aggroed', "Pull any monster aggressive to the party.")
state.AutoPullMode:set_description('All', "Pull any monster that's nearby.")

state.AutoCampMode = M{['description'] = 'Return to Camp', 'Off', 'Auto', 'Pull'}
state.AutoCampMode:set_description('Auto', "Return to camp after battle (set with // trust pull camp).")
state.AutoCampMode:set_description('Pull', "Return to camp after pulling, before engaging (set with // trust pull camp pull).")

state.PullActionMode = M{['description'] = 'Pull Actions', 'Auto', 'Target', 'Approach'}
state.PullActionMode:set_description('Auto', "Pull with pull actions in settings.")
state.PullActionMode:set_description('Target', "Pull by targeting and engaging.")
state.PullActionMode:set_description('Approach', "Pull by engaging and approaching.")


function Puller.new(action_queue, pull_settings, job)
    local self = setmetatable(Gambiter.new(action_queue, { Gambits = L{} }, state.AutoPullMode), Puller)

    self.job = job
    self.dispose_bag = DisposeBag.new()

    self:set_pull_settings(pull_settings)

    return self
end

function Puller:destroy()
    if self.action_queue.puller == self then
        self.action_queue.puller = nil
    end
    if self.action_queue.action_start_filter == self.action_start_filter then
        self.action_queue.action_start_filter = nil
    end
    Gambiter.destroy(self)

    self.dispose_bag:destroy()
end

function Puller:on_add()
    Gambiter.on_add(self)

    self.action_start_filter = function(action)
        return self:can_start_action(action)
    end
    self.action_queue.action_start_filter = self.action_start_filter
    self.action_queue.puller = self

    self.dispose_bag:add(WindowerEvents.Action:addAction(function(action)
        if action.actor_id ~= windower.ffxi.get_player().id or action.category ~= 1
                or not self:should_wait_for_first_hit() then
            return
        end
        for _, target in ipairs(action.targets or {}) do
            if target.id == self.first_hit_target_id then
                for _, hit in ipairs(target.actions or {}) do
                    if action_message_util.is_hit_attack_message(hit.message) then
                        self.first_hit_target_id = nil
                        return
                    end
                end
            end
        end
    end), WindowerEvents.Action)

    local current_target = self:get_alliance():get_target_by_index(self:get_party():get_player():get_target_index())
    if state.AutoPullMode.value ~= 'Off' and current_target and self:is_valid_target(current_target:get_mob()) then
        self:set_pull_target(Monster.new(current_target.id))
    end

    local on_pull_mode_changed = function(new_value)
        self:get_party():set_should_ignore_assist_target(new_value ~= 'Off')
        if new_value ~= 'Off' then
            self:set_pull_settings(self.pull_settings)
            windower.send_command('input /autotarget off')
            self:get_party():set_assist_target(self:get_party():get_player())
        else
            self:get_party():set_party_target_index(self:get_party():get_assist_target():get_target_index())
        end
    end
    on_pull_mode_changed(state.AutoPullMode.value)

    self.dispose_bag:add(state.AutoPullMode:on_state_change():addAction(function(_, new_value)
        self.returning_to_camp = false
        self.first_hit_target_id = nil
        on_pull_mode_changed(new_value)
    end), state.AutoPullMode:on_state_change())

    self.dispose_bag:add(self.action_queue:on_action_end():addAction(function(action, success)
        if success and action:getidentifier() == 'Return to camp' then
            self.returning_to_camp = false
        end
        if success and action:getidentifier() == self:get_action_identifier() and self:is_pull_to_camp_enabled() then
            local target = self:get_pull_target()
            local mob = target and target.get_mob and target:get_mob()
            self.first_hit_target_id = mob and mob.id
            self.returning_to_camp = true
            self:return_to_camp(true)
        end
    end), self.action_queue:on_action_end())

    self.dispose_bag:add(WindowerEvents.MobKO:addAction(function(mob_id, mob_name, status)
        if self:get_target() and self:get_target():get_id() == mob_id then
            logger.notice(self.__class, 'mob_ko', mob_name, self:get_target():get_mob().hpp, status)
            CooldownCondition.set_timestamp('last_mob_ko', os.time())
            if state.AutoCampMode.value == 'Auto' then
                self.returning_to_camp = true
            end
            self:set_pull_target(nil) -- this is necessary otherwise get_target() returns valid until next loop
            self:check_target(L{ mob_id })
        end
    end), WindowerEvents.MobKO)

    self.dispose_bag:add(self:get_party():get_player():on_status_change():addAction(function(_, new_status, old_status)
        if L{ 'Event' }:contains(new_status) then
            self:set_pull_target(nil)
        end
    end), self:get_party():get_player():on_status_change())
end

function Puller:tic(_, _)
    if state.AutoPullMode.value == 'Off' then
        return
    end

    logger.notice(self.__class, 'tic', 'target_index', self.target_index or 'none')

    self.mob_filter:set_center_position(self:get_pull_origin())
    self:return_to_camp(self.returning_to_camp and (state.AutoCampMode.value == 'Auto' or self:is_pull_to_camp_enabled()))
    self:check_target()
end

function Puller:check_gambits(gambits, param, ignore_delay)
    if self:move_to_pull_point() or self:approach_pull_target() then
        return
    end
    Gambiter.check_gambits(self, gambits, param, ignore_delay)
end

function Puller:get_outbound_aggro_target()
    local target = self:get_pull_target()
    local mob = target and target:get_mob()
    if mob and Condition.check_conditions(L{ AggroedCondition.new() }, mob.index) then
        return mob
    end
    if not self.outbound_mob_filter then
        self.outbound_mob_filter = MobFilter.new(self:get_alliance(), 25)
    end
    return self.outbound_mob_filter:get_aggroed_mobs()[1]
end

function Puller:get_auto_pull_range()
    local range = 0
    for gambit in self.pull_abilities.Auto:it() do
        if gambit:isEnabled() then
            range = math.max(range, gambit:getAbility():get_range())
        end
    end
    return range
end

function Puller:is_in_pull_range(mob)
    local range = self:get_auto_pull_range() - 1
    return mob and mob.distance ~= nil and range > 0 and mob.distance <= range^2
            and self:is_valid_target(mob)
            and Condition.check_conditions(L{ UnclaimedCondition.new() }, mob.index)
end

function Puller:get_in_range_pull_target()
    if not self:is_enabled() or self.action_queue.is_singing or self.returning_to_camp
            or self:get_party():get_player():get_status() ~= 'Idle' or self:should_wait_for_first_hit()
            or not self:check_delay() or self:get_auto_pull_range() <= 1 then
        return nil
    end
    local target = self:get_pull_target()
    local mob = target and target:get_mob()
    if mob and not Condition.check_conditions(L{ UnclaimedCondition.new() }, mob.index) then
        return nil
    end
    if self:is_in_pull_range(mob) then
        return mob
    end
    for candidate in self:get_all_targets():it() do
        if self:is_in_pull_range(candidate) then
            return candidate
        end
    end
    return nil
end

function Puller:can_move_to_pull_point(point, camp)
    if not self:is_enabled() or not self:is_pull_to_camp_enabled() or self:get_pull_point() ~= point
            or self:get_camp_position() ~= camp or self.action_queue.is_singing or self.returning_to_camp
            or self:get_party():get_player():get_status() ~= 'Idle' or self:should_wait_for_first_hit()
            or not self:check_delay() or self.action_queue:has_action(self:get_action_identifier()) then
        return false
    end
    if math.sqrt((point[1] - camp[1])^2 + (point[2] - camp[2])^2) > 35 then
        return false
    end
    local target = self:get_pull_target()
    local mob = target and target:get_mob()
    if mob and not Condition.check_conditions(L{ UnclaimedCondition.new() }, mob.index) then
        return false
    end
    return self:get_outbound_aggro_target() == nil and self:get_in_range_pull_target() == nil
end

function Puller:move_to_pull_point()
    local point = self:get_pull_point()
    if not point or not self:is_pull_to_camp_enabled() or not self:is_enabled()
            or self.action_queue.is_singing or self.returning_to_camp
            or self:get_party():get_player():get_status() ~= 'Idle' or self:should_wait_for_first_hit() then
        return false
    end
    local camp = self:get_camp_position()
    local target = self:get_pull_target()
    local selected_mob = target and target:get_mob()
    local mob = self:get_outbound_aggro_target()
    if self:is_enabled() and not self.action_queue.is_singing and not self.returning_to_camp
            and self:get_party():get_player():get_status() == 'Idle'
            and mob and (self:get_party():get_player():distance(camp[1], camp[2]) > 2
            or not selected_mob or selected_mob.id ~= mob.id) then
        self.first_hit_target_id = mob.id
        self.returning_to_camp = true
        if not selected_mob or selected_mob.id ~= mob.id then
            self:set_pull_target(Monster.new(mob.id))
        end
        self:return_to_camp(true)
        return true
    end
    if mob then
        return false
    end
    local in_range_target = self:get_in_range_pull_target()
    if in_range_target then
        if not selected_mob or selected_mob.id ~= in_range_target.id then
            self:set_pull_target(Monster.new(in_range_target.id))
        end
        return false
    end
    if not self:can_move_to_pull_point(point, camp) then
        return false
    end
    if self.action_queue:has_action('Move to pull point') then
        return true
    end
    if self:get_party():get_player():distance(point[1], point[2]) <= 1 then
        return false
    end
    local action = RunToLocationAction.new(point[1], point[2], point[3], 1)
    action.identifier = 'Move to pull point'
    action.priority = self:get_priority()
    action.revalidate_while_running = true
    action.validate = function()
        return self:can_move_to_pull_point(point, camp)
    end
    self.action_queue:push_action(action, true)
    return true
end

function Puller:approach_pull_target()
    if not self:is_enabled() or state.PullActionMode.value ~= 'Auto' or state.AutoPullMode.value == 'Off'
            or self:is_pull_to_camp_enabled() or self.action_queue.is_singing
            or self.returning_to_camp or self:get_party():get_player():get_status() ~= 'Idle'
            or not self:check_delay() or self.action_queue:has_action(self:get_action_identifier()) then
        return false
    end
    if self.action_queue:has_action('Approach pull target') then
        return true
    end
    local target = self:get_pull_target()
    local mob = target and target:get_mob()
    if not self:is_valid_target(mob) or not Condition.check_conditions(L{ UnclaimedCondition.new() }, mob.index) then
        return false
    end
    local range = self:get_auto_pull_range()
    if range < 15.5 or math.sqrt(mob.distance) <= range then
        return false
    end
    local action = RunToAction.new(mob.index, range - 0.5)
    action.identifier = 'Approach pull target'
    action.revalidate_while_running = true
    action.priority = self:get_priority()
    action.validate = function()
        local current_target = self:get_pull_target()
        local current_mob = current_target and current_target:get_mob()
        return state.AutoPullMode.value ~= 'Off' and state.PullActionMode.value == 'Auto'
            and not self:is_pull_to_camp_enabled() and not self.action_queue.is_singing
                and not self.returning_to_camp and self:get_party():get_player():get_status() == 'Idle'
                and current_mob and current_mob.index == mob.index and self:is_valid_target(current_mob)
                and Condition.check_conditions(L{ UnclaimedCondition.new() }, current_mob.index)
                and not Condition.check_conditions(L{ AggroedCondition.new() }, current_mob.index)
    end
    self.action_queue:push_action(action, true)
    return true
end

function Puller:is_gambit_satisfied(gambit, param, resolved_targets)
    if self:is_pull_to_camp_enabled() and self.returning_to_camp then
        return false, nil
    end
    local point = self:get_pull_point()
    if self:is_pull_to_camp_enabled() and point then
        local target = self:get_pull_target()
        local mob = target and target:get_mob()
        if self.action_queue.is_singing or not self:check_delay()
                or self:get_party():get_player():distance(point[1], point[2]) > 1 and not self:is_in_pull_range(mob) then
            return false, nil
        end
    end
    return Gambiter.is_gambit_satisfied(self, gambit, param, resolved_targets)
end

function Puller:target_change(target_index)
    Gambiter.target_change(self, target_index)

    self:check_gambits(nil, nil, true)
end

function Puller:check_target(target_id_blacklist)
    if state.AutoPullMode.value == 'Off' or self:is_pull_to_camp_enabled()
            and (self.returning_to_camp or self:should_wait_for_first_hit()) then
        return
    end

    local next_target = self:get_pull_target()

        if not self:is_valid_target(next_target and next_target:get_mob(), target_id_blacklist)
            or not self:is_reachable_from_pull_point(next_target and next_target:get_mob()) then
        if next_target and next_target:get_mob() then
            local previous_target = next_target:get_mob()
            logger.notice(self.__class, 'check_target', 'clear', previous_target.name, previous_target.hpp, previous_target.index, previous_target.status, previous_target.claim_id or 'unclaimed')
        end

        next_target = self:get_next_target(target_id_blacklist)
        if next_target then
            self:set_pull_target(next_target)
            logger.notice(self.__class, 'check_target', 'set_pull_target', next_target:get_name(), next_target:get_mob().index)
        else
            self:set_pull_target(nil)
            logger.notice(self.__class, 'check_target', 'no valid targets')
            if state.AutoPullMode.value == 'Auto' then
                self:get_party():add_to_chat(self:get_party():get_player(), "I can't find anything to pull. I'll check again soon.", self.__class..'_no_valid_targets', 15)
            end
            self:return_to_camp()
            return
        end
    end
end

function Puller:get_all_targets()
    local all_targets = L{}
    if not self:check_delay() then
        return all_targets
    end
    local target_names = self.target_names
    local function sort_bucket(mobs)
        table.sort(mobs, function(a, b)
            local index_a = target_names:indexOf(a.name)
            local index_b = target_names:indexOf(b.name)
            if index_a == -1 then index_a = math.huge end
            if index_b == -1 then index_b = math.huge end
            if index_a ~= index_b then
                return index_a < index_b
            end
            if a.distance ~= b.distance then
                return a.distance < b.distance
            end
            return a.id < b.id
        end)
        return mobs
    end
    if state.AutoPullMode.value == 'Aggroed' then
        -- 1. Aggroed mobs that are unclaimed and not targeted by party members
        -- 2. Aggroed mobs that are unclaimed
        -- 3. Aggroed mobs that are party claimed
        all_targets = sort_bucket(self.mob_filter:get_aggroed_mobs(L{ UnclaimedCondition.new(), NotCondition.new(L{ PartyTargetedCondition.new() }) }))
                + sort_bucket(self.mob_filter:get_aggroed_mobs(L{ MobFilter.Type.Unclaimed }))
                + sort_bucket(self.mob_filter:get_aggroed_mobs(L{ MobFilter.Type.PartyClaimed }))
    elseif state.AutoPullMode.value == 'Auto' then
        -- 1. Aggroed mobs that are party claimed
        -- 2. Aggroed mobs that are unclaimed
        -- 3. Unaggroed mobs in target name whitelist
        all_targets = sort_bucket(self.mob_filter:get_aggroed_mobs(L{ MobFilter.Type.PartyClaimed }))
                + sort_bucket(self.mob_filter:get_aggroed_mobs(L{ MobFilter.Type.Unclaimed }))
                + sort_bucket(self.mob_filter:get_nearby_mobs(L{ MobFilter.Type.Unclaimed }):filter(function(mob)
            return self.target_names:contains(mob.name) or self.target_ids:contains(mob.id)
        end))
    elseif state.AutoPullMode.value == 'All' then
        -- 1. All mobs that are party claimed
        -- 2. All mobs that are unclaimed
        all_targets = sort_bucket(self.mob_filter:get_nearby_mobs(L{ MobFilter.Type.PartyClaimed }))
                + sort_bucket(self.mob_filter:get_nearby_mobs(L{ MobFilter.Type.Unclaimed }))
    end
    return all_targets
end

function Puller:check_delay()
    local last_mob_ko = CooldownCondition.get_timestamp('last_mob_ko')
    return last_mob_ko == nil or os.time() >= last_mob_ko + self.delay
end

function Puller:get_next_target(target_id_blacklist)
    target_id_blacklist = target_id_blacklist or L{}

    if self:get_party():get_player():get_status() == 'Event' or not self:check_delay() then
        return nil
    end

    local current_target = self:get_alliance():get_target_by_index(self:get_party():get_player():get_target_index())
    if current_target and not target_id_blacklist:contains(current_target:get_id()) and self:is_valid_target(current_target:get_mob())
            and Condition.check_conditions(L{ AggroedCondition.new() }, current_target:get_mob().index) then
        return Monster.new(current_target:get_id())
    end
    local all_targets = self:get_all_targets():filter(function(target)
        return not target_id_blacklist:contains(target.id) and self:is_valid_target(target)
            and self:is_reachable_from_pull_point(target)
    end)
    if all_targets:length() > 0 then
        return Monster.new(all_targets[1].id)
    else
        return nil
    end
end

function Puller:is_valid_target(target, target_id_blacklist)
    if not target or target_id_blacklist and target_id_blacklist:contains(target.id) then
        return false
    end

    local conditions = L{
        MinHitPointsPercentCondition.new(1),
        ConditionalCondition.new(L{
            PartyClaimedCondition.new(true),
            ConditionalCondition.new(L{ UnclaimedCondition.new(), MaxDistanceCondition.new(self.distance or 25, nil, self:get_pull_origin()) }, Condition.LogicalOperator.And),
        }, Condition.LogicalOperator.Or),
        NotCondition.new(L{ TargetNamesCondition.new(self.blacklist) }),
    }
    return not L{ 2, 3 }:contains(target.status) and Condition.check_conditions(conditions, target.index)
end

function Puller:get_pull_target()
    return self:get_target()
end

function Puller:set_pull_target(target)
    if state.AutoPullMode.value == 'Off' then
        self:get_party():set_party_target_index(self:get_party():get_assist_target():get_target_index())
    else
        self:get_party():set_party_target_index(target and target:get_mob().index)
    end
end

function Puller:get_pull_settings()
    return self.pull_settings
end

function Puller:set_pull_settings(pull_settings)
    self.pull_settings = pull_settings
    self.distance = pull_settings.Distance
    self.blacklist = pull_settings.Blacklist
    self.delay = pull_settings.Delay or 0
    self.mob_filter = MobFilter.new(self:get_alliance(), self.distance or 25, nil, self.blacklist)
    self.mob_filter:set_center_position(self:get_pull_origin())
    if pull_settings.RandomizeTarget then
        self.max_num_targets = 6
    else
        self.max_num_targets = 1
    end
    self:set_target_names(pull_settings.Targets or L{})
    self:set_target_ids((pull_settings.TargetIds or L{}):map(PullTargetUtil.get_id))

    CooldownCondition.set_timestamp('last_mob_ko', os.time() - self.delay)

    for gambit in pull_settings.Gambits:it() do
        gambit.conditions = gambit.conditions:filter(function(condition)
            return condition:is_editable()
        end)
        local conditions = L{
            GambitCondition.new(ModeCondition.new('PullActionMode', 'Auto'), GambitTarget.TargetType.Self)
        } + self:get_default_conditions(gambit)
        for condition in conditions:it() do
            condition:set_editable(false)
            gambit:addCondition(condition)
        end
    end

    local approach = Gambit.new(GambitTarget.TargetType.Enemy, L{}, Approach.new(), GambitTarget.TargetType.Enemy, L{"Pulling"})
    approach.conditions = L{
        GambitCondition.new(ModeCondition.new('PullActionMode', 'Approach'), GambitTarget.TargetType.Self)
    } + self:get_default_conditions(approach)

    local auto_target = Gambit.new(GambitTarget.TargetType.Enemy, L{}, Engage.new(L{MaxDistanceCondition.new(30)}), GambitTarget.TargetType.Enemy, L{"Pulling","Reaction"})
    auto_target.conditions = L{
        GambitCondition.new(ModeCondition.new('PullActionMode', 'Target'), GambitTarget.TargetType.Self),
    } + self:get_default_conditions(auto_target)

    self.pull_abilities = {
        Auto = pull_settings.Gambits,
        Approach = L{ approach },
        Target = L{ auto_target },
    }

    local gambit_settings = {
        Gambits = self.pull_abilities.Auto + self.pull_abilities.Approach + self.pull_abilities.Target
    }
    
    self:set_gambit_settings(gambit_settings)
end

function Puller:get_default_conditions(gambit)
    local conditions = L{
        GambitCondition.new(UnclaimedCondition.new(), GambitTarget.TargetType.Enemy),
        GambitCondition.new(MaxDistanceCondition.new(gambit:getAbility():get_range()), GambitTarget.TargetType.Enemy),
        GambitCondition.new(MinHitPointsPercentCondition.new(1), GambitTarget.TargetType.Enemy),
        GambitCondition.new(NotCondition.new(L{ HasBuffCondition.new('weakness') }), GambitTarget.TargetType.Self),
    }
    if state.AutoPullMode.value == 'Aggroed' then
        conditions:append(GambitCondition.new(AggroedCondition.new(), GambitTarget.TargetType.Enemy))
    elseif state.AutoPullMode.value == 'Auto' then
        conditions:append(GambitCondition.new(ConditionalCondition.new(L{
            TargetNamesCondition.new(self:get_target_names()),
            TargetIdsCondition.new(self:get_target_ids()),
        }, Condition.LogicalOperator.Or), GambitTarget.TargetType.Enemy))
    end
    local alter_ego_conditions = L{
        GambitCondition.new(ConditionalCondition.new(
            L{
                NotCondition.new(L{ PartyLeaderCondition.new() }),
                ModeCondition.new('AutoTrustsMode', 'Off'),
                ConditionalCondition.new(L{ ModeCondition.new('AutoTrustsMode', 'Auto'), NotCondition.new(L{ ModeCondition.new('AutoPullMode', 'Off') }), HasMaxNumAlterEgosCondition.new() }, Condition.LogicalOperator.And)
            },
            Condition.LogicalOperator.Or), GambitTarget.TargetType.Self
        )
    }
    return (alter_ego_conditions + conditions + self.job:get_conditions_for_ability(gambit:getAbility())):map(function(condition)
        if condition.__type ~= GambitCondition.__type then
            return GambitCondition.new(condition, GambitTarget.TargetType.Self)
        end
        return condition
    end)
end

function Puller:get_type()
    return "puller"
end

function Puller:set_target_names(target_names)
    self.target_names = target_names
end

function Puller:get_target_names()
    return self.target_names
end

function Puller:set_target_ids(target_ids)
    self.target_ids = target_ids
end

function Puller:get_target_ids()
    return self.target_ids
end

function Puller:set_camp_position(position)
    self.camp_position = position
    self.returning_to_camp = false
    self.first_hit_target_id = nil
    self.mob_filter:set_center_position(self:get_pull_origin())
end

function Puller:set_pull_point(position)
    self.pull_point = position
    self.mob_filter:set_center_position(self:get_pull_origin())
end

function Puller:get_pull_point()
    return self.pull_point
end

function Puller:get_pull_origin()
    if self:is_pull_to_camp_enabled() and self:get_pull_point() then
        return nil
    end
    return self:get_camp_position()
end

function Puller:is_reachable_from_pull_point(mob)
    local point = self:get_pull_point()
    if not self:is_pull_to_camp_enabled() or not point then
        return true
    end
    if not mob then
        return false
    end
    if Condition.check_conditions(L{ AggroedCondition.new() }, mob.index) then
        return true
    end
    if self:is_in_pull_range(mob) then
        return true
    end
    local range = self:get_auto_pull_range() - 1
    return mob.x ~= nil and mob.y ~= nil and range > 0
            and (mob.x - point[1])^2 + (mob.y - point[2])^2 <= range^2
end

function Puller:get_camp_position()
    return self.camp_position
end

function Puller:is_pull_to_camp_enabled()
    return state.AutoCampMode.value == 'Pull' and state.AutoPullMode.value ~= 'Off'
            and state.PullActionMode.value == 'Auto' and self:get_camp_position() ~= nil
end

function Puller:should_wait_to_engage()
    if not self:is_pull_to_camp_enabled() then
        return false
    end
    local camp_position = self:get_camp_position()
    if self:get_pull_point() then
        local target = self:get_pull_target()
        local mob = target and target:get_mob()
        if mob and not Condition.check_conditions(L{ AggroedCondition.new() }, mob.index) then
            return true
        end
    end
    return self.action_queue:has_action(self:get_action_identifier())
            or self:get_party():get_player():distance(camp_position[1], camp_position[2]) > 2
end

function Puller:should_wait_for_first_hit()
    local target = self:get_pull_target()
    local mob = target and target:get_mob()
    if not self:is_pull_to_camp_enabled() or not mob or mob.id ~= self.first_hit_target_id
            or mob.hpp == 0 or mob.status == 2 or mob.status == 3 then
        self.first_hit_target_id = nil
        return false
    end
    return self.first_hit_target_id ~= nil
end

function Puller:can_start_action(action)
    if not self:should_wait_for_first_hit() then
        return true
    end
    local identifier = action:getidentifier()
    return L{ 'Return to camp', 'attacker_action', 'combatmode_action', 'healer_action' }:contains(identifier)
            or type(identifier) == 'string' and identifier:sub(1, 8) == 'sleeper_'
end

function Puller:get_cooldown()
    return 5
end

function Puller:allows_duplicates()
    return false
end

function Puller:allows_multiple_actions()
    return false
end

function Puller:return_to_camp(allow_pull_target)
    if not self.returning_to_camp or state.AutoCampMode.value == 'Off' or self:get_pull_target() ~= nil and not allow_pull_target
            or self:get_party():get_player():get_status() == 'Engaged' or self:get_camp_position() == nil then
        return false
    end

    local distance = self:get_party():get_player():distance(self:get_camp_position()[1], self:get_camp_position()[2])
    if distance > 40 then
        self:set_camp_position(nil)
        self:get_party():add_to_chat(self:get_party():get_player(), "I'm too far from camp to go back now.")
        windower.ffxi.run(false)
        return false
    end

    if distance > 2 then
        local return_to_camp_action = RunToLocationAction.new(self:get_camp_position()[1], self:get_camp_position()[2], self:get_camp_position()[3], 2.0)
        return_to_camp_action.identifier = "Return to camp"

        self.action_queue:push_action(return_to_camp_action, true)
    else
        self.returning_to_camp = false
    end

    return true
end

return Puller