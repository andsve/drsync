if DRSYNC then
    print("DRSYNC already initialised")
    return DRSYNC
end
DRSYNC = {}

-- update random seed
math.randomseed(os.time())

DRSYNC.ID_LENGTH = 5
DRSYNC.MAKE_ID = function()
    local characters       = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    local result = ""

    for i=1,DRSYNC.ID_LENGTH do
        local t = math.random(#characters)
        result = result .. string.sub(characters, t, t+1)
    end
    
    return result
end
--print("made id:", DRSYNC.MAKE_ID())
DRSYNC.CLIENT_ID = DRSYNC.MAKE_ID()
DRSYNC.LOCAL_IDS = {}
DRSYNC.LOCAL_FACTORY_URLS = {}
DRSYNC.REMOTE_IDS = {}
DRSYNC.REMOTE_CLIENTS = {}

DRSYNC._factory_create = factory.create
factory.create = function(url, position, rotation, properties, scale)
    -- todo verify url is absolue path

    -- actually create the new gameobject
    local obj = DRSYNC._factory_create(url, position, rotation, properties, scale)

    -- generate new local id
    local id = "["..DRSYNC.CLIENT_ID.."]"..DRSYNC.MAKE_ID()
    DRSYNC.LOCAL_IDS[id] = obj
    DRSYNC.LOCAL_FACTORY_URLS[id] = url

    -- notify new gameobject about its DRSYNC id
    msg.post(obj, "DRSYNC_LOCAL", {id = id, factory_url = url})

    return obj
end

DRSYNC.ON_MESSAGE = function(data)
    data = json.decode(data)
    local message_id = data.message_id
    local message = data.message

    if message_id == "DRSYNC_SPAWN" then
        if message.to and message.to == DRSYNC.CLIENT_ID then
            print("ignoring spawn!")
        end
        
        print("DRSYNC GOT: " .. message_id)
        local p = vmath.vector3(tonumber(message.position.x), tonumber(message.position.y), tonumber(message.position.z))
        print("message.url:", message.url)
        local obj = DRSYNC._factory_create(message.url, p)
        DRSYNC.REMOTE_IDS[message.id] = obj
        msg.post(obj, "DRSYNC_REMOTE", {id = message.id, factory_url = message.url})
    elseif message_id == "DRSYNC_PROP" then
        local id = message.id
        if DRSYNC.REMOTE_IDS[id] then
            msg.post(DRSYNC.REMOTE_IDS[id], "DRSYNC_PROP", message)
        end
        
    elseif message_id == "DRSYNC_START" then
        -- someone just started their session
        print("someone just connected: " .. message.from)
        -- make sure its not us.. lol
        if message.from ~= DRSYNC.CLIENT_ID then
            -- just check we haven't seen this client before
            if not DRSYNC.REMOTE_CLIENTS[message.from] then
                -- keep track of who connected
                DRSYNC.REMOTE_CLIENTS[message.from] = message.from

                -- notify new client that we are here as well
                DRSYNC.please_start_session()

                DRSYNC.ON_NEW_CLIENT(message.from, message.data)

                -- make sure the new client knows about our locally created objects
                -- DRSYNC.LOCAL_IDS[id] = obj
                for k,v in pairs(DRSYNC.LOCAL_IDS) do
                    msg.post(v, "DRSYNC_LATE_SPAWN", {to = message.from, id = k, factory_url = DRSYNC.LOCAL_FACTORY_URLS[k]})
                end
            end
        else
            print("this is us connecting")
        end
        
    elseif message_id == "DRSYNC_TELL" then
        
        if not message.to or message.to == DRSYNC.CLIENT_ID then
            DRSYNC.ON_TOLD(message.from, message.data)
        end
        
    else
        --pprint(message)
        error("DRSYNC message_id '" .. message_id .. "' not implemented")
    end
end

DRSYNC.ON_NEW_CLIENT = function(client_id)
    -- overwrite this function if you want to know if someone connects!
end

DRSYNC.ON_TOLD = function(from, data)
    error("we were told but no ON_TOLD function has been implemented!")
end

DRSYNC._SEND_MESSAGE = function(message_id, message)
    DRSYNC.SEND_MESSAGE(json.encode({message_id = message_id, message = message}))
end

DRSYNC.SEND_MESSAGE = function(data)
    error("DRSYNC.SEND_MESSAGE needs to be supplied!")
end

local function is_defold_vector(v)
    local is_vec4 = pcall(function()
        return v.w
    end)
    if is_vec4 then
        return "vec4"
    end
    local is_vec3 = pcall(function()
        return v.z
    end)
    if is_vec3 then
        return "vec3"
    end

    return "unknown"
end

DRSYNC.SYNCED_PROPS = {}
DRSYNC.LOCALY_UPDATED_PROPS = {}
DRSYNC.please_sync = function(prop, update_rate, interpolate)
    local url = msg.url()
    local fragment = url.fragment
    url.fragment = nil

    -- prefetch type
    --print("PROP TYPE:", type(go.get(url, prop)))
    local typestr = type(go.get(url, prop))
    local prop_type = typestr
    local current_value = go.get(url, prop)
    --pprint(debug.getmetatable(go.get(url, prop)))
    
    if typestr == "userdata" then
        -- try to figure out what type it is
        prop_type = is_defold_vector(current_value)
    end

    if prop_type == "unknown" then
        error("trying to sync unknown property type")
    end

    url = hash_to_hex(url.socket)..hash_to_hex(url.path)
    
    
    if not DRSYNC.SYNCED_PROPS[url] then
        DRSYNC.SYNCED_PROPS[url] = {}
    end

    update_rate = update_rate or 60
    interpolate = interpolate or false

    table.insert(DRSYNC.SYNCED_PROPS[url], {
        prop = prop,
        prop_type = prop_type,
        prev_value = current_value,
        update_rate = update_rate,
        update_tick = 0,
        interpolate = interpolate,
        time = 0,
    })
end

DRSYNC.please_tell_everyone = function(data)
    DRSYNC._SEND_MESSAGE("DRSYNC_TELL", {
        to = nil,
        from = DRSYNC.CLIENT_ID,
        data = data
    })
end

DRSYNC.please_tell_client = function(client_id, data)
    DRSYNC._SEND_MESSAGE("DRSYNC_TELL", {
        to = client_id,
        from = DRSYNC.CLIENT_ID,
        data = data
    })
end

DRSYNC.STORED_INITIAL_DATA = nil
DRSYNC.please_start_session = function(initial_data)
    if initial_data then
        DRSYNC.STORED_INITIAL_DATA = initial_data
    end
    initial_data = DRSYNC.STORED_INITIAL_DATA
    DRSYNC._SEND_MESSAGE("DRSYNC_START", {
        from = DRSYNC.CLIENT_ID,
        data = initial_data
    })
end

return DRSYNC