--[[
    MyRec — режиссёрский инструмент: запись движений игрока и воспроизведение их на NPC.

    Установка:  garrysmod/lua/autorun/my_rec.lua

    GUI:
        • C-меню → иконка «Режиссёр»  (или консольная команда  my_rec_menu)
        • Q-меню → Утилиты → Режиссёр: быстрые команды записи и таймлайн
        • Левая панель  — «Анимации»: имя трека, запись, список сохранённых треков.
        • Правая панель — «Группы и настройки»: группы с задержкой старта, привязка
                          треков к NPC, кнопка «ЗАПУСТИТЬ ВСЕХ».

    Консольные команды (дублируют GUI):
        start_my_rec [имя]   — начать запись (имя трека необязательно)
        stop_my_rec          — остановить запись и сохранить трек
        play_my_rec [имя]    — сразу воспроизвести трек (по умолчанию последний)
                               на NPC / рэгдолле, на которого смотришь
        stop_my_play         — остановить всё воспроизведение
        my_rec_menu          — открыть окно режиссёра

    Настройки (серверные convar):
        my_rec_interval   — интервал между кадрами записи, сек (0 = каждый тик)
        my_rec_maxtime    — макс. длина одной записи, сек (по умолчанию 300)
        my_rec_adminonly  — 1 = только админы (по умолчанию 1)

    Кастомное оружие (ARC9 / TFA / Modern Warfare Base):
        • В каждый кадр пишутся ЛКМ (attack), ПКМ-прицел (aim) и перезарядка (reload).
        • Для оружия этих паков выстрел делается родным weapon:PrimaryAttack(),
          прицеливание — через SetInSights / SetIronSights и т.п., перезарядка — weapon:Reload().
        • Старые треки (без aim/reload) воспроизводятся как раньше.
        • Одиночное оружие (револьверы, дробовики, СВД) стреляет только по записанным кликам ЛКМ
          (KeyPressed), автоматическое — пока ЛКМ зажата.
        • Темп стрельбы задаёт само оружие: выстрел не делается, пока
          weapon:GetNextPrimaryFire() > CurTime(). Своих констант задержки нет.
        • Гранаты: бросок в момент отпускания ЛКМ — анимация броска + спавн гранаты
          из рук NPC в направлении взгляда.
        • Пауза / перемотка управляют всеми активными NPC; во время записи показываются
          полупрозрачные призраки прошлых треков текущей сессии.
        • Привязки: группа → NPC (дерево в GUI). Итоговая задержка старта NPC =
          задержка группы + личная задержка NPC.
        • Возобновить сценарий (кнопка в GUI / консоль restore_my_rec): убитые или удалённые NPC
          переспавниваются по манифесту (класс, модель, позиция, углы, оружие, трек, группа);
          если сцена идёт — новые NPC подключаются с текущего момента таймлайна.
        • Для новых треков (hasShots) в каждый кадр пишется shots — число реально вылетевших пуль
          (EntityFireBullets). Одиночное оружие на воспроизведении стреляет ровно по этим событиям,
          а не по флагу ЛКМ. «Автомат» определяется только по записи (3+ выстрела за одно удержание).
        • Для новых треков AmmoFired ограничивает воспроизведение числом записанных выстрелов.
]]

-- =====================================================================
--  LOCALIZATION / ЛОКАЛИЗАЦИЯ (EN / RU)
-- =====================================================================
local MyRec_Lang = {
    ["en"] = {
        title = "MyRec — Director Tool",
        anim_header = "ANIMATIONS (Recordings)",
        groups_header = "GROUPS & SETTINGS",
        tree_header = "Tree: group → NPC (class [index] · track · delay)",
        start_rec = "● Start Recording",
        stop_rec = "■ Stop Recording",
        del_track = "Delete Selected Track",
        play_all = "LAUNCH ALL",
        stop_all = "Stop All",
        unbind = "Remove Binding",
        restore_scene = "↻ Restore Scene",
        add_group = "+ Add Group",
        del_group = "− Delete Group",
        bind_track = "Bind Track to NPC",
        group_delay = "Group Delay, s",
        npc_delay = "Personal NPC Delay, s",
        track_name_col = "Track Name",
        duration_col = "Dur., s",
        weapon_col = "Weapon",
        pause_btn = "Ⅱ Pause",
        resume_btn = "▶ Resume",
        timeline_label = "Timeline: %.1f / %.1f s",
        seek_label = "Seek, s",
    },
    ["ru"] = {
        title = "MyRec — Режиссёр",
        anim_header = "АНИМАЦИИ (записи)",
        groups_header = "ГРУППЫ И НАСТРОЙКИ",
        tree_header = "Дерево: группа → NPC (класс [индекс] · трек · задержка)",
        start_rec = "● Начать запись",
        stop_rec = "■ Остановить запись",
        del_track = "Удалить выбранный трек",
        play_all = "ЗАПУСТИТЬ ВСЕХ",
        stop_all = "Остановить всех",
        unbind = "Убрать привязку",
        restore_scene = "↻ Возобновить сценарий",
        add_group = "+ Добавить группу",
        del_group = "− Удалить группу",
        bind_track = "Привязать трек к NPC",
        group_delay = "Задержка ГРУППЫ, с",
        npc_delay = "Личная задержка NPC, с",
        track_name_col = "Имя трека",
        duration_col = "Длит., с",
        weapon_col = "Оружие",
        pause_btn = "Ⅱ Пауза",
        resume_btn = "▶ Продолжить",
        timeline_label = "Таймлайн: %.1f / %.1f с",
        seek_label = "Перемотка, с",
    }
}

local function L(phraseKey)
    local lang = "en"
    if CLIENT then
        local sysLang = GetConVarString("gmod_language") or "en"
        if sysLang == "ru" then
            lang = "ru"
        end
    end
    return MyRec_Lang[lang][phraseKey] or MyRec_Lang["en"][phraseKey] or phraseKey
end

local NET_CMD   = "MyRec_Cmd"    -- клиент -> сервер (действия из GUI)
local NET_SYNC  = "MyRec_Sync"   -- сервер -> клиент (состояние для GUI)
local NET_TIME  = "MyRec_Time"   -- сервер -> клиент (таймлайн воспроизведения)
local NET_GHOST = "MyRec_Ghosts" -- сервер -> клиент (призраки прошлых дублей)

local STATE_IDLE, STATE_REC, STATE_PLAY = 0, 1, 2

local CMD = {
    START = 1, STOP = 2, DEL_TRACK = 3,
    ADD_GROUP = 4, DEL_GROUP = 5, SET_GROUP = 6,
    BIND = 7, UNBIND = 8,
    PLAY_ALL = 9, STOP_ALL = 10,
    SYNC = 11,
    PAUSE = 12, SEEK = 13,
    SET_NPC_DELAY = 14, RESTORE = 15, -- (4 бита: максимум 15)
}

local MAX_TRACKS, MAX_GROUPS, MAX_BINDINGS = 100, 50, 200

-- =====================================================================
--  СЕРВЕР
-- =====================================================================
if SERVER then
    AddCSLuaFile()
    util.AddNetworkString(NET_CMD)
    util.AddNetworkString(NET_SYNC)
    util.AddNetworkString(NET_TIME)
    util.AddNetworkString(NET_GHOST)

    local cv_interval = CreateConVar("my_rec_interval", "0", FCVAR_ARCHIVE,
        "Интервал между кадрами записи (сек). 0 = каждый тик.", 0, 5)
    local cv_maxtime = CreateConVar("my_rec_maxtime", "300", FCVAR_ARCHIVE,
        "Максимальная длина записи (сек).", 1, 3600)
    local cv_admin = CreateConVar("my_rec_adminonly", "1", FCVAR_ARCHIVE,
        "1 = пользоваться инструментом могут только админы.", 0, 1)

    -- Pose-параметры, влияющие на вид ходьбы/бега/прицеливания
    local POSE_PARAMS = {
        "move_x", "move_y", "move_yaw",
        "aim_pitch", "aim_yaw", "body_yaw",
        "head_pitch", "head_yaw",
    }

    -- Оружие, которое NPC выдавать бессмысленно
    local WEAPON_BLACKLIST = {
        gmod_tool = true, weapon_physgun = true, gmod_camera = true,
        weapon_physcannon = true, weapon_fists = true, none = true,
    }

    -- Пороги скорости (units/сек) для выбора активности
    local SPEED_WALK_MIN = 10   -- выше этого — ходьба
    local SPEED_RUN_MIN  = 250  -- выше этого — бег

    -- Знак наклона ствола при прицеливании. Если у какой-то модели NPC ствол при ADS
    -- смотрит вверх/вниз наоборот — поменяй 1 на -1
    local AIM_PITCH_SIGN = 1

    -- Гранаты: признаки по имени класса (плюс SWEP.Slot == 4) и параметры броска
    local NADE_WORDS = { "grenade", "frag", "smoke", "flash" }
    local NADE_SPEED = 900  -- скорость броска, units/сек
    local NADE_LIFT  = 120  -- добавка вверх, чтобы бросок шёл дугой

    -- Признаки кастомных оружейных паков (имя класса / база SWEP, без учёта регистра)
    local PACK_MARKERS      = { "arc9", "tfa", "mwb", "mg_base" }
    local PACK_CLASS_PREFIX = { "mg_" } -- классы Modern Warfare Base начинаются с mg_

    -- Холодное оружие: для него используется melee-анимация атаки
    local MELEE_WEAPONS = {
        weapon_crowbar = true, weapon_stunstick = true,
    }

    -- Запасной вариант стрельбы (если события анимации не сработали): параметры оружия HL2
    local FIRE_INFO = {
        weapon_smg1    = { ammo = "SMG1",     snd = "Weapon_SMG1.NPC_Single",    delay = 0.075, spread = 0.04 },
        weapon_ar2     = { ammo = "AR2",      snd = "Weapon_AR2.NPC_Single",     delay = 0.1,   spread = 0.03 },
        weapon_pistol  = { ammo = "Pistol",   snd = "Weapon_Pistol.NPC_Single",  delay = 0.4,   spread = 0.03 },
        weapon_357     = { ammo = "357",      snd = "Weapon_357.Single",         delay = 0.75,  spread = 0.01 },
        weapon_shotgun = { ammo = "Buckshot", snd = "Weapon_Shotgun.NPC_Single", delay = 0.9,   spread = 0.08, num = 7 },
    }

    local recording = {} -- [ply] = { name, frames, start, nextT, weapon }
    local playbacks = {} -- [ent] = pb
    local director  = {} -- [ply] = { tracks, groups, nextGroup, bindings }
    local ownerPaused = {} -- [ply] = true, когда режиссёр поставил воспроизведение на паузу

    ------------------------------------------------------------------
    -- Данные «режиссёра» (на каждого игрока свои)
    ------------------------------------------------------------------
    local function Dir(ply)
        local d = director[ply]
        if not d then
            d = {
                tracks    = {},  -- { name, frames, weapon, duration }
                groups    = { { id = 1, name = "Группа 1", delay = 0 } },
                nextGroup = 2,
                nextBid   = 1,
                -- { bid, ent, track (имя), group (id), delay (личный оффсет, с),
                --   manifest = { class, model, pos, ang, weapon, skin, bodygroups, spawnflags, health },
                --   played (true после первого запуска сцены: манифест позиции больше не обновляется) }
                bindings  = {},
            }
            director[ply] = d
        end
        return d
    end

    local function FindTrack(d, name)
        for _, t in ipairs(d.tracks) do
            if t.name == name then return t end
        end
    end

    local function FindGroup(d, id)
        for _, g in ipairs(d.groups) do
            if g.id == id then return g end
        end
    end

    local function CleanName(s)
        s = (s or ""):gsub("%c", "")
        s = string.Trim(s)

        -- обрезаем до 24 символов (utf8.offset на пустой строке падает, поэтому проверка и pcall)
        if #s > 0 then
            local ok, cut = pcall(utf8.offset, s, 25)
            if ok and cut then s = s:sub(1, cut - 1) end
        end

        return s
    end

    local function UniqueTrackName(d, base)
        if base == "" then base = "track_" .. (#d.tracks + 1) end
        local name, n = base, 2
        while FindTrack(d, name) do
            name = base .. "_" .. n
            n = n + 1
        end
        return name
    end

    ------------------------------------------------------------------
    -- Утилиты
    ------------------------------------------------------------------
    local function Say(ply, msg)
        if IsValid(ply) then ply:ChatPrint("[MyRec] " .. msg) end
    end

    local function CanUse(ply)
        if not IsValid(ply) then return false end -- вызов из серверной консоли
        if cv_admin:GetBool() and not (ply:IsAdmin() or game.SinglePlayer()) then
            Say(ply, "Инструмент доступен только администраторам.")
            return false
        end
        return true
    end

    local function IsPlaying(ply)
        for _, pb in pairs(playbacks) do
            if pb.owner == ply then return true end
        end
        return false
    end

    local function StateOf(ply)
        if recording[ply] then return STATE_REC end
        if IsPlaying(ply) then return STATE_PLAY end
        return STATE_IDLE
    end

    ------------------------------------------------------------------
    -- Манифест спавна привязанного NPC (нужен для «Возобновить сценарий»)
    ------------------------------------------------------------------
    local function CaptureManifest(ent, weaponClass)
        local m = {
            class      = ent:GetClass(),
            model      = ent:GetModel() or "",
            pos        = ent:GetPos(),
            ang        = ent:GetAngles(),
            skin       = ent:GetSkin() or 0,
            spawnflags = ent:GetSpawnFlags(),
            health     = ent:IsNPC() and ent:Health() or 0,
            bodygroups = {},
            weapon     = weaponClass or "",
        }
        for i = 0, (ent:GetNumBodyGroups() or 0) - 1 do
            m.bodygroups[i] = ent:GetBodygroup(i)
        end
        if m.weapon == "" and ent:IsNPC() then
            local w = ent:GetActiveWeapon()
            if IsValid(w) then m.weapon = w:GetClass() end
        end
        return m
    end

    -- NPC из привязки жив? Убитый, но ещё не удалённый NPC (Health <= 0) считается мёртвым.
    local function BindingAlive(b)
        local ent = b.ent
        if not IsValid(ent) then return false end
        if ent:IsNPC() and (b.manifest and (b.manifest.health or 0) > 0) and ent:Health() <= 0 then
            return false
        end
        return true
    end

    -- Отправить клиенту полное состояние для GUI
    local function SendSync(ply)
        if not IsValid(ply) then return end
        local d = Dir(ply)

        -- Мёртвые привязки НЕ удаляем: по манифесту их можно возродить кнопкой «Возобновить сценарий».
        net.Start(NET_SYNC)
            net.WriteUInt(StateOf(ply), 2)
            local rec = recording[ply]
            net.WriteString(rec and rec.name or "")

            net.WriteUInt(#d.tracks, 8)
            for _, t in ipairs(d.tracks) do
                net.WriteString(t.name)
                net.WriteFloat(t.duration)
                net.WriteString(t.weapon or "")
            end

            net.WriteUInt(#d.groups, 8)
            for _, g in ipairs(d.groups) do
                net.WriteUInt(g.id, 16)
                net.WriteString(g.name)
                net.WriteFloat(g.delay)
            end

            net.WriteUInt(#d.bindings, 8)
            for _, b in ipairs(d.bindings) do
                local alive = BindingAlive(b)
                net.WriteUInt(b.bid, 16)
                net.WriteBool(alive)
                net.WriteUInt(alive and b.ent:EntIndex() or 0, 16)
                net.WriteString(b.manifest.class)
                net.WriteString(b.track)
                net.WriteUInt(b.group, 16)
                net.WriteFloat(b.delay or 0)
            end
        net.Send(ply)
    end

    -- Передаём прошлые записи отдельными небольшими пакетами, чтобы не упираться
    -- в лимит размера одного net-сообщения. Для призрака достаточно до 48 точек.
    local function SendGhostTracks(ply)
        local d = Dir(ply)
        net.Start(NET_GHOST)
            net.WriteUInt(0, 2) -- begin
            net.WriteUInt(#d.tracks, 8)
        net.Send(ply)

        for trackIndex, track in ipairs(d.tracks) do
            local delay = (trackIndex - 1) * 0.025
            local selectedTrack, selectedIndex = track, trackIndex
            timer.Simple(delay, function()
                if not IsValid(ply) or not recording[ply] then return end
                local frames = selectedTrack.frames or {}
                if #frames == 0 then return end

                local sampleCount = math.min(#frames, 48)
                net.Start(NET_GHOST)
                    net.WriteUInt(1, 2) -- track
                    net.WriteString(selectedTrack.name or ("track_" .. selectedIndex))
                    net.WriteString(selectedTrack.model or "")
                    net.WriteFloat(tonumber(selectedTrack.duration) or frames[#frames].t or 0)
                    net.WriteUInt(sampleCount, 6)
                    for j = 0, sampleCount - 1 do
                        local frameIndex = sampleCount == 1 and 1 or math.floor(1 + (j / (sampleCount - 1)) * (#frames - 1) + 0.5)
                        local frame = frames[frameIndex]
                        net.WriteFloat(tonumber(frame.t) or 0)
                        net.WriteVector(frame.pos or vector_origin)
                        net.WriteAngle(frame.ang or angle_zero)
                    end
                net.Send(ply)
            end)
        end

        timer.Simple(#d.tracks * 0.025 + 0.05, function()
            if not IsValid(ply) or not recording[ply] then return end
            net.Start(NET_GHOST)
                net.WriteUInt(2, 2) -- end of transfer
            net.Send(ply)
        end)
    end

    local function StopGhostTracks(ply)
        if not IsValid(ply) then return end
        net.Start(NET_GHOST)
            net.WriteUInt(3, 2) -- remove clientside ghost models
        net.Send(ply)
    end

    local function IsValidTarget(ent)
        return IsValid(ent) and (ent:IsNPC() or ent:GetClass() == "prop_ragdoll")
    end

    -- Pose-параметр в нормализованном виде 0..1 (чтобы переносить между моделями)
    local function GetNormPose(ent, name)
        local id = ent:LookupPoseParameter(name)
        if not id or id < 0 then return nil end
        local mn, mx = ent:GetPoseParameterRange(id)
        if mx == mn then return nil end
        return (ent:GetPoseParameter(name) - mn) / (mx - mn)
    end

    local function SetNormPose(ent, name, norm)
        local id = ent:LookupPoseParameter(name)
        if not id or id < 0 then return end
        local mn, mx = ent:GetPoseParameterRange(id)
        ent:SetPoseParameter(name, mn + norm * (mx - mn))
    end

    -- Выдать NPC оружие из трека (если это возможно)
    local function GiveNPCWeapon(npc, class)
        if not class or class == "" or WEAPON_BLACKLIST[class] then return false end
        if not IsValid(npc) or not npc:IsNPC() then return false end

        local cur = npc:GetActiveWeapon()
        if IsValid(cur) and cur:GetClass() == class then return true end

        npc:Give(class)
        return true
    end

    ------------------------------------------------------------------
    -- Кастомные оружейные паки (ARC9 / TFA / Modern Warfare Base)
    ------------------------------------------------------------------
    local customCache = {} -- [class] = true/false

    -- Оружие из кастомного пака? Проверяем имя класса, SWEP.Base и цепочку BaseClass
    local function IsCustomWeapon(wep)
        if not IsValid(wep) then return false end

        local class = string.lower(wep:GetClass())
        local cached = customCache[class]
        if cached ~= nil then return cached end

        local result = false

        for _, m in ipairs(PACK_MARKERS) do
            if string.find(class, m, 1, true) then result = true break end
        end

        if not result then
            for _, pfx in ipairs(PACK_CLASS_PREFIX) do
                if string.sub(class, 1, #pfx) == pfx then result = true break end
            end
        end

        if not result then
            local t, depth = wep:GetTable(), 0
            while istable(t) and depth < 10 do
                local base = isstring(t.Base) and string.lower(t.Base) or ""
                local cn   = isstring(t.ClassName) and string.lower(t.ClassName) or ""
                for _, m in ipairs(PACK_MARKERS) do
                    if string.find(base, m, 1, true) or string.find(cn, m, 1, true) then
                        result = true
                        break
                    end
                end
                if result then break end
                t = t.BaseClass
                depth = depth + 1
            end
        end

        if not result and (wep.ARC9 == true or wep.IsTFAWeapon == true) then result = true end

        customCache[class] = result
        return result
    end

    -- Включить/выключить прицеливание у самого оружия (каждый пак хранит это по-своему)
    local AIM_SETTERS = { "SetADS", "SetAiming", "SetIsAiming" }

    local function SetWeaponAim(wep, state)
        if not IsValid(wep) then return end
        state = state and true or false

        -- ARC9
        if wep.SetInSights then pcall(wep.SetInSights, wep, state) end
        if wep.SetSightAmount then pcall(wep.SetSightAmount, wep, state and 1 or 0) end

        -- TFA
        if wep.SetIronSightsRaw then pcall(wep.SetIronSightsRaw, wep, state) end
        if wep.SetIronSights then pcall(wep.SetIronSights, wep, state) end

        -- Modern Warfare Base и прочие базы
        for _, fn in ipairs(AIM_SETTERS) do
            if wep[fn] then pcall(wep[fn], wep, state) end
        end

        -- Общая переменная состояния (не трогаем, если IsAiming — это метод)
        if wep.IsAiming == nil or isbool(wep.IsAiming) then wep.IsAiming = state end
    end

    -- Игрок сейчас целится по данным самого оружия (на случай toggle-ADS без зажатой ПКМ)
    local AIM_GETTERS = { "GetInSights", "GetIronSightsRaw", "GetIronSights" }

    local function WeaponInSights(wep)
        if not IsValid(wep) then return false end
        for _, fn in ipairs(AIM_GETTERS) do
            if wep[fn] then
                local ok, v = pcall(wep[fn], wep)
                if ok and v == true then return true end
            end
        end
        return false
    end

    -- Граната ли это оружие: имя класса (grenade / frag / smoke / flash) или слот 4 у SWEP
    local nadeCache = {}

    local function IsGrenadeClass(class)
        if not class or class == "" then return false end

        local cached = nadeCache[class]
        if cached ~= nil then return cached end

        local lc = string.lower(class)
        local result = false

        if not string.find(lc, "flashlight", 1, true) then
            for _, w in ipairs(NADE_WORDS) do
                if string.find(lc, w, 1, true) then result = true break end
            end
        end

        if not result then
            local sw = weapons.Get(class)
            if sw and tonumber(sw.Slot) == 4 then result = true end -- слоты в GMod считаются с 0
        end

        nadeCache[class] = result
        return result
    end

    -- Pose-параметр в реальных единицах (с ограничением по диапазону модели)
    local function SetRealPose(ent, name, value)
        local id = ent:LookupPoseParameter(name)
        if not id or id < 0 then return end
        local mn, mx = ent:GetPoseParameterRange(id)
        ent:SetPoseParameter(name, math.Clamp(value, mn, mx))
    end

    ------------------------------------------------------------------
    -- ЗАПИСЬ
    ------------------------------------------------------------------
    local function Capture(ply, t, rec)
        local pose = {}
        for _, name in ipairs(POSE_PARAMS) do
            local v = GetNormPose(ply, name)
            if v then pose[name] = v end
        end

        local wep = ply:GetActiveWeapon()

        -- ПКМ (прицеливание): IN_ATTACK2, а также IN_AIM, если такая клавиша есть в этой сборке;
        -- плюс состояние прицела самого оружия (если игрок целится по toggle)
        local aim = ply:KeyDown(IN_ATTACK2)
            or (IN_AIM ~= nil and ply:KeyDown(IN_AIM))
            or WeaponInSights(wep)

        -- R: учитываем и короткое нажатие между кадрами (если my_rec_interval > 0)
        local reload = ply:KeyDown(IN_RELOAD)
        if rec and rec.pendReload then
            reload = true
            rec.pendReload = false
        end

        local attack = ply:KeyDown(IN_ATTACK)

        -- Клик ЛКМ: KeyPressed + хук KeyPress (чтобы не терять быстрые клики между кадрами)
        local click = rec.pendClick or (ply:KeyPressed(IN_ATTACK) and not rec.prevAttack)
        -- Отпускание ЛКМ (бросок гранаты)
        local release = rec.pendRelease or (rec.prevAttack and not attack)
        rec.pendClick, rec.pendRelease = false, false

        -- Реальные выстрелы (EntityFireBullets), произошедшие с прошлого кадра.
        -- Именно они, а не флаг attack, управляют стрельбой полуавтоматов при воспроизведении.
        local shots = rec.shotsPending or 0
        rec.shotsPending = 0
        rec.prevAttack = attack

        return {
            t      = t,                  -- время от начала записи
            pos    = ply:GetPos(),       -- Vector (ноги)
            ang    = ply:EyeAngles(),    -- Angle
            crouch = ply:Crouching(),    -- приседание
            weapon = IsValid(wep) and wep:GetClass() or "", -- активное оружие в этом кадре
            attack = attack,                                -- ЛКМ зажата
            click  = click and true or false,               -- ЛКМ только что нажата (клик)
            release = release and true or false,            -- ЛКМ только что отпущена
            aim    = aim and true or false,                 -- прицеливание (ПКМ / ADS)
            reload = reload and true or false,              -- перезарядка (R)
            AmmoFired = rec and (rec.ammoFired or 0) or 0, -- накопительное число реальных выстрелов
            shots  = shots > 0 and shots or nil,           -- сколько пуль реально вылетело с прошлого кадра
            pose   = pose,
        }
    end

    local function StartRecording(ply, rawName)
        if recording[ply] then
            Say(ply, "Запись уже идёт.")
            return
        end

        local d = Dir(ply)
        if #d.tracks >= MAX_TRACKS then
            Say(ply, "Достигнут лимит треков (" .. MAX_TRACKS .. "). Удали ненужные.")
            return
        end

        -- Запоминаем класс активного оружия на момент старта записи
        local wep = ply:GetActiveWeapon()
        local wclass = IsValid(wep) and wep:GetClass() or ""

        recording[ply] = {
            name   = UniqueTrackName(d, CleanName(rawName)),
            frames = {},
            start  = CurTime(),
            nextT  = 0,
            weapon = wclass,
            model  = ply:GetModel(),
            ammoFired = 0,
            autoClass  = {},    -- [класс оружия] = true, если оно стреляло очередью при зажатой ЛКМ
            holdShots  = 0,     -- выстрелы с момента последнего нажатия ЛКМ
            shotsPending = 0,   -- выстрелы, ещё не записанные в кадр
            lastShotTime = -1,
            prevAttack = false,
        }
        Say(ply, "Запись «" .. recording[ply].name .. "» началась. Остановить: stop_my_rec")
        SendSync(ply)
        SendGhostTracks(ply)
    end

    local function StopRecording(ply, silent)
        local rec = recording[ply]
        if not rec then return end
        recording[ply] = nil
        StopGhostTracks(ply)

        if #rec.frames >= 2 then
            -- Финальный кадр отражает и выстрелы, произошедшие после последнего Tick Capture.
            local last = rec.frames[#rec.frames]
            last.AmmoFired = rec.ammoFired or 0
            if (rec.shotsPending or 0) > 0 then
                last.shots = (last.shots or 0) + rec.shotsPending
                rec.shotsPending = 0
            end
            local d = Dir(ply)
            d.tracks[#d.tracks + 1] = {
                name     = rec.name,
                frames   = rec.frames,
                weapon   = rec.weapon,
                model    = rec.model,
                duration = rec.frames[#rec.frames].t,
                ammoFired = rec.ammoFired or 0,
                autoClass = rec.autoClass,
                hasClick  = true, -- в кадрах есть click/release (у старых треков их нет)
                hasShots  = true, -- в кадрах есть shots: реальные события выстрелов
            }
            if not silent then
                Say(ply, ("Трек «%s» сохранён: %d кадров, %.1f сек."):format(
                    rec.name, #rec.frames, rec.frames[#rec.frames].t))
            end
        elseif not silent then
            Say(ply, "Запись слишком короткая, не сохранена.")
        end
        SendSync(ply)
    end

    hook.Add("Tick", "MyRec_Record", function()
        local now      = CurTime()
        local interval = cv_interval:GetFloat()
        local maxtime  = cv_maxtime:GetFloat()

        for ply, rec in pairs(recording) do
            if not IsValid(ply) then
                recording[ply] = nil
            else
                local t = now - rec.start
                if t >= maxtime then
                    Say(ply, "Достигнут лимит длины записи.")
                    StopRecording(ply)
                elseif t >= rec.nextT then
                    rec.frames[#rec.frames + 1] = Capture(ply, t, rec)
                    rec.nextT = (interval > 0) and (t + interval) or 0
                end
            end
        end
    end)

    -- Короткие нажатия (R, клик ЛКМ) и отпускание ЛКМ не должны теряться между кадрами записи
    hook.Add("KeyPress", "MyRec_Keys", function(ply, key)
        local rec = recording[ply]
        if not rec then return end
        if key == IN_RELOAD then rec.pendReload = true end
        if key == IN_ATTACK then
            rec.pendClick = true
            rec.holdShots = 0
        end
    end)

    hook.Add("KeyRelease", "MyRec_KeysUp", function(ply, key)
        local rec = recording[ply]
        if rec and key == IN_ATTACK then rec.pendRelease = true end
    end)

    -- Единый учёт выстрелов: запись считает реальные события пуль, а воспроизведение
    -- блокирует любое лишнее событие до того, как пули будут выпущены.
    hook.Add("EntityFireBullets", "MyRec_ShotAccounting", function(ent)
        if IsValid(ent) and ent:IsWeapon() then ent = ent:GetOwner() end

        if IsValid(ent) and ent:IsPlayer() then
            local rec = recording[ent]
            if rec then
                -- Несколько вызовов FireBullets в одном тике (дробь по пулям) — один выстрел
                local ct = CurTime()
                if ct ~= rec.lastShotTime then
                    rec.lastShotTime = ct
                    rec.ammoFired    = (rec.ammoFired or 0) + 1
                    rec.shotsPending = (rec.shotsPending or 0) + 1

                    -- Автоматическое оружие: 3+ выстрела за одно удержание ЛКМ без нового клика
                    rec.holdShots = (rec.holdShots or 0) + 1
                    local w = ent:GetActiveWeapon()
                    if rec.holdShots >= 3 and ent:KeyDown(IN_ATTACK) and IsValid(w) then
                        rec.autoClass[w:GetClass()] = true
                    end
                end
            end
        end

        local pb = IsValid(ent) and playbacks[ent]
        if not (pb and pb.active) then return end

        -- Старые треки без AmmoFired сохраняют совместимость и не получают искусственный лимит.
        if pb.maxShots ~= nil and (pb.budgetUsed or 0) >= pb.maxShots then
            return true -- отменяет лишний EntityFireBullets до выпуска пуль
        end

        pb.ammoFired = (pb.ammoFired or 0) + 1
        pb.budgetUsed = (pb.budgetUsed or 0) + 1
        pb.shotEvents = (pb.shotEvents or 0) + 1
        if not pb.manualShot and pb.wantWeapon then
            pb.native[pb.wantWeapon] = true
        end
    end)

    ------------------------------------------------------------------
    -- ВОСПРОИЗВЕДЕНИЕ
    ------------------------------------------------------------------
    local function StopPlayback(ent, silent, nosync)
        local pb = playbacks[ent]
        if not pb then return end
        playbacks[ent] = nil

        if pb.active and IsValid(ent) then
            if pb.rag then
                for _, p in ipairs(pb.phys) do
                    if IsValid(p.obj) then
                        p.obj:EnableMotion(p.motion)
                        p.obj:Wake()
                    end
                end
            else
                if pb.aimState then SetWeaponAim(ent:GetActiveWeapon(), false) end
                if pb.npcState ~= nil and ent.SetNPCState then ent:SetNPCState(pb.npcState) end
                ent:RemoveEFlags(EFL_NO_THINK_FUNCTION)
                ent:SetMoveType(pb.moveType)
                ent:SetPlaybackRate(1)
            end
        end

        if not silent then Say(pb.owner, "Воспроизведение завершено: " .. (IsValid(ent) and ent:GetClass() or "NPC")) end
        if not nosync then SendSync(pb.owner) end
    end

    -- События кадра записи (клик ЛКМ, отпускание у гранаты) копим в очередь воспроизведения,
    -- чтобы они не терялись, даже если за один тик проскочило несколько кадров
    local function QueueFrameEvents(pb, f, now)
        if pb.useShots then
            -- Новые треки: реальные выстрелы из записи (клик ЛКМ больше не влияет на стрельбу)
            local n = tonumber(f.shots) or 0
            if n > 0 then
                if (pb.shotQueue or 0) <= 0 then pb.shotQueueT = now end
                pb.shotQueue = (pb.shotQueue or 0) + n
            end
        elseif f.click then
            pb.clickPending = true
        end
        if f.release and IsGrenadeClass(f.weapon) then pb.throwQ = f.weapon end
    end

    -- Реальный старт (после задержки группы): отключаем AI, замораживаем и т.д.
    local function Activate(pb, skipEvents)
        local ent = pb.ent
        pb.active = true
        pb.curAct = nil
        if not skipEvents then QueueFrameEvents(pb, pb.frames[1], CurTime()) end

        if pb.rag then
            -- Рэгдолл остаётся там, где лежит, и повторяет форму маршрута
            pb.offset = ent:GetPos() - pb.frames[1].pos
            pb.phys = {}
            for i = 0, ent:GetPhysicsObjectCount() - 1 do
                local obj = ent:GetPhysicsObjectNum(i)
                if IsValid(obj) then
                    pb.phys[#pb.phys + 1] = { obj = obj, motion = obj:IsMotionEnabled() }
                    obj:EnableMotion(false)
                end
            end
        else
            pb.moveType = ent:GetMoveType()
            if ent.GetNPCState then pb.npcState = ent:GetNPCState() end
            ent:AddEFlags(EFL_NO_THINK_FUNCTION) -- AI не мешает анимации/позиции
            ent:SetMoveType(MOVETYPE_NONE)
            if ent.StopMoving then ent:StopMoving() end
        end
    end

    local function StartPlayback(ply, ent, track, delay)
        StopPlayback(ent, true, true)

        playbacks[ent] = {
            ent    = ent,
            owner  = ply,
            frames = track.frames,
            rag    = ent:GetClass() == "prop_ragdoll",
            i      = 1,
            begin  = CurTime() + (delay or 0),
            delay  = delay or 0,
            active = false,
            paused = false,
            native = {}, -- классы оружия, которые стреляют сами (от событий анимации)
            autoClass = track.autoClass or {},
            maxShots = track.ammoFired, -- nil у старых записей; у новых — жёсткий предел выстрелов
            ammoFired = 0, -- фактически произведённые выстрелы в текущем playback-сеансе
            budgetUsed = 0, -- расход лимита, включая выстрелы, пропущенные перемоткой вперёд
            shotEvents = 0,
            legacy    = not track.hasClick, -- старый трек без кликов: стреляем как раньше (по удержанию)
            useShots  = track.hasShots == true, -- трек с записанными событиями выстрелов
            shotQueue = 0,  -- сколько записанных выстрелов ещё ждут воспроизведения
            shotQueueT = 0, -- когда выстрел встал в очередь (для срока годности)
        }
        if ownerPaused[ply] then
            local pb = playbacks[ent]
            pb.paused = true
            pb.pausedDelay = math.max(0, pb.begin - CurTime())
        end
    end

    -- Есть ли у модели NPC анимация под эту активность
    local function HasActivity(ent, act)
        local s = ent:SelectWeightedSequence(act)
        return s ~= nil and s >= 0
    end

    local function FirstAvailable(ent, list)
        for _, act in ipairs(list) do
            if HasActivity(ent, act) then return act end
        end
        return ACT_IDLE
    end

    -- Список активностей по именам (часть констант может отсутствовать в этой версии GMod)
    local function ActsByName(names)
        local out = {}
        for _, n in ipairs(names) do
            local v = _G[n]
            if v ~= nil then out[#out + 1] = v end
        end
        return out
    end

    local ACTS_AIM_IDLE   = ActsByName({ "ACT_IDLE_ANGRY", "ACT_IDLE_AIM_RIFLE_STIMULATED", "ACT_RANGE_AIM_MED", "ACT_IDLE" })
    local ACTS_AIM_LOW    = ActsByName({ "ACT_RANGE_AIM_LOW", "ACT_IDLE_ANGRY", "ACT_CROUCHIDLE", "ACT_IDLE" })
    local ACTS_AIM_WALK   = ActsByName({ "ACT_WALK_AIM", "ACT_WALK_AIM_RIFLE", "ACT_WALK_AIM_RIFLE_STIMULATED", "ACT_WALK" })
    local ACTS_AIM_RUN    = ActsByName({ "ACT_RUN_AIM", "ACT_RUN_AIM_RIFLE", "ACT_RUN_AIM_RIFLE_STIMULATED", "ACT_RUN" })
    local ACTS_RELOAD     = ActsByName({ "ACT_RELOAD", "ACT_RELOAD_SMG1", "ACT_RELOAD_PISTOL", "ACT_RELOAD_SHOTGUN" })
    local ACTS_RELOAD_LOW = ActsByName({ "ACT_RELOAD_LOW", "ACT_RELOAD", "ACT_RELOAD_SMG1", "ACT_RELOAD_PISTOL" })
    local ACTS_THROW      = ActsByName({ "ACT_GMOD_GESTURE_ITEM_THROW", "ACT_RANGE_ATTACK_THROW", "ACT_RANGE_ATTACK2" })

    -- Выбрать активность по скорости движения, приседу и прицеливанию (ПКМ)
    local function PickActivity(ent, speed, crouch, aiming)
        if aiming then
            if crouch then
                if speed <= SPEED_WALK_MIN then return FirstAvailable(ent, ACTS_AIM_LOW) end
                -- движение в приседе с прицелом — обычные анимации приседа ниже
            elseif speed > SPEED_RUN_MIN then
                return FirstAvailable(ent, ACTS_AIM_RUN)
            elseif speed > SPEED_WALK_MIN then
                return FirstAvailable(ent, ACTS_AIM_WALK)
            else
                return FirstAvailable(ent, ACTS_AIM_IDLE)
            end
        end

        if crouch then
            if speed > SPEED_RUN_MIN then
                return FirstAvailable(ent, { ACT_RUN_CROUCH, ACT_WALK_CROUCH, ACT_RUN, ACT_WALK })
            elseif speed > SPEED_WALK_MIN then
                return FirstAvailable(ent, { ACT_WALK_CROUCH, ACT_RUN_CROUCH, ACT_WALK, ACT_RUN })
            else
                return FirstAvailable(ent, { ACT_CROUCHIDLE, ACT_COVER_LOW, ACT_IDLE })
            end
        end

        if speed > SPEED_RUN_MIN and HasActivity(ent, ACT_RUN) then
            return ACT_RUN
        elseif speed > SPEED_WALK_MIN then
            return FirstAvailable(ent, { ACT_WALK, ACT_RUN })
        end
        return ACT_IDLE
    end

    -- Привести оружие NPC в соответствие с классом из кадра записи
    local function SyncWeapon(pb, class)
        class = class or ""
        if pb.wantWeapon == class then return end
        pb.wantWeapon = class

        -- пустые руки / инструменты: оружие NPC не трогаем (стрелять с ним тоже не будем)
        if class == "" or WEAPON_BLACKLIST[class] then return end

        local npc = pb.ent
        local old = npc:GetActiveWeapon()
        if IsValid(old) and old:GetClass() == class then return end

        local new = npc:Give(class)
        if npc.SelectWeapon then pcall(npc.SelectWeapon, npc, class) end

        -- не копим старое оружие в инвентаре NPC
        if IsValid(old) and IsValid(new) and old ~= new then old:Remove() end
    end

    -- Можно ли в этом кадре стрелять: нажата ЛКМ, оружие годится и реально в руках у NPC
    local function CanAttack(pb, a)
        local class = a.weapon
        if not a.attack or class == "" or WEAPON_BLACKLIST[class] or IsGrenadeClass(class) then return false end

        local w = pb.ent:GetActiveWeapon()
        return IsValid(w) and w:GetClass() == class
    end

    -- Активность атаки (движок сам подберёт анимацию под оружие в руках NPC)
    local function AttackActivity(class, crouch)
        if MELEE_WEAPONS[class] then return ACT_MELEE_ATTACK1 end
        return crouch and ACT_RANGE_ATTACK1_LOW or ACT_RANGE_ATTACK1
    end

    -- Огнестрельное оружие в руках NPC, если оно совпадает с записанным в кадре
    local function HeldFirearm(pb, a)
        local class = a.weapon
        if class == "" or WEAPON_BLACKLIST[class] or MELEE_WEAPONS[class] or IsGrenadeClass(class) then return nil end

        local w = pb.ent:GetActiveWeapon()
        if IsValid(w) and w:GetClass() == class then return w end
        return nil
    end

    -- Готово ли оружие технически стрелять: кулдаун считает само оружие по часам сервера
    local function WeaponReady(wep)
        return IsValid(wep) and not (wep:GetNextPrimaryFire() > CurTime())
    end

    -- Дополнительные функции сброса виртуального курка (для кастомных баз)
    local function ReleaseTrigger(wep)
        if not IsValid(wep) then return end
        if wep.InitializeClicks then pcall(wep.InitializeClicks, wep) end
        if wep.ReleaseTrigger then pcall(wep.ReleaseTrigger, wep) end
        for _, fn in ipairs({ "ResetClicks", "ResetTrigger" }) do
            if isfunction(wep[fn]) then pcall(wep[fn], wep) end
        end
        for _, fn in ipairs({ "SetTriggerDown", "SetTriggerHeld" }) do
            if isfunction(wep[fn]) then pcall(wep[fn], wep, false) end
        end
    end

    -- Выстрел «родным» методом оружия. На время вызова подменяем у NPC направление
    -- прицеливания, чтобы кастомная база стреляла туда, куда смотрел игрок.
    local function FirePrimary(ent, wep, dir)
        local tbl = ent:GetTable()
        local oldAim, oldEye = rawget(tbl, "GetAimVector"), rawget(tbl, "EyeAngles")
        local eyeAng = dir:Angle()

        tbl.GetAimVector = function() return dir end
        tbl.EyeAngles    = function() return eyeAng end

        local ok, err = pcall(wep.PrimaryAttack, wep)

        tbl.GetAimVector = oldAim
        tbl.EyeAngles    = oldEye
        return ok, err
    end

    -- Запасной выстрел, если PrimaryAttack() у этого оружия на NPC падает с ошибкой.
    -- Темп берётся из данных самого оружия (Primary.Delay / RPM) и хранится в его NextPrimaryFire.
    -- Возвращает true, если выстрел произведён.
    local function GenericFire(pb, ent, wep, now, dir)
        if not WeaponReady(wep) then return false end

        local pr = istable(wep.Primary) and wep.Primary or {}
        local rpm = tonumber(pr.RPM) or tonumber(wep.RPM)
        local delay = tonumber(pr.Delay) or tonumber(wep.Delay) or tonumber(wep.NPCFireRate)
        if rpm and rpm > 0 then delay = 60 / rpm end
        wep:SetNextPrimaryFire(CurTime() + (delay or 0.1))

        local dmg = tonumber(pr.Damage) or tonumber(wep.Damage) or tonumber(wep.DamageMax) or 12
        local sp  = tonumber(pr.Spread) or 0.02

        pb.manualShot = true
        ent:FireBullets({
            Attacker = ent, Inflictor = wep,
            Damage = dmg, Num = tonumber(pr.NumShots) or 1,
            Src = ent:GetShootPos(), Dir = dir,
            Spread = Vector(sp, sp, 0),
            Tracer = 1, Force = dmg * 0.1,
        })
        pb.manualShot = false

        local snd = pr.Sound or wep.ShootSound
        if isstring(snd) and snd ~= "" then wep:EmitSound(snd) end
        return true
    end

    -- Автоматическое ли оружие (стреляет, пока ЛКМ зажата).
    -- Одиночное (револьвер, дробовик, СВД) стреляет только по кликам из записи.
    local function IsAutoFire(pb, wep, class)
        if pb.legacy then return true end                      -- старый трек: как раньше
        if pb.autoClass and pb.autoClass[class] then return true end -- при записи стреляло очередью

        -- Новые треки: «автомат» определяется только по записанному поведению.
        -- Primary.Automatic у ARC9 / TFA / MWB часто true даже у полуавтоматов, ему верить нельзя.
        if pb.useShots then return false end

        if wep.GetStatL then                                   -- TFA: учитывает режим огня
            local ok, v = pcall(wep.GetStatL, wep, "Primary.Automatic")
            if ok and v == true then return true end
        end

        local pr = wep.Primary
        return istable(pr) and pr.Automatic == true
    end

    local SHOT_GRACE = 0.25 -- сек: сколько записанный выстрел ждёт готовности оружия NPC

    local function ShotLimitReached(pb)
        return pb.maxShots ~= nil and (pb.budgetUsed or pb.ammoFired or 0) >= pb.maxShots
    end

    -- Стрельба из кастомного оружия (ARC9 / TFA / MWB)
    local function CustomFire(pb, ent, wep, now, ang)
        if not IsValid(wep) then
            pb.clickPending = false
            return
        end

        local class = wep:GetClass()
        local automatic = IsAutoFire(pb, wep, class)
        local singleClick = not automatic

        -- Полуавтоматическое оружие получает право на одну попытку
        -- только при наличии нового записанного клика.
        if singleClick then
            if pb.useShots then
                if (pb.shotQueue or 0) <= 0 then return end

                -- Выстрел из записи живёт недолго: если оружие NPC не успело
                -- остыть за SHOT_GRACE, событие пропадает, а не стреляет «потом».
                if now - (pb.shotQueueT or now) > SHOT_GRACE then
                    pb.shotQueue = 0
                    ReleaseTrigger(wep)
                    return
                end
            else
                if not pb.clickPending then return end

                -- Старые треки: клик гасится ДО любых проверок и вызовов.
                pb.clickPending = false
            end
        end

        -- Проверяем кулдаун именно того SWEP, который собираемся использовать.
        -- Для одиночного оружия заблокированный клик окончательно пропускается.
        if isfunction(wep.GetNextPrimaryFire) then
            local ok, nextFire = pcall(wep.GetNextPrimaryFire, wep)

            if ok and isnumber(nextFire) and nextFire > now then
                if singleClick then
                    ReleaseTrigger(wep)
                end
                return
            end
        end

        -- Кулдаун пройден: этот выстрел реально произойдёт — списываем одно записанное событие
        if singleClick and pb.useShots then
            pb.shotQueue  = math.max(0, (pb.shotQueue or 0) - 1)
            pb.shotQueueT = now
        end

        local dir = ang:Forward()

        if pb.brokenClass == class then
            GenericFire(pb, ent, wep, now, dir)
            if singleClick then
                ReleaseTrigger(wep)
            end
            return
        end

        -- Пополняем пустой магазин, если запись не воспроизводит перезарядку.
        if not pb.reloadUntil then
            local mx = wep:GetMaxClip1()
            if mx and mx > 0 and wep:Clip1() == 0 then wep:SetClip1(mx) end
        end

        local beforeEvents = pb.shotEvents or 0
        local ok, err = FirePrimary(ent, wep, dir)

        if singleClick then
            ReleaseTrigger(wep)
        end

        if ok then
            if (pb.shotEvents or 0) == beforeEvents and pb.maxShots ~= nil then
                pb.ammoFired = (pb.ammoFired or 0) + 1
                pb.budgetUsed = (pb.budgetUsed or 0) + 1
            end
        else
            pb.brokenClass = class
            local msg = ("PrimaryAttack() у %s выдал ошибку: %s — включён запасной выстрел."):format(
                class, tostring(err))
            Say(pb.owner, msg)
            MsgN("[MyRec] " .. msg)
        end
    end

    ------------------------------------------------------------------
    -- Гранаты
    ------------------------------------------------------------------
    local function NadeEntityCandidates(wep, class)
        local list, seen = {}, {}
        local function add(v)
            if isstring(v) and v ~= "" and not seen[v] then
                seen[v] = true
                list[#list + 1] = v
            end
        end

        local sources = { weapons.Get(class) }
        if IsValid(wep) then sources[#sources + 1] = wep end

        for _, src in ipairs(sources) do
            add(src.ShootEnt) add(src.ShootEntity) add(src.ProjectileEntity)
            add(src.Projectile) add(src.ProjectileClass)
            if istable(src.Primary) then
                add(src.Primary.Projectile) add(src.Primary.ProjectileClass)
            end
        end

        local lc = string.lower(class)
        local special = string.find(lc, "smoke", 1, true) or string.find(lc, "flash", 1, true)
            or string.find(lc, "gas", 1, true) or string.find(lc, "stun", 1, true)
        if not special and (class == "weapon_frag" or string.find(lc, "frag", 1, true)
            or string.find(lc, "grenade", 1, true)) then
            add("npc_grenade_frag")
        end

        return list
    end

    local function SpawnNade(ent, cls, src, ang, vel)
        local g = ents.Create(cls)
        if not IsValid(g) then return nil end

        g.MyRecNade = true
        g:SetPos(src)
        g:SetAngles(ang)
        g:SetOwner(ent)

        local ok = pcall(function()
            g:Spawn()
            g:Activate()
        end)
        if not ok or not IsValid(g) then
            if IsValid(g) then g:Remove() end
            return nil
        end

        pcall(g.SetSaveValue, g, "m_hThrower", ent)
        if cls == "npc_grenade_frag" then g:Fire("SetTimer", 3, 0) end

        local phys = g:GetPhysicsObject()
        if IsValid(phys) then
            phys:Wake()
            phys:SetVelocity(vel)
            phys:AddAngleVelocity(VectorRand() * 300)
        else
            g:SetVelocity(vel)
        end

        return g
    end

    local function ThrowGrenade(pb, ent, class, ang, now)
        local wep = ent:GetActiveWeapon()
        if not (IsValid(wep) and wep:GetClass() == class) then wep = nil end

        local act
        for _, v in ipairs(ACTS_THROW) do
            if HasActivity(ent, v) then act = v break end
        end

        local dur = 0.8
        if act then
            ent:SetActivity(act)
            ent:ResetSequenceInfo()
            ent:SetCycle(0)
            dur = math.Clamp(ent:SequenceDuration() or dur, 0.5, 3)
            pb.throwAct   = act
            pb.throwUntil = now + dur
            pb.curAct     = act
        elseif ACT_GMOD_GESTURE_ITEM_THROW then
            pcall(ent.AddGesture, ent, ACT_GMOD_GESTURE_ITEM_THROW)
        end

        pb.nadeGuardUntil = now + dur + 0.5

        local fwd = ang:Forward()
        local src = ent:GetShootPos() + fwd * 16
        local vel = fwd * NADE_SPEED + Vector(0, 0, NADE_LIFT)

        for _, cls in ipairs(NadeEntityCandidates(wep, class)) do
            if SpawnNade(ent, cls, src, ang, vel) then return end
        end

        if wep and IsCustomWeapon(wep) and FirePrimary(ent, wep, fwd) then return end

        if not pb.nadeWarned then
            pb.nadeWarned = true
            Say(pb.owner, ("Не удалось определить сущность гранаты для %s — бросок не выполнен."):format(class))
        end
    end

    local function StartReload(pb, ent, wep, crouch, now)
        pcall(wep.Reload, wep)

        local list = crouch and ACTS_RELOAD_LOW or ACTS_RELOAD
        local act
        for _, v in ipairs(list) do
            if HasActivity(ent, v) then act = v break end
        end
        act = act or ACT_RELOAD

        ent:SetActivity(act)
        ent:ResetSequenceInfo()
        ent:SetCycle(0)

        local dur = ent:SequenceDuration()
        if not dur or dur < 1 then dur = 1.5 end

        pb.reloadAct   = act
        pb.reloadUntil = now + math.min(dur, 6)
        pb.curAct      = act
    end

    local function ManualFire(pb, ent, now, class, ang)
        if pb.native[class] then return end
        if ShotLimitReached(pb) then return end

        if not pb.attackSince then pb.attackSince = now end
        if now - pb.attackSince < 1 then return end

        local wep = ent:GetActiveWeapon()
        if not IsValid(wep) then return end
        if not WeaponReady(wep) then return end

        local info = FIRE_INFO[class]

        if not wep.NPCShoot_Primary and not info and weapons.GetStored(class) then
            if not WeaponReady(wep) then return end
            local beforeNext = wep:GetNextPrimaryFire()
            local beforeEvents = pb.shotEvents or 0
            pb.manualShot = true
            FirePrimary(ent, wep, ang:Forward())
            pb.manualShot = false
            if (pb.shotEvents or 0) == beforeEvents and pb.maxShots ~= nil then
                pb.ammoFired = (pb.ammoFired or 0) + 1
                pb.budgetUsed = (pb.budgetUsed or 0) + 1
            end
            wep:SetNextPrimaryFire(beforeNext)
            return
        end

        if now < (pb.nextManual or 0) then return end
        pb.nextManual = now + (wep.NPCFireRate or (info and info.delay) or 0.12)

        local src = ent:GetShootPos()
        local dir = ang:Forward()

        local beforeEvents = pb.shotEvents or 0
        pb.manualShot = true
        if wep.NPCShoot_Primary then
            pcall(wep.NPCShoot_Primary, wep, src, dir)
        elseif info then
            local sp = info.spread
            ent:FireBullets({
                Attacker = ent, Num = info.num or 1,
                Src = src, Dir = dir,
                Spread = Vector(sp, sp, 0),
                Tracer = 1, Force = 2,
                AmmoType = info.ammo,
            })
            wep:EmitSound(info.snd)
        end
        pb.manualShot = false
        if (pb.shotEvents or 0) == beforeEvents and pb.maxShots ~= nil then
            pb.ammoFired = (pb.ammoFired or 0) + 1
            pb.budgetUsed = (pb.budgetUsed or 0) + 1
        end
    end

    local function ApplyToNPC(pb, a, b, frac)
        local ent = pb.ent
        local now = CurTime()

        SyncWeapon(pb, a.weapon)

        ent:SetPos(LerpVector(frac, a.pos, b.pos))
        local ang = LerpAngle(frac, a.ang, b.ang)
        ent:SetAngles(Angle(0, ang.y, 0))

        local span  = b.t - a.t
        local speed = (span > 0) and (a.pos:Distance(b.pos) / span) or 0

        local wep    = HeldFirearm(pb, a)
        local custom = wep ~= nil and IsCustomWeapon(wep)

        local aiming = (wep ~= nil and a.aim) and true or false
        if aiming then
            if ent.SetNPCState then ent:SetNPCState(NPC_STATE_COMBAT) end
            SetWeaponAim(wep, true)
            pb.aimState = true
        elseif pb.aimState then
            SetWeaponAim(ent:GetActiveWeapon(), false)
            pb.aimState = false
        end

        local wantReload = (wep ~= nil and a.reload) and true or false
        if wantReload and not pb.prevReload and not pb.reloadUntil then
            StartReload(pb, ent, wep, a.crouch, now)
        end
        pb.prevReload = wantReload

        local reloading = pb.reloadUntil ~= nil
        if reloading and now >= pb.reloadUntil then
            pb.reloadUntil = nil
            pb.curAct = nil
            reloading = false

            if IsValid(wep) then
                local mx = wep:GetMaxClip1()
                if mx and mx > 0 and wep:Clip1() < mx then wep:SetClip1(mx) end
            end
        end

        if pb.throwQ then
            ThrowGrenade(pb, ent, pb.throwQ, ang, now)
            pb.throwQ = nil
        end

        local throwing = pb.throwUntil ~= nil
        if throwing and now >= pb.throwUntil then
            pb.throwUntil = nil
            pb.curAct = nil
            throwing = false
        end

        local attacking = CanAttack(pb, a) and not reloading and not throwing

        local fire = false
        if custom then
            local automatic = IsAutoFire(pb, wep, a.weapon)
            if not reloading and not throwing then
                if automatic then
                    pb.clickPending = false
                    pb.shotQueue = 0
                    fire = attacking
                elseif pb.useShots then
                    -- Полуавтомат: стреляем строго по записанным событиям выстрела,
                    -- сколько бы кадров ни была зажата ЛКМ
                    fire = (pb.shotQueue or 0) > 0
                else
                    fire = pb.clickPending == true
                end
            else
                if not automatic then
                    pb.clickPending = false
                    pb.shotQueue = 0 -- во время перезарядки/броска выстрелы не копим
                end
            end
        end

        local act
        if reloading then
            act = pb.reloadAct
        elseif throwing then
            act = pb.throwAct
        elseif attacking then
            act = AttackActivity(a.weapon, a.crouch)
        else
            act = PickActivity(ent, speed, a.crouch, aiming)
        end
        if pb.curAct ~= act then
            pb.curAct = act
            ent:SetActivity(act)
        end

        local rate = 1
        if not attacking and not reloading and not throwing
            and act ~= ACT_IDLE and act ~= ACT_CROUCHIDLE and act ~= ACT_COVER_LOW then
            local gs = ent:GetSequenceGroundSpeed(ent:GetSequence())
            if gs and gs > 1 then
                rate = math.Clamp(speed / gs, 0.3, 3)
            end
        end
        ent:SetPlaybackRate(rate)
        ent:FrameAdvance(engine.TickInterval())

        if attacking and ent:IsSequenceFinished() then
            ent:ResetSequenceInfo()
            ent:SetCycle(0)
        end

        if not pb.suppressFire then
            if fire then
                CustomFire(pb, ent, wep, now, ang)
            elseif attacking and not custom then
                ManualFire(pb, ent, now, a.weapon, ang)
            end
        end

        if not attacking then pb.attackSince = nil end

        if custom and not IsAutoFire(pb, wep, a.weapon) then
            if pb.clickPending then pb.clickPending = false end
        elseif pb.shotQueue and pb.shotQueue > 0 and not custom then
            pb.shotQueue = 0 -- не кастомное оружие в руках: очередь не нужна
        end

        for name, va in pairs(a.pose) do
            local vb = b.pose[name] or va
            SetNormPose(ent, name, Lerp(frac, va, vb))
        end

        if aiming or (custom and (attacking or fire)) then
            SetRealPose(ent, "aim_pitch", math.NormalizeAngle(ang.p) * AIM_PITCH_SIGN)
            SetRealPose(ent, "aim_yaw", 0)
        end
    end

    local function ApplyToRagdoll(pb, a, b, frac)
        local ent = pb.ent
        local target = LerpVector(frac, a.pos, b.pos) + pb.offset
        local delta = target - ent:GetPos()

        for _, p in ipairs(pb.phys) do
            if IsValid(p.obj) then
                p.obj:SetPos(p.obj:GetPos() + delta)
            end
        end
    end

    local function Apply(pb, a, b, frac)
        if pb.rag then ApplyToRagdoll(pb, a, b, frac) else ApplyToNPC(pb, a, b, frac) end
    end

    local function PlaybackElapsed(pb, now)
        if not pb.active then return 0 end
        local frames = pb.frames or {}
        local duration = #frames > 0 and math.max(0, frames[#frames].t or 0) or 0
        if pb.paused then return math.min(duration, pb.pausedElapsed or 0) end
        return math.min(duration, math.max(0, now - (pb.start or now)))
    end

    local function SetOwnerPaused(ply, paused)
        if not IsPlaying(ply) then
            ownerPaused[ply] = false
            return
        end
        local now = CurTime()
        ownerPaused[ply] = paused and true or false
        for ent, pb in pairs(playbacks) do
            if pb.owner == ply then
                if paused and not pb.paused then
                    local elapsedBeforePause = PlaybackElapsed(pb, now)
                    pb.paused = true
                    if pb.active then
                        pb.pausedElapsed = elapsedBeforePause
                    else
                        pb.pausedDelay = math.max(0, (pb.begin or now) - now)
                    end
                    if IsValid(ent) and not pb.rag then
                        ent:SetVelocity(vector_origin)
                        ent:SetPlaybackRate(0)
                    end
                elseif not paused and pb.paused then
                    pb.paused = false
                    if pb.active then
                        pb.start = now - (pb.pausedElapsed or 0)
                    else
                        pb.begin = now + (pb.pausedDelay or 0)
                    end
                    pb.pausedElapsed, pb.pausedDelay = nil, nil
                    if IsValid(ent) and not pb.rag then ent:SetPlaybackRate(1) end
                end
            end
        end
    end

    local function ApplyAtTime(pb, requestedTime)
        if not IsValid(pb.ent) or #pb.frames == 0 then return end
        local now = CurTime()
        local frames, n = pb.frames, #pb.frames
        local duration = math.max(0, frames[n].t or 0)
        local requested = math.max(0, tonumber(requestedTime) or 0)
        local elapsed = math.Clamp(requested, 0, duration)
        pb.holdEnd = requested >= duration

        if not pb.active then
            pb.begin = now
            Activate(pb, true)
            pb.start = now - elapsed
        else
            pb.start = now - elapsed
        end
        pb.pausedElapsed = pb.paused and elapsed or nil
        pb.i = 1
        pb.clickPending, pb.throwQ = false, nil
        pb.shotQueue = 0
        pb.attackSince, pb.reloadUntil, pb.throwUntil = nil, nil, nil
        pb.curAct, pb.reloadAct, pb.throwAct = nil, nil, nil

        local i = 1
        while i < n - 1 and frames[i + 1].t <= elapsed do i = i + 1 end
        pb.i = i
        local a, b, frac
        if i >= n then
            a, b, frac = frames[n], frames[n], 0
        else
            a, b = frames[i], frames[i + 1]
            local span = (b.t or 0) - (a.t or 0)
            frac = span > 0 and math.Clamp((elapsed - a.t) / span, 0, 1) or 0
        end
        pb.suppressFire = true
        Apply(pb, a, b, frac)
        pb.suppressFire = nil

        local shotsA = tonumber(a.AmmoFired) or 0
        local shotsB = tonumber(b.AmmoFired) or shotsA
        if pb.maxShots ~= nil then
            local expectedShots = math.floor(Lerp(frac, shotsA, shotsB) + 0.5)
            pb.budgetUsed = math.max(pb.budgetUsed or 0, math.min(pb.maxShots, expectedShots))
        end
        if pb.paused and IsValid(pb.ent) and not pb.rag then
            pb.ent:SetVelocity(vector_origin)
            pb.ent:SetPlaybackRate(0)
        end
    end

    local function SeekOwner(ply, requestedTime)
        requestedTime = math.Clamp(tonumber(requestedTime) or 0, 0, 3600)
        for _, pb in pairs(playbacks) do
            if pb.owner == ply and IsValid(pb.ent) then
                ApplyAtTime(pb, requestedTime)
            end
        end
    end

    local function TimelineInfo(ply)
        local now, current, maximum, paused = CurTime(), 0, 0, ownerPaused[ply] == true
        for _, pb in pairs(playbacks) do
            if pb.owner == ply then
                local frames = pb.frames or {}
                local duration = #frames > 0 and (frames[#frames].t or 0) or 0
                maximum = math.max(maximum, duration)
                current = math.max(current, PlaybackElapsed(pb, now))
                paused = paused or pb.paused == true
            end
        end
        return current, maximum, paused
    end

    hook.Add("Tick", "MyRec_Playback", function()
        local now = CurTime()

        for ent, pb in pairs(playbacks) do
            if not IsValid(ent) then
                playbacks[ent] = nil
                SendSync(pb.owner)
            else
                if pb.paused then
                    if IsValid(ent) and not pb.rag then
                        ent:SetVelocity(vector_origin)
                        ent:SetPlaybackRate(0)
                    end
                else
                    if not pb.active and now >= pb.begin then
                        Activate(pb)
                        pb.start = now
                    end

                    if pb.active then
                        local frames = pb.frames
                        local n  = #frames
                        local el = now - pb.start

                        if el >= frames[n].t then
                            if pb.holdEnd then
                                ent:SetVelocity(vector_origin)
                                ent:SetPlaybackRate(0)
                            else
                                local last = frames[n]
                                for k = pb.i + 1, n do QueueFrameEvents(pb, frames[k], now) end
                                Apply(pb, last, last, 0)
                                StopPlayback(ent)
                            end
                        else
                            pb.holdEnd = false
                            local i = pb.i
                            while i < n - 1 and frames[i + 1].t <= el do
                                i = i + 1
                                QueueFrameEvents(pb, frames[i], now)
                            end
                            pb.i = i

                            local a, b = frames[i], frames[i + 1]
                            local span = b.t - a.t
                            local frac = span > 0 and math.Clamp((el - a.t) / span, 0, 1) or 0
                            Apply(pb, a, b, frac)
                        end
                    end
                end
            end
        end
    end)

    hook.Add("OnEntityCreated", "MyRec_NoDupNade", function(e)
        if not IsValid(e) or e:GetClass() ~= "npc_grenade_frag" then return end

        timer.Simple(0, function()
            if not IsValid(e) or e.MyRecNade then return end

            local o = e:GetOwner()
            if not IsValid(o) then o = e:GetInternalVariable("m_hThrower") end

            local pb = IsValid(o) and playbacks[o]
            if pb and pb.active and CurTime() < (pb.nadeGuardUntil or 0) then e:Remove() end
        end)
    end)

    local function BindTrack(ply, trackName, groupId)
        local d = Dir(ply)
        local track = FindTrack(d, trackName)
        local group = FindGroup(d, groupId)

        if not track then Say(ply, "Выбери трек в списке «Анимации».") return end
        if not group then Say(ply, "Выбери группу в списке групп.") return end

        local ent = ply:GetEyeTrace().Entity
        if not IsValidTarget(ent) then
            Say(ply, "Наведи прицел на NPC (или рэгдолл) и повтори.")
            return
        end

        -- Один объект — одна привязка; личную задержку при перепривязке сохраняем
        local keepDelay = 0
        for i, b in ipairs(d.bindings) do
            if b.ent == ent then
                keepDelay = b.delay or 0
                table.remove(d.bindings, i)
                break
            end
        end
        if #d.bindings >= MAX_BINDINGS then
            Say(ply, "Достигнут лимит привязок.")
            return
        end

        local gave = GiveNPCWeapon(ent, track.weapon)

        -- Манифест спавна: класс, модель, позиция, углы, оружие (+ трек и группа в самой привязке)
        local bid = d.nextBid
        d.nextBid = bid + 1
        d.bindings[#d.bindings + 1] = {
            bid = bid, ent = ent, track = track.name, group = group.id,
            delay = keepDelay,
            manifest = CaptureManifest(ent, track.weapon),
        }

        Say(ply, ("«%s» → %s (%s)%s"):format(track.name, ent:GetClass(), group.name,
            gave and (", оружие: " .. track.weapon) or ""))
        SendSync(ply)
    end

    -- Текущее время сцены (с учётом задержек): max по активным и ожидающим старта NPC
    local function SceneTime(ply)
        local now, best = CurTime(), nil
        for ent, pb in pairs(playbacks) do
            if pb.owner == ply and IsValid(ent) then
                local t
                if pb.active then
                    t = PlaybackElapsed(pb, now) + (pb.delay or 0)
                else
                    t = (pb.delay or 0) - math.max(0, (pb.begin or now) - now)
                end
                if not best or t > best then best = t end
            end
        end
        return best
    end

    -- Создать NPC (или рэгдолл) по манифесту
    local function SpawnFromManifest(m)
        local ent = ents.Create(m.class)
        if not IsValid(ent) then return nil end

        if m.model and m.model ~= "" then ent:SetModel(m.model) end
        ent:SetPos(m.pos)
        ent:SetAngles(m.ang)
        if m.class ~= "prop_ragdoll" and m.spawnflags then
            ent:SetKeyValue("spawnflags", tostring(m.spawnflags))
        end
        ent:Spawn()
        ent:Activate()
        ent:SetPos(m.pos)
        ent:SetAngles(m.ang)

        ent:SetSkin(m.skin or 0)
        for i, v in pairs(m.bodygroups or {}) do ent:SetBodygroup(i, v) end
        if m.weapon and m.weapon ~= "" then GiveNPCWeapon(ent, m.weapon) end
        return ent
    end

    local function PlayAll(ply)
        local d = Dir(ply)
        local count, dead = 0, 0

        for _, b in ipairs(d.bindings) do
            local track = FindTrack(d, b.track)
            local group = FindGroup(d, b.group)
            if BindingAlive(b) and track and group then
                -- До первого запуска обновляем манифест (NPC могли передвинуть после привязки);
                -- после запуска NPC уезжает по треку, и «точка спавна» фиксируется.
                if not b.played and not playbacks[b.ent] then
                    local w = b.manifest.weapon
                    b.manifest = CaptureManifest(b.ent, w)
                end
                b.played = true

                -- Итоговая задержка = задержка группы + личная задержка NPC
                StartPlayback(ply, b.ent, track, (group.delay or 0) + (b.delay or 0))
                count = count + 1
            elseif not BindingAlive(b) then
                dead = dead + 1
            end
        end

        if count == 0 and dead == 0 then
            Say(ply, "Нет привязанных NPC. Привяжи треки к NPC.")
        else
            local msg = "Запущено объектов: " .. count
            if dead > 0 then msg = msg .. (" (убитых: %d — нажми «Возобновить сценарий»)"):format(dead) end
            Say(ply, msg)
        end
        SendSync(ply)
    end

    -- Возобновить сценарий: переспавнить убитых / удалённых NPC по манифесту,
    -- вернуть им оружие, трек и группу; если сцена идёт — включить их с нужного момента таймлайна.
    local function RestoreScene(ply)
        local d = Dir(ply)
        local restored, started, failed = 0, 0, 0
        local sceneT = SceneTime(ply) -- nil, если сцена не проигрывается

        for _, b in ipairs(d.bindings) do
            if not BindingAlive(b) then
                local track = FindTrack(d, b.track)
                local group = FindGroup(d, b.group)

                if not (track and group and b.manifest) then
                    failed = failed + 1
                else
                    -- убитый, но ещё не удалённый NPC: гасим его воспроизведение и убираем
                    local old = b.ent
                    if IsValid(old) then
                        if playbacks[old] then StopPlayback(old, true, true) end
                        old:Remove()
                    end

                    local ent = SpawnFromManifest(b.manifest)
                    if not IsValid(ent) then
                        failed = failed + 1
                    else
                        b.ent = ent -- повторная привязка к тому же треку и группе (b.track / b.group)
                        restored = restored + 1

                        if sceneT then
                            local total = (group.delay or 0) + (b.delay or 0)
                            local localT = sceneT - total
                            local duration = track.duration or 0

                            if localT < 0 then
                                -- его старт ещё впереди: ждём оставшуюся задержку
                                StartPlayback(ply, ent, track, -localT)
                                started = started + 1
                            elseif localT < duration then
                                -- сцена уже идёт: подключаем с нужного места таймлайна
                                StartPlayback(ply, ent, track, 0)
                                local pb = playbacks[ent]
                                if pb then
                                    pb.delay = total
                                    ApplyAtTime(pb, localT)
                                    started = started + 1
                                end
                            end
                            -- localT >= duration: его часть сцены уже закончилась, просто стоит на месте
                            b.played = true
                        end
                    end
                end
            end
        end

        if restored == 0 and failed == 0 then
            Say(ply, "Все NPC сценария живы — восстанавливать нечего.")
        else
            local msg = ("Возобновлено NPC: %d"):format(restored)
            if sceneT then msg = msg .. (", подключено к идущей сцене: %d"):format(started) end
            if failed > 0 then msg = msg .. (", не удалось: %d (нет трека/группы или класс не создаётся)"):format(failed) end
            Say(ply, msg)
        end
        SendSync(ply)
    end

    -- Обновляем GUI, когда привязанный NPC погиб или был удалён
    local function ResyncOwnersOf(ent)
        for ply, d in pairs(director) do
            for _, b in ipairs(d.bindings) do
                if b.ent == ent then
                    if IsValid(ply) then SendSync(ply) end
                    break
                end
            end
        end
    end

    hook.Add("OnNPCKilled", "MyRec_BindingDeath", function(npc)
        timer.Simple(0, function() ResyncOwnersOf(npc) end)
    end)

    hook.Add("EntityRemoved", "MyRec_BindingRemoved", function(ent)
        if not (ent:IsNPC() or ent:GetClass() == "prop_ragdoll") then return end
        timer.Simple(0, function() ResyncOwnersOf(ent) end)
    end)

    local function StopAll(ply)
        for ent, pb in pairs(playbacks) do
            if pb.owner == ply then StopPlayback(ent, true, true) end
        end
        ownerPaused[ply] = false
        SendSync(ply)
    end

    net.Receive(NET_CMD, function(_, ply)
        if not CanUse(ply) then return end
        local cmd = net.ReadUInt(4)
        local d = Dir(ply)

        if cmd == CMD.SYNC then
            SendSync(ply)
        elseif cmd == CMD.START then
            StartRecording(ply, net.ReadString())
        elseif cmd == CMD.STOP then
            if recording[ply] then StopRecording(ply) else Say(ply, "Запись не идёт.") end
        elseif cmd == CMD.DEL_TRACK then
            local name = net.ReadString()
            for i, t in ipairs(d.tracks) do
                if t.name == name then table.remove(d.tracks, i) break end
            end
            for i = #d.bindings, 1, -1 do
                if d.bindings[i].track == name then table.remove(d.bindings, i) end
            end
            SendSync(ply)
        elseif cmd == CMD.ADD_GROUP then
            if #d.groups >= MAX_GROUPS then
                Say(ply, "Достигнут лимит групп.")
            else
                local id = d.nextGroup
                d.nextGroup = id + 1
                d.groups[#d.groups + 1] = { id = id, name = "Группа " .. id, delay = 0 }
                SendSync(ply)
            end
        elseif cmd == CMD.DEL_GROUP then
            local id = net.ReadUInt(16)
            if #d.groups <= 1 then
                Say(ply, "Нельзя удалить последнюю группу.")
            else
                for i, g in ipairs(d.groups) do
                    if g.id == id then table.remove(d.groups, i) break end
                end
                for i = #d.bindings, 1, -1 do
                    if d.bindings[i].group == id then table.remove(d.bindings, i) end
                end
                SendSync(ply)
            end
        elseif cmd == CMD.SET_GROUP then
            local id    = net.ReadUInt(16)
            local name  = CleanName(net.ReadString())
            local delay = math.Clamp(net.ReadFloat(), 0, 600)
            local g = FindGroup(d, id)
            if g then
                if name ~= "" then g.name = name end
                g.delay = delay
                SendSync(ply)
            end
        elseif cmd == CMD.BIND then
            local trackName = net.ReadString()
            local groupId   = net.ReadUInt(16)
            BindTrack(ply, trackName, groupId)
        elseif cmd == CMD.UNBIND then
            local bid = net.ReadUInt(16)
            for i, b in ipairs(d.bindings) do
                if b.bid == bid then
                    table.remove(d.bindings, i)
                    break
                end
            end
            SendSync(ply)
        elseif cmd == CMD.SET_NPC_DELAY then
            local bid   = net.ReadUInt(16)
            local delay = math.Clamp(net.ReadFloat(), 0, 600)
            for _, b in ipairs(d.bindings) do
                if b.bid == bid then
                    b.delay = delay
                    break
                end
            end
            SendSync(ply)
        elseif cmd == CMD.RESTORE then
            if recording[ply] then
                Say(ply, "Сначала останови запись.")
            else
                RestoreScene(ply)
            end
        elseif cmd == CMD.PLAY_ALL then
            PlayAll(ply)
        elseif cmd == CMD.STOP_ALL then
            StopAll(ply)
        elseif cmd == CMD.PAUSE then
            SetOwnerPaused(ply, not (ownerPaused[ply] == true))
        elseif cmd == CMD.SEEK then
            SeekOwner(ply, net.ReadFloat())
        end
    end)

    concommand.Add("start_my_rec", function(ply, _, args)
        if not CanUse(ply) then return end
        StartRecording(ply, args[1] or "")
    end)

    concommand.Add("stop_my_rec", function(ply)
        if not CanUse(ply) then return end
        if recording[ply] then StopRecording(ply) else Say(ply, "Запись не идёт.") end
    end)

    concommand.Add("play_my_rec", function(ply, _, args)
        if not CanUse(ply) then return end
        if recording[ply] then
            Say(ply, "Сначала останови запись (stop_my_rec).")
            return
        end

        local d = Dir(ply)
        local track = args[1] and FindTrack(d, args[1]) or d.tracks[#d.tracks]
        if not track then
            Say(ply, "Нет подходящего трека. Используй start_my_rec / stop_my_rec.")
            return
        end

        local ent = ply:GetEyeTrace().Entity
        if not IsValidTarget(ent) then
            Say(ply, "Наведи прицел на NPC или рэгдолл.")
            return
        end

        GiveNPCWeapon(ent, track.weapon)
        StartPlayback(ply, ent, track, 0)
        Say(ply, "Воспроизведение «" .. track.name .. "»: " .. ent:GetClass())
        SendSync(ply)
    end)

    -- Возобновить сценарий: переспавнить убитых NPC и вернуть их в сцену
    local function RestoreCmd(ply)
        if not CanUse(ply) then return end
        if recording[ply] then
            Say(ply, "Сначала останови запись (stop_my_rec).")
            return
        end
        RestoreScene(ply)
    end
    concommand.Add("restore_my_rec", function(ply) RestoreCmd(ply) end)
    concommand.Add("respawn_my_rec", function(ply) RestoreCmd(ply) end)

    concommand.Add("stop_my_play", function(ply)
        if not CanUse(ply) then return end
        StopAll(ply)
        Say(ply, "Воспроизведение остановлено.")
    end)

    hook.Add("PlayerDisconnected", "MyRec_Cleanup", function(ply)
        recording[ply] = nil
        ownerPaused[ply] = nil
        director[ply] = nil
        for ent, pb in pairs(playbacks) do
            if pb.owner == ply then StopPlayback(ent, true, true) end
        end
    end)

    timer.Create("MyRec_TimelineSync", 0.15, 0, function()
        for _, ply in ipairs(player.GetAll()) do
            local current, maximum, paused = TimelineInfo(ply)
            if not IsPlaying(ply) then current, maximum, paused = 0, 1, false end
            net.Start(NET_TIME)
                net.WriteFloat(current)
                net.WriteFloat(maximum)
                net.WriteBool(paused)
            net.Send(ply)
        end
    end)

-- =====================================================================
--  КЛИЕНТ
-- =====================================================================
else
    local data = {
        state = STATE_IDLE, recName = "",
        tracks = {}, groups = {}, bindings = {},
        timeline = 0, timelineMax = 1, paused = false,
    }
    local since = 0
    local ui = {}
    local standalone
    local timelineControls = {}
    local ghostTracks = {}
    local ghostRecordingStart = 0
    local ghostExpected, ghostReceived = 0, 0

    local COL_GREEN = Color(40, 160, 70)

    local function SendCmd(cmd, writer)
        net.Start(NET_CMD)
            net.WriteUInt(cmd, 4)
            if writer then writer() end
        net.SendToServer()
    end

    local function UIAlive()
        return ui.frame and IsValid(ui.frame)
    end

    local function Warn(text)
        notification.AddLegacy(text, NOTIFY_ERROR, 3)
        surface.PlaySound("buttons/button10.wav")
    end

    local ClearGhosts
    net.Receive(NET_SYNC, function()
        local newState = net.ReadUInt(2)
        if newState ~= data.state then since = CurTime() end
        data.state   = newState
        data.recName = net.ReadString()
        if data.state ~= STATE_REC and #ghostTracks > 0 then ClearGhosts() end

        data.tracks = {}
        for i = 1, net.ReadUInt(8) do
            data.tracks[i] = {
                name = net.ReadString(),
                duration = net.ReadFloat(),
                weapon = net.ReadString(),
            }
        end

        data.groups = {}
        for i = 1, net.ReadUInt(8) do
            data.groups[i] = {
                id = net.ReadUInt(16),
                name = net.ReadString(),
                delay = net.ReadFloat(),
            }
        end

        data.bindings = {}
        for i = 1, net.ReadUInt(8) do
            data.bindings[i] = {
                bid      = net.ReadUInt(16),
                alive    = net.ReadBool(),
                entIndex = net.ReadUInt(16),
                class    = net.ReadString(),
                track    = net.ReadString(),
                group    = net.ReadUInt(16),
                delay    = net.ReadFloat(),
            }
        end

        if UIAlive() and ui.Refresh then ui.Refresh() end
    end)

    net.Receive(NET_TIME, function()
        data.timeline = math.max(0, net.ReadFloat())
        data.timelineMax = math.max(1, net.ReadFloat())
        data.paused = net.ReadBool()
        for _, controls in ipairs(timelineControls) do
            if IsValid(controls.panel) and IsValid(controls.slider) then
                controls.refreshing = true
                controls.slider:SetMin(0)
                controls.slider:SetMax(data.timelineMax)
                if CurTime() - (controls.lastUserChange or 0) > 0.3 then
                    controls.slider:SetValue(math.Clamp(data.timeline, 0, data.timelineMax))
                end
                if IsValid(controls.pauseButton) then
                    controls.pauseButton:SetText(data.paused and L("resume_btn") or L("pause_btn"))
                end
                if IsValid(controls.timeLabel) then
                    controls.timeLabel:SetText(string.format(L("timeline_label"), data.timeline, data.timelineMax))
                end
                controls.refreshing = false
            end
        end
    end)

    ClearGhosts = function()
        for _, ghost in ipairs(ghostTracks) do
            if IsValid(ghost.model) then ghost.model:Remove() end
        end
        ghostTracks = {}
        ghostExpected, ghostReceived = 0, 0
    end

    net.Receive(NET_GHOST, function()
        local kind = net.ReadUInt(2)
        if kind == 0 then
            ClearGhosts()
            ghostExpected = net.ReadUInt(8)
            ghostRecordingStart = CurTime()
        elseif kind == 1 then
            local name = net.ReadString()
            local modelPath = net.ReadString()
            local duration = math.max(0, net.ReadFloat())
            local count = net.ReadUInt(6)
            local frames = {}
            for i = 1, count do
                frames[i] = { t = net.ReadFloat(), pos = net.ReadVector(), ang = net.ReadAngle() }
            end
            local fallback = IsValid(LocalPlayer()) and LocalPlayer():GetModel() or "models/player/kleiner.mdl"
            if not util.IsValidModel(modelPath) then modelPath = fallback end
            local ghost = ClientsideModel(modelPath, RENDERGROUP_OPAQUE)
            if IsValid(ghost) then
                ghost:SetNoDraw(true)
                ghost:SetRenderMode(RENDERMODE_TRANSCOLOR)
                ghost:SetColor(Color(115, 210, 255, 85))
                ghost:SetMaterial("models/wireframe")
                ghostTracks[#ghostTracks + 1] = { name = name, duration = duration, frames = frames, model = ghost }
            end
            ghostReceived = ghostReceived + 1
        elseif kind == 3 then
            ClearGhosts()
        end
    end)

    hook.Add("PostDrawTranslucentRenderables", "MyRec_GhostRender", function()
        if data.state ~= STATE_REC or #ghostTracks == 0 then return end
        local elapsed = math.max(0, CurTime() - ghostRecordingStart)
        for _, track in ipairs(ghostTracks) do
            local model, frames = track.model, track.frames
            if IsValid(model) and #frames > 0 then
                local t = math.min(elapsed, track.duration)
                local i = 1
                while i < #frames - 1 and frames[i + 1].t <= t do i = i + 1 end
                local a = frames[i]
                local b = frames[math.min(i + 1, #frames)]
                local span = (b.t or 0) - (a.t or 0)
                local frac = span > 0 and math.Clamp((t - (a.t or 0)) / span, 0, 1) or 0
                model:SetPos(LerpVector(frac, a.pos, b.pos))
                local ang = LerpAngle(frac, a.ang, b.ang)
                model:SetAngles(Angle(0, ang.y, 0))
                local moving = a.pos:Distance(b.pos) > 4
                local seqName = moving and "walk_all" or "idle_all"
                local seq = model:LookupSequence(seqName)
                if seq and seq >= 0 and model:GetSequence() ~= seq then
                    model:SetSequence(seq)
                    model:SetCycle(0)
                end
                model:SetPlaybackRate(moving and 1 or 0)
                model:FrameAdvance(FrameTime())
                model:DrawModel()
            end
        end
    end)

    hook.Add("ShutDown", "MyRec_GhostCleanup", ClearGhosts)

    local function GroupName(id)
        for _, g in ipairs(data.groups) do
            if g.id == id then return g.name end
        end
        return "?"
    end

    local function Header(parent, text)
        local lbl = vgui.Create("DLabel", parent)
        lbl:Dock(TOP)
        lbl:SetText(text)
        lbl:SetFont("DermaDefaultBold")
        lbl:SetDark(true)
        lbl:SetTall(20)
        return lbl
    end

    local function MakeRow(parent, h)
        local row = vgui.Create("DPanel", parent)
        row:Dock(TOP)
        row:SetTall(h)
        row:DockMargin(0, 4, 0, 0)
        row.Paint = function() end
        return row
    end

    local function SplitRow(row, a, b)
        row.PerformLayout = function(_, w, h)
            a:SetPos(0, 0)
            a:SetSize(w / 2 - 2, h)
            b:SetPos(w / 2 + 2, 0)
            b:SetSize(w / 2 - 2, h)
        end
    end

    local function SendNpcDelay()
        if not ui.selBid then return end
        SendCmd(CMD.SET_NPC_DELAY, function()
            net.WriteUInt(ui.selBid, 16)
            net.WriteFloat(ui.npcDelaySlider:GetValue())
        end)
    end

    local function FindGroupData(id)
        for _, g in ipairs(data.groups) do
            if g.id == id then return g end
        end
    end

    local function FindBindingData(bid)
        for _, b in ipairs(data.bindings) do
            if b.bid == bid then return b end
        end
    end

    local function SendGroupSettings()
        if not ui.selGroup then return end
        SendCmd(CMD.SET_GROUP, function()
            net.WriteUInt(ui.selGroup, 16)
            net.WriteString(ui.groupName:GetValue())
            net.WriteFloat(ui.delaySlider:GetValue())
        end)
    end

    local timelineControlId = 0
    local function CreateTimelineControls(parent, dockSide)
        timelineControlId = timelineControlId + 1
        local id = timelineControlId
        local controls = { refreshing = false }
        controls.panel = vgui.Create("DPanel", parent)
        controls.panel:Dock(dockSide or TOP)
        controls.panel:SetTall(70)
        controls.panel:DockMargin(0, 4, 0, 0)
        controls.panel.Paint = function() end

        controls.pauseButton = vgui.Create("DButton", controls.panel)
        controls.pauseButton:Dock(LEFT)
        controls.pauseButton:SetWide(125)
        controls.pauseButton:SetText(data.paused and L("resume_btn") or L("pause_btn"))
        controls.pauseButton.DoClick = function() SendCmd(CMD.PAUSE) end

        controls.timeLabel = vgui.Create("DLabel", controls.panel)
        controls.timeLabel:Dock(TOP)
        controls.timeLabel:SetTall(18)
        controls.timeLabel:SetTextColor(Color(45, 45, 45))
        controls.timeLabel:SetText(string.format(L("timeline_label"), data.timeline, data.timelineMax))

        controls.slider = vgui.Create("DNumSlider", controls.panel)
        controls.slider:Dock(FILL)
        controls.slider:SetText(L("seek_label"))
        controls.slider:SetMin(0)
        controls.slider:SetMax(math.max(1, data.timelineMax))
        controls.slider:SetDecimals(1)
        controls.slider.Label:SetDark(true)
        controls.slider.OnValueChanged = function(_, value)
            if controls.refreshing then return end
            controls.lastUserChange = CurTime()
            local seekValue = tonumber(value) or 0
            timer.Create("MyRec_Seek_" .. id, 0.08, 1, function()
                if IsValid(controls.panel) and not controls.refreshing then
                    SendCmd(CMD.SEEK, function() net.WriteFloat(seekValue) end)
                end
            end)
        end

        timelineControls[#timelineControls + 1] = controls
        controls.panel.OnRemove = function()
            for i = #timelineControls, 1, -1 do
                if timelineControls[i] == controls then table.remove(timelineControls, i) end
            end
            timer.Remove("MyRec_Seek_" .. id)
        end
        return controls
    end

    local function BuildUI(frame)
        local oldTrack, oldGroup = ui.selTrack, ui.selGroup
        ui = { frame = frame, selTrack = oldTrack, selGroup = oldGroup }

        frame:DockPadding(6, 30, 6, 6)

        local left = vgui.Create("DPanel", frame)
        left:Dock(LEFT)
        left:SetWide(430)
        left:DockMargin(0, 0, 6, 0)
        left:DockPadding(8, 8, 8, 8)

        Header(left, L("anim_header"))

        ui.nameEntry = vgui.Create("DTextEntry", left)
        ui.nameEntry:Dock(TOP)
        ui.nameEntry:DockMargin(0, 4, 0, 0)
        ui.nameEntry:SetTall(24)
        ui.nameEntry:SetPlaceholderText("Имя трека, например victim_1 или swat_2")

        local recRow = MakeRow(left, 32)
        ui.btnStart = vgui.Create("DButton", recRow)
        ui.btnStart:SetText(L("start_rec"))
        ui.btnStart.DoClick = function()
            SendCmd(CMD.START, function() net.WriteString(ui.nameEntry:GetValue()) end)
        end
        ui.btnStop = vgui.Create("DButton", recRow)
        ui.btnStop:SetText(L("stop_rec"))
        ui.btnStop.DoClick = function() SendCmd(CMD.STOP) end
        SplitRow(recRow, ui.btnStart, ui.btnStop)

        ui.recStatus = vgui.Create("DLabel", left)
        ui.recStatus:Dock(TOP)
        ui.recStatus:DockMargin(0, 4, 0, 4)
        ui.recStatus:SetTall(18)
        ui.recStatus:SetDark(true)
        ui.recStatus.Think = function(s)
            if data.state == STATE_REC then
                s:SetText(string.format("● Идёт запись «%s»: %.1f с", data.recName, CurTime() - since))
                s:SetTextColor(Color(200, 30, 30))
            elseif data.state == STATE_PLAY then
                s:SetText("▶ Идёт воспроизведение")
                s:SetTextColor(COL_GREEN)
            else
                s:SetText("Ожидание. Сохранено треков: " .. #data.tracks)
                s:SetTextColor(Color(60, 60, 60))
            end
        end

        local btnDelTrack = vgui.Create("DButton", left)
        btnDelTrack:Dock(BOTTOM)
        btnDelTrack:DockMargin(0, 4, 0, 0)
        btnDelTrack:SetTall(26)
        btnDelTrack:SetText(L("del_track"))
        btnDelTrack.DoClick = function()
            if not ui.selTrack then Warn("Сначала выбери трек.") return end
            SendCmd(CMD.DEL_TRACK, function() net.WriteString(ui.selTrack) end)
            ui.selTrack = nil
        end

        ui.trackList = vgui.Create("DListView", left)
        ui.trackList:Dock(FILL)
        ui.trackList:SetMultiSelect(false)
        ui.trackList:AddColumn(L("track_name_col"))
        ui.trackList:AddColumn(L("duration_col")):SetFixedWidth(70)
        ui.trackList:AddColumn(L("weapon_col"))
        ui.trackList.OnRowSelected = function(_, _, line)
            ui.selTrack = line.trackName
        end

        local right = vgui.Create("DPanel", frame)
        right:Dock(FILL)
        right:DockPadding(8, 8, 8, 8)

        local btnPlay = vgui.Create("DButton", right)
        btnPlay:Dock(BOTTOM)
        btnPlay:DockMargin(0, 6, 0, 0)
        btnPlay:SetTall(58)
        btnPlay:SetFont("DermaLarge")
        btnPlay:SetText(L("play_all"))
        btnPlay:SetTextColor(color_white)
        btnPlay.Paint = function(s, w, h)
            draw.RoundedBox(6, 0, 0, w, h, s:IsHovered() and Color(60, 200, 90) or COL_GREEN)
        end
        btnPlay.DoClick = function() SendCmd(CMD.PLAY_ALL) end

        local btnStopAll = vgui.Create("DButton", right)
        btnStopAll:Dock(BOTTOM)
        btnStopAll:DockMargin(0, 4, 0, 0)
        btnStopAll:SetTall(26)
        btnStopAll:SetText(L("stop_all"))
        btnStopAll.DoClick = function() SendCmd(CMD.STOP_ALL) end

        CreateTimelineControls(right, BOTTOM)

        -- Нижний ряд: убрать привязку | возобновить сценарий
        local botRow = vgui.Create("DPanel", right)
        botRow:Dock(BOTTOM)
        botRow:DockMargin(0, 4, 0, 0)
        botRow:SetTall(26)
        botRow.Paint = function() end

        local btnUnbind = vgui.Create("DButton", botRow)
        btnUnbind:SetText(L("unbind"))
        btnUnbind.DoClick = function()
            if not ui.selBid then Warn("Выбери NPC в дереве (внутри группы).") return end
            SendCmd(CMD.UNBIND, function() net.WriteUInt(ui.selBid, 16) end)
            ui.selBid = nil
        end

        local btnRestore = vgui.Create("DButton", botRow)
        btnRestore:SetText(L("restore_scene"))
        btnRestore:SetTooltip("Переспавнить убитых/удалённых NPC по манифесту (класс, модель, позиция, оружие, трек, группа).\nЕсли сцена идёт — новые NPC включатся с текущего момента.")
        btnRestore.DoClick = function() SendCmd(CMD.RESTORE) end
        SplitRow(botRow, btnUnbind, btnRestore)

        Header(right, L("groups_header"))

        local grpRow = MakeRow(right, 26)
        local btnAddGroup = vgui.Create("DButton", grpRow)
        btnAddGroup:SetText(L("add_group"))
        btnAddGroup.DoClick = function() SendCmd(CMD.ADD_GROUP) end
        local btnDelGroup = vgui.Create("DButton", grpRow)
        btnDelGroup:SetText(L("del_group"))
        btnDelGroup.DoClick = function()
            if not ui.selGroup then Warn("Сначала выбери группу.") return end
            SendCmd(CMD.DEL_GROUP, function() net.WriteUInt(ui.selGroup, 16) end)
            ui.selGroup, ui.selBid = nil, nil
        end
        SplitRow(grpRow, btnAddGroup, btnDelGroup)

        ui.groupName = vgui.Create("DTextEntry", right)
        ui.groupName:Dock(TOP)
        ui.groupName:DockMargin(0, 4, 0, 0)
        ui.groupName:SetTall(24)
        ui.groupName:SetPlaceholderText("Название группы (Enter — применить)")
        ui.groupName.OnEnter = function() SendGroupSettings() end

        ui.delaySlider = vgui.Create("DNumSlider", right)
        ui.delaySlider:Dock(TOP)
        ui.delaySlider:DockMargin(0, 2, 0, 0)
        ui.delaySlider:SetTall(26)
        ui.delaySlider:SetText(L("group_delay"))
        ui.delaySlider:SetMin(0)
        ui.delaySlider:SetMax(60)
        ui.delaySlider:SetDecimals(1)
        ui.delaySlider.Label:SetDark(true)
        ui.delaySlider.OnValueChanged = function()
            if ui.refreshing or not ui.selGroup then return end
            timer.Create("MyRec_GroupDelay", 0.35, 1, function()
                if UIAlive() then SendGroupSettings() end
            end)
        end

        ui.npcDelaySlider = vgui.Create("DNumSlider", right)
        ui.npcDelaySlider:Dock(TOP)
        ui.npcDelaySlider:DockMargin(0, 2, 0, 0)
        ui.npcDelaySlider:SetTall(26)
        ui.npcDelaySlider:SetText(L("npc_delay"))
        ui.npcDelaySlider:SetMin(0)
        ui.npcDelaySlider:SetMax(60)
        ui.npcDelaySlider:SetDecimals(1)
        ui.npcDelaySlider.Label:SetDark(true)
        ui.npcDelaySlider.OnValueChanged = function()
            if ui.refreshing or not ui.selBid then return end
            timer.Create("MyRec_NpcDelay", 0.35, 1, function()
                if UIAlive() then SendNpcDelay() end
            end)
        end

        ui.targetLabel = vgui.Create("DLabel", right)
        ui.targetLabel:Dock(TOP)
        ui.targetLabel:DockMargin(0, 6, 0, 0)
        ui.targetLabel:SetTall(18)
        ui.targetLabel:SetDark(true)
        ui.targetLabel.Think = function(s)
            if CurTime() < (s.nextCheck or 0) then return end
            s.nextCheck = CurTime() + 0.15
            local ent = LocalPlayer():GetEyeTrace().Entity
            if IsValid(ent) and (ent:IsNPC() or ent:GetClass() == "prop_ragdoll") then
                s:SetText("Цель под прицелом: " .. ent:GetClass())
                s:SetTextColor(COL_GREEN)
            else
                s:SetText("Цель под прицелом: нет (наведись на NPC)")
                s:SetTextColor(Color(150, 60, 60))
            end
        end

        local btnBind = vgui.Create("DButton", right)
        btnBind:Dock(TOP)
        btnBind:DockMargin(0, 2, 0, 0)
        btnBind:SetTall(34)
        btnBind:SetText(L("bind_track"))
        btnBind.DoClick = function()
            if not ui.selTrack then Warn("Выбери трек в списке «Анимации».") return end
            if not ui.selGroup then Warn("Выбери группу в дереве.") return end
            SendCmd(CMD.BIND, function()
                net.WriteString(ui.selTrack)
                net.WriteUInt(ui.selGroup, 16)
            end)
        end

        local treeHeader = Header(right, L("tree_header"))
        treeHeader:DockMargin(0, 6, 0, 0)

        ui.expanded = ui.expanded or {}

        ui.tree = vgui.Create("DTree", right)
        ui.tree:Dock(FILL)

        -- Выбор узла: группа задаёт ui.selGroup; NPC — ещё и ui.selBid (и берёт группу родителя)
        ui.tree.OnNodeSelected = function(_, node)
            local prev = ui.refreshing
            ui.refreshing = true

            if node.bid then
                ui.selBid = node.bid
                local bd = FindBindingData(node.bid)
                ui.selGroup = bd and bd.group or ui.selGroup
            elseif node.groupId then
                ui.selGroup, ui.selBid = node.groupId, nil
            end

            local g  = FindGroupData(ui.selGroup)
            local bd = ui.selBid and FindBindingData(ui.selBid)
            if g then
                ui.groupName:SetValue(g.name)
                ui.delaySlider:SetValue(g.delay)
            end
            ui.npcDelaySlider:SetValue(bd and bd.delay or 0)
            ui.npcDelaySlider:SetAlpha(bd and 255 or 90)
            ui.npcDelaySlider:SetMouseInputEnabled(bd ~= nil)

            ui.refreshing = prev
        end

        function ui.Refresh()
            ui.refreshing = true

            ui.trackList:Clear()
            local foundTrack = false
            for _, t in ipairs(data.tracks) do
                local line = ui.trackList:AddLine(t.name, string.format("%.1f", t.duration),
                    t.weapon ~= "" and t.weapon or "—")
                line.trackName = t.name
                if t.name == ui.selTrack then
                    ui.trackList:SelectItem(line)
                    foundTrack = true
                end
            end
            if not foundTrack then ui.selTrack = nil end

            -- Дерево: группы (раскрываются) → привязанные NPC
            ui.tree:Clear()
            local selectNode
            local firstGroupNode

            for _, g in ipairs(data.groups) do
                local members = {}
                for _, bd in ipairs(data.bindings) do
                    if bd.group == g.id then members[#members + 1] = bd end
                end

                local gNode = ui.tree:AddNode(
                    string.format("%s  —  задержка %.1f с  [NPC: %d]", g.name, g.delay, #members),
                    "icon16/folder.png")
                gNode.groupId = g.id
                firstGroupNode = firstGroupNode or gNode

                -- запоминаем раскрытость группы между обновлениями
                local gid, setExp = g.id, gNode.SetExpanded
                gNode.SetExpanded = function(self, state, ...)
                    ui.expanded[gid] = state and true or false
                    return setExp(self, state, ...)
                end
                if ui.expanded[gid] == nil then ui.expanded[gid] = true end

                if g.id == ui.selGroup and not ui.selBid then selectNode = gNode end

                for _, bd in ipairs(members) do
                    local text = string.format("%s [%s]  ·  %s  ·  +%.1f с (итого %.1f с)%s",
                        bd.class, bd.alive and bd.entIndex or "—", bd.track, bd.delay,
                        g.delay + bd.delay, bd.alive and "" or "  — УБИТ")
                    local nNode = gNode:AddNode(text, bd.alive and "icon16/user.png" or "icon16/user_delete.png")
                    nNode.bid = bd.bid
                    if not bd.alive and nNode.Label then nNode.Label:SetTextColor(Color(170, 50, 50)) end
                    if bd.bid == ui.selBid then selectNode = nNode end
                end

                -- раскрываем/сворачиваем уже после добавления детей, без анимации
                setExp(gNode, ui.expanded[gid], true)
            end

            if not selectNode then
                ui.selGroup, ui.selBid = nil, nil
                selectNode = firstGroupNode
            end
            if selectNode then ui.tree:SetSelectedItem(selectNode) end

            ui.btnStart:SetEnabled(data.state ~= STATE_REC)
            ui.btnStop:SetEnabled(data.state == STATE_REC)

            ui.refreshing = false
        end

        ui.Refresh()
        SendCmd(CMD.SYNC)
    end

    hook.Add("PopulateToolMenu", "MyRec_PopulateToolMenu", function()
        spawnmenu.AddToolMenuOption("Utilities", "Режиссёр", "MyRec_QMenu", "Режиссёр", "", "", function(panel)
            panel:ClearControls()
            panel:AddControl("Header", { Description = "Управление режиссёром MyRec (Q-Панель)" })
            panel:AddControl("Button", { Label = "● Начать запись", Command = "start_my_rec" })
            panel:AddControl("Button", { Label = "■ Остановить запись", Command = "stop_my_rec" })
            panel:AddControl("Button", { Label = "Открыть интерфейс (C-Меню)", Command = "my_rec_menu" })
            panel:AddControl("Button", { Label = "⏹ СТОП ВСЕХ NPC", Command = "stop_my_play" })
            panel:AddControl("Button", { Label = "↻ Возобновить сценарий", Command = "restore_my_rec" })
        end)
    end)

    list.Set("DesktopWindows", "MyRecDirector", {
        title  = "Режиссёр",
        icon   = "icon64/tool.png",
        width  = 900,
        height = 720,
        init   = function(_, window)
            BuildUI(window)
        end,
    })

    concommand.Add("my_rec_menu", function()
        if IsValid(standalone) then
            standalone:Remove()
            return
        end

        local f = vgui.Create("DFrame")
        f:SetTitle(L("title"))
        f:SetSize(960, 720)
        f:Center()
        f:MakePopup()
        standalone = f
        BuildUI(f)
    end)

    local function FormatTime(s)
        return string.format("%02d:%02d", math.floor(s / 60), math.floor(s % 60))
    end

    hook.Add("HUDPaint", "MyRec_HUD", function()
        if data.state == STATE_IDLE then return end

        local x, y = ScrW() - 170, 30
        local elapsed = CurTime() - since

        if data.state == STATE_REC then
            if math.sin(CurTime() * 6) > 0 then
                draw.RoundedBox(8, x, y + 4, 16, 16, Color(230, 30, 30))
            end
            draw.SimpleText("REC " .. FormatTime(elapsed), "DermaLarge", x + 26, y,
                color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText("▶ PLAY " .. FormatTime(elapsed), "DermaLarge", x, y,
                Color(80, 220, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end
    end)
end