--------------------------------------------------------------------------
--===              RahvinGS -- GearSwap Engine for FFXI              ===--
--===       DO NOT MODIFY THIS FILE - ONLY MODIFY JOB FILES          ===--
--------------------------------------------------------------------------
-- Copyright (c) 2026 Rahvin
-- Released under the MIT License. See LICENSE.md.
--
-- See https://github.com/rahvincode for the latest version.
-- README.md covers installation, features, commands and troubleshooting.
--------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
-- COMPONENT: export -- //gs export all, grouped by bag
----------------------------------------------------------------------------------------------------
-- CONTENTS
--   GearSwap's own '//gs export all' writes every item you own into one flat sets.exported
--   table, so the file does not say which bag an item is in. This component wraps GearSwap's
--   export_set so that 'all' writes one table per bag instead, named as Windower names the
--   bag (inventory, safe2, wardrobe3...), then one table per storage slip (slip1...slip33)
--   for the items stored on it with a porter moogle. A bag or slip with nothing to export is
--   left out.
--
--   Every other export, and 'all' with compact or bgwiki, goes to GearSwap's own export_set
--   untouched. The options read here mean what they mean to GearSwap: setname, filename,
--   onlyaugmented, mini, clipboard, mainjob, mainsubjob and overwrite.
--
-- EXPORTS  E.export_restore, which lifecycle.lua calls on unload. GearSwap's export_set is
--          a global in GearSwap's own table, so it outlives the job file. The original is
--          kept in gearswap.rahvin_export_base, so a reload never wraps a wrapper, and the
--          unload puts it back for whatever file loads next.
-- LOADS    Before lifecycle. Reads nothing from E.

return function(E)
    local g = gearswap
    if type(g) ~= 'table' or type(g.export_set) ~= 'function' then
        E.export_restore = function() end
        return '2.1'
    end

    local base = g.rahvin_export_base or g.export_set
    g.rahvin_export_base = base

    -- The real windower table. The job file's own windower is a reduced copy, and the
    -- export needs the clipboard and the directory calls.
    local function export_all_by_bag(options)
        local msg, res, items, gwin = g.msg, g.res, g.items, g.windower

        local filename_index = table.find(options, set.contains+{S{'filename', 'file', 'f'}})
        local filename = filename_index ~= nil and options[filename_index+1]
        if filename_index and not filename then
            msg.addon_msg(123, 'Cannot export to named file because a filename was not provided.')
            return
        end

        local setname_index = table.find(options, set.contains+{S{'setname', 'name', 'n'}})
        local setname = setname_index ~= nil and options[setname_index+1]
        if setname_index and not setname then
            msg.addon_msg(123, 'Cannot export to named set because a set name was not provided.')
            return
        end

        local opts = S(options):map(string.lower)
        local contains_any = function(...) return not (opts * S{...}):empty() end
        local check_exclusive = function(...) return #T{...}:filter(true) > 1 end

        local noaugments = contains_any('noaugments', 'noaugs')
        local onlyaugmented = contains_any('onlyaugmented', 'onlyaugs')
        if check_exclusive(noaugments, onlyaugmented) then
            msg.addon_msg(123, 'Cannot export: "noaugments" and "onlyaugmented" are mutually exclusive.')
            return
        end

        local minify = contains_any('mini', 'minify')
        local clipboard = contains_any('copy', 'clipboard', 'c')
        local use_job_in_filename = contains_any('mainjob')
        local use_subjob_in_filename = contains_any('mainsubjob')
        if check_exclusive(filename, clipboard, use_job_in_filename, use_subjob_in_filename) then
            msg.addon_msg(123, 'Cannot export: "filename", "clipboard", "use_job_in_filename", "use_subjob_in_filename" are mutually exclusive.')
            return
        end
        local overwrite_existing = contains_any('overwrite')

        local buildmsg = 'Exporting all your items, grouped by bag'
        if noaugments then
            buildmsg = buildmsg .. ' (omitting augments)'
        elseif onlyaugmented then
            buildmsg = buildmsg .. ' (only augmented items)'
        end
        if clipboard then
            buildmsg = buildmsg .. ' to clipboard.'
        else
            buildmsg = buildmsg .. ' as a lua file.'
            if filename then
                buildmsg = buildmsg .. ' (Named: Character_'..filename..')'
            elseif use_job_in_filename then
                buildmsg = buildmsg .. ' (Naming format: Character_JOB)'
            elseif use_subjob_in_filename then
                buildmsg = buildmsg .. ' (Naming format: Character_JOB_SUB)'
            end
            if overwrite_existing then
                buildmsg = buildmsg .. ' Will overwrite existing files with same name.'
            end
        end
        msg.addon_msg(123, buildmsg)

        -- Each bag's items stay together, in Windower's bag order.
        local bag_lists, total = {}, 0
        for i = 0, #res.bags do
            local bag_name = res.bags[i].english:gsub(' ', ''):lower()
            local bag_items = items[bag_name] and g.get_item_list(items[bag_name]) or {}
            bag_lists[#bag_lists+1] = {name = bag_name, items = bag_items}
            total = total + #bag_items
        end

        -- Then each storage slip's items, as the slips lib that porter and findAll use reads
        -- them from the slip's extdata. g.require is Lua's own require; the job file's is
        -- GearSwap's include. A slip holds only which items are stored, so these never carry
        -- augments.
        local slips = g.require('slips')
        local slip_items = slips.get_player_items()
        for n, slip_id in ipairs(slips.storages) do
            local list = {}
            for _, id in ipairs(slip_items[slip_id]) do
                local item = res.items[id]
                if item then
                    local slot_id = item.slots and next(item.slots)
                    list[#list+1] = {
                        name = item[g.language],
                        slot = slot_id and (res.slots[slot_id].english:gsub(' ', '_'):lower()) or 'item',
                    }
                end
            end
            bag_lists[#bag_lists+1] = {name = 'slip' .. n, items = list}
            total = total + #list
        end

        if total == 0 then
            msg.addon_msg(123, 'There is nothing to export.')
            return
        end

        local newline = minify and '' or '\n'
        local output
        if setname then
            output = 'sets["' .. setname .. '"] = {' .. newline
        else
            output = 'sets.exported = {' .. newline
        end

        for _, bag in ipairs(bag_lists) do
            local lines = ''
            for _, v in ipairs(bag.items) do
                if v.augments and not noaugments then
                    lines = lines .. ('        %s={ name="%s", augments={%s}},'):format(v.slot, v.name, v.augments) .. newline
                elseif not onlyaugmented then
                    lines = lines .. ('        %s="%s",'):format(v.slot, v.name) .. newline
                end
            end
            if lines ~= '' then
                output = output .. ('    %s = {'):format(bag.name) .. newline .. lines .. '    },' .. newline
            end
        end

        output = output .. '}'

        if clipboard then
            gwin.copy_to_clipboard(output)
            return
        end

        if not gwin.dir_exists(gwin.addon_path .. 'data/export') then
            gwin.create_dir(gwin.addon_path .. 'data/export')
        end

        local path = gwin.addon_path .. 'data/export/' .. player.name
        if use_job_in_filename then
            path = path .. '_' .. gwin.ffxi.get_player().main_job
        elseif use_subjob_in_filename then
            path = path .. '_' .. gwin.ffxi.get_player().main_job .. '_' .. gwin.ffxi.get_player().sub_job
        elseif filename then
            path = path .. '_' .. filename
        else
            path = path .. os.date(' %Y-%m-%d %H-%M-%S')
        end
        if (not overwrite_existing) and gwin.file_exists(path .. '.lua') then
            path = path .. ' ' .. os.clock()
        end

        local f = io.open(path .. '.lua', 'w+')
        f:write(output)
        f:close()
    end

    -- 'all' without compact or bgwiki is grouped by bag. Everything else is GearSwap's.
    g.export_set = function(options)
        local opts = S(options):map(string.lower)
        if opts:contains('all') and not opts:contains('compact') and not opts:contains('bgwiki') then
            return export_all_by_bag(options)
        end
        return base(options)
    end

    E.export_restore = function()
        g.export_set = base
    end

    return '2.1'
end
