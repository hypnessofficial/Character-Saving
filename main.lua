if LoadoutCharacters then return end
LoadoutCharacters = { channel = "LC2", known = {} }
local LC = LoadoutCharacters

function LC:session()
    local s = managers.network and managers.network:session()
    if self.current_session ~= s then
        self.current_session = s
        self.known = {}
        self.next_hello = 0
    end
    return s
end

function LC:notice(message)
    log("[Loadout Characters] " .. message)
    if managers.chat and ChatManager then
        managers.chat:feed_system_message(ChatManager.GAME, "Loadout Characters: " .. message)
    end
end

function LC:capture(profile)
    if not profile or self.restoring or not managers.blackmarket then return end
    profile.lc_preferences = clone(managers.blackmarket:get_preferred_characters_list())
end

function LC:valid(character, check_owned)
    if type(character) ~= "string" then return false end
    local name = CriminalsManager.convert_old_to_new_character_workname(character)
    local characters = tweak_data.blackmarket.characters
    local data = characters[name] or (characters.locked and characters.locked[name])
    if not data then return false end
    return not check_owned or not data.dlc or managers.dlc:is_dlc_unlocked(data.dlc)
end

function LC:clean(list, check_owned)
    local result, used = {}, {}
    if type(list) ~= "table" then return result end
    for i = 1, 4 do
        local character = list[i]
        if self:valid(character, check_owned) and not used[character] then
            result[#result + 1] = character
            used[character] = true
        end
    end
    return result
end

function LC:restore(profile)
    if not profile or not managers.blackmarket then return end
    if not profile.lc_preferences then self:capture(profile) end
    local preferences = self:clean(profile.lc_preferences, true)
    if #preferences == 0 then return end
    self.restoring = true
    local bm = managers.blackmarket
    bm._global._preferred_characters = preferences
    bm:_update_preferred_character(true)
    self.restoring = false
end

function LC:send(peer_id, message)
    LuaNetworking:SendToPeer(peer_id, self.channel, json.encode(message))
end

function LC:change_phase()
    local name = game_state_machine:current_state_name()
    if name == "menu_main" then return "lobby" end
    if name ~= "ingame_waiting_for_players" then return end

    local state = game_state_machine:current_state()
    if state._starting_game_intro or state:blackscreen_started() or state:check_is_dropin() then return end
    return "briefing"
end

function LC:peer_available(peer, phase)
    if not peer or (peer.unit and alive(peer:unit())) then return false end
    if phase == "briefing" then
        return not peer:loading()
    end
    return phase == "lobby" and peer:in_lobby()
end

function LC:can_change(s)
    local phase = self:change_phase()
    if not self:peer_available(s:local_peer(), phase) then return false end
    for _, peer in pairs(s:peers()) do
        if self.known[peer:id()] ~= peer or not self:peer_available(peer, phase) then return false end
    end
    return true
end

function LC:pick(s, peer_id, preferences)
    local used = {}
    local me = s:local_peer()
    if me:id() ~= peer_id and me:character() then used[me:character()] = true end
    for _, peer in pairs(s:peers()) do
        if peer:id() ~= peer_id and peer:character() then used[peer:character()] = true end
    end
    for _, character in ipairs(preferences) do
        if not used[character] then return character end
    end
end

function LC:apply(peer_id, character)
    local s = self:session()
    local peer = s and s:peer(peer_id)
    local phase = self:change_phase()
    if not s or not self:peer_available(s:local_peer(), phase) or not self:peer_available(peer, phase) then return false end
    if not self:valid(character, false) then return false end
    if peer:character() == character then return true end
    peer:set_character(character)
    local outfit = peer:profile("outfit_string")
    local scene = managers.menu_scene
    if phase == "lobby" and outfit and outfit ~= "" and scene and scene._lobby_characters and alive(scene._lobby_characters[peer_id]) then
        scene:set_lobby_character_out_fit(peer_id, outfit, peer:rank())
    end
    local kit = managers.menu:get_menu("kit_menu")
    if outfit and outfit ~= "" and kit and kit.renderer then
        kit.renderer:set_slot_outfit(peer_id, character, outfit)
    end
    if managers.menu_component then managers.menu_component:peer_outfit_updated(peer_id) end
    log("[Loadout Characters] Peer " .. peer_id .. " -> " .. character)
    return true
end

function LC:assign(s, peer_id, preferences)
    if not s:is_host() or not self:can_change(s) then return false end
    local character = self:pick(s, peer_id, self:clean(preferences, false))
    if not character then return false end
    if not self:apply(peer_id, character) then return false end
    for _, peer in pairs(s:peers()) do
        self:send(peer:id(), { kind = "assign", peer = peer_id, character = character })
    end
    return true
end

function LC:select()
    local s = self:session()
    if not s then return end
    local preferences = self:clean(managers.blackmarket:get_preferred_characters_list(), true)
    if not self:can_change(s) then
        self:notice("Tercih kaydedildi. Lobide degisim icin herkes bu modu kullanmali ve lobi ekraninda olmali. Sonraki lobi girisinde tercih uygulanir.")
        return
    end
    if s:is_host() then
        if not self:assign(s, s:local_peer():id(), preferences) then
            self:notice("Tercih edilen karakterlerin hepsi dolu; mevcut karakter korundu.")
        end
    else
        local host = s:server_peer()
        if host then self:send(host:id(), { kind = "request", preferences = preferences }) end
    end
end

Hooks:Add("NetworkReceivedData", "LC_Network", function(sender, channel, data)
    if channel ~= LC.channel or type(data) ~= "string" or #data > 1024 then return end
    local s = LC:session()
    sender = tonumber(sender)
    local peer = s and sender and s:peer(sender)
    if not peer or peer == s:local_peer() then return end
    local ok, message = pcall(json.decode, data)
    if not ok or type(message) ~= "table" then return end
    if message.kind == "hello" or message.kind == "ack" then
        LC.known[sender] = peer
        if message.kind == "hello" then LC:send(sender, { kind = "ack" }) end
    elseif message.kind == "request" and s:is_host() and LC.known[sender] == peer then
        if not LC:assign(s, sender, message.preferences) then
            LC:send(sender, { kind = "rejected" })
        end
    elseif message.kind == "assign" and not s:is_host() and peer == s:server_peer() then
        if type(message.peer) == "number" then
            LC:apply(message.peer, message.character)
        end
    elseif message.kind == "rejected" and not s:is_host() and peer == s:server_peer() then
        LC:notice("Karakter degisimi uygulanamadi; tercihler kayitli, mevcut lobi karakteri korundu.")
    end
end)

local function update_handshake()
    local s = LC:session()
    local me = s and s:local_peer()
    if not LuaNetworking or not LC:peer_available(me, LC:change_phase()) then return end
    local t = Application:time()
    if t < (LC.next_hello or 0) then return end
    LC.next_hello = t + 2
    for _, peer in pairs(s:peers()) do
        if LC.known[peer:id()] ~= peer then LC:send(peer:id(), { kind = "hello" }) end
    end
end

Hooks:Add("MenuUpdate", "LC_Handshake", update_handshake)
Hooks:Add("GameSetupUpdate", "LC_Handshake", update_handshake)
