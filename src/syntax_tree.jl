#-------------------------------------------------------------------------------
# Syntax tree types

#-------------------------------------------------------------------------------

const RawFlags = UInt32
const EMPTY_FLAGS = RawFlags(0)
const TRIVIA_FLAG = RawFlags(1<<0)
# Some of the following flags are head-specific and could probably be allowed
# to cover the same bits...
const INFIX_FLAG  = RawFlags(1<<1)
# Record whether syntactic operators were dotted
const DOTOP_FLAG = RawFlags(1<<2)
# try-finally-catch
const TRY_CATCH_AFTER_FINALLY_FLAG = RawFlags(1<<3)
# Flags holding the dimension of an nrow or other UInt8 not held in the source
const NUMERIC_FLAGS = RawFlags(RawFlags(0xff)<<8)
# Todo ERROR_FLAG = 0x80000000 ?

struct SyntaxHead
    kind::Kind
    flags::RawFlags
end

kind(head::SyntaxHead) = head.kind
flags(head::SyntaxHead) = head.flags
hasflags(head::SyntaxHead, flags_) = (flags(head) & flags_) == flags_

istrivia(head::SyntaxHead) = hasflags(head, TRIVIA_FLAG)
isinfix(head::SyntaxHead)  = hasflags(head, INFIX_FLAG)

iserror(head::SyntaxHead)  = kind(head) == K"error"

is_dotted(head::SyntaxHead) = hasflags(head, DOTOP_FLAG)

function Base.summary(head::SyntaxHead)
    _kind_str(kind(head))
end

function untokenize(head::SyntaxHead)
    str = untokenize(kind(head))
    if is_dotted(head)
        str = "."*str
    end
    str
end

function raw_flags(; trivia::Bool=false, infix::Bool=false)
    flags = RawFlags(0)
    trivia && (flags |= TRIVIA_FLAG)
    infix  && (flags |= INFIX_FLAG)
    return flags::RawFlags
end

function numeric_flags(n::Integer)
    RawFlags(UInt8(n)) << 8
end

function extract_numeric_flags(f::RawFlags)
    Int((f >> 8) % UInt8)
end

kind(node::GreenNode{SyntaxHead})  = head(node).kind
flags(node::GreenNode{SyntaxHead}) = head(node).flags

isinfix(node) = isinfix(head(node))

# Value of an error node with no children
struct ErrorVal
end

#-------------------------------------------------------------------------------
# AST interface, built on top of raw tree

"""
Design options:
* rust-analyzer treats their version of an untyped syntax node as a cursor into
  the green tree. They deallocate aggressively.
"""
mutable struct SyntaxNode
    source::SourceFile
    raw::GreenNode{SyntaxHead}
    position::Int
    parent::Union{Nothing,SyntaxNode}
    head::Symbol
    val::Any
end

Base.show(io::IO, ::ErrorVal) = printstyled(io, "✘", color=:light_red)

function SyntaxNode(source::SourceFile, raw::GreenNode{SyntaxHead}, position::Integer=1)
    if !haschildren(raw) && !is_syntax_kind(raw)
        # Leaf node
        k = kind(raw)
        val_range = position:position + span(raw) - 1
        val_str = source[val_range]
        # Here we parse the values eagerly rather than representing them as
        # strings. Maybe this is good. Maybe not.
        val = if k == K"Integer"
            # FIXME: this doesn't work with _'s as in 1_000_000
            Base.parse(Int, val_str)
        elseif k == K"Float"
            # FIXME: Other float types!
            Base.parse(Float64, val_str)
        elseif k == K"true"
            true
        elseif k == K"false"
            false
        elseif k == K"Char"
            # FIXME: Escape sequences...
            unescape_string(val_str)[2]
        elseif k == K"Identifier"
            Symbol(val_str)
        elseif k == K"VarIdentifier"
            Symbol(val_str[5:end-1])
        elseif iskeyword(k)
            # This only happens nodes nested inside errors
            Symbol(val_str)
        elseif k in (K"String", K"Cmd")
            unescape_string(source[position+1:position+span(raw)-2])
        elseif k in (K"TripleString", K"TripleCmd")
            unescape_string(source[position+3:position+span(raw)-4])
        elseif k == K"UnquotedString"
            String(val_str)
        elseif isoperator(k)
            isempty(val_range)  ?
                Symbol(untokenize(k)) : # synthetic invisible tokens
                Symbol(val_str)
        elseif k == K"NothingLiteral"
            nothing
        elseif k == K"error"
            ErrorVal()
        elseif k == K"@."
            :var"@__dot__"
        elseif k == K"MacroName"
            Symbol("@$val_str")
        elseif k == K"VarMacroName"
            Symbol("@$(val_str[5:end-1])")
        elseif k == K"StringMacroName"
            Symbol("@$(val_str)_str")
        elseif k == K"CmdMacroName"
            Symbol("@$(val_str)_cmd")
        elseif k == K"core_@doc"
            GlobalRef(Core, :var"@doc")
        elseif k == K"core_@cmd"
            GlobalRef(Core, :var"@cmd")
        elseif is_syntax_kind(raw)
            nothing
        else
            @error "Leaf node of kind $k unknown to SyntaxNode"
            val = nothing
        end
        return SyntaxNode(source, raw, position, nothing, :leaf, val)
    else
        str = untokenize(head(raw))
        headsym = !isnothing(str) ? Symbol(str) :
            error("Can't untokenize head of kind $(kind(raw))")
        cs = SyntaxNode[]
        pos = position
        for (i,rawchild) in enumerate(children(raw))
            # FIXME: Allowing trivia iserror nodes here corrupts the tree layout.
            if !istrivia(rawchild) || iserror(rawchild)
                push!(cs, SyntaxNode(source, rawchild, pos))
            end
            pos += rawchild.span
        end
        # Julia's standard `Expr` ASTs have children stored in a canonical
        # order which is not always source order.
        #
        # Swizzle the children here as necessary to get the canonical order.
        if isinfix(raw)
            cs[2], cs[1] = cs[1], cs[2]
        end
        node = SyntaxNode(source, raw, position, nothing, headsym, cs)
        for c in cs
            c.parent = node
        end
        return node
    end
end

iserror(node::SyntaxNode) = iserror(node.raw)
istrivia(node::SyntaxNode) = istrivia(node.raw)
hasflags(node::SyntaxNode, f) = hasflags(head(node.raw), f)

head(node::SyntaxNode) = node.head
kind(node::SyntaxNode)  = kind(node.raw)
flags(node::SyntaxNode) = flags(node.raw)

haschildren(node::SyntaxNode) = node.head !== :leaf
children(node::SyntaxNode) = haschildren(node) ? node.val::Vector{SyntaxNode} : ()

span(node::SyntaxNode) = span(node.raw)

function interpolate_literal(node::SyntaxNode, val)
    @assert node.head == :$
    SyntaxNode(node.source, node.raw, node.position, node.parent, :leaf, val)
end

function _show_syntax_node(io, current_filename, node, indent)
    fname = node.source.filename
    line, col = source_location(node.source, node.position)
    posstr = "$(lpad(line, 4)):$(rpad(col,3))│$(lpad(node.position,6)):$(rpad(node.position+span(node)-1,6))│"
    nodestr = !haschildren(node) ?
              repr(node.val) :
              "[$(_kind_str(kind(node.raw)))]"
    treestr = string(indent, nodestr)
    # Add filename if it's changed from the previous node
    if fname != current_filename[]
        #println(io, "# ", fname)
        treestr = string(rpad(treestr, 40), "│$fname")
        current_filename[] = fname
    end
    println(io, posstr, treestr)
    if haschildren(node)
        new_indent = indent*"  "
        for n in children(node)
            _show_syntax_node(io, current_filename, n, new_indent)
        end
    end
end

function _show_syntax_node_sexpr(io, node)
    if !haschildren(node)
        if iserror(node)
            print(io, "(error)")
        else
            print(io, repr(node.val))
        end
    else
        print(io, "(", untokenize(head(node.raw)))
        first = true
        for n in children(node)
            print(io, ' ')
            _show_syntax_node_sexpr(io, n)
            first = false
        end
        print(io, ')')
    end
end

function Base.show(io::IO, ::MIME"text/plain", node::SyntaxNode)
    println(io, "line:col│ byte_range  │ tree                                   │ file_name")
    _show_syntax_node(io, Ref{Union{Nothing,String}}(nothing), node, "")
end

function Base.show(io::IO, ::MIME"text/x.sexpression", node::SyntaxNode)
    _show_syntax_node_sexpr(io, node)
end

function Base.show(io::IO, node::SyntaxNode)
    _show_syntax_node_sexpr(io, node)
end

function Base.push!(node::SyntaxNode, child::SyntaxNode)
    if !haschildren(node)
        error("Cannot add children")
    end
    args = node.val::Vector{SyntaxNode}
    push!(args, child)
end

#-------------------------------------------------------------------------------
# Tree utilities
"""
    child(node, i1, i2, ...)

Get child at a tree path. If indexing accessed children, it would be
`node[i1][i2][...]`
"""
function child(node, path::Integer...)
    n = node
    for index in path
        n = children(n)[index]
    end
    return n
end

function setchild!(node::SyntaxNode, path, x)
    n1 = child(node, path[1:end-1]...)
    n1.val[path[end]] = x
end

# We can overload multidimensional Base.getindex / Base.setindex! for node
# types.
#
# The justification for this is to view a tree as a multidimensional ragged
# array, where descending depthwise into the tree corresponds to dimensions of
# the array.
#
# However... this analogy is only good for complete trees at a given depth (=
# dimension). But the syntax is oh-so-handy!
function Base.getindex(node::Union{SyntaxNode,GreenNode}, path::Int...)
    child(node, path...)
end
function Base.setindex!(node::SyntaxNode, x::SyntaxNode, path::Int...)
    setchild!(node, path, x)
end

"""
Get absolute position and span of the child of `node` at the given tree `path`.
"""
function child_position_span(node::GreenNode, path::Int...)
    n = node
    p = 1
    for index in path
        cs = children(n)
        for i = 1:index-1
            p += span(cs[i])
        end
        n = cs[index]
    end
    return n, p, n.span
end

function child_position_span(node::SyntaxNode, path::Int...)
    n = child(node, path...)
    n, n.position, span(n)
end

"""
Print the code, highlighting the part covered by `node` at tree `path`.
"""
function highlight(code::String, node, path::Int...; color=(40,40,70))
    node, p, span = child_position_span(node, path...)
    q = p + span
    print(stdout, code[1:p-1])
    _printstyled(stdout, code[p:q-1]; color)
    print(stdout, code[q:end])
end


#-------------------------------------------------------------------------------
# Conversion to Base.Expr

function _to_expr(node::SyntaxNode)
    if haschildren(node)
        args = Vector{Any}(undef, length(children(node)))
        args = map!(_to_expr, args, children(node))
        # Convert elements
        if head(node) == :macrocall
            line_node = source_location(LineNumberNode, node.source, node.position)
            insert!(args, 2, line_node)
        elseif head(node) in (:call, :ref)
            # Move parameters block to args[2]
            if length(args) > 1 && Meta.isexpr(args[end], :parameters)
                insert!(args, 2, args[end])
                pop!(args)
            end
        elseif head(node) in (:tuple, :parameters, :vect)
            # Move parameters blocks to args[1]
            if length(args) > 1 && Meta.isexpr(args[end], :parameters)
                pushfirst!(args, args[end])
                pop!(args)
            end
        elseif head(node) == :try
            # Try children in source order:
            #   try_block catch_var catch_block else_block finally_block
            # Expr ordering:
            #   try_block catch_var catch_block [finally_block] [else_block]
            catch_ = nothing
            if hasflags(node, TRY_CATCH_AFTER_FINALLY_FLAG)
                catch_ = pop!(args)
                catch_var = pop!(args)
            end
            finally_ = pop!(args)
            else_ = pop!(args)
            if hasflags(node, TRY_CATCH_AFTER_FINALLY_FLAG)
                pop!(args)
                pop!(args)
                push!(args, catch_var)
                push!(args, catch_)
            end
            # At this point args is
            # [try_block catch_var catch_block]
            if finally_ !== false
                push!(args, finally_)
            end
            if else_ !== false
                push!(args, else_)
            end
        elseif head(node) == :filter
            pushfirst!(args, last(args))
            pop!(args)
        elseif head(node) == :flatten
            # The order of nodes inside the generators in Julia's flatten AST
            # is noncontiguous in the source text, so need to reconstruct
            # Julia's AST here from our alternative `flatten` expression.
            gen = Expr(:generator, args[1], args[end])
            for i in length(args)-1:-1:2
                gen = Expr(:generator, gen, args[i])
            end
            args = [gen]
        elseif head(node) in (:nrow, :ncat)
            # For lack of a better place, the dimension argument to nrow/ncat
            # is stored in the flags
            pushfirst!(args, extract_numeric_flags(flags(node)))
        end
        if head(node) == :inert || (head(node) == :quote &&
                                    length(args) == 1 && !(only(args) isa Expr))
            QuoteNode(only(args))
        else
            Expr(head(node), args...)
        end
    else
        node.val
    end
end

Base.Expr(node::SyntaxNode) = _to_expr(node)


#-------------------------------------------------------------------------------

"""
    parse_all(Expr, code::AbstractString; filename="none")

Parse the given code and convert to a standard Expr
"""
function parse_all(::Type{Expr}, code::AbstractString; filename="none")
    source_file = SourceFile(code, filename=filename)

    stream = ParseStream(code)
    parse_all(stream)

    if !isempty(stream.diagnostics)
        buf = IOBuffer()
        show_diagnostics(IOContext(buf, stdout), stream, code)
        @error Text(String(take!(buf)))
    end

    green_tree = build_tree(GreenNode, stream, wrap_toplevel_as_kind=K"toplevel")

    tree = SyntaxNode(source_file, green_tree)

    # convert to Julia expr
    ex = Expr(tree)

    flisp_ex = flisp_parse_all(code)
    if ex != flisp_ex && !(!isempty(flisp_ex.args) &&
                           Meta.isexpr(flisp_ex.args[end], :error))
        @error "Mismatch with Meta.parse()" ex flisp_ex
    end
    ex
end

function flisp_parse_all(code)
    flisp_ex = Base.remove_linenums!(Meta.parseall(code))
    filter!(x->!(x isa LineNumberNode), flisp_ex.args)
    flisp_ex
end
