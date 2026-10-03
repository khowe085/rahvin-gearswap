--------------------------------------------------------------------------
--===              RahvinGS -- GearSwap Engine for FFXI              ===--
--===       DO NOT MODIFY THIS FILE - ONLY MODIFY JOB FILES          ===--
--------------------------------------------------------------------------
-- Copyright (c) 2026 Rahvin
-- Released under the MIT License. See LICENSE.md.
--
-- Derived from Mirdain-Include (github.com/Mirdain/Gearswap) Copyright (c)
-- 2020 Mirdain, used with the author's permission. The monolithic include
-- has been decomposed into components and substantially rewritten; portions
-- of the original remain, and the job-file API is preserved for compatibility.
--
-- See https://github.com/rahvincode for the latest version.
-- README.md covers installation, features, commands and troubleshooting.
--------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
-- COMPONENT: lifecycle -- section 22: job file load, unload and subjob change
----------------------------------------------------------------------------------------------------
-- CONTENTS
--   Section 22 - Job lifecycle. Four global functions covering the life of a job file: the
--   setup call the job file makes itself, the startup notice about unsupported leftovers,
--   the teardown that gives every held slot back, and the subjob-change refresh. Load and
--   subjob change both ask for the lockstyle, which waits for the client to settle.
--
-- EXPORTS  Nothing onto E. The teardown clears two E fields that the enchanted item engine
--          sets, ench_active and ench_held_slot, because an item use must not outlive the
--          job file that started it.
-- CALLERS  No other engine file calls these four, and the root registers none of them.
--            jobsetup .......... called by the job file, at file scope
--            file_unload ....... called by GearSwap, which looks it up by name
--            sub_job_change .... called by GearSwap, which looks it up by name
--            migration_notice .. scheduled by the root shortly after load
--          A search for callers of the first three finds none, and that is expected.
-- LOADS    After every component whose exports it binds. sub_job_change reads the three
--          functions it schedules as globals when it runs, long after load. That is how it
--          can schedule equip_set_command, which the root declares after this file.

-- requires: rahvings/core, rahvings/equip, rahvings/display, rahvings/commands, rahvings/export
return function(E)
    -- The exports this file uses, bound once at construction. The shared mutable fields are
    -- never bound here. ench_active and ench_held_slot are written through E, because a
    -- local copy would not be the one the other components read.
    local clear_locked_slots, gs_debug, gs_status, hoxne, reset_set_warnings =
        E.clear_locked_slots, E.gs_debug, E.gs_status, E.hoxne, E.reset_set_warnings
    local display_unload, drag_flush = E.display_unload, E.drag_flush
    local weapon_lock_drop, release_implement = E.weapon_lock_drop, E.release_implement
    local strip_clear, disable_clear, sleep_held = E.strip_clear, E.disable_clear, E.sleep_held
    local keybind_apply, keybind_release, keybind_list = E.keybind_apply, E.keybind_release, E.keybind_list
    local test_hold_clear = E.test_hold_clear
    local export_restore = E.export_restore

    ------------------------------------------------------------------------------------------------
    -- SECTION 22 - JOB LIFECYCLE
    ------------------------------------------------------------------------------------------------
    -- The four entry points a job file passes through, in the order they occur: setup on
    -- load, the leftover notice shortly after, the subjob-change refresh, and teardown on
    -- unload.

    -- The lockstyle, applied on load and again after each subjob change, because the game
    -- turns lockstyle off on any job change, subjob included. A job change made at a moogle
    -- loads this file while the job menu is still open, and the subjob is often changed in
    -- that same menu seconds later. So a request waits LOCKSTYLE_SETTLE seconds, then until
    -- the client can take the command: logged in, not zoning, and out of the menu or any
    -- other event. Each request replaces the one before, so a job change followed by a
    -- subjob change sends one lockstyle, after the last of them. file_unload cancels a
    -- request still waiting, so it never fires into the next job file's load.
    local LOCKSTYLE_SETTLE = 5
    local LOCKSTYLE_POLL   = 1
    local lockstyle_pallet = nil
    local lockstyle_gen    = 0

    -- Whether the client can take /lockstyleset now. Status 4 is an event: an NPC menu, the
    -- moogle's job menu among them, or a cutscene. The player's own mob is absent while
    -- zoning.
    local function lockstyle_ready()
        local info = windower.ffxi.get_info()
        if not (info and info.logged_in) then return false end
        local p = windower.ffxi.get_player()
        if not p or p.status == 4 then return false end
        return windower.ffxi.get_mob_by_target('me') ~= nil
    end

    -- Send the lockstyle once the client is ready, polling until it is. A request that a
    -- newer one or an unload has replaced stops here. The closing gs c update auto dresses
    -- the character once the lockstyle is applied.
    local function lockstyle_try(gen)
        if gen ~= lockstyle_gen then return end
        if not lockstyle_ready() then
            coroutine.schedule(function() lockstyle_try(gen) end, LOCKSTYLE_POLL)
            return
        end
        windower.send_command('input /lockstyleset ' .. lockstyle_pallet ..
            ';input /echo Change Complete;gs c update auto')
    end

    -- Ask for the lockstyle, replacing any request still waiting. Nothing is asked before
    -- jobsetup has named a pallet.
    local function lockstyle_request()
        lockstyle_gen = lockstyle_gen + 1
        if lockstyle_pallet == nil then return end
        local gen = lockstyle_gen
        coroutine.schedule(function() lockstyle_try(gen) end, LOCKSTYLE_SETTLE)
    end

    -- Apply the job file's macro book, lockstyle and keybinds, and print the key list.
    -- The job file calls this itself, so anything raised here aborts the job file.
    function jobsetup(LockStylePallet, MacroBook, MacroSet)
        -- math.random(0) raises, and an empty Lockstyle_List would reach it. Because jobsetup
        -- runs at file scope above get_sets, that error would abort the whole job file. So
        -- an empty list warns and keeps the pallet it was given.
        if Random_Lockstyle then
            if #Lockstyle_List > 0 then
                LockStylePallet = Lockstyle_List[math.random(#Lockstyle_List)]
            else
                warn('Random_Lockstyle is on but Lockstyle_List is empty; using pallet ' ..
                    tostring(LockStylePallet) .. '.')
            end
        end

        -- One chained command, so the waits space out the game's responses. gs validate
        -- lists any set item the character does not carry.
        windower.send_command('wait 1;input /macro book ' ..
            MacroBook ..
            ';wait 1;input /macro set ' ..
            MacroSet ..
            ';gs validate')

        -- The lockstyle goes on its own path, which waits for the client to settle. The
        -- pallet is kept so a subjob change re-applies this same one.
        lockstyle_pallet = LockStylePallet
        lockstyle_request()

        -- Bind the mode keys from settings.Keybinds. keybind_apply records what it binds,
        -- and file_unload releases that record. Every key sends a self command, so each has
        -- a typeable equivalent. A second call in one load re-binds only what changed.
        keybind_apply()

        -- Print the key list on the notice channel.
        keybind_list()
    end

    -- Tell the player when the job file still defines something the engine ignores: the
    -- check_buff_JA or check_buff_SP hooks, which nothing calls, or a job mode labeled
    -- Auto Tank or Runes, which drives nothing. The root schedules this shortly after load,
    -- because it must run after the job file's main chunk has defined its functions.
    -- Called any earlier, the tests below read nil for functions that exist. It prints on
    -- notice, the one ungated channel, because nothing else reports these leftovers.
    function migration_notice()
        if check_buff_JA or check_buff_SP then
            notice('Auto Buff was removed: this job file still defines check_buff_JA or ' ..
                'check_buff_SP and nothing calls them. They can be deleted.')
        end
        if UI_Name == 'Auto Tank' or UI_Name == 'Runes'
            or UI_Name2 == 'Auto Tank' or UI_Name2 == 'Runes' then
            notice('Auto Tank and Runes were removed: this job file still names one, so ' ..
                'the mode is still shown but now drives nothing.')
        end
    end

    -- Tear the job file down: save a pending box drag, take down the display, release the
    -- keys, and give back the slots this engine holds. GearSwap calls this when the file
    -- unloads.
    --
    -- GearSwap's slot flags outlive the job file, so a slot left disabled here stays
    -- disabled for whatever file loads next. The root's load-time release of all sixteen
    -- slots covers only a next file that is this engine. Enabling a slot can make GearSwap
    -- send an item it held back while the slot was disabled.
    function file_unload(file_name)
        -- A lockstyle request still waiting is cancelled, so it never fires after this file
        -- is gone.
        lockstyle_pallet = nil
        lockstyle_request()

        -- A box drag the settle has not saved yet is saved now. It touches no box, and
        -- nothing below depends on it.
        drag_flush()
        -- The standing renderer steps aside while the status box still exists. Leaving
        -- restores the box's own background, which raises on a destroyed box.
        display_unload()
        if gs_status then
            gs_status:destroy()
        end
        if gs_debug then
            gs_debug:destroy()
        end

        -- Release the keys this load bound, from the record keybind_apply kept. The live
        -- settings table may already hold another character's keys at unload, so it is not
        -- read.
        keybind_release()

        -- A gs c test hold switched the whole job file off. Its timer would outlive this
        -- file, so the switch is put back here.
        test_hold_clear()

        -- The disable hold, then the strip hold. Each forgets its slots and enables only
        -- those no lower layer still shuts. No rebuild follows the teardown, so a hold left
        -- standing would keep its slots shut past the unload.
        disable_clear()
        strip_clear()

        -- An item use in flight and the Hoxne hold both hold slots, and neither gets another
        -- tick. Their state is dropped by hand, because their own release paths rebuild
        -- gear. The item use's slot is enabled by the name it recorded, and range and ammo
        -- are enabled for the Hoxne hold.
        local held = E.ench_held_slot
        E.ench_active      = nil
        E.ench_held_slot   = nil
        if held then enable(held) end
        hoxne.window     = false
        hoxne.recheck_at = 0
        enable('range', 'ammo')

        -- The Sleep hold, which ranks below the Hoxne hold and above every layer released
        -- after it. Its own release dresses gear and repaints the status box, which this
        -- teardown has already destroyed. So its registry is emptied by hand, and each slot
        -- it held is enabled. The registry is emptied in place, because the equip
        -- component's resolver holds this same table. Clearing a key during its own pairs
        -- walk is defined in Lua 5.1.
        for canon in pairs(sleep_held) do
            sleep_held[canon] = nil
            enable(canon)
        end

        -- Slots held for received gear. active_external_locks is a global the interface
        -- declares, so the job file sees it. Each held slot is enabled, and the global is
        -- reset to an empty table.
        if active_external_locks and next(active_external_locks) ~= nil then
            for slot, _ in pairs(active_external_locks) do
                enable(slot)
            end
            active_external_locks = {}
        end

        -- The cast in progress lets its implements go. Each slot passes to the next layer
        -- that claims it, or is enabled.
        release_implement()

        -- The lock modes, then the weapon lock. Each deregisters a slot before releasing it,
        -- so the release hands the slot to whatever still claims it, or enables it.
        if clear_locked_slots() > 0 then notice('Lock modes released (unloaded).') end
        weapon_lock_drop()

        -- GearSwap's own export_set, which the export component wrapped, so a file that
        -- loads next gets GearSwap's export back.
        export_restore()

        if user_file_unload then
            user_file_unload()
        else
            info('user_file_unload() not found!')
        end
    end

    -- Refresh everything a subjob change invalidates: the display layout, the set-name index
    -- and the empty-set warnings, then the two weapon traits, the gear and the lockstyle,
    -- which the game turned off. GearSwap calls this by name.
    --
    -- The three scheduled calls are staggered, and their order matters. Both trait checks
    -- must land before the rebuild, or the rebuild dresses the character from a stale flag.
    -- A subjob change moves Dual Wield. two_hand_check is here for a job file whose
    -- sub_job_change_custom switches the weapon mode. The calls are scheduled rather than
    -- made here because the game has not finished applying the subjob when this fires.
    function sub_job_change(new, old)
        invalidate_layout()
        invalidate_set_index()
        reset_set_warnings()
        coroutine.schedule(dual_wield_check, 2)
        coroutine.schedule(two_hand_check, 2.1)
        coroutine.schedule(equip_set_command, 2.2)
        lockstyle_request()
        if sub_job_change_custom then
            sub_job_change_custom(new, old)
        end
    end

    -- The version stamp. The root checks it against Rahvin_GS, so a stale copy of this file
    -- stops the load with an error that names it.
    return '2.1'
end
