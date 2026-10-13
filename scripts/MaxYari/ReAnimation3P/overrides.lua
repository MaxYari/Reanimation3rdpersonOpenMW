-- ReAnimation in third person: the overrides ReAnimation registers for its first-person animations
-- (ReAnimation_v3's AnimationOverrides.lua, on the player only), registered again for their
-- third-person versions, which this mod ships under the same group names in animations/xbase_anim*
-- - the first-person animations in "Animations/1st person sources", tweaked for third person, merged
-- onto Animation Compilation's third-person ones by ReAnimation's
-- Sources/Tools/FirstToThird/first_to_third.py (see README.md here for the command).
-- For the player with the camera pulled back, and for every NPC: ReAnimation's API runs on both, and
-- an NPC is always third person to it.
--
-- Most of the set needs nothing here: an idle, a walk, a turn, a jump, an attack, an equip under an
-- engine group name plays as it is, and so do the attack tails ("<group>extra"), which ReAnimation
-- plays on its own in either view. What does need registering is what the engine never asks for -
-- the alternate attacks and the spear's sneaking idle - which ReAnimation plays over the engine's
-- groups through these registrations.
--
-- Only what this set ships is registered: ReAnimation takes a registered variant as a promise that
-- its animation exists, section and all. So unlike first person there is no katana or throwing star
-- set (katanas swing as claymores, stars are thrown as knives), no two-handed alternate thrust and no
-- spear slash variant, and no sneaking idle but the spear's - the other weapons sneak on Animation
-- Compilation's own.
local animation = require('openmw.animation')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local omwself = require('openmw.self')
local types = require('openmw.types')

if not core.contentFiles.has("ReAnimation_API.omwscripts") then
    if types.Player.objectIsInstance(omwself) then
        print("[ReAnimation Third Person] ERROR: ReAnimation is missing - these animations are its own, " ..
            "and without it the alternate attacks and the spear's sneaking idle never play.")
    end
    return
end

local RA = I.ReAnimation
if RA == nil then
    -- Installed, but loaded after this: its interface is not there yet when this script starts.
    if types.Player.objectIsInstance(omwself) then
        print("[ReAnimation Third Person] ERROR: ReAnimation is loaded after ReAnimation_ThirdPerson.omwscripts. " ..
            "Move it above this in the launcher's Content Files.")
    end
    return
end

local gutils = RA.gutils
local THIRD = RA.ARMATURE_TYPE.ThirdPerson
local BG = animation.BONE_GROUP
local controls = omwself.controls

--- How an override sits over its parent -------------------------------------------------------------
-- Outranked: one above the parent on every bone group, two on the lower body, as AnimationOverrides.lua
-- does it (outrankPriority): a priority set equal to one already playing makes the engine destroy the
-- other state (animation.cpp:905), and the uneven lower body keeps it from ever matching a uniform
-- engine one. For what has to be able to stop while its parent plays on.
local function outrankParent(self, pOptions)
    local opts = gutils.cloneAnimOptions(pOptions or self.parentOptions)
    local priority = opts.priority
    local function at(group)
        if type(priority) == "number" then return priority end
        return priority[group]
    end
    opts.priority = {
        [BG.LeftArm] = at(BG.LeftArm) + 1,
        [BG.RightArm] = at(BG.RightArm) + 1,
        [BG.Torso] = at(BG.Torso) + 1,
        [BG.LowerBody] = at(BG.LowerBody) + 2,
    }
    return opts
end

--- What is in hand ------------------------------------------------------------------------------------
-- The engine's short group for the weapon in hand (weapontype.cpp): what its idles and walks end in.
-- Cached by record id, which ReAnimation itself caches for everyone, so a condition polled every frame
-- costs a table lookup. The record comes from the item, not the id - see equippedWeaponType in
-- AnimationOverrides.lua for why.
local WT = types.Weapon.TYPE
local SHORT_GROUP = {
    [WT.ShortBladeOneHand] = "1s", [WT.LongBladeOneHand] = "1h", [WT.LongBladeTwoHand] = "2c",
    [WT.BluntOneHand] = "1b", [WT.BluntTwoClose] = "2b", [WT.BluntTwoWide] = "2w",
    [WT.SpearTwoWide] = "2w", [WT.AxeOneHand] = "1h", [WT.AxeTwoHand] = "2c",
    [WT.MarksmanBow] = "bow", [WT.MarksmanCrossbow] = "crossbow", [WT.MarksmanThrown] = "1t",
}
local TWO_HANDED_MELEE = { ["2c"] = true, ["2b"] = true, ["2w"] = true }

local shortById = {}

local function shortGroup()
    local id = RA.getEquippedWeaponId()
    if id == nil then return "hh" end
    local short = shortById[id]
    if short == nil then
        local item = RA.getEquippedWeapon()
        local record = item and types.Weapon.objectIsInstance(item) and types.Weapon.record(item)
        -- Not a weapon: a lockpick or probe, which the engine holds as a one-handed weapon.
        short = record and SHORT_GROUP[record.type] or "1h"
        shortById[id] = short
    end
    return short
end

-- The idle the engine plays for what is in hand when not sneaking: "idle" + its short group, or when
-- there is none, the one-handed or two-handed sword's - or for fists the plain idle
-- (CharacterController::refreshIdleAnims, fallbackShortWeaponGroup). Per short group: an actor's
-- third-person groups do not change.
local idleByShort = {}

local function stanceIdle()
    local short = shortGroup()
    local idle = idleByShort[short]
    if idle == nil then
        idle = "idle" .. short
        if not animation.hasGroup(omwself, idle) then
            if short == "hh" then
                idle = "idle"
            elseif TWO_HANDED_MELEE[short] then
                idle = "idle2c"
            else
                idle = "idle1h"
            end
        end
        idleByShort[short] = idle
    end
    return idle
end

--- Sneaking idles ---------------------------------------------------------------------------------------
-- In first person a sneaking weapon user still plays its stance idle - there is no "idlesneak" there -
-- and ReAnimation plays the weapon's sneaking idle over it while controls.sneak is down. Third person
-- has "idlesneak", and plays it for anyone sneaking, weapon or not (refreshIdleAnims only adds the
-- weapon's suffix to a plain idle). So the sneaking idle goes over "idlesneak" as well, for the weapons
-- whose idle it stands in for - the parent says the actor is sneaking, which is how an NPC tells,
-- since only the player's controls say so - and over the stance idle for the player's sneak key, as
-- in first person.
--
-- The spear's, the two-handed sword's and the thrown weapon's are made from their idles on Animation
-- Compilation's sneaking legs. Ranked 0, so each stands down for anything ranked above it on the same
-- parent instead of both playing.
local SNEAK_IDLE = "idlesneak"

local function sneaking(self)
    return self.parent == SNEAK_IDLE or controls.sneak
end

local function addSneakIdle(stanceIdleGroup, groupname, rank)
    RA.addAnimationOverride({
        id = "ReAnimation3P_" .. groupname,
        parent = { stanceIdleGroup, SNEAK_IDLE },
        groupname = groupname,
        armatureType = THIRD,
        overridePriority = rank,
        condition = function(self)
            -- parentOptions is only filled once the parent has been seen starting; one already
            -- playing when the save loaded never was.
            return self.parentOptions ~= nil and sneaking(self)
                and (self.parent ~= SNEAK_IDLE or stanceIdle() == stanceIdleGroup)
        end,
        stopCondition = function(self) return not self:condition() end,
        options = outrankParent,
        startOnAnimEvent = true,
        startOnUpdate = true,
    })
end

addSneakIdle("idle2w", "idle2wsneak", 0)
addSneakIdle("idle2c", "idle2csneak", 0)
addSneakIdle("idle1t", "idle1tsneak", 0)

--- Attacks ----------------------------------------------------------------------------------------------
-- The same sets as AnimationOverrides.lua, with the same modes, cut to the groups and sections this set
-- has. Every attack type a set takes needs a list, even one with only the engine's own attack in it.
RA.addAttackVariants({
    id = "TwoHand3P",
    parentAttackGroupname = "weapontwohand",
    armatureType = THIRD,
    attacks = {
        chop = { { "weapontwohand", "weapontwohandsub" }, { "weapontwohandalt" } },
        slash = { { "weapontwohand" }, { "weapontwohandalt" } },
        thrust = { { "weapontwohand" } },
    },
})

RA.addAttackVariants({
    id = "TwoWide3P",
    parentAttackGroupname = "weapontwowide",
    armatureType = THIRD,
    subAttackMode = RA.SUB_ATTACK_MODE.Random,
    randomMaxRepeats = 2,
    attacks = {
        chop = { { "weapontwowide" }, { "weapontwowidealt" } },
        thrust = { { "weapontwowide", "weapontwowidesub2", "weapontwowidesub3", "weapontwowidesub4" } },
        slash = { { "weapontwowide" }, { "weapontwowidealt" } },
    },
})

RA.addAttackVariants({
    id = "HandToHand3P",
    parentAttackGroupname = "handtohand",
    armatureType = THIRD,
    subAttackMode = RA.SUB_ATTACK_MODE.RoundRobin,
    attacks = {
        slash = { { "handtohand" }, { "handtohandalt" } },
        thrust = { { "handtohand" }, { "handtohandalt" } },
        chop = { { "handtohand" }, { "handtohandalt" } },
    },
})

RA.addAttackVariants({
    id = "Throw3P",
    parentAttackGroupname = "throwweapon",
    armatureType = THIRD,
    attacks = {
        shoot = { { "throwweapon" }, { "throwweaponalt" } },
    },
})
