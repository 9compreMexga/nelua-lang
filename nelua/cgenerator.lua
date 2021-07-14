local CEmitter = require 'nelua.cemitter'
local iters = require 'nelua.utils.iterators'
local traits = require 'nelua.utils.traits'
local stringer = require 'nelua.utils.stringer'
local bn = require 'nelua.utils.bn'
local pegger = require 'nelua.utils.pegger'
local cdefs = require 'nelua.cdefs'
local cbuiltins = require 'nelua.cbuiltins'
local typedefs = require 'nelua.typedefs'
local CContext = require 'nelua.ccontext'
local types = require 'nelua.types'
local ccompiler = require 'nelua.ccompiler'
local primtypes = typedefs.primtypes
local luatype = type
local izip2 = iters.izip2
local emptynext = function() end

local cgenerator = {}
cgenerator.compiler = ccompiler

local function izipargnodes(vars, argnodes)
  if #vars == 0 and #argnodes == 0 then return emptynext end
  local iter, ts, i = izip2(vars, argnodes)
  local lastargindex = #argnodes
  local lastargnode = argnodes[#argnodes]
  local calleetype = lastargnode and lastargnode.attr.calleetype
  if lastargnode and lastargnode.tag:find('^Call') and (not calleetype or not calleetype.is_type) then
    -- last arg is a runtime call
    assert(calleetype)
    -- we know the callee type
    return function()
      local var, argnode
      i, var, argnode = iter(ts, i)
      if not i then return nil end
      if i >= lastargindex and lastargnode.attr.multirets then
        -- argnode does not exists, fill with multiple returns type
        -- in case it doest not exists, the argtype will be false
        local callretindex = i - lastargindex + 1
        local argtype = calleetype:get_return_type(callretindex)
        return i, var, argnode, argtype, callretindex, calleetype
      else
        local argtype = argnode and argnode.attr.type
        return i, var, argnode, argtype, nil
      end
    end
  else
    -- no calls from last argument
    return function()
      local var, argnode
      i, var, argnode = iter(ts, i)
      if i then
        return i, var, argnode, argnode and argnode.attr.type
      end
    end
  end
end


local typevisitors = {}
cgenerator.typevisitors = typevisitors

local function emit_type_attributes(decemitter, type)
  if type.aligned then
    decemitter:add(' __attribute__((aligned(', type.aligned, ')))')
  end
  if type.packed then
    decemitter:add(' __attribute__((packed))')
  end
end

typevisitors[types.ArrayType] = function(context, type)
  local decemitter = CEmitter(context)
  decemitter:add('typedef struct {', type.subtype, ' data[', type.length, '];} ', type.codename)
  emit_type_attributes(decemitter, type)
  decemitter:add(';')
  if type.size and type.size > 0 and not context.pragmas.nocstaticassert then
    context:ensure_builtins('nelua_static_assert', 'nelua_alignof')
    decemitter:add(' nelua_static_assert(sizeof(',type.codename,') == ', type.size, ' && ',
                      'nelua_alignof(',type.codename,') == ', type.align,
                      ', "Nelua and C disagree on type size or align");')
  end
  decemitter:add_ln()
  table.insert(context.declarations, decemitter:generate())
end

typevisitors[types.PointerType] = function(context, type)
  local decemitter = CEmitter(context)
  local index = nil
  if type.subtype.is_composite and not type.subtype.nodecl and not context.declarations[type.subtype.codename] then
    -- offset declaration of pointers before records/unions
    index = #context.declarations+2
  end
  if type.subtype.is_array and type.subtype.length == 0 then
    decemitter:add_ln('typedef ', type.subtype.subtype, '* ', type.codename, ';')
  else
    decemitter:add_ln('typedef ', type.subtype, '* ', type.codename, ';')
  end
  if not index then
    index = #context.declarations+1
  end
  table.insert(context.declarations, index, decemitter:generate())
end

local function typevisitor_CompositeType(context, type)
  local decemitter = CEmitter(context)
  local kindname = type.is_record and 'struct' or 'union'
  if not context.pragmas.noctypedefs then
    decemitter:add_ln('typedef ', kindname, ' ', type.codename, ' ', type.codename, ';')
  end
  table.insert(context.declarations, decemitter:generate())
  local defemitter = CEmitter(context)
  defemitter:add(kindname, ' ', type.codename)
  defemitter:add(' {')
  if #type.fields > 0 then
    defemitter:add_ln()
    for _,field in ipairs(type.fields) do
      local fieldctype
      if field.type.is_array then
        fieldctype = field.type.subtype
      else
        fieldctype = context:ensure_type(field.type)
      end
      defemitter:add('  ', fieldctype, ' ', field.name)
      if field.type.is_array then
        defemitter:add('[', field.type.length, ']')
      end
      defemitter:add_ln(';')
    end
  end
  defemitter:add('}')
  emit_type_attributes(defemitter, type)
  defemitter:add(';')
  if type.size and type.size > 0 and not context.pragmas.nocstaticassert then
    context:ensure_builtins('nelua_static_assert', 'nelua_alignof')
    defemitter:add(' nelua_static_assert(sizeof(',type.codename,') == ', type.size, ' && ',
                      'nelua_alignof(',type.codename,') == ', type.align,
                      ', "Nelua and C disagree on type size or align");')
  end
  defemitter:add_ln()
  table.insert(context.declarations, defemitter:generate())
end

typevisitors[types.RecordType] = typevisitor_CompositeType
typevisitors[types.UnionType] = typevisitor_CompositeType

typevisitors[types.EnumType] = function(context, type)
  local decemitter = CEmitter(context)
  decemitter:add_ln('typedef ', type.subtype, ' ', type.codename, ';')
  table.insert(context.declarations, decemitter:generate())
end

typevisitors[types.FunctionType] = function(context, type)
  local decemitter = CEmitter(context)
  decemitter:add('typedef ', context:funcrettypename(type), ' (*', type.codename, ')(')
  for i,argtype in ipairs(type.argtypes) do
    if i>1 then
      decemitter:add(', ')
    end
    decemitter:add(argtype)
  end
  decemitter:add_ln(');')
  table.insert(context.declarations, decemitter:generate())
end

typevisitors[types.NiltypeType] = function(context)
  context:ensure_builtin('nlniltype')
end

typevisitors.FunctionReturnType = function(context, functype)
  if #functype.rettypes <= 1 then
    return context:ensure_type(functype:get_return_type(1))
  end
  local rettypes = functype.rettypes
  local retnames = {'nlmulret'}
  for i=1,#rettypes do
    retnames[#retnames+1] = rettypes[i].codename
  end
  local rettypename = table.concat(retnames, '_')
  if context:is_declared(rettypename) then return rettypename end
  local retemitter = CEmitter(context)
  retemitter:add_indent()
  if not context.pragmas.noctypedefs then
    retemitter:add('typedef ')
  end
  retemitter:add_ln('struct ', rettypename, ' {') retemitter:inc_indent()
  for i=1,#rettypes do
    retemitter:add_indent_ln(rettypes[i], ' ', 'r', i, ';')
  end
  retemitter:dec_indent() retemitter:add_indent('}')
  if not context.pragmas.noctypedefs then
    retemitter:add(' ', rettypename)
  end
  retemitter:add_ln(';')
  context:add_declaration(retemitter:generate(), rettypename)
  return rettypename
end

--[[
typevisitors[types.PolyFunctionType] = function(context, type)
  if type.nodecl or context:is_declared(type.codename) then return end
  local decemitter = CEmitter(context)
  decemitter:add_ln('typedef void* ', type.codename, ';')
  context:add_declaration(decemitter:generate(), type.codename)
end
]]

typevisitors[types.Type] = function(context, type)
  local node = context:get_visiting_node()
  if type.is_any or type.is_varanys then
    node:raisef("compiler deduced the type 'any' here, but it's not supported yet in the C backend")
  else
    node:raisef("type '%s' is not supported yet in the C backend", type)
  end
end

local visitors = {}
cgenerator.visitors = visitors

function visitors.Number(context, node, emitter)
  local attr = node.attr
  local type = attr.type
  if not type.is_float and not attr.untyped and not context.state.ininitializer then
    emitter:add('(', type, ')')
  end
  emitter:add_scalar_literal(attr.value, attr.type, attr.base)
end

-- Emits a string literal.
function visitors.String(_, node, emitter)
  local attr = node.attr
  local type = attr.type
  if type.is_stringy then
    emitter:add_string_literal(attr.value, type.is_cstring)
  else -- an integral
    if type == primtypes.cchar then -- C character literal
      emitter:add(pegger.single_quote_c_string(string.char(bn.tointeger(attr.value))))
    else -- number
      emitter:add_scalar_literal(attr.value, type, attr.base)
    end
  end
end

-- Emits a boolean literal.
function visitors.Boolean(_, node, emitter)
  emitter:add_boolean(node.attr.value)
end

-- Emits a `nil` literal.
function visitors.Nil(_, _, emitter)
  emitter:add_nil_literal()
end

-- Emits a `nilptr` literal.
function visitors.Nilptr(_, _, emitter)
  emitter:add_null()
end

-- Emits C varargs `...` in function arguments.
function visitors.VarargsType(_, node, emitter)
  local type = node.attr.type
  if type.is_varanys then
    node:raisef("compiler deduced the type 'varanys' here, but it's not supported yet in the C backend")
  end
  assert(type.is_cvarargs)
  emitter:add('...')
end

-- Check if a an array of nodes can be emitted using an initialize.
local function can_use_initializer(childnodes)
  local hassideeffect = false
  for _,childnode in ipairs(childnodes) do
    local childvalnode
    if childnode.tag == 'Pair' then
      childvalnode = childnode[2]
    else
      childvalnode = childnode
    end
    local childvaltype = childvalnode.attr.type
    local sideeffect = childvalnode:recursive_has_attr('sideeffect')
    if childvaltype.is_array or (hassideeffect and sideeffect) then
      return false
    end
    if sideeffect then hassideeffect = true end
  end
  return true
end

function visitors.InitList(context, node, emitter)
  local attr = node.attr
  local childnodes, type = node, attr.type
  local len = #childnodes
  if len == 0 and type.is_aggregate then
    if not context.state.ininitializer then
      emitter:add('(', type, ')')
    end
    emitter:add_zeroed_type_literal(type)
  elseif type.is_composite then
    if context.state.ininitializer then
      context:push_forked_state{incompositeinitializer = true}
      emitter:add('{')
      emitter:add_list(childnodes)
      emitter:add('}')
      context:pop_state()
    elseif type.cconstruct then -- used to construct vector types when generating GLSL code
      --luacov:disable
      emitter:add(type,'(')
      emitter:add('(')
      emitter:add_list(childnodes)
      emitter:add(')')
      --luacov:enable
    else
      local useinitializer = can_use_initializer(childnodes)
      if useinitializer then
        emitter:add('(',type,'){')
      else
        emitter:add_ln('({') emitter:inc_indent()
        emitter:add_indent(type, ' _tmp = ')
        emitter:add_zeroed_type_literal(type)
        emitter:add_ln(';')
      end
      local lastfieldindex = 0
      for i,childnode in ipairs(childnodes) do
        local named = false
        local childvalnode
        local field
        if childnode.tag == 'Pair' then
          childvalnode = childnode[2]
          field = type.fields[childnode[1]]
          named = true
        else
          childvalnode = childnode
          field = type.fields[lastfieldindex + 1]
        end
        lastfieldindex = field.index
        assert(field)
        if useinitializer then
          if i > 1 then
            emitter:add(', ')
          end
          if named then
            emitter:add('.', field.name, ' = ')
          end
        else
          local childvaltype = childvalnode.attr.type
          if childvaltype.is_array then
            emitter:add_indent('(*(', childvaltype, '*)_tmp.', field.name, ') = ')
          else
            emitter:add_indent('_tmp.', field.name, ' = ')
          end
        end
        local fieldtype = type.fields[field.name].type
        assert(fieldtype)
        emitter:add_converted_val(fieldtype, childvalnode)
        if not useinitializer then
          emitter:add_ln(';')
        end
      end
      if useinitializer then
        emitter:add('}')
      else
        emitter:add_indent_ln('_tmp;')
        emitter:dec_indent() emitter:add_indent('})')
      end
    end
  elseif type.is_array then
    if context.state.ininitializer then
      if context.state.incompositeinitializer then
        emitter:add('{')
        emitter:add_list(childnodes)
        emitter:add('}')
      else
        emitter:add('{{')
        emitter:add_list(childnodes)
        emitter:add('}}')
      end
    else
      local useinitializer = can_use_initializer(childnodes)
      if useinitializer then
        emitter:add('(', type, '){{')
      else
        emitter:add_ln('({') emitter:inc_indent()
        emitter:add_indent(type, ' _tmp = ')
        emitter:add_zeroed_type_literal(type)
        emitter:add_ln(';')
      end
      local subtype = type.subtype
      for i,childnode in ipairs(childnodes) do
        if useinitializer then
          if i > 1 then
            emitter:add(', ')
          end
        else
          emitter:add_indent('_tmp.data[', i-1 ,'] = ')
        end
        emitter:add_converted_val(subtype, childnode)
        if not useinitializer then
          emitter:add_ln(';')
        end
      end
      if useinitializer then
        emitter:add('}}')
      else
        emitter:add_indent_ln('_tmp;')
        emitter:dec_indent() emitter:add_indent('})')
      end
    end
  else --luacov:disable
    error('not implemented yet')
  end --luacov:enable
end

function visitors.Pair(_, node, emitter)
  local namenode, valuenode = node[1], node[2]
  local parenttype = node.attr.parenttype
  if parenttype and parenttype.is_composite then
    assert(traits.is_string(namenode))
    local field = parenttype.fields[namenode]
    emitter:add('.', cdefs.quotename(field.name), ' = ')
    emitter:add_converted_val(field.type, valuenode)
  else --luacov:disable
    error('not implemented yet')
  end --luacov:enable
end

-- Process directives, they may effect code generation.
function visitors.Directive(context, node, emitter)
  local name, args = node[1], node[2]
  if name == 'cinclude' then
    context:ensure_include(args[1])
  elseif name == 'cfile' then
    context:ensure_cfile(args[1])
  elseif name == 'cemit' then
    local code = args[1]
    if traits.is_string(code) then
      emitter:add(stringer.ensurenewline(code))
    elseif traits.is_function(code) then
      code(emitter)
    end
  elseif name == 'cemitdecl' then
    local code = args[1]
    if traits.is_string(code) then
      code = stringer.ensurenewline(code)
    elseif traits.is_function(code) then
      local decemitter = CEmitter(context)
      code(decemitter)
      code = decemitter:generate()
    end
    -- actually add in the directives section (just above declarations section)
    context:add_directive(code)
  elseif name == 'cemitdef' then
    local code = args[1]
    if traits.is_string(code) then
      code = stringer.ensurenewline(code)
    elseif traits.is_function(code) then
      local defemitter = CEmitter(context)
      code(defemitter)
      code = defemitter:generate()
    end
    context:add_definition(code)
  elseif name == 'cdefine' then
    context:ensure_define(args[1])
  elseif name == 'cflags' then
    table.insert(context.compileopts.cflags, args[1])
  elseif name == 'ldflags' then
    table.insert(context.compileopts.ldflags, args[1])
  elseif name == 'linklib' then
    context:ensure_linklib(args[1])
  elseif name == 'pragmapush' then
    context:push_forked_pragmas(args[1])
  elseif name == 'pragmapop' then
    context:pop_pragmas()
  end
end

-- Emits a identifier.
function visitors.Id(context, node, emitter)
  local attr = node.attr
  local type = attr.type
  assert(not type.is_comptime)
  if type.is_nilptr then
    emitter:add_null()
  elseif attr.comptime then
    emitter:add_literal(attr)
  else
    emitter:add(context:declname(attr))
  end
end

-- Emits a expression between parenthesis.
function visitors.Paren(_, node, emitter)
  -- adding parenthesis is not needed, because other expressions already adds them
  emitter:add(node[1])
end

-- Emits declaration of identifiers.
function visitors.IdDecl(context, node, emitter)
  local attr = node.attr
  local type = attr.type
  local name = context:declname(attr)
  if context.state.infuncdecl then -- function name
    emitter:add(name)
  elseif type.is_comptime or attr.comptime then -- pass compile-time identifiers as `nil`
    emitter:add_builtin('nlniltype')
    emitter:add(' ', name)
  else -- runtime declaration
    emitter:add_qualified_declaration(attr, type, name)
  end
end

local function visitor_Call(context, node, emitter, argnodes, callee, calleeobjnode)
  local isblockcall = context:get_visiting_node(1).tag == 'Block'
  if isblockcall then
    emitter:add_indent()
  end
  local attr = node.attr
  local calleetype = attr.calleetype
  local upfuncscope = context.scope:get_up_function_scope()
  if calleetype.is_procedure then
    -- function call
    local tmpargs
    local tmpcount = 0
    local lastcalltmp
    local sequential
    local serialized
    local callargtypes = attr.pseudoargtypes or calleetype.argtypes
    local callargattrs = attr.pseudoargattrs or calleetype.argattrs
    for i,funcargtype,argnode,_,lastcallindex in izipargnodes(callargtypes, argnodes) do
      if not argnode and (funcargtype.is_cvarargs or funcargtype.is_varargs) then break end
      if (argnode and argnode.attr.sideeffect) or lastcallindex == 1 then
        -- expressions with side effects need to be evaluated in sequence
        -- and expressions with multiple returns needs to be stored in a temporary
        if tmpcount == 0 then
          tmpargs = {}
        end
        tmpcount = tmpcount + 1
        local tmpname = '_tmp' .. tmpcount
        tmpargs[i] = tmpname
        if lastcallindex == 1 then
          lastcalltmp = tmpname
        end
        if tmpcount >= 2 or lastcallindex then
          -- only need to evaluate in sequence mode if we have two or more temporaries
          -- or the last argument is a multiple return call
          sequential = true
          serialized = true
        end
      end
    end

    local handlereturns
    local retvalname
    local returnfirst
    if #calleetype.rettypes > 1 and not isblockcall and not attr.multirets then
      -- we are handling the returns
      returnfirst = true
      handlereturns = true
      serialized = true
    end

    if serialized then
      -- break apart the call into many statements
      if not isblockcall then
        emitter:add_value('(')
      end
      emitter:add_ln('{') emitter:inc_indent()
    end

    if sequential then
      for _,tmparg,argnode,argtype,_,lastcalletype in izipargnodes(tmpargs, argnodes) do
        -- set temporary values in sequence
        if tmparg then
          if lastcalletype then
            -- type for result of multiple return call
            argtype = context:funcrettypename(lastcalletype)
          end
          emitter:add_indent_ln(argtype, ' ', tmparg, ' = ', argnode, ';')
        end
      end
    end

    if serialized then
      emitter:add_indent()
      if handlereturns then
        -- save the return type
        local rettypename = context:funcrettypename(calleetype)
        retvalname = upfuncscope:generate_name('_callret')
        emitter:add(rettypename, ' ', retvalname, ' = ')
      end
    end

    local ismethod = attr.ismethod
    if ismethod then
      local selftype = calleetype.argtypes[1]
      if attr.calleesym then
        emitter:add_value(context:declname(attr.calleesym))
      else
        assert(luatype(callee) == 'string')
        emitter:add_value('(')
        emitter:add_converted_val(selftype, calleeobjnode)
        emitter:add_value(')')
        emitter:add_value(selftype.is_pointer and '->' or '.')
        emitter:add_value(callee)
      end
      emitter:add_value('(')
      emitter:add_converted_val(selftype, calleeobjnode)
    else
      local ispointercall = attr.pointercall
      if ispointercall then
        emitter:add_text('(*')
      end
      if luatype(callee) ~= 'string' and attr.calleesym then
        emitter:add_text(context:declname(attr.calleesym))
      else
        emitter:add_value(callee)
      end
      if ispointercall then
        emitter:add_text(')')
      end
      emitter:add_text('(')
    end

    for i,funcargtype,argnode,argtype,lastcallindex in izipargnodes(callargtypes, argnodes) do
      if not argnode and (funcargtype.is_cvarargs or funcargtype.is_varargs) then break end
      if i > 1 or ismethod then emitter:add_value(', ') end
      local arg = argnode
      if sequential then
        if lastcallindex then
          arg = string.format('%s.r%d', lastcalltmp, lastcallindex)
        elseif tmpargs[i] then
          arg = tmpargs[i]
        end
      end

      local callargattr = callargattrs[i]
      if callargattr.comptime then
        -- compile time function argument
        emitter:add_nil_literal()

        if argnode and argnode.tag == 'Function' then -- force declaration of anonymous functions
          emitter:fork():add(argnode)
        end
      else
        emitter:add_converted_val(funcargtype, arg, argtype)
      end
    end
    emitter:add_text(')')

    if serialized then
      -- end sequential expression
      emitter:add_ln(';')
      if returnfirst then
        -- get just the first result in multiple return functions
        assert(#calleetype.rettypes > 1)
        emitter:add_indent_ln(retvalname, '.r1;')
      end
      emitter:dec_indent() emitter:add_indent('}')
      if not isblockcall then
        emitter:add_value(')')
      end
    end
  end
  if isblockcall then
    emitter:add_text(";\n")
  end
end

-- Emits a call.
function visitors.Call(context, node, emitter)
  local argnodes, calleenode = node[1], node[2]
  local attr = node.attr
  if attr.calleetype.is_type then -- is a type cast?
    local type = attr.type
    if #argnodes == 0 then -- no arguments? then it's a zeroed type initialization
      emitter:add_zeroed_type_literal(type, true)
    else -- explicit type cast
      emitter:add_converted_val(type, argnodes[1], nil, true)
    end
  else -- usual function call
    local callee = calleenode
    local calleeattr = calleenode.attr
    if calleeattr.builtin then -- is a builtin call?
      local builtin = cbuiltins.calls[calleeattr.name]
      callee = builtin(context, node, emitter)
    end
    if callee then -- call not omitted?
      visitor_Call(context, node, emitter, argnodes, callee)
    end
  end
end

-- Emits a method call.
function visitors.CallMethod(context, node, emitter)
  local name, argnodes, calleeobjnode = node[1], node[2], node[3]
  visitor_Call(context, node, emitter, argnodes, name, calleeobjnode)
end

-- indexing
function visitors.DotIndex(context, node, emitter)
  local attr = node.attr
  local name = attr.dotfieldname or node[1]
  local objnode = node[2]
  local type = attr.type
  local objtype = objnode.attr.type
  local poparray = false
  if type.is_array then
    if objtype:implicit_deref_type().is_composite and context.state.inarrayindex == node then
      context.state.fieldindexed = node
    elseif not attr.globalfield then
      emitter:add('(*(', type, '*)')
      poparray = true
    end
  end
  if objtype.is_type then
    objtype = attr.indextype
    if objtype.is_enum then
      local field = objtype.fields[name]
      emitter:add_scalar_literal(field.value, objtype.subtype)
    elseif objtype.is_composite then
      if attr.comptime then
        emitter:add_literal(attr)
      else
        emitter:add(context:declname(attr))
      end
    else --luacov:disable
      error('not implemented yet')
    end --luacov:enable
  elseif objtype.is_pointer then
    emitter:add(objnode, '->', cdefs.quotename(name))
  else
    emitter:add(objnode, '.', cdefs.quotename(name))
  end
  if poparray then
    emitter:add(')')
  end
end

visitors.ColonIndex = visitors.DotIndex

function visitors.KeyIndex(context, node, emitter)
  local indexnode, objnode = node[1], node[2]
  local objtype = objnode.attr.type
  local pointer = false
  if objtype.is_pointer and not objtype.is_generic_pointer then
    -- indexing a pointer to an array
    objtype = objtype.subtype
    pointer = true
  end

  if objtype.is_record then
    local atindex = node.attr.calleesym and node.attr.calleesym.name:match('.__atindex')
    if atindex then
      emitter:add('(*')
    end
    visitor_Call(context, node, emitter, {indexnode}, nil, objnode)
    if atindex then
      emitter:add(')')
    end
  else
    if not objtype.is_array then --luacov:disable
      error('not implemented yet')
    end --luacov:enable

    if pointer then
      if objtype.length == 0 then
        emitter:add('(',objnode, ')[')
      else
        emitter:add('((', objtype.subtype, '*)', objnode, ')[')
      end
    elseif objtype.length == 0 then
      emitter:add('((', objtype.subtype, '*)&', objnode, ')[')
    else
      context:push_forked_state{inarrayindex = objnode}
      emitter:add(objnode)
      if context.state.fieldindexed ~= objnode then
        emitter:add('.data')
      end
      emitter:add('[')
      context:pop_state()
    end
    if not context.pragmas.nochecks and objtype.length > 0 and not indexnode.attr.comptime then
      local indextype = indexnode.attr.type
      emitter:add_builtin('nelua_assert_bounds_', indextype)
      emitter:add('(', indexnode, ', ', objtype.length, ')')
    else
      emitter:add(indexnode)
    end
    emitter:add(']')
  end
end

-- Emits all statements from a block.
function visitors.Block(context, node, emitter)
  local scope = context:push_forked_scope(node)
  emitter:inc_indent()
  emitter:add_list(node, '')
  cgenerator.emit_close_scope(context, emitter, scope)
  emitter:dec_indent()
  context:pop_scope()
end

-- Emits `return` statement.
function visitors.Return(context, node, emitter)
  local deferemitter = emitter:fork()
  -- close parent blocks before returning
  local scope = context.scope
  local retscope = scope:get_up_return_scope()
  cgenerator.emit_close_upscopes(context, deferemitter, scope, retscope)
  if retscope.is_doexpr then -- inside a do expression
    emitter:add_indent_ln('_expr = ', node[1], ';')
    emitter:add(deferemitter)
    local needgoto = true
    if context:get_visiting_node(2).tag == 'DoExpr' then
      local blockstats = context:get_visiting_node(1)
      if node == blockstats[#blockstats] then -- last statement does not need goto
        needgoto = false
      end
    end
    if needgoto then
      local doexprlabel = retscope.doexprlabel
      if not doexprlabel then
        doexprlabel = context.scope:get_up_function_scope():generate_name('_doexprlabel')
        retscope.doexprlabel = doexprlabel
      end
      emitter:add_indent_ln('goto ', doexprlabel, ';')
    end
  else -- returning from a function
    local funcscope = context.state.funcscope
    assert(funcscope == retscope)
    local functype = funcscope.funcsym and funcscope.funcsym.type
    local numrets = functype and #functype.rettypes or #node
    if numrets == 0 then -- no returns
      emitter:add_value(deferemitter)
      if retscope.is_root then -- main must always return an integer
        emitter:add_indent_ln('return 0;')
      else
        emitter:add_indent_ln('return;')
      end
    elseif numrets == 1 then -- one return
      local retnode = node[1]
      local rettype = retscope.is_root and primtypes.cint or functype:get_return_type(1)
      if not deferemitter:empty() and retnode and retnode.tag ~= 'Id' and not retnode.attr.comptime then
        local retname = funcscope:generate_name('_ret')
        emitter:add_indent(rettype, ' ', retname, ' = ')
        emitter:add_converted_val(rettype, retnode)
        emitter:add_ln(';')
        emitter:add_value(deferemitter)
        emitter:add_indent_ln('return ', retname, ';')
      else
        emitter:add_value(deferemitter)
        emitter:add_indent('return ')
        emitter:add_converted_val(rettype, retnode, nil, true)
        emitter:add_ln(';')
      end
    else -- multiple returns
      if retscope.is_root then
        node:raisef("multiple returns in main is not supported")
      end
      local funcrettypename = context:funcrettypename(functype)
      local multiretvalname, retname, retemitter
      local sideeffects = not deferemitter:empty() or node:recursive_has_attr('sideeffect')
      if sideeffects then
        retname = funcscope:generate_name('_mulret')
        emitter:add_indent_ln(funcrettypename, ' ', retname, ';')
      else -- no side effects
        retemitter = emitter:fork()
        retemitter:add_indent('return (', funcrettypename, '){')
      end
      for i,funcrettype,retnode,rettype,lastcallindex in izipargnodes(functype.rettypes, node) do
        if not sideeffects and i > 1 then
          retemitter:add(', ')
        end
        if lastcallindex == 1 then -- last assignment value may be a multiple return call
          multiretvalname = funcscope:generate_name('_ret')
          local rettypename = context:funcrettypename(retnode.attr.calleetype)
          emitter:add_indent_ln(rettypename, ' ', multiretvalname, ' = ', retnode, ';')
        end
        local retvalname = retnode
        if lastcallindex then
          retvalname = string.format('%s.r%d', multiretvalname, lastcallindex)
        end
        if sideeffects then
          emitter:add_indent(string.format('%s.r%d', retname, i), ' = ')
          emitter:add_converted_val(funcrettype, retvalname, rettype)
          emitter:add_ln(';')
        else
          retemitter:add_converted_val(funcrettype, retvalname, rettype)
        end
      end
      if sideeffects then
        emitter:add(deferemitter)
        emitter:add_indent_ln('return ', retname, ';')
      else -- no side effects
        retemitter:add_ln('};')
        emitter:add(retemitter)
      end
    end
  end
end

-- Emits `if` statement.
function visitors.If(_, node, emitter)
  local ifpairs, elseblock = node[1], node[2]
  for i=1,#ifpairs,2 do
    local condnode, blocknode = ifpairs[i], ifpairs[i+1]
    if i == 1 then -- first if
      emitter:add_indent("if(")
      emitter:add_val2boolean(condnode)
      emitter:add_ln(") {")
    else -- other ifs
      emitter:add_indent("} else if(")
      emitter:add_val2boolean(condnode)
      emitter:add_ln(") {")
    end
    emitter:add(blocknode)
  end
  if elseblock then -- else
    emitter:add_indent_ln("} else {")
    emitter:add(elseblock)
  end
  emitter:add_indent_ln("}")
end

-- Emits `switch` statement.
function visitors.Switch(context, node, emitter)
  local valnode, casepairs, elsenode = node[1], node[2], node[3]
  emitter:add_indent_ln("switch(", valnode, ") {") emitter:inc_indent()
  context:push_forked_scope(node)
  for i=1,#casepairs,2 do -- add case blocks
    local caseexprs, caseblock = casepairs[i], casepairs[i+1]
    for j=1,#caseexprs-1 do -- multiple cases
      emitter:add_indent_ln("case ", caseexprs[j], ":")
    end
    emitter:add_indent_ln("case ", caseexprs[#caseexprs], ': {') -- last case
    emitter:add(caseblock) -- block
    emitter:add_indent_ln('  break;')
    emitter:add_indent_ln("}")
  end
  if elsenode then -- add default case block
    emitter:add_indent_ln('default: {')
    emitter:add(elsenode)
    emitter:add_indent_ln('  break;')
    emitter:add_indent_ln("}")
  end
  context:pop_scope(node)
  emitter:dec_indent() emitter:add_indent_ln("}")
end

-- Emits `do` statement.
function visitors.Do(_, node, emitter)
  local blocknode = node[1]
  local rollbackpos = emitter:get_pos()
  emitter:add_indent_ln("{")
  local startpos = emitter:get_pos()
  emitter:add(blocknode)
  if emitter:get_pos() == startpos then -- no statement added, we can rollback
    emitter:rollback(rollbackpos)
  else
    emitter:add_indent_ln("}")
  end
end

-- Emits `(do end)` expression.
function visitors.DoExpr(context, node, emitter)
  local attr = node.attr
  local isstatement = context:get_visiting_node(1).tag == 'Block'
  if isstatement then -- a macros could have replaced a statement with do exprs
    if attr.noop then -- skip macros without operations
      return true
    end
    emitter:add_indent('(void)')
  end
  local blocknode = node[1]
  if blocknode[1].tag == 'Return' then -- single statement
    emitter:add(blocknode[1][1])
  else -- multiple statements
    emitter:add_ln("({") emitter:inc_indent()
    emitter:add_indent_ln(attr.type, ' _expr;')
    emitter:dec_indent()
    local scope = context:push_forked_scope(node)
    emitter:add(blocknode)
    context:pop_scope()
    emitter:inc_indent()
    local doexprlabel = scope.doexprlabel
    if doexprlabel then
      emitter:add_indent_ln(doexprlabel, ': _expr;')
    else
      emitter:add_indent_ln('_expr;')
    end
    emitter:dec_indent() emitter:add_indent("})")
  end
  if isstatement then
    emitter:add_ln(';')
  end
end

-- Emits `defer` statement.
function visitors.Defer(context, node)
  local blocknode = node[1]
  context.scope:add_defer_block(blocknode)
end

-- Emits `while` statement.
function visitors.While(context, node, emitter)
  local condnode, blocknode = node[1], node[2]
  emitter:add_indent("while(")
  emitter:add_val2boolean(condnode)
  emitter:add_ln(') {')
  local scope = context:push_forked_scope(node)
  emitter:add(blocknode)
  context:pop_scope()
  emitter:add_indent_ln("}")
  if scope.breaklabel then
    emitter:add_indent_ln(scope.breaklabel, ':;')
  end
end

-- Emits `repeat` statement.
function visitors.Repeat(context, node, emitter)
  local blocknode, condnode = node[1], node[2]
  emitter:add_indent_ln("while(1) {")
  local scope = context:push_forked_scope(node)
  emitter:add(blocknode)
  emitter:inc_indent()
  emitter:add_indent('if(')
  emitter:add_val2boolean(condnode)
  emitter:add_ln(') {')
  emitter:add_indent_ln('  break;')
  emitter:add_indent_ln('}')
  context:pop_scope()
  emitter:dec_indent()
  emitter:add_indent_ln('}')
  if scope.breaklabel then
    emitter:add_indent_ln(scope.breaklabel, ':;')
  end
end

-- Emits numeric `for` statement.
function visitors.ForNum(context, node, emitter)
  local itnode, begvalnode, endvalnode, stepvalnode, blocknode = node[1], node[2], node[4], node[5], node[6]
  local attr = node.attr
  local compop, fixedstep, fixedend = attr.compop, attr.fixedstep, attr.fixedend
  local itattr = itnode.attr
  local ittype, itmutate = itattr.type, itattr.mutate or itattr.refed
  local itforname = itmutate and '_it' or context:declname(itattr)
  local scope = context:push_forked_scope(node)
  emitter:add_indent('for(', ittype, ' ', itforname, ' = ')
  emitter:add_converted_val(ittype, begvalnode)
  local cmpval, stepval = endvalnode, fixedstep
  if not fixedend or not compop then -- end expression
    emitter:add(', _end = ')
    emitter:add_converted_val(ittype, endvalnode)
    cmpval = '_end'
  end
  if not fixedstep then -- step expression
    emitter:add(', _step = ')
    emitter:add_converted_val(ittype, stepvalnode)
    stepval = '_step'
  end
  emitter:add('; ')
  if compop then -- fixed compare operator
    emitter:add(itforname, ' ', cdefs.for_compare_ops[compop], ' ')
    if traits.is_string(cmpval) then
      emitter:add(cmpval)
    else
      emitter:add_converted_val(ittype, cmpval)
    end
  else -- step is an expression, must detect the compare operation at runtime
    emitter:add('_step >= 0 ? ', itforname, ' <= _end : ', itforname, ' >= _end')
  end
  emitter:add_ln('; ', itforname, ' = ', itforname, ' + ', stepval, ') {')
  if itmutate then -- block mutates the iterator, copy it
    emitter:inc_indent()
    emitter:add_indent_ln(itnode, ' = _it;')
    emitter:dec_indent()
  end
  emitter:add(blocknode)
  emitter:add_indent_ln('}')
  context:pop_scope()
  if scope.breaklabel then
    emitter:add_indent_ln(scope.breaklabel, ':;')
  end
end

-- Emits `break` statement.
function visitors.Break(context, _, emitter)
  local scope = context.scope
  cgenerator.emit_close_upscopes(context, emitter, scope, scope:get_up_loop_scope())
  local breakscope = context.scope:get_up_scope_of_any_kind('is_loop', 'is_switch')
  if breakscope.is_switch then -- use goto when inside a switch to not break it
    breakscope = context.scope:get_up_loop_scope()
    local breaklabel = breakscope.breaklabel
    if not breaklabel then -- generate a break label
      breaklabel = context.scope:get_up_function_scope():generate_name('_breaklabel')
      breakscope.breaklabel = breaklabel
    end
    emitter:add_indent_ln('goto ', breaklabel, ';')
  else
    emitter:add_indent_ln('break;')
  end
end

-- Emits `continue` statement.
function visitors.Continue(context, _, emitter)
  local scope = context.scope
  cgenerator.emit_close_upscopes(context, emitter, scope, scope:get_up_loop_scope())
  emitter:add_indent_ln('continue;')
end

-- Emits label statement.
function visitors.Label(context, node, emitter)
  local attr = node.attr
  if not attr.used then return end -- ignore unused labels
  emitter:add_ln(context:declname(attr), ':;')
end

-- Emits `goto` statement.
function visitors.Goto(context, node, emitter)
  local label = node.attr.label
  emitter:add_indent_ln('goto ', context:declname(label), ';')
end

-- Emits variable declaration statement.
function visitors.VarDecl(context, node, emitter)
  local varnodes, valnodes = node[2], node[3]
  local defemitter = emitter:fork()
  local multiretvalname
  local upfuncscope = context.scope:get_up_function_scope()
  for _,varnode,valnode,valtype,lastcallindex in izipargnodes(varnodes, valnodes or {}) do
    local varattr = varnode.attr
    local vartype = varattr.type
    if lastcallindex == 1 then -- last assignment may be a multiple return call
      multiretvalname = upfuncscope:generate_name('_asgnret')
      local rettypename = context:funcrettypename(valnode.attr.calleetype)
      emitter:add_indent_ln(rettypename, ' ', multiretvalname, ' = ', valnode, ';')
    end
    if varattr:must_declare_at_runtime() and (context.pragmas.nodce or varattr:is_used(true)) then
      local zeroinit = not context.pragmas.noinit and varattr:must_zero_initialize()
      local declared, defined
      if varattr.staticstorage then -- declare variables in the top scope
        local decemitter = CEmitter(context)
        decemitter:add_indent(varnode)
        if valnode and valnode.attr.initializer then -- initialize to const values
          assert(not lastcallindex)
          decemitter:add(' = ')
          context:push_forked_state{ininitializer = true}
          decemitter:add_converted_val(vartype, valnode)
          context:pop_state()
          defined = true
        elseif zeroinit then -- pre initialize with zeros
          decemitter:add(' = ')
          decemitter:add_zeroed_type_literal(vartype)
          defined = not valnode and not lastcallindex
        end
        decemitter:add_ln(';')
        context:add_declaration(decemitter:generate())
        declared = true
      end
      if varattr:must_define_at_runtime() then
        local asgnvalname, asgnvaltype = valnode, valtype
        if lastcallindex then
          asgnvalname = string.format('%s.r%d', multiretvalname, lastcallindex)
        end
        local mustdefine = not defined and (zeroinit or asgnvalname)
        if not declared or mustdefine then -- declare or define if needed
          if not declared then
            defemitter:add_indent(varnode)
          else
            defemitter:add_indent(context:declname(varattr))
          end
          if mustdefine then -- initialize variable
            defemitter:add(' = ')
            defemitter:add_converted_val(vartype, asgnvalname, asgnvaltype)
          end
          defemitter:add_ln(';')
        end
      elseif not defined and not vartype.is_comptime and valnode and not valnode.attr.comptime then
        -- could be a call
        emitter:add_indent_ln('(void)', valnode, ';')
      end
    elseif not vartype.is_comptime and valnode and not valnode.attr.comptime then  -- could be a call
      emitter:add_indent_ln('(void)', valnode, ';')
    end
    if varattr.cinclude then
      context:ensure_include(varattr.cinclude)
    end
  end
  emitter:add(defemitter)
end

-- Emits assignment statement.
function visitors.Assign(context, node, emitter)
  local varnodes, valnodes = node[1], node[2]
  local defemitter = emitter:fork()
  local multiretvalname
  local upfuncscope = context.scope:get_up_function_scope()
  for _,varnode,valnode,valtype,lastcallindex in izipargnodes(varnodes, valnodes or {}) do
    local varattr = varnode.attr
    local vartype = varattr.type
    if lastcallindex == 1 then -- last assignment may be a multiple return call
      multiretvalname = upfuncscope:generate_name('_asgnret')
      local rettypename = context:funcrettypename(valnode.attr.calleetype)
      emitter:add_indent_ln(rettypename, ' ', multiretvalname, ' = ', valnode, ';')
    end
    if varattr:must_define_at_runtime() then
      local asgnvalname, asgnvaltype = valnode, valtype
      if lastcallindex then
        asgnvalname = string.format('%s.r%d', multiretvalname, lastcallindex)
      elseif #valnodes > 1 then -- multiple assignments, assign to a temporary first
        asgnvalname, asgnvaltype = upfuncscope:generate_name('_asgntmp'), valtype
        emitter:add_indent(vartype, ' ', asgnvalname, ' = ')
        emitter:add_converted_val(vartype, valnode, valtype)
        emitter:add_ln(';')
      end
      defemitter:add_indent(varnode, ' = ')
      defemitter:add_converted_val(vartype, asgnvalname, asgnvaltype)
      defemitter:add_ln(';')
    elseif not vartype.is_comptime and valnode and not valnode.attr.comptime then -- could be a call
      emitter:add_indent_ln('(void)', valnode, ';')
    end
  end
  emitter:add(defemitter)
end

-- Emits function definition statement.
function visitors.FuncDef(context, node, emitter)
  local attr = node.attr
  local type = attr.type
  if type.is_polyfunction then -- is a polymorphic function?
    local polyevals = type.evals
    for i=1,#polyevals do -- emit all evaluations
      local polyeval = polyevals[i]
      emitter:add(polyeval.node)
    end
    return -- nothing more to do
  end
  if not context.pragmas.nodce and not attr:is_used(true) then
    return -- didn't pass dead code elimination, omit it
  end
  if attr.cinclude then -- requires a including a C file?
    context:ensure_include(attr.cinclude)
  end
  if attr.cimport and cdefs.builtins_headers[attr.codename] then -- importing a builtin?
    context:ensure_builtin(attr.codename) -- ensure the builtin is declared and defined
    return -- nothing more to do
  end
  local mustdecl, mustdefn = not attr.nodecl, not attr.cimport
  if not (mustdecl or mustdefn) then -- do we need to declare or define?
    return -- nothing to do
  end
  -- lets declare or define the function
  local varscope, varnode, argnodes, blocknode = node[1], node[2], node[3], node[6]
  local funcname = varnode
  -- handle function variable assignment
  if not varscope then
    local vartag = varnode.tag
    if vartag == 'Id' then
      funcname = context.rootscope:generate_name(context:declname(varnode.attr))
      emitter:add_indent_ln(varnode, ' = ', funcname, ';')
    elseif vartag == 'ColonIndex' or vartag == 'DotIndex' then
      local fieldname, objtype = varnode[1], varnode[2].attr.type
      if objtype.is_record then
        funcname = context.rootscope:generate_name(objtype.codename..'_funcdef_'..fieldname)
        emitter:add_indent_ln(varnode, ' = ', funcname, ';')
      else
        assert(objtype.is_type)
      end
    end
  end
  -- push function state
  local funcscope = context:push_forked_scope(node)
  context:push_forked_state{funcscope = funcscope}
  -- add function return type and name
  context:push_forked_state{infuncdecl = true}
  local rettypename = context:funcrettypename(type)
  local decemitter, defemitter
  if mustdecl then
    decemitter = CEmitter(context)
    decemitter:add_indent()
    decemitter:add_qualified_declaration(attr, rettypename, funcname)
  end
  if mustdefn then
    defemitter = CEmitter(context)
    defemitter:add_indent(rettypename, ' ', funcname)
  end
  context:pop_state()
  -- add function arguments
  local argsemitter = CEmitter(context)
  argsemitter:add('(')
  if varnode.tag == 'ColonIndex' then -- need to inject first argument `self`
    local selftype = type.argtypes[1]
    argsemitter:add(selftype, ' self')
    if #argnodes > 0 then -- extra arguments?
      argsemitter:add(', ')
    end
  end
  argsemitter:add(argnodes, ')')
  -- add function declaration
  if mustdecl then
    decemitter:add_ln(argsemitter, ';')
    context:add_declaration(decemitter:generate(), attr.codename)
  end
  -- add function definition
  if mustdefn then
    defemitter:add_ln(argsemitter, ' {')
    local implemitter = CEmitter(context)
    implemitter:add(blocknode)
    implemitter:add_indent_ln('}')
    if attr.entrypoint and not context.hookmain then -- this function is the main hook
      context.emitentrypoint = function(mainemitter)
        defemitter:add(mainemitter) -- emit top scope statements
        defemitter:add(implemitter) -- emit this function statements
        context:add_definition(defemitter:generate())
      end
    else
      defemitter:add(implemitter)
      context:add_definition(defemitter:generate())
    end
  end
  -- restore state
  context:pop_state()
  context:pop_scope()
end

-- Emits anonymous functions.
function visitors.Function(context, node, emitter)
  local argnodes, blocknode = node[1], node[4]
  local attr = node.attr
  local argsemitter, decemitter, defemitter = CEmitter(context), CEmitter(context), CEmitter(context)
  -- add function qualifiers and name
  local declname = context:declname(attr)
  local rettypename = context:funcrettypename(attr.type)
  decemitter:add_qualified_declaration(attr, rettypename, declname)
  defemitter:add(rettypename, ' ', declname)
  emitter:add(declname)
  local funcscope = context:push_forked_scope(node)
  context:push_forked_state{funcscope = funcscope}
  -- add function arguments
  argsemitter:add('(', argnodes, ')')
  decemitter:add_ln(argsemitter, ';')
  defemitter:add_ln(argsemitter, ' {')
  -- add function block
  defemitter:add(blocknode)
  defemitter:add_ln('}')
  context:pop_state()
  context:pop_scope()
  -- add function declaration and definition
  context:add_declaration(decemitter:generate())
  context:add_definition(defemitter:generate())
end

-- Emits operation on one expression.
function visitors.UnaryOp(context, node, emitter)
  local attr = node.attr
  if attr.type.is_any then
    node:raisef("compiler deduced the type 'any' here, but it's not supported yet in the C backend")
  end
  if attr.comptime then -- compile time constant
    emitter:add_literal(attr)
    return
  end
  local opname, argnode = node[1], node[2]
  local surround = not cdefs.surrounded_node_tags[context:get_visiting_node(1).tag]
  if surround then emitter:add_text('(') end
  local builtin = cbuiltins.operators[opname]
  builtin(context, node, emitter, argnode.attr, argnode)
  if surround then emitter:add_text(')') end
end

-- Emits operation between two expressions.
function visitors.BinaryOp(context, node, emitter)
  local attr = node.attr
  local type = attr.type
  if type.is_any then
    node:raisef("compiler deduced the type 'any' here, but it's not supported yet in the C backend")
  end
  if attr.comptime then -- compile time constant
    emitter:add_literal(attr)
    return
  end
  local lnode, opname, rnode = node[1], node[2], node[3]
  local surround = not cdefs.surrounded_node_tags[context:get_visiting_node(1).tag]
  if surround then emitter:add_text('(') end
  if attr.dynamic_conditional then
    if attr.ternaryor then -- lua style "ternary" operator
      local anode, bnode, cnode = lnode[1], lnode[3], rnode
      if anode.attr.type.is_boolean and not bnode.attr.type.is_falseable then -- use C ternary operator
        emitter:add_val2boolean(anode)
        emitter:add(' ? ')
        emitter:add_converted_val(type, bnode)
        emitter:add(' : ')
        emitter:add_converted_val(type, cnode)
      else
        emitter:add_ln('({') emitter:inc_indent()
        emitter:add_indent_ln(type, ' t_;')
        emitter:add_indent(primtypes.boolean, ' cond_ = ')
        emitter:add_val2boolean(anode)
        emitter:add_ln(';')
        emitter:add_indent_ln('if(cond_) {') emitter:inc_indent()
        emitter:add_indent('t_ = ')
        emitter:add_converted_val(type, bnode)
        emitter:add_ln(';')
        emitter:add_indent('cond_ = ')
        emitter:add_val2boolean('t_', type)
        emitter:add_ln(';')
        emitter:dec_indent() emitter:add_indent_ln('}')
        emitter:add_indent_ln('if(!cond_) {') emitter:inc_indent()
        emitter:add_indent('t_ = ')
        emitter:add_converted_val(type, cnode)
        emitter:add_ln(';')
        emitter:dec_indent() emitter:add_indent_ln('}')
        emitter:add_indent_ln('t_;')
        emitter:dec_indent() emitter:add_indent('})')
      end
    else
      emitter:add_ln('({') emitter:inc_indent()
      emitter:add_indent(type, ' t1_ = ')
      emitter:add_converted_val(type, lnode)
      --TODO: be smart and remove this unused code
      emitter:add_ln(';')
      emitter:add_indent(type, ' t2_ = ')
      emitter:add_zeroed_type_literal(type)
      emitter:add_ln(';')
      if opname == 'and' then
        assert(not attr.ternaryand)
        emitter:add_indent(primtypes.boolean, ' cond_ = ')
        emitter:add_val2boolean('t1_', type)
        emitter:add_ln(';')
        emitter:add_indent_ln('if(cond_) {') emitter:inc_indent()
        emitter:add_indent('t2_ = ')
        emitter:add_converted_val(type, rnode)
        emitter:add_ln(';')
        emitter:add_indent('cond_ = ')
        emitter:add_val2boolean('t2_', type)
        emitter:add_ln(';')
        emitter:dec_indent() emitter:add_indent_ln('}')
        emitter:add_indent('cond_ ? t2_ : ')
        emitter:add_zeroed_type_literal(type, true)
        emitter:add_ln(';')
      elseif opname == 'or' then
        emitter:add_indent(primtypes.boolean, ' cond_ = ')
        emitter:add_val2boolean('t1_', type)
        emitter:add_ln(';')
        emitter:add_indent_ln('if(!cond_) {') emitter:inc_indent()
        emitter:add_indent('t2_ = ')
        emitter:add_converted_val(type, rnode)
        emitter:add_ln(';')
        emitter:dec_indent() emitter:add_indent_ln('}')
        emitter:add_indent_ln('cond_ ? t1_ : t2_;')
      end
      emitter:dec_indent() emitter:add_indent('})')
    end
  else
    local lname, rname = lnode, rnode
    local lattr, rattr = lnode.attr, rnode.attr
    local sequential = (lattr.sideeffect and rattr.sideeffect) and
                        not (opname == 'or' or opname == 'and')
    if sequential then
      -- need to evaluate args in sequence when a expression has side effects
      emitter:add_ln('({') emitter:inc_indent()
      emitter:add_indent_ln(lattr.type, ' t1_ = ', lnode, ';')
      emitter:add_indent_ln(rattr.type, ' t2_ = ', rnode, ';')
      emitter:add_indent()
      lname, rname = 't1_', 't2_'
    end
    local builtin = cbuiltins.operators[opname]
    builtin(context, node, emitter, lattr, rattr, lname, rname)
    if sequential then
      emitter:add_ln(';')
      emitter:dec_indent() emitter:add_indent('})')
    end
  end
  if surround then emitter:add_text(')') end
end

-- Emits defers before exiting scope `scope`.
function cgenerator.emit_close_scope(context, emitter, scope, isupscope)
  if scope.closed then return end -- already closed
  if not isupscope then -- mark as closed
    scope.closed = true
  end
  local deferblocks = scope.deferblocks
  if deferblocks then
    for i=#deferblocks,1,-1 do
      local deferblock = deferblocks[i]
      emitter:add_indent_ln('{ /* defer */')
      context:push_scope(deferblock.scope.parent)
      emitter:add(deferblock)
      context:pop_scope()
      emitter:add_indent_ln('}')
    end
  end
end

-- Emits all defers when exiting a nested scope.
function cgenerator.emit_close_upscopes(context, emitter, scope, topscope)
  cgenerator.emit_close_scope(context, emitter, scope)
  repeat
    scope = scope.parent
    cgenerator.emit_close_scope(context, emitter, scope, true)
  until scope == topscope
  cgenerator.emit_close_scope(context, emitter, scope, true)
end

-- Emits C pragmas to disable harmless C warnings that the generated code may trigger.
function cgenerator.emit_warning_pragmas(context)
  if context.pragmas.nocwarnpragas then return end
  local emitter = CEmitter(context)
  emitter:add_ln('#ifdef __GNUC__')
  emitter:add_ln('  #ifndef __cplusplus')
  -- disallow implicit declarations
  emitter:add_ln('    #pragma GCC diagnostic error   "-Wimplicit-function-declaration"')
  emitter:add_ln('    #pragma GCC diagnostic error   "-Wimplicit-int"')
  -- importing C functions can cause this warn
  emitter:add_ln('    #pragma GCC diagnostic ignored "-Wincompatible-pointer-types"')
  emitter:add_ln('  #else')
  emitter:add_ln('    #pragma GCC diagnostic ignored "-Wwrite-strings"')
  emitter:add_ln('  #endif')
  -- C zero initialization for anything
  emitter:add_ln('  #pragma GCC diagnostic ignored "-Wmissing-braces"')
  emitter:add_ln('  #pragma GCC diagnostic ignored "-Wmissing-field-initializers"')
  -- may generate always true/false expressions for integers
  emitter:add_ln('  #pragma GCC diagnostic ignored "-Wtype-limits"')
  -- may generate unused variables, parameters, functions
  emitter:add_ln('  #pragma GCC diagnostic ignored "-Wunused-parameter"')
  emitter:add_ln('  #ifdef __clang__')
  emitter:add_ln('    #pragma GCC diagnostic ignored "-Wunused"')
  emitter:add_ln('  #else')
  emitter:add_ln('    #pragma GCC diagnostic ignored "-Wunused-variable"')
  emitter:add_ln('    #pragma GCC diagnostic ignored "-Wunused-function"')
  emitter:add_ln('    #pragma GCC diagnostic ignored "-Wunused-but-set-variable"')
  emitter:add_ln('    #ifndef __cplusplus')
  -- for ignoring const* on pointers
  emitter:add_ln('      #pragma GCC diagnostic ignored "-Wdiscarded-qualifiers"')
  emitter:add_ln('    #endif')
  emitter:add_ln('  #endif')
  emitter:add_ln('#endif')
  if ccompiler.get_cc_info().is_emscripten then --luacov:disable
    emitter:add_ln('#ifdef __EMSCRIPTEN__')
    -- will be fixed in future upstream release
    emitter:add_ln('  #pragma GCC diagnostic ignored "-Wformat"')
    emitter:add_ln('#endif')
  end --luacov:enable
  context:add_directive(emitter:generate(), 'warnings_pragmas') -- defines all the above pragmas
end

-- Emits C features checks, to make sure the Nelua compiler and the C compiler agrees on features.
function cgenerator.emit_feature_checks(context)
  if context.pragmas.nocstaticassert then return end
  local emitter = CEmitter(context)
  context:ensure_builtin('nelua_static_assert')
  -- it's important that pointer size is on agreement, otherwise primitives sizes will wrong
  emitter:add_ln('nelua_static_assert(sizeof(void*) == ',primtypes.pointer.size,
              ', "Nelua and C disagree on pointer size");')
  context:add_directive(emitter:generate(), 'features_checks')
end

-- Emits `nelua_main`.
function cgenerator.emit_nelua_main(context, ast, emitter)
  assert(ast.tag == 'Block') -- ast is expected to be a Block
  local rollbackpos = emitter:get_pos()
  emitter:add_text("int nelua_main(int nelua_argc, char** nelua_argv) {\n") -- begin block
  local startpos = emitter:get_pos() -- save current emitter position
  context:traverse_node(ast, emitter) -- emit ast statements
  if context.hookmain or emitter:get_pos() ~= startpos then -- main is used or statements were added
    if #ast == 0 or ast[#ast].tag ~= 'Return' then -- last statement is not a return
      emitter:add_indent_ln("  return 0;") -- ensures that an int is always returned
    end
    emitter:add_ln("}") -- end bock
    context:add_declaration('static int nelua_main(int nelua_argc, char** nelua_argv);\n', 'nelua_main')
  else -- empty main, we can skip `nelua_main` usage
    emitter:rollback(rollbackpos) -- revert text added for begin block
  end
end

-- Emits C `main`.
function cgenerator.emit_entrypoint(context, ast)
  local emitter = CEmitter(context)
  context:push_forked_state{funcscope = context.rootscope}
  -- if custom entry point is set while `nelua_main` is not hooked,
  -- then we can skip `nelua_main` and `main` declarations
  if context.entrypoint and not context.hookmain then
    context:traverse_node(ast, emitter) -- emit ast statements
    context.emitentrypoint(emitter) -- inject ast statements into the custom entry point
  else -- need to define `nelua_main`, it will be called from the entry point
    cgenerator.emit_nelua_main(context, ast, emitter)
    -- if no custom entry point is set, then use `main` as the default entry point
    if not context.entrypoint and not context.pragmas.noentrypoint then
      emitter:add_indent_ln('int main(int argc, char** argv) {') emitter:inc_indent() -- begin block
      if context:is_declared('nelua_main') then -- `nelua_main` is declared
        emitter:add_indent_ln('return nelua_main(argc, argv);') -- return `nelua_main` results
      else -- `nelua_main` is not be declared, probably it was empty
        emitter:add_indent_ln('return 0;') -- ensures that an int is always returned
      end
      emitter:dec_indent() emitter:add_indent_ln('}') -- end block
    end
    context:add_definition(emitter:generate()) -- defines `nelua_main` and/or `main`
  end
  context:pop_state()
end

-- Generates C code for the analyzed context `context`.
function cgenerator.generate(context)
  context:promote(CContext, visitors, typevisitors) -- promote AnalyzerContext to CContext
  cgenerator.emit_warning_pragmas(context) -- silent some C warnings
  cgenerator.emit_feature_checks(context) -- check C primitive sizes
  cgenerator.emit_entrypoint(context, context.ast) -- emit `main` and `nelua_main`
  return context:concat_chunks(cdefs.template) -- concatenate emitted chunks
end

return cgenerator
