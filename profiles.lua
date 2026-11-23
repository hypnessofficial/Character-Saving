dofile(ModPath .. "main.lua")
local LC = LoadoutCharacters

Hooks:PostHook(MultiProfileManager, "save_current", "LC_SavePreferences", function(self)
    LC:capture(self:current_profile())
end)

Hooks:PreHook(MultiProfileManager, "load_current", "LC_RestorePreferences", function(self)
    LC:restore(self:current_profile())
end)

Hooks:PostHook(MultiProfileManager, "load_current", "LC_SelectCharacter", function(self)
    LC:select()
end)
