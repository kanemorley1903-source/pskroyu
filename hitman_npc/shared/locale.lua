Locales = Locales or {}

-- Translate a key. Extra arguments are passed to string.format.
function L(key, ...)
    local lang = Locales[Config.Locale] or {}
    local fallback = Locales.en or {}
    local str = lang[key] or fallback[key] or key
    if select('#', ...) > 0 then
        local ok, res = pcall(string.format, str, ...)
        if ok then return res end
    end
    return str
end

-- Every key that starts with "ui_" (sent to the NUI so the page can be translated).
function GetUIStrings()
    local out = {}
    local fallback = Locales.en or {}
    local lang = Locales[Config.Locale] or {}
    for k, v in pairs(fallback) do
        if k:sub(1, 3) == 'ui_' then out[k] = v end
    end
    for k, v in pairs(lang) do
        if k:sub(1, 3) == 'ui_' then out[k] = v end
    end
    return out
end

-- 12345 -> "$12,345"
function Money(amount)
    amount = math.floor(tonumber(amount) or 0)
    local negative = amount < 0
    local digits = tostring(math.abs(amount))
    local out = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return (negative and '-' or '') .. (Config.Currency or '$') .. out
end

-- 125 -> "2:05"
function Duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format('%d:%02d', seconds // 60, seconds % 60)
end
