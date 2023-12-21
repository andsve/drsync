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
DRSYNC.REMOTE_IDS = {}
DRSYNC._factory_create = factory.create
factory.create = function(url, position, rotation, properties, scale)
    -- todo verify url is absolue path

    -- actually create the new gameobject
    local obj = DRSYNC._factory_create(url, position, rotation, properties, scale)

    -- generate new local id
    local id = "["..DRSYNC.CLIENT_ID.."]"..DRSYNC.MAKE_ID()
    DRSYNC.LOCAL_IDS[id] = obj

    -- notify new gameobject about its DRSYNC id
    msg.post(obj, "DRSYNC_LOCAL", {id = id, factory_url = url})

    return obj
end

DRSYNC.ON_MESSAGE = function(data)
    data = json.decode(data)
    local message_id = data.message_id
    local message = data.message

    if message_id == "DRSYNC_SPAWN" then
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
    end
end

DRSYNC._SEND_MESSAGE = function(message_id, message)
    DRSYNC.SEND_MESSAGE(json.encode({message_id = message_id, message = message}))    
end

DRSYNC.SEND_MESSAGE = function(data)
    print("DRSYNC.SEND_MESSAGE needs to be supplied!")
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
        interpolate = interpolate
    })
end

return DRSYNC