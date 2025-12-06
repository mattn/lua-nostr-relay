local copas = require 'copas'
local socket = require 'socket'
local url = require 'socket.url'
local cjson = require 'cjson'
local pgsql = require 'pgsql'
local handshake = require 'websocket.handshake'
local sync = require 'websocket.sync'
local schnorr = require 'nostr_schnorr'
local log = require 'log'

log.usecolor = false

-- Load secrets from environment variables
local database_url = os.getenv('DATABASE_URL') or error('Environment variable DATABASE_URL is required')

-- Connect to PostgreSQL
log.info('Connecting to PostgreSQL...')
local con = assert(pgsql.connectdb(database_url))
log.info('PostgreSQL connected.')

-- Prepare schema
log.info('Preparing database schema...')
con:exec([[
CREATE OR REPLACE FUNCTION tags_to_tagvalues(jsonb) RETURNS text[]
    AS 'SELECT array_agg(t->>1) FROM (SELECT jsonb_array_elements($1) AS t)s WHERE length(t->>0) = 1;'
    LANGUAGE SQL
    IMMUTABLE
    RETURNS NULL ON NULL INPUT;

CREATE TABLE IF NOT EXISTS event (
  id text NOT NULL,
  pubkey text NOT NULL,
  created_at integer NOT NULL,
  kind integer NOT NULL,
  tags jsonb NOT NULL,
  content text NOT NULL,
  sig text NOT NULL,
  tagvalues text[] GENERATED ALWAYS AS (tags_to_tagvalues(tags)) STORED
);

CREATE UNIQUE INDEX IF NOT EXISTS ididx ON event USING btree (id text_pattern_ops);
CREATE INDEX IF NOT EXISTS pubkeyprefix ON event USING btree (pubkey text_pattern_ops);
CREATE INDEX IF NOT EXISTS timeidx ON event (created_at DESC);
CREATE INDEX IF NOT EXISTS kindidx ON event (kind);
CREATE INDEX IF NOT EXISTS kindtimeidx ON event(kind,created_at DESC);
CREATE INDEX IF NOT EXISTS arbitrarytagvalues ON event USING gin (tagvalues);
]])
log.info('Database schema prepared.')

----------------------------------------------------------------
-- JSON encoder
----------------------------------------------------------------
local function to_json(value)
    local function escape_str(s)
        local result = s:gsub('\\', '\\\\')
                        :gsub('"', '\\"')
                        :gsub('\b', '\\b')
                        :gsub('\f', '\\f')
                        :gsub('\n', '\\n')
                        :gsub('\r', '\\r')
                        :gsub('\t', '\\t')
        return '"' .. result .. '"'
    end

    local function serialize(t)
        local tp = type(t)
        if tp == 'string' then
            return escape_str(t)
        elseif tp == 'number' or tp == 'boolean' then
            return tostring(t)
        elseif tp == 'nil' then
            return 'null'
        elseif tp == 'table' then
            local is_array = true
            local max_idx = 0
            for k,_ in pairs(t) do
                if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
                    is_array = false
                else
                    max_idx = math.max(max_idx, k)
                end
            end
            if is_array then
                for i=1,max_idx do
                    if t[i] == nil then
                        is_array = false
                        break
                    end
                end
            end

            local parts = {}
            if is_array then
                for i=1,max_idx do
                    parts[#parts+1] = serialize(t[i])
                end
                return '[' .. table.concat(parts, ',') .. ']'
            else
                for k,v in pairs(t) do
                    local key = type(k)=='string' and escape_str(k) or serialize(k)
                    parts[#parts+1] = key .. ':' .. serialize(v)
                end
                return '{' .. table.concat(parts, ',') .. '}'
            end
        else
            log.error('JSON serialization failed for type: %s', tp)
            error('invalid value: ' .. tp)
        end
    end
    return serialize(value)
end

----------------------------------------------------------------
-- Subscribers table
----------------------------------------------------------------
local subscribers = {}

----------------------------------------------------------------
-- SQL builder for REQ filter
----------------------------------------------------------------
local function build_filter_query(filters)
    local where = {}
    local params = {}
    local idx = 1

    -- ids
    if filters['ids'] then
        local list = {}
        for _, id in ipairs(filters['ids']) do
            list[#list+1] = string.format('$%d', idx)
            params[#params+1] = id
            idx = idx + 1
        end
        table.insert(where, 'id = ANY(ARRAY[' .. table.concat(list, ',') .. '])')
    end

    -- authors
    if filters['authors'] then
        local list = {}
        for _, a in ipairs(filters['authors']) do
            list[#list+1] = string.format('$%d', idx)
            params[#params+1] = a
            idx = idx + 1
        end
        table.insert(where, 'pubkey = ANY(ARRAY[' .. table.concat(list, ',') .. '])')
    end

    -- kinds
    if filters['kinds'] then
        local list = {}
        for _, k in ipairs(filters['kinds']) do
            list[#list+1] = string.format('$%d', idx)
            params[#params+1] = k
            idx = idx + 1
        end
        table.insert(where, 'kind = ANY(ARRAY[' .. table.concat(list, ',') .. '])')
    end

    -- since
    if filters['since'] then
        table.insert(where, 'created_at >= $' .. idx)
        params[#params+1] = filters['since']
        idx = idx + 1
    end

    -- until
    if filters['until'] then
        table.insert(where, 'created_at <= $' .. idx)
        params[#params+1] = filters['until']
        idx = idx + 1
    end

    local sql = 'SELECT id, pubkey, created_at, kind, tags, content, sig FROM event'
    if #where > 0 then
        sql = sql .. ' WHERE ' .. table.concat(where, ' AND ')
    end
    sql = sql .. ' ORDER BY created_at DESC'

    if filters['limit'] then
        sql = sql .. ' LIMIT ' .. tonumber(filters['limit'])
    else
        sql = sql .. ' LIMIT 500'
    end

    return sql, params
end

----------------------------------------------------------------
-- Event type classification
----------------------------------------------------------------
local function is_ephemeral(kind)
    return kind >= 20000 and kind < 30000
end

local function is_replaceable(kind)
    return kind == 0 or kind == 3 or (kind >= 10000 and kind < 20000)
end

local function is_parameterized_replaceable(kind)
    return kind >= 30000 and kind < 40000
end

local function get_d_tag(tags)
    for _, tag in ipairs(tags) do
        if tag[1] == 'd' and tag[2] then
            return tag[2]
        end
    end
    return ''
end

----------------------------------------------------------------
-- Handle replaceable events
----------------------------------------------------------------
local function handle_replaceable_event(event)
    local kind = tonumber(event['kind'])

    if is_ephemeral(kind) then
        return true -- Don't store ephemeral events
    end

    if is_replaceable(kind) then
        con:execParams([[
            DELETE FROM event WHERE pubkey = $1 AND kind = $2
        ]], event['pubkey'], event['kind'])
    elseif is_parameterized_replaceable(kind) then
        local d_tag = get_d_tag(event['tags'])
        con:execParams([[
            DELETE FROM event WHERE pubkey = $1 AND kind = $2 AND tags @> $3
        ]], event['pubkey'], event['kind'], to_json({{'d', d_tag}}))
    end

    return false -- Store the event
end

----------------------------------------------------------------
-- Broadcast EVENT to all subscribers that match filters
----------------------------------------------------------------
local function broadcast_event(event)
    log.info('Broadcasting EVENT ID: %s, Kind: %d', event['id'], event['kind'])
    for ws, subs in pairs(subscribers) do
        for sub_id, info in pairs(subs) do
            local filters = info['filters']
            if not filters then goto continue end

            if filters['kinds'] then
                local ok = false
                for _,k in ipairs(filters['kinds']) do
                    if event['kind'] == k then ok = true break end
                end
                if not ok then goto continue end
            end

            if filters['authors'] then
                local ok = false
                for _,a in ipairs(filters['authors']) do
                    if event['pubkey'] == a then ok = true break end
                end
                if not ok then goto continue end
            end

            if filters['since'] and event['created_at'] < filters['since'] then goto continue end
            if filters['until'] and event['created_at'] > filters['until'] then goto continue end

            log.debug('Sending EVENT %s to subscriber %s', event['id'], sub_id)
            ws:send(to_json({'EVENT', sub_id, event}))

            ::continue::
        end
    end
end

----------------------------------------------------------------
-- Main relay handler
----------------------------------------------------------------
local function handle_websocket(ws)
    subscribers[ws] = {}

    while true do
        local message = ws:receive()
        if not message then
            subscribers[ws] = nil
            return
        end

        log.debug(string.format('Received raw message: %s', message))

        local ok, payload = pcall(cjson.decode, message)
        if not ok then 
            log.warn(string.format('Failed to decode JSON from message: %s', payload))
            goto continue 
        end

        local method = payload[1]

        ------------------------------------------------------------
        -- EVENT
        ------------------------------------------------------------
        if method == 'EVENT' then
            local ev = payload[2]

            if not schnorr.verify(ev['sig'], ev['id'], ev['pubkey']) then
                log.error(string.format('Invalid event signature %s', ev['sig']))
                ws:send(cjson.encode({'NOTICE', 'Invalid event signature'}))
                goto continue
            end

            local kind = tonumber(ev['kind'])
            local skip_storage = handle_replaceable_event(ev)

            local result = true
            if not skip_storage then
                result = con:execParams([[
                    INSERT INTO event (id, pubkey, created_at, kind, tags, content, sig)
                    VALUES ($1,$2,$3,$4,$5::jsonb,$6,$7)
                    ON CONFLICT (id) DO NOTHING
                ]],
                    ev['id'], ev['pubkey'], ev['created_at'], ev['kind'],
                    to_json(ev['tags']), ev['content'], ev['sig']
                )
            end

            if result then
                ws:send(cjson.encode({'OK', ev['id'], true, ''}))
                broadcast_event(ev)
            else
                log.error(string.format('Failed to store EVENT %s.', ev['id']))
                ws:send(cjson.encode({'OK', ev['id'], false, 'failed to insert record'}))
            end

        ------------------------------------------------------------
        -- REQ
        ------------------------------------------------------------
        elseif method == 'REQ' then
            local sub_id = payload[2]
            local filters = payload[3]

            subscribers[ws][sub_id] = { ['filters'] = filters }

            local sql, params = build_filter_query(filters)
            local res = con:execParams(sql, table.unpack(params))
            if not res then
                log.error('Failed to query records')
                ws:send(cjson.encode({'NOTICE', 'Failed  to query records'}))
                ws:send(cjson.encode({'CLOSED', sub_id, 'Failed  to query records'}))
                goto continue
            end

            for tuple,_ in res:tuples() do
                ws:send(to_json({'EVENT', sub_id, {
                    ['id'] = tuple.id,
                    ['kind'] = tonumber(tuple.kind),
                    ['pubkey'] = tuple.pubkey,
                    ['created_at'] = tonumber(tuple.created_at),
                    ['content'] = tuple.content,
                    ['tags'] = cjson.decode(tuple.tags),
                    ['sig'] = tuple.sig,
                }}))
            end

            ws:send(cjson.encode({'EOSE', sub_id}))

        ------------------------------------------------------------
        -- CLOSE
        ------------------------------------------------------------
        elseif method == 'CLOSE' then
            local sub_id = payload[2]
            if subscribers[ws] then
                subscribers[ws][sub_id] = nil
            end
        end

        ::continue::
    end
end

local function write_http_response(conn, status, content_type, body)
    local response = 'HTTP/1.1 ' .. status .. '\r\n'
    response = response .. 'Content-Type: ' .. content_type .. '\r\n'
    response = response .. 'Content-Length: ' .. (#body or 0) .. '\r\n'
    response = response .. 'Connection: close\r\n'
    response = response .. '\r\n'
    response = response .. (body or '')
    conn:send(response)
end

local function handle_nip11(conn, _)
    log.info('Handling NIP-11 (Relay Information Document) request.')
    local relay_info = {
        name = os.getenv('RELAY_NAME') or 'Lua Nostr Relay',
        description = os.getenv('RELAY_DESCRIPTION') or 'A simple Nostr relay powered by Copas/LuaSocket.',
        pubkey = os.getenv('RELAY_PUBKEY') or '',
        contact = os.getenv('RELAY_CONTACT') or '',
        supported_nips = {1, 2, 4, 9, 11, 12, 15, 16, 20, 22, 28, 33, 40},
        software = 'lua-nostr-relay',
        version = '0.0.1'
    }
    local relay_url = os.getenv('RELAY_URL')
    if relay_url and relay_url ~= '' then
        relay_info['url'] = relay_url
    end
    local relay_icon = os.getenv('RELAY_ICON')
    if relay_icon and relay_icon ~= '' then
        relay_info['icon'] = relay_icon
    end
    local body = cjson.encode(relay_info)
    write_http_response(conn, '200 OK', 'application/nostr+json', body)
end

local MIME_TYPES = {
    ['html'] = 'text/html',
    ['css']  = 'text/css',
    ['js']   = 'application/javascript',
    ['json'] = 'application/json',
    ['png']  = 'image/png',
    ['jpg']  = 'image/jpeg',
    ['jpeg'] = 'image/jpeg',
    ['gif']  = 'image/gif',
    ['svg']  = 'image/svg+xml',
    ['ico']  = 'image/x-icon',
}

local function normalize_path(path)
  path = url.unescape(path)
  path = path:gsub('\\', '/')
  path = path:gsub('/+', '/')
  path = path:gsub('/%./', '/')
  while path:find('/%.%./') do
    path = path:gsub('/[^/]+/%.%./', '/')
  end
  path = path:gsub('^%.%./', '')
  path = path:gsub('^/%.%./', '/')
  return path
end


----------------------------------------------------------------
-- handle static files
----------------------------------------------------------------
local function handle_static_file(conn, path)
    log.info(string.format('Serving static file for path: %s', path))
    local filename = path
    if filename == '/' then
        filename = '/index.html'
    end
    local file_path = 'public' .. filename
    local f = io.open(file_path, 'rb')
    if not f then
        log.warn(string.format('404 Not Found for static file: %s', file_path))
        write_http_response(conn, '404 Not Found', 'text/plain', '404 Not Found')
        return
    end

    local content = f:read('*all')
    f:close()

    local ext = string.match(filename, '%.([^%.]+)$')
    local content_type = MIME_TYPES[ext] or 'application/octet-stream'
    log.debug(string.format('Static file found and served: %s (Type: %s)', file_path, content_type))
    write_http_response(conn, '200 OK', content_type, content)
end

----------------------------------------------------------------
-- read HTTP headers
----------------------------------------------------------------
local function read_headers(sock)
    local headers = {}
    local line, err = sock:receive('*l')
    if not line or err then
        log.debug(string.format('Failed to receive initial HTTP line: %s', err))
        return nil, nil
    end

    while true do
        local header_line, err2 = sock:receive('*l')
        if not header_line then
            log.debug(string.format('Failed to receive HTTP header line: %s', err2))
            return nil, nil
        end

        if header_line:match('^%s*$') then
            break
        end

        local key, value = header_line:match('^(.-):%s*(.*)$')
        if key and value then
            local lower_key = key:lower()
            if lower_key:match('^sec%-websocket%-') then
                headers[lower_key] = value
            else
                headers[lower_key] = value:lower()
            end
        end
    end

    return headers, line
end

----------------------------------------------------------------
-- handle HTTP connection. called per clients
----------------------------------------------------------------
local function handle_connection(sock)
    local peer_name = tostring(sock:getpeername())
    log.info(string.format('New incoming connection from %s', peer_name))

    local conn = copas.wrap(sock)
    local headers, request_line = read_headers(conn)
    if not headers then
        log.warn(string.format('Connection %s closed early (no headers).', peer_name))
        sock:close()
        return
    end

    local is_websocket = headers['upgrade'] == 'websocket' and headers['connection'] == 'upgrade'
    if is_websocket then
        local upgrade_request = request_line .. '\r\n'
        for k, v in pairs(headers) do
            upgrade_request = upgrade_request .. k .. ': ' .. v .. '\r\n'
        end
        upgrade_request = upgrade_request .. '\r\n'

        local response, protocol = handshake.accept_upgrade(upgrade_request, {})
        if not response then
            log.error(string.format('WebSocket handshake failed for %s: %s', peer_name, protocol or 'Bad Request'))
            conn:send(protocol or 'HTTP/1.1 400 Bad Request\r\n\r\n')
            return
        end
        conn:send(response)

        local ws = {}
        ws.state = 'OPEN'
        ws.is_server = true
        ws.sock_send = function(_, ...)
            return conn:send(...)
        end
        ws.sock_receive = function(_, ...)
            return conn:receive(...)
        end
        ws.sock_close = function(_)
            log.debug(string.format('Closing underlying socket for %s.', peer_name))
        end
        ws = sync.extend(ws)
        handle_websocket(ws)
    elseif headers['accept'] == 'application/nostr+json' then
        log.info(string.format('Connection %s handling NIP-11.', peer_name))
        handle_nip11(conn, headers)
    else
        local _, path = request_line:match('^(%S+)%s+(%S+)')
        handle_static_file(conn, normalize_path(path))
    end
end

local server = socket.bind('0.0.0.0', 8080)
log.info('Nostr Relay listening on 0.0.0.0:8080. Starting Copas loop.')
copas.addserver(server, handle_connection)
copas.loop()
