dofile(ModPath .. "main.lua")

Hooks:PostHook(BlackMarketManager, "_update_preferred_character", "LC_ManualPreferences", function(self)
    local LC = LoadoutCharacters
    if not LC.restoring and managers.multi_profile then
        LC:capture(managers.multi_profile:current_profile())
    end
end)
