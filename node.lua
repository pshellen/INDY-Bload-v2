-- Copyright (C) 2015, 2017 Florian Wesch <fw@dividuum.de>
-- All Rights Reserved.
--
-- Unauthorized copying of this file, via any medium is
-- strictly prohibited. Proprietary and confidential.

util.no_globals()

local json = require "json"

local scissors = sys.get_ext "scissors"

local st
local image_files = {}
local loaded_images = {}
local rotation = 0
local bload_threshold = 3600
local bload_fallback = resource.load_image "empty.png"
local screen_idx, screen_cnt
local logo
local black = resource.create_colored_texture(0, 0, 0, 1)

local function mipmapped_image(filename)
    return resource.load_image(filename, true)
end
util.loaders.jpg = mipmapped_image
util.loaders.png = mipmapped_image

local badge_3d = mipmapped_image("3D.png")
local badge_green = resource.create_colored_texture(0.02, 0.55, 0.18, 1)
local badge_blue = resource.create_colored_texture(2/255, 122/255, 193/255, 1)

local res = util.resource_loader({
    "font.ttf";
    "times.ttf";
    "label.ttf";
    "threed.png";
    "showtime.png";
}, {})

local bgfill = resource.create_colored_texture(0,0,0,1)
local fgfill = resource.create_colored_texture(.1,.1,.1,1)
local infofill = resource.create_colored_texture(1,1,1,1)

local strike_through = resource.create_colored_texture(1,1,1,1)
local strike_through_color = resource.create_shader[[
    uniform sampler2D Texture;
    varying vec2 TexCoord;
    uniform vec4 color;
    void main() {
        gl_FragColor = texture2D(Texture, TexCoord) * color;
    }
]]

local base_time = N.base_time or 0
local bload_age = 0

-- Board settings (set from config.json further down)
local board_style = "premium"
local brand = "flagship"
local show_header = true
local wide_threshold = 8 -- movies with more showtimes than this get a double-wide card (0 = off)
local brand_logo -- logo drawn in the header strip and empty cells
local show_reserved = true
local te_logo -- Theater Ears logo image (white on transparent)
local show_icons = {} -- per-showtime badge art: ["3D"], OC, SENSORY

local function current_offset()
    local time = base_time + sys.now()
    local offset = (time % 86400) / 60
    return offset
end

util.data_mapper{
    ["clock/set"] = function(time)
        print("time set to", time)
        base_time = tonumber(time) - sys.now()
        N.base_time = base_time
        print("CURRENT OFFSET is now", current_offset())
    end;
}

local bload = (function()
    local display_cfg = {
        movies_per_page = 4,
        page_interval = 5,
        hide_poster = false,
        display_badges = true,
        show_logo = false,
    }
    local data_source = "bload"
    local function strip(s)
        return s:match "^%s*(.-)%s*$"
    end

    -- Sometimes the name has another numerical suffix. Throw that away.
    local function strip_name(s)
        return strip(s:sub(1, 29))
    end

    local function hhmm(s)
        local hour, minute = s:match("(..)(..)")
        local hour, minute = tonumber(hour), tonumber(minute)
        local function mil2ampm(hour, minute)
            local suffix = hour < 12 and "am" or ""
            return ("%d:%02d%s"):format((hour-1) % 12 +1, minute, suffix)
        end
        return {
            hour = hour,
            minute = minute,
            offset = hour * 60 + minute,
            string = mil2ampm(hour, minute),
        }
    end
    local function tobool(str)
        return tonumber(str) == 1
    end

    local function convert(names, fixups, ...)
        local cols = {...}
        local out = {}
        for i = 1, #fixups do
            out[names[i]] = fixups[i](cols[i])
        end
        return out
    end

    local sorted_movies = {}
    local movies_on_screen = 1
    local bload, date

    local function parse_bload()
        if not date or not bload then
            print("cannot parse yet. no bload or no date")
            return
        end

        local movies = {}
        for line in bload:gmatch("[^\r\n]+") do
            -- "123456789012345678901234567890123456789012345678901234567890123456789012345"
            -- "1111111122 33 4444 555  6666 7777 8 9999AAAAAAAAAAAAAAAAAAAAAAAAAAAAA     B"
            -- "06/25/151  1  1320 94   10   231  0     Inside Out                        0"

            local single_day = true
            local row

            if single_day then 
                row = convert(
                    {"screen", "show",   "showtime", "runtime", "sold",   "seats",  "threed", "mpaa", "name"},
                    {strip,    tonumber, hhmm,       tonumber,  tonumber, tonumber, tobool,   strip,  strip},
                    line:match("(..) (..) (....) (...)  (....) (....) (.) (....)(.*)")
                )
            else
                row = convert(
                    {"date","screen", "show",   "showtime", "runtime", "sold",   "seats",  "threed", "mpaa", "name"},
                    {strip, strip,    tonumber, hhmm,       tonumber,  tonumber, tonumber, tobool,   strip,  strip_name},
                    line:match("(........)(..) (..) (....) (...)  (....) (....) (.) (....)(.*)")
                )
            end

            if single_day or row.date == date then
                if not movies[row.name] then
                    movies[row.name] = {}
                end

                local movie = movies[row.name]
                movie[#movie+1] = {
                    mpaa = row.mpaa,
                    threed = row.threed,
                    showtime = row.showtime,
                    seats = row.seats,
                    sold = row.sold,
                }
            end
        end

        local pre_sorted_movies = {}
        for name, shows in pairs(movies) do
            table.sort(shows, function(a, b)
                return a.showtime.offset < b.showtime.offset
            end)
            local mpaa = shows[1].mpaa
            local threed = shows[1].threed
            pre_sorted_movies[#pre_sorted_movies+1] = {
                name = name,
                image = name:gsub('[^%w]', ''):lower(),     
                mpaa = mpaa,
                threed = threed,
                shows = shows,
            }
        end
        table.sort(pre_sorted_movies, function(a, b)
            return a.name < b.name
        end)

        movies_on_screen = math.ceil(
            #pre_sorted_movies / screen_cnt
        )
        local split_start = movies_on_screen * (screen_idx - 1) + 1
        local split_end = split_start + movies_on_screen - 1
        print(#pre_sorted_movies, split_start, split_end)

        sorted_movies = {}
        for idx, movie in ipairs(pre_sorted_movies) do
            if idx >= split_start and idx <= split_end then
                sorted_movies[#sorted_movies+1] = movie
            end
        end

        -- pp(sorted_movies)
    end

    local function normalize_show(show)
        local normalized
        if show.showtime then
            normalized = show
        else
            normalized = {
                showtime = {
                    hour = show.hour,
                    minute = show.minute,
                    offset = show.offset,
                    string = show.string,
                },
                seats = show.seats or 100,
                sold = show.sold or 0,
                past = show.past,
            }
        end
        if show.threed ~= nil then normalized.threed = show.threed end
        if show.sensory ~= nil then normalized.sensory = show.sensory end
        if show.open_caption ~= nil then normalized.open_caption = show.open_caption end
        return normalized
    end

    local function set_indy_showings(data)
        sorted_movies = {}
        for _, movie in ipairs(data.movies or {}) do
            local shows = {}
            for _, show in ipairs(movie.shows or {}) do
                shows[#shows+1] = normalize_show(show)
            end
            sorted_movies[#sorted_movies+1] = {
                name = movie.name,
                image = movie.image or movie.name:gsub('[^%w]', ''):lower(),
                mpaa = movie.mpaa or "",
                badges = movie.badges or {},
                shows = shows,
            }
        end
        movies_on_screen = #sorted_movies
        display_cfg.movies_per_page = data.movies_per_page or 4
        display_cfg.page_interval = data.page_interval or 5
        display_cfg.hide_poster = data.hide_poster ~= false
        display_cfg.display_badges = data.display_badges ~= false
        display_cfg.show_logo = data.show_logo == true
        data_source = "indy"
    end

    local function get_paged_movies()
        local per_page = display_cfg.movies_per_page or 4
        if data_source ~= "indy" or #sorted_movies <= per_page then
            return sorted_movies, math.max(#sorted_movies, 1)
        end
        local pages = math.max(1, math.ceil(#sorted_movies / per_page))
        local interval = math.max(1, display_cfg.page_interval or 5)
        local page = math.floor(sys.now() / interval) % pages
        local start_idx = page * per_page + 1
        local out = {}
        for i = start_idx, math.min(start_idx + per_page - 1, #sorted_movies) do
            out[#out+1] = sorted_movies[i]
        end
        return out, per_page
    end

    local function get_display_cfg()
        return display_cfg
    end

    local function get_data_source()
        return data_source
    end

    local function get_sorted_movies()
        return sorted_movies
    end

    local function set_bload(new_bload)
        if new_bload == bload then return end
        bload = new_bload
        return parse_bload()
    end

    local function set_date(new_date)
        if new_date == date then return end
        date = new_date
        return parse_bload()
    end

    local function get_movies_on_screen()
        return movies_on_screen
    end

    return {
        set_bload = set_bload;
        set_date = set_date;
        set_indy_showings = set_indy_showings;
        force_parse = parse_bload;

        get_sorted_movies = get_sorted_movies;
        get_paged_movies = get_paged_movies;
        get_movies_on_screen = get_movies_on_screen;
        get_display_cfg = get_display_cfg;
        get_data_source = get_data_source;
    }
end)()

util.json_watch("config.json", function(config)
    image_files = {}
    loaded_images = {}

    gl.setup(1920, 1080)

    rotation = config.rotation or 0
    local setup_rotation = config.__metadata.device_data.rotation
    if setup_rotation and setup_rotation ~= -1 then
        rotation = setup_rotation
    end

    st = util.screen_transform(rotation)

    for _, image in ipairs(config.images) do
        -- key = file name without folder, extension and punctuation:
        -- "logos/Avengers Endgame.png" -> "avengersendgame"
        local fname = image.file.filename or image.file.asset_name or ""
        fname = fname:gsub("^.*[/\\]", "")
        local key = fname:lower():gsub('%.%w+$', ''):gsub('[^%w]', '')
        if key ~= "" then
            image_files[key] = resource.open_file(image.file.asset_name)
            print("title art: " .. fname .. " -> key '" .. key .. "'")
        end
    end

    board_style = config.board_style or "premium"
    brand = config.brand or "flagship"
    show_header = config.show_header ~= false
    wide_threshold = tonumber(config.wide_threshold) or 8
    local brand_logo_name = brand == "harbor_east"
        and ((config.harbor_east_logo and config.harbor_east_logo.asset_name) or "harbor-east.png")
        or ((config.logo and config.logo.asset_name) or "flagship.png")
    local okb, imgb = pcall(resource.load_image, {file = brand_logo_name, mipmap = true})
    brand_logo = okb and imgb or nil
    show_reserved = config.show_reserved_seating ~= false
    local te_name = (config.theater_ears_logo and config.theater_ears_logo.asset_name) or "theater-ears.png"
    local ok, img = pcall(resource.load_image, {file = te_name, mipmap = true})
    te_logo = ok and img or nil
    show_icons = {}
    for tag, opt in pairs{["3D"] = {"threed_icon", "badge-3d.png"},
                          OC = {"open_caption_icon", "open-caption.png"},
                          SENSORY = {"sensory_icon", "badge-sf.png"}} do
        local name = (config[opt[1]] and config[opt[1]].asset_name) or opt[2]
        local ok_i, img_i = pcall(resource.load_image, {file = name, mipmap = true})
        if ok_i then show_icons[tag] = img_i end
    end

    bload_threshold = config.bload_threshold
    bload_fallback = resource.load_image(config.bload_fallback.asset_name)

    local split = config.__metadata.device_data.split
    if split then
        screen_idx = split[1]
        screen_cnt = split[2]
    else
        screen_idx = 1
        screen_cnt = 1
    end

    logo = resource.load_image{
        file = config.logo.asset_name,
        mipmap = true,
    }

    bload.force_parse()

    node.gc()
end)

util.file_watch("BLOAD.txt", bload.set_bload)

util.json_watch("showings.json", function(data)
    bload.set_indy_showings(data)
end)

util.data_mapper{
    ["date/set"] = function(date)
        print("date set to", date)
        bload.set_date(date)
    end;
    ["source/set"] = function(src)
        if src == "indy" then
            bload_age = 0
        end
    end;
}

local function layouter(rotation, num_shows)
    if rotation == 90 or rotation == 270 then
        if num_shows <= 3 then
            return 1, 3
        elseif num_shows <= 6 then
            return 2, 3 -- no empty bottom row for 5-6 movies
        elseif num_shows <= 8 then
            return 2, 4
        elseif num_shows <= 10 then
            return 2, 5
        elseif num_shows <= 15 then
            return 3, 5
        else
            return 3, 6
        end
    else
        if num_shows <= 4 then
            return 2, 2
        elseif num_shows <= 6 then
            return 3, 2
        elseif num_shows <= 9 then
            return 3, 3
        elseif num_shows <= 12 then
            return 4, 3
        elseif num_shows <= 16 then
            return 4, 4
        else
            return 5, 4
        end
    end
end

local function visible_movie_badges(badges)
    local visible = {}

    for _, badge in ipairs(badges or {}) do
        local text = tostring(badge or "")

        -- Keep the badge information, but remove auditorium labels
        -- such as "Screen 5", "Screen 9", etc.
        text = text:gsub("[Ss][Cc][Rr][Ee][Ee][Nn]%s*%d+", "")

        -- Clean up extra whitespace left behind.
        text = text:gsub("%s+", " ")
        text = text:match("^%s*(.-)%s*$")

        if text ~= "" then
            visible[#visible + 1] = text
        end
    end

    return visible
end

-- Board styling ---------------------------------------------------------
-- Three looks, picked with the "Board style" setting:
--   refined  - the original layout (white rating bar, times below), cleaned up
--   minimal  - no boxes: title art, one quiet info line, very large times
--   premium  - title art glow, rounded brand-blue frame, gold next showing

local function tex(r, g, b, a) return resource.create_colored_texture(r, g, b, a or 1) end
local T = {
    black = tex(0, 0, 0),
    white = tex(1, 1, 1),
    info_white = tex(0.95, 0.95, 0.95),
    divider = tex(0.17, 0.17, 0.19),
    blue = tex(2/255, 122/255, 193/255),
    gold = tex(0.91, 0.77, 0.42),
    clear = tex(0, 0, 0, 0),
}
local grad_times = resource.load_image "grad-times.png"
local grad_card = resource.load_image "grad-card.png"
local grad_premium = resource.load_image "grad-premium.png"

local shaders = {}
for _, name in ipairs{"keyblack", "glow", "frame"} do
    util.file_watch(name .. ".glsl", function(raw)
        shaders[name] = resource.create_shader(raw)
    end)
end

local STYLES = {
    refined = {
        gap = 4, inset = 0,
        logo = 0.60, info = 0.14, times = 0.26,
        time_color = {1, 1, 1}, other_color = {0.86, 0.86, 0.86},
        next_mark = "underline", mark_tex = T.blue,
    },
    minimal = {
        gap = 6, inset = 0,
        logo = 0.56, info = 0.13, times = 0.31,
        time_color = {1, 1, 1}, other_color = {0.62, 0.64, 0.68},
        next_mark = "underline", mark_tex = T.blue,
    },
    premium = {
        gap = 10, inset = 14,
        logo = 0.56, info = 0.14, times = 0.30,
        time_color = {1, 1, 1}, other_color = {0.92, 0.92, 0.92},
        next_mark = "underline", mark_tex = T.blue,
    },
}

-- Brand palettes ------------------------------------------------------------
-- Flagship: Flagship blue + red with silver (no gold).
-- Harbor East: taken from harboreastcinemas.com - deep navy, royal blue, white.
local BRANDS = {
    flagship = {
        card = grad_premium,
        header = resource.load_image "grad-header-fs.png",
        header_line = tex(0/255, 121/255, 193/255),
        frame = {0/255, 121/255, 193/255, 0.95},
        underline = tex(237/255, 28/255, 36/255),
        rule = tex(237/255, 28/255, 36/255),
        next = {1, 1, 1},
        other = {0.78, 0.80, 0.84},
        rating = {0.80, 0.83, 0.88},
        text = {0.80, 0.83, 0.88},
        clock = {0.80, 0.83, 0.88},
    },
    harbor_east = {
        card = resource.load_image "grad-premium-he.png",
        header = resource.load_image "grad-header-he.png",
        header_line = tex(32/255, 79/255, 199/255),
        frame = {32/255, 79/255, 199/255, 0.95},
        underline = tex(0.36, 0.56, 1.0), -- brighter royal blue so it reads on navy
        rule = tex(32/255, 79/255, 199/255),
        next = {1, 1, 1},
        other = {0.70, 0.76, 0.90},
        rating = {0.69, 0.77, 0.96},
        text = {0.80, 0.85, 0.96},
        clock = {0.85, 0.89, 0.98},
    },
}

local function B()
    return BRANDS[brand] or BRANDS.flagship
end

local function display_time(showtime)
    local h, m = showtime.hour or 0, showtime.minute or 0
    return ("%d:%02d"):format((h - 1) % 12 + 1, m), h < 12 and "AM" or "PM"
end

local SUFFIX_SCALE = 0.62

local function time_width(font, hm, suffix, size)
    return font:width(hm, size) + font:width(" " .. suffix, size * SUFFIX_SCALE)
end

local function fit_size(font, text, size, max_w, min_size)
    min_size = min_size or 12
    while size > min_size and font:width(text, size) > max_w do
        size = size - 1
    end
    return size
end

local function centered(font, text, size, cx, y, r, g, b, a)
    local w = font:width(text, size)
    font:write(cx - w / 2, y, text, size, r, g, b, a or 1)
    return w
end

local function feature_list(movie, cfg)
    local out = {}
    if not cfg.display_badges then
        return out
    end
    for _, badge in ipairs(visible_movie_badges(movie.badges)) do
        local lower = badge:lower()
        if lower:find("reserved seat", 1, true) then
            if show_reserved then
                out[#out+1] = {text = badge:upper()}
            end
        elseif lower:find("theater ears", 1, true) or lower:find("theatre ears", 1, true) then
            if te_logo then
                out[#out+1] = {logo = te_logo}
            else
                out[#out+1] = {text = badge:upper()}
            end
        else
            out[#out+1] = {text = badge:upper()}
        end
    end
    return out
end

-- One centered row: rating, then features separated by dots. The Theater
-- Ears logo is drawn larger than the text so it stays recognizable.
-- colors: {rating = {r,g,b}, text = {r,g,b}, logo_tint = {r,g,b} or nil}
local function draw_info_row(movie, cfg, x, y, w, h, colors, rating_scale)
    local rating = movie.mpaa or ""
    local items = feature_list(movie, cfg)
    local sep = "  \194\183  "

    local function measure(size)
        local rsize = size * (rating_scale or 1.25)
        local logo_h = math.min(h * 0.86, size * 2.6)
        local total = res.times:width(rating, rsize)
        for i, item in ipairs(items) do
            if i > 1 or rating ~= "" then
                total = total + res.label:width(sep, size)
            end
            if item.logo then
                local lw, lh = item.logo:size()
                total = total + logo_h * lw / math.max(lh, 1)
            else
                total = total + res.label:width(item.text, size)
            end
        end
        return total, rsize, logo_h
    end

    local size = math.floor(h * 0.36)
    while size > 10 and measure(size) > w - 24 do
        size = size - 1
    end
    local total, rsize, logo_h = measure(size)
    local cx = x + (w - total) / 2
    local mid = y + h / 2

    local rc = colors.rating
    if rating ~= "" then
        res.times:write(cx, mid - rsize / 2, rating, rsize, rc[1], rc[2], rc[3], 1)
        cx = cx + res.times:width(rating, rsize)
    end
    local tc = colors.text
    for i, item in ipairs(items) do
        if i > 1 or rating ~= "" then
            res.label:write(cx, mid - size / 2, sep, size, tc[1], tc[2], tc[3], 1)
            cx = cx + res.label:width(sep, size)
        end
        if item.logo then
            local lw, lh = item.logo:size()
            local dw = logo_h * lw / math.max(lh, 1)
            local tint = colors.logo_tint
            if tint then
                strike_through_color:use{color = {tint[1], tint[2], tint[3], 1}}
            end
            item.logo:draw(cx, mid - logo_h / 2, cx + dw, mid + logo_h / 2)
            if tint then
                strike_through_color:deactivate()
            end
            cx = cx + dw
        else
            res.label:write(cx, mid - size / 2, item.text, size, tc[1], tc[2], tc[3], 1)
            cx = cx + res.label:width(item.text, size)
        end
    end
end

-- Info area, one variant per style -----------------------------------------
local function info_refined(movie, cfg, x, y, w, h)
    T.info_white:draw(x, y, x + w, y + h)
    draw_info_row(movie, cfg, x, y, w, h, {
        rating = {0.05, 0.05, 0.06},
        text = {0.30, 0.31, 0.34},
        logo_tint = {0.10, 0.10, 0.12},
    })
end

local function info_minimal(movie, cfg, x, y, w, h)
    draw_info_row(movie, cfg, x, y, w, h, {
        rating = {1, 1, 1},
        text = {0.66, 0.69, 0.74},
    }, 1.1)
end

local function info_premium(movie, cfg, x, y, w, h)
    local b = B()
    draw_info_row(movie, cfg, x, y, w, h, {
        rating = b.rating,
        text = b.text,
    })
end

-- Showtimes ------------------------------------------------------------------
local function time_grid(n)
    if n <= 1 then return 1, 1
    elseif n <= 2 then return 2, 1
    elseif n <= 3 then return 3, 1
    elseif n <= 6 then return 3, 2
    elseif n <= 9 then return 3, 3
    elseif n <= 12 then return 4, 3
    elseif n <= 16 then return 4, 4
    elseif n <= 20 then return 5, 4
    else return 6, 5 end
end

-- For roomy areas (wide cards): try every column count and keep the one
-- that allows the largest time text.
local function best_grid(n, w, h)
    local per_size = time_width(res.times, "10:45", "PM", 1) + 0.5
    local best_cols, best_size = 1, 0
    for cols = 1, math.min(n, 8) do
        local rows = math.ceil(n / cols)
        local size = math.min((h / rows) * 0.70, (w / cols) * 0.88 / per_size)
        if size > best_size then
            best_cols, best_size = cols, size
        end
    end
    return best_cols, math.ceil(n / best_cols)
end

local function draw_times(movie, cfg, st, x, y, w, h, now, roomy)
    local font = res.times
    local shows = movie.shows
    local cols, rows
    if roomy then
        cols, rows = best_grid(#shows, w, h)
    else
        cols, rows = time_grid(#shows)
    end
    local slot_w, slot_h = w / cols, h / rows
    local gap = 8
    local icon_h = math.floor(slot_h * 0.38)
    local icon_w = math.floor(icon_h * 920 / 716)
    local tag_size = math.floor(slot_h * 0.17)

    local function started_at(show)
        return now > show.showtime.offset + 15 or show.past
    end
    local function tags_for(show)
        local tags = {}
        if cfg.display_badges and not started_at(show) then
            if show.threed == true then tags[#tags+1] = "3D" end
            if show.sensory == true then tags[#tags+1] = "SENSORY" end
            if show.open_caption == true then tags[#tags+1] = "OC" end
        end
        return tags
    end
    -- badge art (3D / OC / SF) is drawn at icon_h, keeping its proportions
    local function icon_size(tag)
        local img = show_icons[tag]
        local iw, ih = img:size()
        return icon_h * iw / math.max(ih, 1), icon_h
    end
    local function tag_width(tag)
        if show_icons[tag] then return (icon_size(tag)) end
        if tag == "3D" then return icon_w end
        return res.label:width(tag, tag_size) + tag_size * 0.8
    end
    local function tags_width(tags)
        local total = 0
        for _, tag in ipairs(tags) do total = total + gap + tag_width(tag) end
        return total
    end

    local size = math.floor(math.min(slot_h * 0.70, 140))
    for _, show in ipairs(shows) do
        local hm, suffix = display_time(show.showtime)
        local avail = slot_w * 0.88 - tags_width(tags_for(show))
        while size > 14 and time_width(font, hm, suffix, size) > avail do
            size = size - 1
        end
    end
    local suffix_size = math.floor(size * SUFFIX_SCALE)

    local next_idx
    for si, show in ipairs(shows) do
        if not started_at(show) then next_idx = si; break end
    end

    for si, show in ipairs(shows) do
        local col = (si - 1) % cols
        local row = math.floor((si - 1) / cols)
        local sx, sy = x + col * slot_w, y + row * slot_h
        local started = started_at(show)
        local hm, suffix = display_time(show.showtime)
        local tags = tags_for(show)

        local hm_w = font:width(hm, size)
        local tw = time_width(font, hm, suffix, size)
        local tx = sx + (slot_w - tw - tags_width(tags)) / 2
        local ty = sy + (slot_h - size) / 2

        local c = st.time_color
        if started then
            c = {0.40, 0.40, 0.42}
        elseif next_idx and si ~= next_idx then
            c = st.other_color
        end
        local r, g, b = c[1], c[2], c[3]
        if show.seats == 0 then
            r, g, b = 1, 0.3, 0.3
        elseif show.seats and show.seats <= 20 and not started then
            r, g, b = 1, 0.8, 0.2
        end

        if si == next_idx and #shows > 1 and st.next_mark == "underline" then
            local uh = math.max(3, math.floor(size * 0.05))
            st.mark_tex:draw(tx, ty + size + 2, tx + tw, ty + size + 2 + uh)
        end

        font:write(tx, ty, hm, size, r, g, b, 1)
        font:write(tx + hm_w + font:width(" ", suffix_size), ty + size - suffix_size - size * 0.02,
            suffix, suffix_size, r, g, b, 1)

        local cx = tx + tw + gap
        for _, tag in ipairs(tags) do
            local tag_w = tag_width(tag)
            if show_icons[tag] then
                local ow, oh = icon_size(tag)
                local iy = sy + (slot_h - oh) / 2
                show_icons[tag]:draw(cx, iy, cx + ow, iy + oh)
            elseif tag == "3D" then
                local iy = sy + (slot_h - icon_h) / 2
                badge_3d:draw(cx, iy, cx + icon_w, iy + icon_h)
            else
                local tag_h = tag_size * 1.4
                local tag_y = sy + (slot_h - tag_h) / 2
                local fill = tag == "SENSORY" and badge_green or badge_blue
                fill:draw(cx, tag_y, cx + tag_w, tag_y + tag_h)
                res.label:write(cx + tag_size * 0.4, tag_y + (tag_h - tag_size) / 2, tag, tag_size, 1, 1, 1, 1)
            end
            cx = cx + tag_w + gap
        end

        if started then
            strike_through_color:use{color = {r, g, b, 1}}
            strike_through:draw(tx - 6, ty + size * 0.55, tx + tw + 6, ty + size * 0.55 + 3, 1)
            strike_through_color:deactivate()
        end
    end
end

-- Title art ------------------------------------------------------------------
-- loaded_images[key] is the image, or false when that file failed to load
-- or draw (then the card falls back to the movie name instead of the whole
-- board going black). Errors are printed to the device log.
-- Find the title art for a movie: exact key first, then a file whose key
-- ends with or contains the movie key (handles prefixes like "logos-",
-- "logo_" or suffixes like "-title"), preferring the shortest match.
local function find_image_file(key)
    if not key or key == "" then return end
    local file = image_files[key]
    if file then return file end
    local best, best_len
    for k, f in pairs(image_files) do
        if #key >= 4 and (k:sub(-#key) == key or k:find(key, 1, true)) then
            if not best_len or #k < best_len then
                best, best_len = f, #k
            end
        end
    end
    return best
end

local function movie_image(movie, cfg)
    local file = find_image_file(movie.image)
    if cfg.hide_poster or not file then
        return
    end
    local image = loaded_images[movie.image]
    if image == false then
        return
    end
    if not image then
        local ok, img = pcall(resource.load_image, { file = file:copy(), mipmap = true })
        if not ok then
            print("title art: mipmapped load failed for " .. movie.image .. ": " .. tostring(img))
            ok, img = pcall(resource.load_image, { file = file:copy() })
        end
        if not ok then
            print("title art: could not load " .. movie.image .. ": " .. tostring(img))
            loaded_images[movie.image] = false
            return
        end
        image = img
        loaded_images[movie.image] = image
    end
    -- still loading (or broken): draw the name for now
    local ok, iw, ih = pcall(image.size, image)
    if not ok or not iw or iw <= 0 or ih <= 0 then
        return
    end
    return image
end

local function fit_rect(image, x1, y1, x2, y2)
    local iw, ih = image:size()
    local w, h = x2 - x1, y2 - y1
    local s = math.min(w / iw, h / ih)
    local dw, dh = iw * s, ih * s
    return x1 + (w - dw) / 2, y1 + (h - dh) / 2, x1 + (w + dw) / 2, y1 + (h + dh) / 2
end

local function title_rect(image, x, y, w, h)
    local pad_x, pad_y = w * 0.07, h * 0.12
    return fit_rect(image, x + pad_x, y + pad_y, x + w - pad_x, y + h - pad_y * 0.6)
end

local function draw_title(movie, image, keyed, x, y, w, h)
    local pad_x, pad_y = w * 0.07, h * 0.12
    if image then
        local x1, y1, x2, y2 = title_rect(image, x, y, w, h)
        if keyed and shaders.keyblack then
            shaders.keyblack:use{alpha = 1}
            image:draw(x1, y1, x2, y2)
            shaders.keyblack:deactivate()
        else
            image:draw(x1, y1, x2, y2)
        end
    else
        local name = movie.name:upper()
        local size = fit_size(res.times, name, math.floor(h * 0.34), w - pad_x * 2, 16)
        centered(res.times, name, size, x + w / 2, y + (h - size) / 2, 1, 1, 1)
    end
end

-- One movie card ---------------------------------------------------------------
-- Double-tall card for movies with more showtimes than wide_threshold:
-- title art and info keep the same size as a normal card (so rows line up)
-- and all the extra height goes to a big showtime grid.
local function draw_tall_card(movie, cfg, st, x, y, w, h, cell_h, now)
    local image = movie_image(movie, cfg)
    local logo_h = math.floor(cell_h * st.logo)
    local info_h = math.floor(cell_h * st.info)
    local times_y = y + logo_h + info_h
    local inset = st.inset or 0

    if board_style == "refined" then
        T.black:draw(x, y, x + w, y + logo_h)
        draw_title(movie, image, false, x, y, w, logo_h)
        info_refined(movie, cfg, x, y + logo_h, w, info_h)
        grad_times:draw(x, times_y, x + w, y + h)
        draw_times(movie, cfg, st, x + 6, times_y, w - 12, y + h - times_y, now, true)

    elseif board_style == "minimal" then
        grad_card:draw(x, y, x + w, y + h)
        draw_title(movie, image, true, x, y, w, logo_h)
        info_minimal(movie, cfg, x, y + logo_h, w, info_h)
        draw_times(movie, cfg, st, x + 6, times_y, w - 12, y + h - times_y - cell_h * 0.03, now, true)

    else -- premium
        B().card:draw(x, y, x + w, y + h)
        if image and shaders.glow then
            local x1, y1, x2, y2 = title_rect(image, x, y + inset, w, logo_h)
            local gw, gh = (x2 - x1) * 0.12, (y2 - y1) * 0.18
            local iw, ih = image:size()
            shaders.glow:use{dim = 0.16, spread = {0.05, 0.05 * iw / ih}}
            image:draw(math.max(x, x1 - gw), math.max(y, y1 - gh), math.min(x + w, x2 + gw), math.min(y + logo_h + info_h * 0.3, y2 + gh))
            shaders.glow:deactivate()
        end
        draw_title(movie, image, true, x, y + inset, w, logo_h)
        info_premium(movie, cfg, x, y + logo_h, w, info_h)
        draw_times(movie, cfg, st, x + inset, times_y, w - inset * 2, y + h - times_y - inset, now, true)
        if shaders.frame then
            shaders.frame:use{size = {w, h}, radius = 18, border = 3, color = B().frame}
            T.white:draw(x, y, x + w, y + h)
            shaders.frame:deactivate()
        end
    end
end

local function draw_card(movie, cfg, st, x, y, w, h, now)
    local image = movie_image(movie, cfg)
    local logo_h = math.floor(h * st.logo)
    local info_h = math.floor(h * st.info)
    local times_y = y + logo_h + info_h

    if board_style == "refined" then
        T.black:draw(x, y, x + w, y + logo_h)
        draw_title(movie, image, false, x, y, w, logo_h)
        info_refined(movie, cfg, x, y + logo_h, w, info_h)
        grad_times:draw(x, times_y, x + w, y + h)
        draw_times(movie, cfg, st, x + 6, times_y, w - 12, y + h - times_y, now)

    elseif board_style == "minimal" then
        grad_card:draw(x, y, x + w, y + h)
        draw_title(movie, image, true, x, y, w, logo_h)
        info_minimal(movie, cfg, x, y + logo_h, w, info_h)
        draw_times(movie, cfg, st, x + 6, times_y, w - 12, y + h - times_y - h * 0.03, now)

    else -- premium
        B().card:draw(x, y, x + w, y + h)
        if image and shaders.glow then
            -- barely-there halo sitting just behind the title art
            local x1, y1, x2, y2 = title_rect(image, x, y + st.inset, w, logo_h)
            local gw, gh = (x2 - x1) * 0.12, (y2 - y1) * 0.18
            local iw, ih = image:size()
            shaders.glow:use{dim = 0.16, spread = {0.05, 0.05 * iw / ih}}
            image:draw(math.max(x, x1 - gw), math.max(y, y1 - gh), math.min(x + w, x2 + gw), math.min(y + logo_h + info_h * 0.3, y2 + gh))
            shaders.glow:deactivate()
        end
        draw_title(movie, image, true, x, y + st.inset, w, logo_h)
        info_premium(movie, cfg, x, y + logo_h, w, info_h)
        draw_times(movie, cfg, st, x + st.inset, times_y, w - st.inset * 2, y + h - times_y - st.inset, now)
        if shaders.frame then
            shaders.frame:use{
                size = {w, h}, radius = 18, border = 3,
                color = B().frame,
            }
            T.white:draw(x, y, x + w, y + h)
            shaders.frame:deactivate()
        end
    end
end

local function header_height()
    return show_header and math.floor(HEIGHT * 0.085) or 0
end

local function draw_header()
    local hh = header_height()
    if hh == 0 then return end
    local b = B()
    b.header:draw(0, 0, WIDTH, hh)
    b.header_line:draw(0, hh - 3, WIDTH, hh)
    if brand_logo then
        local x1, y1, x2, y2 = fit_rect(brand_logo, WIDTH * 0.015, hh * 0.06, WIDTH * 0.30, hh * 0.94)
        brand_logo:draw(WIDTH * 0.015, y1, WIDTH * 0.015 + (x2 - x1), y2)
    end
    -- current local time on the right
    local minutes = math.floor(current_offset()) % 1440
    local h, m = math.floor(minutes / 60), minutes % 60
    local hm = ("%d:%02d"):format((h - 1) % 12 + 1, m)
    local suffix = h < 12 and "AM" or "PM"
    local size = math.floor(hh * 0.52)
    local c = b.clock
    local w = time_width(res.times, hm, suffix, size)
    local tx = WIDTH * 0.985 - w
    local ty = (hh - size) / 2
    res.times:write(tx, ty, hm, size, c[1], c[2], c[3], 1)
    local ss = math.floor(size * SUFFIX_SCALE)
    res.times:write(tx + res.times:width(hm, size) + res.times:width(" ", ss), ty + size - ss - size * 0.02, suffix, ss, c[1], c[2], c[3], 1)
end

local function show_bload()
    local cfg = bload.get_display_cfg()
    local movies, page_size = bload.get_paged_movies()
    local st = STYLES[board_style] or STYLES.refined
    local b = B()
    -- brand colors for the showtimes in every style
    local style = {}
    for k, v in pairs(st) do style[k] = v end
    style.mark_tex = b.underline
    if board_style == "premium" then
        style.time_color = b.next
        style.other_color = b.other
    end
    st = style

    -- how many grid cells each movie needs (2 = double-tall card)
    local spans, cells = {}, 0
    for i, movie in ipairs(movies) do
        local wide = wide_threshold > 0 and #movie.shows > wide_threshold
        spans[i] = wide and 2 or 1
        cells = cells + spans[i]
    end
    local extra = cells - #movies
    local cols, rows = layouter(rotation, math.max(page_size + extra, cells))
    if rows < 2 then
        for i = 1, #spans do spans[i] = 1 end
    end
    local top = header_height()
    local cell_w = WIDTH / cols
    local cell_h = (HEIGHT - top) / rows
    local now = current_offset()

    if board_style == "refined" then
        T.divider:draw(0, 0, WIDTH, HEIGHT)
    else
        T.black:draw(0, 0, WIDTH, HEIGHT)
    end
    draw_header()

    -- place cards in reading order; a tall card takes the first spot with
    -- two free cells stacked, and single cards back-fill any gaps
    local used = {}
    local function free(r, c) return r < rows and c < cols and not used[r * cols + c] end
    local placed = {}
    for i, movie in ipairs(movies) do
        local span = spans[i]
        local spot
        for pos = 0, cols * rows - 1 do
            local r, c = math.floor(pos / cols), pos % cols
            if free(r, c) and (span == 1 or free(r + 1, c)) then
                spot = {r = r, c = c}
                break
            end
        end
        if not spot and span == 2 then
            -- no room for a tall card: fall back to a normal one
            span = 1
            for pos = 0, cols * rows - 1 do
                local r, c = math.floor(pos / cols), pos % cols
                if free(r, c) then spot = {r = r, c = c}; break end
            end
        end
        if spot then
            used[spot.r * cols + spot.c] = true
            if span == 2 then used[(spot.r + 1) * cols + spot.c] = true end
            placed[#placed + 1] = {movie = movie, r = spot.r, c = spot.c, span = span}
        end
    end

    for _, p in ipairs(placed) do
        local x = p.c * cell_w + st.gap / 2
        local y = top + p.r * cell_h + st.gap / 2
        local w = cell_w - st.gap
        local h = cell_h * p.span - st.gap
        local function draw_it()
            if p.span == 2 then
                draw_tall_card(p.movie, cfg, st, x, y, w, h, cell_h - st.gap, now)
            else
                draw_card(p.movie, cfg, st, x, y, w, h, now)
            end
        end
        local ok, err = pcall(draw_it)
        if not ok then
            -- a bad title image must not black out the board: log it, stop
            -- using that image and draw the card with the movie name instead
            print("card for " .. tostring(p.movie.name) .. " failed: " .. tostring(err))
            loaded_images[p.movie.image] = false
            for _, sh in pairs(shaders) do pcall(sh.deactivate, sh) end
            pcall(draw_it)
        end
    end

    for pos = 0, cols * rows - 1 do
        local r, c = math.floor(pos / cols), pos % cols
        if not used[pos] then
            local x = c * cell_w + st.gap / 2
            local y = top + r * cell_h + st.gap / 2
            local w, h = cell_w - st.gap, cell_h - st.gap
            T.black:draw(x, y, x + w, y + h)
            if cfg.show_logo and (brand_logo or logo) then
                util.draw_correct(brand_logo or logo, x + w * 0.15, y + h * 0.3, x + w * 0.85, y + h * 0.7)
            end
        end
    end
end

util.data_mapper{
    ["age/set"] = function(age)
        bload_age = tonumber(age)
    end;
}

local function show_fallback()
    util.draw_correct(bload_fallback, 0, 0, WIDTH, HEIGHT)
end

-- "Logo wall" shown when there are no showings to list (e.g. after the last
-- show of the night with Hide past showings on): every uploaded title logo
-- tiled and dimmed, rows slowly drifting in opposite directions, with the
-- brand logo and a short message in the middle.
local wall_bg = {
    flagship = resource.load_image "grad-wall-fs.png",
    harbor_east = resource.load_image "grad-wall-he.png",
}
local wall_shade = resource.load_image "wall-shade.png"
local BRAND_NAMES = {flagship = "FLAGSHIP CINEMAS", harbor_east = "HARBOR EAST CINEMAS"}
local WALL_BG_RGB = {flagship = {3/255, 4/255, 7/255}, harbor_east = {3/255, 11/255, 29/255}}

local function wall_logos()
    local list = {}
    for key in pairs(image_files) do
        list[#list + 1] = key
    end
    table.sort(list)
    local out = {}
    for _, key in ipairs(list) do
        local img = movie_image({image = key}, {hide_poster = false})
        if img then out[#out + 1] = img end
    end
    return out
end

local function draw_clock(right_x, y, size, c)
    local minutes = math.floor(current_offset()) % 1440
    local h, m = math.floor(minutes / 60), minutes % 60
    local hm = ("%d:%02d"):format((h - 1) % 12 + 1, m)
    local suffix = h < 12 and "AM" or "PM"
    local w = time_width(res.times, hm, suffix, size)
    local tx = right_x - w
    res.times:write(tx, y, hm, size, c[1], c[2], c[3], 1)
    local ss = math.floor(size * SUFFIX_SCALE)
    res.times:write(tx + res.times:width(hm, size) + res.times:width(" ", ss), y + size - ss - size * 0.02, suffix, ss, c[1], c[2], c[3], 1)
end

local function show_no_showings()
    local b = B()
    -- scale against the short side so portrait screens get full-size text
    local s = math.min(WIDTH, HEIGHT) / 1080
    local portrait_wall = HEIGHT > WIDTH
    ;(wall_bg[brand] or wall_bg.flagship):draw(0, 0, WIDTH, HEIGHT)

    -- the wall
    local logos = wall_logos()
    if #logos > 0 then
        local cw, ch = 420 * s, 190 * s
        local rows = math.ceil(HEIGHT / ch) + 1
        local cols = math.ceil(WIDTH / cw) + 2
        local t = sys.now()
        for r = 0, rows - 1 do
            local dir = (r % 2 == 0) and 1 or -1
            local offset = (t * 22 * s * dir + ((r % 2 == 1) and cw / 2 or 0)) % cw
            local y = r * ch - ch / 3
            for c = -1, cols - 1 do
                local img = logos[((r * 3 + c) % #logos) + 1]
                local x = c * cw + offset
                local x1, y1, x2, y2 = fit_rect(img, x + 35 * s, y + 25 * s, x + cw - 35 * s, y + ch - 25 * s)
                if shaders.keyblack then
                    shaders.keyblack:use{alpha = 0.30}
                    img:draw(x1, y1, x2, y2)
                    shaders.keyblack:deactivate()
                else
                    img:draw(x1, y1, x2, y2, 0.30)
                end
            end
        end
    end

    -- soft dark centre so the brand reads clearly, tinted to the background
    local bg = WALL_BG_RGB[brand] or WALL_BG_RGB.flagship
    strike_through_color:use{color = {bg[1], bg[2], bg[3], 1}}
    wall_shade:draw(WIDTH * 0.10, HEIGHT * 0.08, WIDTH * 0.90, HEIGHT * 0.96)
    strike_through_color:deactivate()

    -- brand logo + message
    local text_c = b.clock
    local ly = HEIGHT * (portrait_wall and 0.34 or 0.30)
    local lx = portrait_wall and 0.12 or 0.30
    if brand_logo then
        local x1, y1, x2, y2 = fit_rect(brand_logo, WIDTH * lx, ly, WIDTH * (1 - lx), ly + 300 * s)
        brand_logo:draw(x1, y1, x2, y2)
        ly = y2
    end
    local line1 = "NOW PLAYING AT " .. (BRAND_NAMES[brand] or "FLAGSHIP CINEMAS")
    local size1 = fit_size(res.times, line1, math.floor(64 * s), WIDTH * 0.90, 16)
    local y1 = ly + 50 * s
    centered(res.times, line1, size1, WIDTH / 2, y1, text_c[1], text_c[2], text_c[3], 1)

    -- "all shows have started" only makes sense in the evening; earlier in
    -- the day (schedule not published yet) just show the brand line
    local minutes = math.floor(current_offset()) % 1440
    if minutes >= 17 * 60 or minutes < 4 * 60 then
        local ry = y1 + size1 + 28 * s
        b.underline:draw(WIDTH / 2 - 140 * s, ry, WIDTH / 2 + 140 * s, ry + 4 * s)
        local line2 = "ALL SHOWS HAVE STARTED FOR THE DAY"
        local size2 = fit_size(res.label, line2, math.floor(40 * s), WIDTH * 0.90, 12)
        centered(res.label, line2, size2, WIDTH / 2, ry + 28 * s, text_c[1], text_c[2], text_c[3], 0.92)
    end

    draw_clock(WIDTH - 40 * s, 34 * s, math.floor(54 * s), text_c)
end

function node.render()
    gl.clear(0,0,0,1)
    black:draw(0, 0, WIDTH, HEIGHT)
    st()

    local movies = bload.get_paged_movies()
    local stale = bload.get_data_source() ~= "indy" and bload_age > bload_threshold

    if stale then
        show_fallback()
    elseif #movies == 0 then
        if bload.get_data_source() == "indy" then
            show_no_showings()
        else
            show_fallback()
        end
    else
        show_bload()
    end
end
