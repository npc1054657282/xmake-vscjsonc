-- 结构化的 JSONC 解析器
-- 保持注释与数据的关联

import("core.base.json")

-- ============================================
-- JSON 类型包装器
-- ============================================

local _JSON_ARRAY_TYPE = "jsonarray"
local _JSON_OBJECT_TYPE = "jsonobject"

-- 数组包装器
function array(t)
    return {
        [_JSON_ARRAY_TYPE] = true,
        values = t or {}
    }
end

-- 对象包装器
function object(t)
    return {
        [_JSON_OBJECT_TYPE] = true,
        values = t or {}
    }
end

-- 检测是否是包装的类型
function is_array(t)
    return type(t) == "table" and t[_JSON_ARRAY_TYPE] == true
end

function is_object(t)
    return type(t) == "table" and t[_JSON_OBJECT_TYPE] == true
end

-- 获取实际值
function unwrap_json_value(t)
    if is_array(t) or is_object(t) then
        return t.values
    end
    return t
end

-- ============================================
-- 核心数据结构
-- ============================================

-- JSONC 节点类型
local _NodeType = {
    OBJECT = "object",
    ARRAY = "array",
    STRING = "string",
    NUMBER = "number",
    BOOLEAN = "boolean",
    NULL = "null"
}

-- JSONC 节点（包含值和相关注释）
local _JsoncNode = {}
_JsoncNode.__index = _JsoncNode

function _JsoncNode.new(type, value, location)
    return debug.setmetatable({
        type = type,
        value = value,
        location = location or {},  -- {line, column, offset}
        comments = {
            before = {},      -- 节点前的注释
            after = nil,      -- 节点后的行尾注释
            inner_before = {}, -- 对象/数组内部开始的注释
            inner_after = {}   -- 对象/数组内部结束的注释
        },
        children = {},        -- 对于对象和数组，保存子节点
        parent = nil,
        key = nil            -- 如果是对象的值，记录对应的键
    }, _JsoncNode)
end

-- ============================================
-- 增强的词法分析器
-- ============================================

local _Lexer = {}
_Lexer.__index = _Lexer

function _Lexer.new(text)
    return debug.setmetatable({
        text = text,
        pos = 1,
        line = 1,
        column = 1,
        tokens = {},
        pending_comments = {}  -- 待关联的注释
    }, _Lexer)
end

function _Lexer:current_location()
    return {
        line = self.line,
        column = self.column,
        offset = self.pos
    }
end

function _Lexer:advance()
    if self.pos <= #self.text then
        if self.text:sub(self.pos, self.pos) == '\n' then
            self.line = self.line + 1
            self.column = 1
        else
            self.column = self.column + 1
        end
        self.pos = self.pos + 1
    end
end

function _Lexer:skip_whitespace()
    while self.pos <= #self.text and self.text:sub(self.pos, self.pos):match('%s') do
        self:advance()
    end
end

function _Lexer:read_comment()
    local start_loc = self:current_location()
    local comment = {
        location = start_loc,
        text = "",
        type = nil
    }

    if self.text:sub(self.pos, self.pos + 1) == '//' then
        -- 单行注释
        comment.type = "line"
        self.pos = self.pos + 2
        self.column = self.column + 2
        local start = self.pos
        while self.pos <= #self.text and self.text:sub(self.pos, self.pos) ~= '\n' do
            self:advance()
        end
        comment.text = self.text:sub(start, self.pos - 1):match("^%s*(.-)%s*$")
    elseif self.text:sub(self.pos, self.pos + 1) == '/*' then
        -- 多行注释
        comment.type = "block"
        self.pos = self.pos + 2
        self.column = self.column + 2
        local start = self.pos
        while self.pos < #self.text do
            if self.text:sub(self.pos, self.pos + 1) == '*/' then
                comment.text = self.text:sub(start, self.pos - 1)
                self.pos = self.pos + 2
                self.column = self.column + 2
                break
            end
            self:advance()
        end
    end

    return comment
end

function _Lexer:collect_comments()
    local comments = {}
    while true do
        self:skip_whitespace()
        if self.pos <= #self.text and self.text:sub(self.pos, self.pos) == '/' then
            local comment = self:read_comment()
            if comment.text then
                table.insert(comments, comment)
            else
                break
            end
        else
            break
        end
    end
    return comments
end

-- ============================================
-- 结构化解析器
-- ============================================

local _Parser = {}
_Parser.__index = _Parser

function _Parser.new(text)
    return debug.setmetatable({
        lexer = _Lexer.new(text),
        text = text
    }, _Parser)
end

function _Parser:parse()
    local root = self:parse_value()

    -- 处理文件末尾的注释
    local trailing_comments = self.lexer:collect_comments()
    if #trailing_comments > 0 then
        root.comments.after = trailing_comments
    end

    return root
end

function _Parser:parse_value()
    -- 收集值前的注释
    local comments_before = self.lexer:collect_comments()

    self.lexer:skip_whitespace()
    local loc = self.lexer:current_location()
    local ch = self.lexer.text:sub(self.lexer.pos, self.lexer.pos)

    local node

    if ch == '{' then
        node = self:parse_object(loc)
    elseif ch == '[' then
        node = self:parse_array(loc)
    elseif ch == '"' then
        node = self:parse_string(loc)
    elseif ch == 't' or ch == 'f' then
        node = self:parse_boolean(loc)
    elseif ch == 'n' then
        node = self:parse_null(loc)
    elseif ch:match('[%-%d]') then
        node = self:parse_number(loc)
    else
        os.raise("Unexpected character at line " .. self.lexer.line)
    end

    -- 关联前置注释
    node.comments.before = comments_before

    -- 检查行尾注释
    local saved_pos = self.lexer.pos
    local saved_line = self.lexer.line
    local saved_column = self.lexer.column
    self.lexer:skip_whitespace()

    if self.lexer.line == saved_line and self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '/' then
        local line_comment = self.lexer:read_comment()
        if line_comment.type == "line" then
            node.comments.after = line_comment
        else
            -- 不是行尾注释，回退
            self.lexer.pos = saved_pos
            self.lexer.line = saved_line
            self.lexer.column = saved_column
        end
    end

    return node
end

function _Parser:parse_object(loc)
    local node = _JsoncNode.new(_NodeType.OBJECT, {}, loc)
    self.lexer.pos = self.lexer.pos + 1  -- skip {
    self.lexer.column = self.lexer.column + 1

    -- 收集对象内部开始的注释
    node.comments.inner_before = self.lexer:collect_comments()

    self.lexer:skip_whitespace()

    if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '}' then
        self.lexer.pos = self.lexer.pos + 1
        self.lexer.column = self.lexer.column + 1
        node._key_order = {}  -- 空对象也要保存空的键顺序
        return node
    end

    -- 保持键的顺序 - 这是关键！
    local key_order = {}

    while true do
        -- 获取待处理的注释
        local key_comments = self.lexer.pending_comments or {}
        self.lexer.pending_comments = nil

        -- 解析键前的注释
        local new_comments = self.lexer:collect_comments()
        for _, comment in ipairs(new_comments) do
            table.insert(key_comments, comment)
        end

        self.lexer:skip_whitespace()

        -- 检查是否到了对象结尾
        if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '}' then
            -- 这些注释属于对象结束
            node.comments.inner_after = key_comments
            self.lexer.pos = self.lexer.pos + 1
            self.lexer.column = self.lexer.column + 1
            break
        end

        if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) ~= '"' then
            os.raise("Expected string key at line " .. self.lexer.line)
        end

        local key_node = self:parse_string()
        key_node.comments.before = key_comments
        local key = key_node.value

        self.lexer:skip_whitespace()
        if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) ~= ':' then
            os.raise("Expected ':' at line " .. self.lexer.line)
        end
        self.lexer.pos = self.lexer.pos + 1
        self.lexer.column = self.lexer.column + 1

        -- 解析值
        local value_node = self:parse_value()
        value_node.parent = node
        value_node.key = key

        -- 保存键值对
        node.value[key] = value_node.value
        node.children[key] = {
            key = key_node,
            value = value_node
        }
        -- 记录键的顺序！
        table.insert(key_order, key)

        -- 检查逗号或结束
        self.lexer:skip_whitespace()
        local ch = self.lexer.text:sub(self.lexer.pos, self.lexer.pos)

        if ch == ',' then
            self.lexer.pos = self.lexer.pos + 1
            self.lexer.column = self.lexer.column + 1
            
            -- 修复：正确处理逗号后的注释
            -- 保存当前位置信息
            local saved_pos = self.lexer.pos
            local saved_line = self.lexer.line
            local saved_column = self.lexer.column
            
            -- 先跳过逗号后的空白（不包括换行）
            while self.lexer.pos <= #self.lexer.text do
                local char = self.lexer.text:sub(self.lexer.pos, self.lexer.pos)
                if char == ' ' or char == '\t' then
                    self.lexer:advance()
                else
                    break
                end
            end
            
            -- 检查是否有行尾注释
            if self.lexer.line == saved_line and 
               self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '/' then
                local comment = self.lexer:read_comment()
                if comment.type == "line" then
                    -- 这是逗号后的行尾注释，应该归属于当前值
                    value_node.comments.after = comment
                else
                    -- 块注释，回退并作为下一个键的前置注释
                    self.lexer.pos = saved_pos
                    self.lexer.line = saved_line
                    self.lexer.column = saved_column
                end
            else
                -- 没有行尾注释，回退
                self.lexer.pos = saved_pos
                self.lexer.line = saved_line
                self.lexer.column = saved_column
            end
            
            -- 继续收集其他注释作为下一个键的前置注释
            local after_comma_comments = self.lexer:collect_comments()
            self.lexer:skip_whitespace()
            
            if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '}' then
                -- 尾随逗号，注释属于对象结束
                node.comments.inner_after = after_comma_comments
                self.lexer.pos = self.lexer.pos + 1
                self.lexer.column = self.lexer.column + 1
                break
            else
                -- 注释属于下一个键
                self.lexer.pending_comments = after_comma_comments
            end
        elseif ch == '}' then
            -- 收集对象结束前的注释
            self.lexer.pos = self.lexer.pos + 1
            self.lexer.column = self.lexer.column + 1
            break
        else
            os.raise("Expected ',' or '}' at line " .. self.lexer.line)
        end
    end

    -- 保存键的顺序
    node._key_order = key_order

    return node
end

function _Parser:parse_array(loc)
    local node = _JsoncNode.new(_NodeType.ARRAY, {}, loc)
    self.lexer.pos = self.lexer.pos + 1  -- skip [
    self.lexer.column = self.lexer.column + 1

    -- 收集数组内部开始的注释
    node.comments.inner_before = self.lexer:collect_comments()

    self.lexer:skip_whitespace()

    if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == ']' then
        self.lexer.pos = self.lexer.pos + 1
        self.lexer.column = self.lexer.column + 1
        return node
    end

    local index = 1
    while true do
        -- 获取待处理的注释
        if self.lexer.pending_comments then
            -- 待处理的注释会在 parse_value 中处理
        end

        -- 检查是否到了数组结尾
        local element_comments = self.lexer:collect_comments()
        self.lexer:skip_whitespace()
        if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == ']' then
            -- 这些注释属于数组结束
            node.comments.inner_after = element_comments
            self.lexer.pos = self.lexer.pos + 1
            self.lexer.column = self.lexer.column + 1
            break
        else
            -- 注释属于下一个元素
            self.lexer.pending_comments = element_comments
        end

        -- 解析元素
        local element_node = self:parse_value()
        element_node.parent = node
        element_node.key = index

        table.insert(node.value, element_node.value)
        node.children[index] = element_node
        index = index + 1

        -- 检查逗号或结束
        self.lexer:skip_whitespace()
        local ch = self.lexer.text:sub(self.lexer.pos, self.lexer.pos)

        if ch == ',' then
            self.lexer.pos = self.lexer.pos + 1
            self.lexer.column = self.lexer.column + 1
            
            -- 修复：正确处理逗号后的注释
            local saved_pos = self.lexer.pos
            local saved_line = self.lexer.line
            local saved_column = self.lexer.column
            
            -- 先跳过逗号后的空白（不包括换行）
            while self.lexer.pos <= #self.lexer.text do
                local char = self.lexer.text:sub(self.lexer.pos, self.lexer.pos)
                if char == ' ' or char == '\t' then
                    self.lexer:advance()
                else
                    break
                end
            end
            
            -- 检查是否有行尾注释
            if self.lexer.line == saved_line and 
               self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '/' then
                local comment = self.lexer:read_comment()
                if comment.type == "line" then
                    -- 这是逗号后的行尾注释，应该归属于当前元素
                    element_node.comments.after = comment
                else
                    -- 块注释，回退并作为下一个元素的前置注释
                    self.lexer.pos = saved_pos
                    self.lexer.line = saved_line
                    self.lexer.column = saved_column
                end
            else
                -- 没有行尾注释，回退
                self.lexer.pos = saved_pos
                self.lexer.line = saved_line
                self.lexer.column = saved_column
            end
            
            -- 继续收集其他注释
            local after_comma_comments = self.lexer:collect_comments()
            self.lexer:skip_whitespace()
            
            if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == ']' then
                -- 尾随逗号
                node.comments.inner_after = after_comma_comments
                self.lexer.pos = self.lexer.pos + 1
                self.lexer.column = self.lexer.column + 1
                break
            else
                -- 注释属于下一个元素
                self.lexer.pending_comments = after_comma_comments
            end
        elseif ch == ']' then
            self.lexer.pos = self.lexer.pos + 1
            self.lexer.column = self.lexer.column + 1
            break
        else
            os.raise("Expected ',' or ']' at line " .. self.lexer.line)
        end
    end

    return node
end

function _Parser:parse_string(loc)
    loc = loc or self.lexer:current_location()
    self.lexer.pos = self.lexer.pos + 1  -- skip "
    self.lexer.column = self.lexer.column + 1

    local chars = {}
    while self.lexer.pos <= #self.lexer.text do
        local ch = self.lexer.text:sub(self.lexer.pos, self.lexer.pos)
        if ch == '"' then
            self.lexer.pos = self.lexer.pos + 1
            self.lexer.column = self.lexer.column + 1
            break
        elseif ch == '\\' then
            self.lexer:advance()
            -- 处理转义字符
            local escape = self.lexer.text:sub(self.lexer.pos, self.lexer.pos)
            local escaped_chars = {
                ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                ['b'] = '\b', ['f'] = '\f', ['n'] = '\n',
                ['r'] = '\r', ['t'] = '\t'
            }
            if escape == 'u' then
                -- Unicode 转义
                self.lexer:advance()
                local hex = self.lexer.text:sub(self.lexer.pos, self.lexer.pos + 3)
                if #hex == 4 and hex:match("^%x%x%x%x$") then
                    local code = tonumber(hex, 16)
                    table.insert(chars, utf8.char(code))
                    self.lexer.pos = self.lexer.pos + 4
                    self.lexer.column = self.lexer.column + 4
                else
                    os.raise("Invalid unicode escape at line " .. self.lexer.line)
                end
            else
                table.insert(chars, escaped_chars[escape] or escape)
                self.lexer:advance()
            end
        else
            table.insert(chars, ch)
        end
        self.lexer:advance()
    end

    return _JsoncNode.new(_NodeType.STRING, table.concat(chars), loc)
end

function _Parser:parse_number(loc)
    local start = self.lexer.pos

    -- 可选的负号
    if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '-' then
        self.lexer:advance()
    end

    -- 整数部分
    while self.lexer.pos <= #self.lexer.text and self.lexer.text:sub(self.lexer.pos, self.lexer.pos):match('%d') do
        self.lexer:advance()
    end

    -- 小数部分
    if self.lexer.text:sub(self.lexer.pos, self.lexer.pos) == '.' then
        self.lexer:advance()
        while self.lexer.pos <= #self.lexer.text and self.lexer.text:sub(self.lexer.pos, self.lexer.pos):match('%d') do
            self.lexer:advance()
        end
    end

    -- 指数部分
    if self.lexer.text:sub(self.lexer.pos, self.lexer.pos):match('[eE]') then
        self.lexer:advance()
        if self.lexer.text:sub(self.lexer.pos, self.lexer.pos):match('[+-]') then
            self.lexer:advance()
        end
        while self.lexer.pos <= #self.lexer.text and self.lexer.text:sub(self.lexer.pos, self.lexer.pos):match('%d') do
            self.lexer:advance()
        end
    end

    local num_str = self.lexer.text:sub(start, self.lexer.pos - 1)
    return _JsoncNode.new(_NodeType.NUMBER, tonumber(num_str), loc)
end

function _Parser:parse_boolean(loc)
    if self.lexer.text:sub(self.lexer.pos, self.lexer.pos + 3) == "true" then
        self.lexer.pos = self.lexer.pos + 4
        self.lexer.column = self.lexer.column + 4
        return _JsoncNode.new(_NodeType.BOOLEAN, true, loc)
    elseif self.lexer.text:sub(self.lexer.pos, self.lexer.pos + 4) == "false" then
        self.lexer.pos = self.lexer.pos + 5
        self.lexer.column = self.lexer.column + 5
        return _JsoncNode.new(_NodeType.BOOLEAN, false, loc)
    else
        os.raise("Invalid boolean")
    end
end

function _Parser:parse_null(loc)
    if self.lexer.text:sub(self.lexer.pos, self.lexer.pos + 3) == "null" then
        self.lexer.pos = self.lexer.pos + 4
        self.lexer.column = self.lexer.column + 4
        return _JsoncNode.new(_NodeType.NULL, nil, loc)  -- Lua 中用 nil 表示 null
    else
        os.raise("Invalid null")
    end
end

-- ============================================
-- 序列化器（保留注释和格式）
-- ============================================

local _Serializer = {}
_Serializer.__index = _Serializer

function _Serializer.new(options)
    options = options or {}
    return debug.setmetatable({
        indent = options.indent or "    ",
        newline = options.newline or "\n",
        space = options.space or " "
    }, _Serializer)
end

function _Serializer:serialize(node, depth)
    depth = depth or 0
    local parts = {}

    -- 添加前置注释
    for _, comment in ipairs(node.comments.before) do
        table.insert(parts, self:indent_string(depth) .. self:format_comment(comment))
    end

    -- 序列化值
    local value_str = self:serialize_value(node, depth)
    table.insert(parts, value_str)

    -- 添加行尾注释
    if node.comments.after then
        parts[#parts] = parts[#parts] .. self.space .. self:format_comment(node.comments.after)
    end

    return table.concat(parts, self.newline)
end

function _Serializer:format_comment(comment)
    if comment.type == "line" then
        return "//" .. (comment.text and " " .. comment.text or "")
    else
        return "/*" .. (comment.text or "") .. "*/"
    end
end

function _Serializer:indent_string(depth)
    return string.rep(self.indent, depth)
end

function _Serializer:serialize_value(node, depth)
    if node.type == _NodeType.OBJECT then
        return self:serialize_object(node, depth)
    elseif node.type == _NodeType.ARRAY then
        return self:serialize_array(node, depth)
    elseif node.type == _NodeType.STRING then
        return json.encode(node.value)  -- 使用 JSON 编码处理转义
    elseif node.type == _NodeType.NUMBER then
        return tostring(node.value)
    elseif node.type == _NodeType.BOOLEAN then
        return tostring(node.value)
    elseif node.type == _NodeType.NULL then
        return "null"
    end
end

function _Serializer:serialize_object(node, depth)
    local is_empty = true
    for _ in pairs(node.children) do
        is_empty = false
        break
    end

    if is_empty then
        -- 空对象
        local parts = {"{"}
        if #node.comments.inner_before > 0 or #node.comments.inner_after > 0 then
            table.insert(parts, self.newline)
            for _, comment in ipairs(node.comments.inner_before) do
                table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
            end
            for _, comment in ipairs(node.comments.inner_after) do
                table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
            end
            table.insert(parts, self:indent_string(depth) .. "}")
        else
            table.insert(parts, "}")
        end
        return table.concat(parts)
    end

    local parts = {"{", self.newline}

    -- 内部开始注释
    for _, comment in ipairs(node.comments.inner_before) do
        table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
    end

    -- 键值对 - 使用保存的顺序
    local keys = node._key_order
    if not keys or #keys == 0 then
        -- 如果没有保存顺序（不应该发生），至少保持一致性
        keys = {}
        for k in pairs(node.children) do
            table.insert(keys, k)
        end
        table.sort(keys)  -- 使用排序来保证一致性
    end

    for i, key in ipairs(keys) do
        local pair = node.children[key]
        if pair then
            -- 键的前置注释
            for _, comment in ipairs(pair.key.comments.before) do
                table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
            end

            -- 值
            local value_node = pair.value

            -- 值的前置注释（独立成行）
            for _, comment in ipairs(value_node.comments.before) do
                table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
            end

            -- 构建键值对行
            local line = self:indent_string(depth + 1) .. json.encode(key) .. ":" .. self.space

            -- 检查值是否是简单类型
            if value_node.type ~= _NodeType.OBJECT and value_node.type ~= _NodeType.ARRAY then
                -- 简单值，放在同一行
                line = line .. self:serialize_value(value_node, depth + 1)

                -- 添加逗号
                if i < #keys or self.trailing_comma then
                    line = line .. ","
                end

                -- 添加行尾注释
                if value_node.comments.after then
                    line = line .. self.space .. self:format_comment(value_node.comments.after)
                end

                table.insert(parts, line)
            else
                -- 复杂值（对象或数组）- 开始符号应该在同一行！
                line = line .. self:serialize_value(value_node, depth + 1)

                -- 添加逗号
                if i < #keys or self.trailing_comma then
                    -- 找到最后一行，在其末尾添加逗号
                    -- serialize_value 返回的字符串可能包含多行
                    local value_lines = {}
                    for vline in line:gmatch("[^\n]+") do
                        table.insert(value_lines, vline)
                    end
                    value_lines[#value_lines] = value_lines[#value_lines] .. ","
                    line = table.concat(value_lines, self.newline)
                end

                -- 添加行尾注释（在最后的 } 或 ] 后面）
                if value_node.comments.after then
                    local value_lines = {}
                    for vline in line:gmatch("[^\n]+") do
                        table.insert(value_lines, vline)
                    end
                    value_lines[#value_lines] = value_lines[#value_lines] .. self.space .. self:format_comment(value_node.comments.after)
                    line = table.concat(value_lines, self.newline)
                end

                table.insert(parts, line)
            end

            if i < #keys then
                table.insert(parts, self.newline)
            end
        end
    end

    -- 内部结束注释
    if #node.comments.inner_after > 0 then
        table.insert(parts, self.newline)
        for _, comment in ipairs(node.comments.inner_after) do
            table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
        end
    else
        table.insert(parts, self.newline)
    end

    table.insert(parts, self:indent_string(depth) .. "}")
    return table.concat(parts)
end

function _Serializer:serialize_array(node, depth)
    -- 类似 serialize_object，但处理数组
    if #node.children == 0 then
        -- 空数组
        local parts = {"["}
        if #node.comments.inner_before > 0 or #node.comments.inner_after > 0 then
            -- 有内部注释
            table.insert(parts, self.newline)
            for _, comment in ipairs(node.comments.inner_before) do
                table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
            end
            for _, comment in ipairs(node.comments.inner_after) do
                table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
            end
            table.insert(parts, self:indent_string(depth) .. "]")
        else
            table.insert(parts, "]")
        end
        return table.concat(parts)
    end

    local parts = {"["}

    -- 内部开始注释
    if #node.comments.inner_before > 0 then
        table.insert(parts, self.newline)
        for _, comment in ipairs(node.comments.inner_before) do
            table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
        end
    else
        table.insert(parts, self.newline)
    end

    -- 数组元素
    for i = 1, #node.children do
        local element = node.children[i]

        -- 元素的前置注释
        for _, comment in ipairs(element.comments.before) do
            table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
        end

        -- 构建元素行
        local line = self:indent_string(depth + 1) .. self:serialize_value(element, depth + 1)

        -- 添加逗号
        if i < #node.children or self.trailing_comma then
            line = line .. ","
        end

        -- 添加行尾注释
        if element.comments.after then
            line = line .. self.space .. self:format_comment(element.comments.after)
        end

        table.insert(parts, line)

        if i < #node.children then
            table.insert(parts, self.newline)
        end
    end

    -- 内部结束注释
    if #node.comments.inner_after > 0 then
        table.insert(parts, self.newline)
        for _, comment in ipairs(node.comments.inner_after) do
            table.insert(parts, self:indent_string(depth + 1) .. self:format_comment(comment) .. self.newline)
        end
        table.insert(parts, self.newline)
        table.insert(parts, self:indent_string(depth) .. "]")
    else
        table.insert(parts, self.newline)
        table.insert(parts, self:indent_string(depth) .. "]")
    end

    return table.concat(parts)
end


-- ============================================
-- 编辑器 API
-- ============================================

local _Editor = {}
_Editor.__index = _Editor

function _Editor.new(filepath)
    local self = debug.setmetatable({
        filepath = filepath,
        root = nil,
        modified = false
    }, _Editor)

    if os.isfile(filepath) then
        self:load()
    else
        -- 创建空文档
        self.root = _JsoncNode.new(_NodeType.OBJECT, {})
    end

    return self
end

function _Editor:load()
    local content = io.readfile(self.filepath)
    local parser = _Parser.new(content)
    self.root = parser:parse()
end

function _Editor:find_node(path, create_missing)
    -- 处理路径输入
    local parts = {}

    if type(path) == "string" then
        -- 字符串作为单个键名
        parts = {path}
    elseif type(path) == "table" then
        -- table 作为路径数组
        parts = path
    end

    local current = self.root
    local parent = nil
    local key = nil

    for i, part in ipairs(parts) do
        parent = current
        key = part

        if current.type == _NodeType.OBJECT then
            local pair = current.children[part]
            if not pair then
                if create_missing and i < #parts then
                    -- 创建中间节点
                    local new_node = self:create_node(object({}))  -- 创建空对象
                    current.value[part] = new_node.value
                    current.children[part] = {
                        key = _JsoncNode.new(_NodeType.STRING, part),
                        value = new_node
                    }
                    if not current._key_order then
                        current._key_order = {}
                    end
                    table.insert(current._key_order, part)
                    new_node.parent = current
                    new_node.key = part
                    current = new_node
                else
                    return nil, parent, key, i == #parts
                end
            else
                current = pair.value
            end
        elseif current.type == _NodeType.ARRAY then
            current = current.children[part]
            if not current then
                return nil, parent, key, i == #parts
            end
        else
            return nil, parent, key, false
        end
    end

    return current, parent, key, true
end

function _Editor:set(path, value, options)
    options = options or {}

    -- 支持创建中间节点
    local node, parent, key, is_leaf = self:find_node(path, true)

    if not parent then
        os.raise("Cannot set root directly")
    end

    -- 创建新节点
    local new_node = self:create_node(value)

    -- 保留原有注释
    if node and options.preserve_comments ~= false then
        new_node.comments = node.comments
    end

    -- 添加新注释
    if options.comment then
        table.insert(new_node.comments.before, {
            type = "line",
            text = options.comment
        })
    end

    -- 更新父节点
    if parent.type == _NodeType.OBJECT then
        parent.value[key] = new_node.value
        if not parent.children[key] then
            -- 新键，创建键节点
            parent.children[key] = {
                key = _JsoncNode.new(_NodeType.STRING, key),
                value = new_node
            }
            -- 更新键顺序
            if not parent._key_order then
                parent._key_order = {}
            end
            table.insert(parent._key_order, key)
        else
            parent.children[key].value = new_node
        end
    elseif parent.type == _NodeType.ARRAY then
        parent.value[key] = new_node.value
        parent.children[key] = new_node
    end

    new_node.parent = parent
    new_node.key = key

    self.modified = true
    return self
end


-- 严格的 create_node 函数，只接受显式类型
function _Editor:create_node(value)
    local t = type(value)

    if t == "table" then
        -- 必须是包装的类型
        if is_array(value) then
            -- 明确的数组
            local node = _JsoncNode.new(_NodeType.ARRAY, {})
            local actual_array = value.values

            for i = 1, #actual_array do
                local child = self:create_node(actual_array[i])
                child.parent = node
                child.key = i
                table.insert(node.value, child.value)
                node.children[i] = child
            end
            return node

        elseif is_object(value) then
            -- 明确的对象
            local node = _JsoncNode.new(_NodeType.OBJECT, {})
            local actual_object = value.values

            for k, v in pairs(actual_object) do
                local child = self:create_node(v)
                child.parent = node
                child.key = k
                node.value[k] = child.value
                node.children[k] = {
                    key = _JsoncNode.new(_NodeType.STRING, k),
                    value = child
                }
            end
            return node

        else
            -- 拒绝未包装的表
            os.raise("Plain tables are not allowed. Use vscjsonc.array() or vscjsonc.object() to specify the type explicitly.")
        end

    elseif t == "string" then
        return _JsoncNode.new(_NodeType.STRING, value)
    elseif t == "number" then
        return _JsoncNode.new(_NodeType.NUMBER, value)
    elseif t == "boolean" then
        return _JsoncNode.new(_NodeType.BOOLEAN, value)
    elseif value == nil then
        return _JsoncNode.new(_NodeType.NULL, nil)
    else
        os.raise("Unsupported type: " .. t)
    end
end

function _Editor:add_comment(path, comment, position)
    position = position or "before"

    local node = self:find_node(path, true)
    if not node then
        os.raise("Path not found: " .. path)
    end

    local comment_obj = {
        type = "line",
        text = comment
    }

    if position == "before" then
        table.insert(node.comments.before, comment_obj)
    elseif position == "after" then
        node.comments.after = comment_obj
    elseif position == "inner_before" then
        table.insert(node.comments.inner_before, comment_obj)
    elseif position == "inner_after" then
        table.insert(node.comments.inner_after, comment_obj)
    end

    self.modified = true
    return self
end

function _Editor:save(options)
    options = options or {}

    if not self.modified and not options.force then
        return false
    end

    -- 创建序列化器
    local serializer = _Serializer.new({
        indent = options.indent or "    ",
        newline = options.newline or "\n"
    })

    -- 序列化
    local content = serializer:serialize(self.root)

    -- 保存文件
    io.writefile(self.filepath, content)

    self.modified = false
    return true
end

-- ============================================
-- 使用示例
-- ============================================

-- 测试代码
function test_jsonc()
    -- 创建测试文件
    local test_content = [[
{
    // 应用配置
    "name": "MyApp",
    "version": "1.0.0",

    /*
     * 数据库配置
     * 这里是多行注释
     */
    "database": {
        "host": "localhost", // 服务器地址
        "port": 5432,
        "credentials": {
            "username": "admin",
            "password": "secret" // TODO: 使用环境变量
        }
    },

    // 功能开关
    "features": [
        "feature1", // 基础功能
        "feature2", // 高级功能
        "feature3"  // 实验功能
    ],

    // 调试选项
    "debug": true,
}
]]

    io.writefile("test.jsonc", test_content)

    -- 测试解析和修改
    local editor = _Editor.new("test.jsonc")

    -- 修改值（保留注释）
    editor:set({"database","port"}, 3306)

    -- 添加新字段带注释
    editor:set("database.timeout", 30, {
        comment = "连接超时时间（秒）"
    })

    editor:set("features", array({}))
    editor:set({"test1","test2"}, 3)
    editor:save()
end

function main(filepath)
    return _Editor.new(filepath)
end