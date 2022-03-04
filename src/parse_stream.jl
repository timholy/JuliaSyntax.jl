#-------------------------------------------------------------------------------
# Flags hold auxilary information about tokens/nonterminals which the Kind
# doesn't capture in a nice way.
#
# TODO: Use `primitive type SyntaxFlags 16 end` rather than an alias?
const RawFlags = UInt16
const EMPTY_FLAGS = RawFlags(0)
const TRIVIA_FLAG = RawFlags(1<<0)
# Some of the following flags are head-specific and could probably be allowed
# to cover the same bits...
const INFIX_FLAG  = RawFlags(1<<1)
# Record whether syntactic operators were dotted
const DOTOP_FLAG = RawFlags(1<<2)
# Set when kind == K"String" was triple-delimited as with """ or ```
const TRIPLE_STRING_FLAG = RawFlags(1<<3)
# Set when a string or identifier needs "raw string" unescaping
const RAW_STRING_FLAG = RawFlags(1<<4)
# try-finally-catch
const TRY_CATCH_AFTER_FINALLY_FLAG = RawFlags(1<<5)
# Flags holding the dimension of an nrow or other UInt8 not held in the source
const NUMERIC_FLAGS = RawFlags(RawFlags(0xff)<<8)
# Todo ERROR_FLAG = 0x8000 ?

## Flags for tokens (may overlap with the flags allocated for syntax above)
const SUFFIXED_FLAG        = RawFlags(1<<6)
const PRECEDING_WHITESPACE_FLAG = RawFlags(1<<7)

function set_numeric_flags(n::Integer)
    f = RawFlags((n << 8) & NUMERIC_FLAGS)
    if numeric_flags(f) != n
        error("Numeric flags unable to hold large integer $n")
    end
    f
end

function numeric_flags(f::RawFlags)
    Int((f >> 8) % UInt8)
end

function remove_flags(n::RawFlags, fs...)
    RawFlags(n & ~(RawFlags((|)(fs...))))
end

# Return true if any of `test_flags` are set
has_flags(flags::RawFlags, test_flags) = (flags & test_flags) != 0

#-------------------------------------------------------------------------------
struct SyntaxHead
    kind::Kind
    flags::RawFlags
end

kind(head::SyntaxHead) = head.kind
flags(head::SyntaxHead) = head.flags

function Base.summary(head::SyntaxHead)
    untokenize(head, unique=false, include_flag_suff=false)
end

function untokenize(head::SyntaxHead; unique=true, include_flag_suff=true)
    str = untokenize(kind(head); unique=unique)
    if is_dotted(head)
        str = "."*str
    end
    f = flags(head)
    # Ignore some flags:
    # - DOTOP_FLAG is represented with . prefix
    # - PRECEDING_WHITESPACE_FLAG relates to the environment of this token
    f &= ~(DOTOP_FLAG | PRECEDING_WHITESPACE_FLAG)
    suffix_flags = remove_flags(flags(head), DOTOP_FLAG, PRECEDING_WHITESPACE_FLAG)
    if include_flag_suff && suffix_flags != EMPTY_FLAGS
        str = str*"-"
        is_trivia(head)  && (str = str*"t")
        is_infix(head)   && (str = str*"i")
        has_flags(head, TRIPLE_STRING_FLAG) && (str = str*"s")
        has_flags(head, RAW_STRING_FLAG) && (str = str*"r")
        has_flags(head, TRY_CATCH_AFTER_FINALLY_FLAG) && (str = str*"f")
        is_suffixed(head) && (str = str*"S")
        n = numeric_flags(head)
        n != 0 && (str = str*string(n))
    end
    str
end

#-------------------------------------------------------------------------------
# Generic interface for types `T` which have kind and flags:
# 1. Define kind(::T) and flags(::T) directly
# 2. Define head(::T) to return a type like `SyntaxKind` for which `kind` and
#    `flags` are defined
kind(x)  = kind(head(x))
flags(x) = flags(head(x))

# Predicates based on kind() / flags()
is_error(x)  = kind(x) == K"error"
has_flags(x, test_flags) = has_flags(flags(x), test_flags)
is_trivia(x) = has_flags(x, TRIVIA_FLAG)
is_infix(x)  = has_flags(x, INFIX_FLAG)
is_dotted(x) = has_flags(x, DOTOP_FLAG)
is_suffixed(x) = has_flags(x, SUFFIXED_FLAG)
preceding_whitespace(x) = has_flags(x, PRECEDING_WHITESPACE_FLAG)
numeric_flags(x) = numeric_flags(flags(x))

#-------------------------------------------------------------------------------
"""
`SyntaxToken` is a token covering a contiguous byte range in the input text.
Information about preceding whitespace is added for use by the parser.
"""
struct SyntaxToken
    head::SyntaxHead
    first_byte::UInt32
    last_byte::UInt32 # TODO: Remove this?
end

function Base.show(io::IO, tok::SyntaxToken)
    print(io, untokenize(tok.head, unique=false), " @", first_byte(tok))
end

head(tok::SyntaxToken) = tok.head
first_byte(tok::SyntaxToken) = tok.first_byte
last_byte(tok::SyntaxToken) = tok.last_byte
span(tok::SyntaxToken) = last_byte(tok) - first_byte(tok) + 1

is_decorated(tok::SyntaxToken) = is_dotted(tok) || is_suffixed(tok)


#-------------------------------------------------------------------------------

"""
Range in the source text which will become a node in the tree. Can be either a
token (leaf node of the tree) or an interior node, depending on how the
start_mark compares to previous nodes.
"""
struct TaggedRange
    head::SyntaxHead # Kind,flags
    orig_kind::Kind  # Kind of the original token for leaf tokens, or K"None"
    first_byte::UInt32  # First byte in the input text
    last_byte::UInt32   # Last byte in the input text
    start_mark::UInt32  # Index of first emitted range which this range covers
    # TODO: Remove the three fields above & replace with:
    # is_leaf::Bool
    # # The following field is used for one of two things:
    # # - For leaf nodes it points to the last byte of the token in the input text
    # # - For non-leaf nodes it points to the index of the first child
    # last_byte_or_first_child::UInt32
end

head(range::TaggedRange)       = range.head
kind(range::TaggedRange)       = kind(range.head)
flags(range::TaggedRange)      = flags(range.head)
first_byte(range::TaggedRange) = Int(range.first_byte)
last_byte(range::TaggedRange)  = Int(range.last_byte)
span(range::TaggedRange)       = 1 + last_byte(range) - first_byte(range)

#-------------------------------------------------------------------------------
struct ParseStreamPosition
    input_byte::Int    # Index of next byte in input
    output_index::Int  # Index of last span in output
end

const NO_POSITION = ParseStreamPosition(0,0)

#-------------------------------------------------------------------------------
"""
ParseStream provides an IO interface for the parser. It
- Wraps the lexer with a lookahead buffer
- Removes insignificant whitespace and comment tokens, shifting them into the
  output implicitly (newlines may be significant depending on `skip_newlines`)
"""
mutable struct ParseStream
    # `textbuf` is a buffer of UTF-8 encoded text of the source code. This is a
    # natural representation as we desire random access and zero-copy parsing
    # of UTF-8 text from various containers, and unsafe_wrap(Vector{UInt8},
    # ...) allows us to use a Vector here.
    #
    # We want `ParseStream` to be concrete so that all `parse_*` functions only
    # need to be compiled once. Thus `textbuf` must not be parameterized here.
    textbuf::Vector{UInt8}
    # GC root for the object which owns the memory in `textbuf`. `nothing` if
    # the `textbuf` owner was unknown (eg, ptr,length was passed)
    text_root::Any
    # Lexer, transforming the input bytes into a token stream
    lexer::Tokenize.Lexers.Lexer{IOBuffer}
    # Lookahead buffer for already lexed tokens
    lookahead::Vector{SyntaxToken}
    # Pool of stream positions for use as working space in parsing
    position_pool::Vector{Vector{ParseStreamPosition}}
    # Parser output as an ordered sequence of ranges, parent nodes after children.
    ranges::Vector{TaggedRange}
    # Parsing diagnostics (errors/warnings etc)
    diagnostics::Vector{Diagnostic}
    # First byte of next token
    next_byte::Int
    # Counter for number of peek()s we've done without making progress via a bump()
    peek_count::Int
    # (major,minor) version of Julia we're parsing this code for.
    # May be different from VERSION!
    version::Tuple{Int,Int}

    function ParseStream(text_buf::Vector{UInt8}, text_root, next_byte::Integer,
                         version::VersionNumber)
        io = IOBuffer(text_buf)
        seek(io, next_byte-1)
        lexer = Tokenize.Lexers.Lexer(io)
        # To avoid keeping track of the exact Julia development version where new
        # features were added or comparing prerelease strings, we treat prereleases
        # or dev versons as the release version using only major and minor version
        # numbers. This means we're inexact for old dev versions but that seems
        # like an acceptable tradeoff.
        ver = (version.major, version.minor)
        new(text_buf, text_root, lexer,
            Vector{Vector{ParseStreamPosition}}(),
            Vector{SyntaxToken}(),
            Vector{TaggedRange}(),
            Vector{Diagnostic}(),
            next_byte,
            0,
            ver)
    end
end

function ParseStream(text::Vector{UInt8}, index::Integer=1; version=VERSION)
    ParseStream(text, text, index, version)
end

# Buffer with unknown owner. Not exactly recommended, but good for C interop
function ParseStream(ptr::Ptr{UInt8}, len::Integer, index::Integer=1; version=VERSION)
    ParseStream(unsafe_wrap(Vector{UInt8}, ptr, len), nothing, index, version)
end

# Buffers originating from strings
function ParseStream(text::String, index::Integer=1; version=VERSION)
    ParseStream(unsafe_wrap(Vector{UInt8}, text),
                text, index, version)
end
function ParseStream(text::SubString, index::Integer=1; version=VERSION)
    # See also IOBuffer(SubString("x"))
    ParseStream(unsafe_wrap(Vector{UInt8}, pointer(text), sizeof(text)),
                text, index, version)
end
function ParseStream(text::AbstractString, index::Integer=1; version=VERSION)
    ParseStream(String(text), index; version=version)
end

# IO-based cases
function ParseStream(io::IOBuffer; version=VERSION)
    ParseStream(io.data, io, position(io)+1, version)
end
function ParseStream(io::Base.GenericIOBuffer; version=VERSION)
    textbuf = unsafe_wrap(Vector{UInt8}, pointer(io.data), length(io.data))
    ParseStream(textbuf, io, position(io)+1, version)
end
function ParseStream(io::IOStream; version=VERSION)
    textbuf = Mmap.mmap(io)
    ParseStream(textbuf, io, position(io)+1, version)
end
function ParseStream(io::IO; version=VERSION)
    textbuf = read(io)
    ParseStream(textbuf, textbuf, 1, version)
end


function Base.show(io::IO, mime::MIME"text/plain", stream::ParseStream)
    println(io, "ParseStream at position $(stream.next_byte)")
end

function show_diagnostics(io::IO, stream::ParseStream, code)
    show_diagnostics(io, stream.diagnostics, code)
end

# We manage a pool of stream positions as parser working space
function acquire_positions(stream)
    if isempty(stream.position_pool)
        return Vector{ParseStreamPosition}()
    end
    pop!(stream.position_pool)
end

function release_positions(stream, positions)
    empty!(positions)
    push!(stream.position_pool, positions)
end

#-------------------------------------------------------------------------------
# Stream input interface - the peek_* family of functions

# Buffer several tokens ahead
function _buffer_lookahead_tokens(stream::ParseStream)
    had_whitespace = false
    token_count = 0
    while true
        raw = Tokenize.Lexers.next_token(stream.lexer)
        k = TzTokens.exactkind(raw)
        was_whitespace = k in (K"Whitespace", K"Comment", K"NewlineWs")
        had_whitespace |= was_whitespace
        f = EMPTY_FLAGS
        had_whitespace && (f |= PRECEDING_WHITESPACE_FLAG)
        raw.dotop      && (f |= DOTOP_FLAG)
        raw.suffix     && (f |= SUFFIXED_FLAG)
        push!(stream.lookahead, SyntaxToken(SyntaxHead(k, f), raw.startbyte + 1, raw.endbyte + 1))
        token_count += 1
        if k == K"EndMarker"
            break
        end
        if !was_whitespace
            # Buffer tokens in batches for lookahead. Generally we want a
            # moderate-size buffer to make sure we hit the fast path of peek(),
            # but not too large to avoid (a) polluting the processor cache and
            # (b) doing unnecessary work when not parsing the whole input.
            had_whitespace = false
            if token_count > 100
                break
            end
        end
    end
end

# Find the index of the next nontrivia token
@inline function _lookahead_index(stream::ParseStream, n::Integer, skip_newlines::Bool)
    # Much of the time we'll be peeking ahead a single token and have one or
    # zero whitespace tokens before the next token. The following code is an
    # unrolled optimized version for that fast path. Empirically it seems we
    # only hit the slow path about 5% of the time here.
    i = 1
    if n == 1 && i+1 <= length(stream.lookahead)
        if skip_newlines
            k = kind(stream.lookahead[i])
            if !(k == K"Whitespace" || k == K"Comment" || k == K"NewlineWs")
                return i
            end
            i += 1
            k = kind(stream.lookahead[i])
            if !(k == K"Whitespace" || k == K"Comment" || k == K"NewlineWs")
                return i
            end
        else
            k = kind(stream.lookahead[i])
            if !(k == K"Whitespace" || k == K"Comment")
                return i
            end
            i += 1
            k = kind(stream.lookahead[i])
            if !(k == K"Whitespace" || k == K"Comment")
                return i
            end
        end
    end
    # Fall through to the general case
    return __lookahead_index(stream, n, skip_newlines)
end

@noinline function __lookahead_index(stream, n, skip_newlines)
    i = 1
    while true
        if i > length(stream.lookahead)
            _buffer_lookahead_tokens(stream)
        end
        k = kind(stream.lookahead[i])
        is_skipped =  k ∈ (K"Whitespace", K"Comment") ||
                     (k == K"NewlineWs" && skip_newlines)
        if !is_skipped
            if n == 1
                return i
            end
            n -= 1
        end
        i += 1
    end
end

@noinline function _parser_stuck_error(stream)
    # Optimization: emit unlikely errors in a separate function
    error("The parser seems stuck at byte $(stream.next_byte)")
end

"""
    peek(stream [, n=1]; skip_newlines=false)

Look ahead in the stream `n` tokens, returning the token kind. Comments and
non-newline whitespace are skipped automatically. Whitespace containing a
single newline is returned as kind `K"NewlineWs"` unless `skip_newlines` is
true.
"""
function Base.peek(stream::ParseStream, n::Integer=1;
                   skip_newlines::Bool=false, skip_whitespace=true)
    kind(peek_token(stream, n; skip_newlines=skip_newlines, skip_whitespace=skip_whitespace))
end

"""
    peek_token(stream [, n=1])

Like `peek`, but return the full token information rather than just the kind.
"""
function peek_token(stream::ParseStream, n::Integer=1;
                    skip_newlines=false, skip_whitespace=true)
    stream.peek_count += 1
    if stream.peek_count > 100_000
        _parser_stuck_error(stream)
    end
    i = _lookahead_index(stream, n, skip_newlines)
    if !skip_whitespace
        i = 1
    end
    return stream.lookahead[i]
end

function _peek_behind_fields(ranges, i)
    r = ranges[i]
    return (kind=kind(r),
            flags=flags(r),
            orig_kind=r.orig_kind,
            is_leaf=r.start_mark == i)
end

"""
    peek_behind(ps; skip_trivia=true)
    peek_behind(ps, pos::ParseStreamPosition)

Return information about a span which was previously inserted into the output,
defaulting to the most previous nontrivia node when `skip_trivia` is true, or
at the provided position `pos`.

Retroactively inspecting or modifying the parser's output can be confusing, so
using this function should be avoided where possible.
"""
function peek_behind(stream::ParseStream; skip_trivia::Bool=true)
    if skip_trivia
        for i = length(stream.ranges):-1:1
            r = stream.ranges[i]
            if !is_trivia(head(r)) && kind(r) != K"TOMBSTONE"
                return _peek_behind_fields(stream.ranges, i)
            end
        end
    elseif !isempty(stream.ranges)
        return _peek_behind_fields(stream.ranges, lastindex(stream.ranges))
    end
    internal_error("Can't peek behind at start of stream")
end

function peek_behind(stream::ParseStream, pos::ParseStreamPosition)
    return _peek_behind_fields(stream.ranges, pos.output_index)
end

#-------------------------------------------------------------------------------
# Stream output interface - the `bump_*` and `emit_*` family of functions
#
# Though note bump() really does both input and output

# Bump the next `n` tokens
# flags and remap_kind are applied to any non-trivia tokens
function _bump_n(stream::ParseStream, n::Integer, flags, remap_kind=K"None")
    if n <= 0
        return
    end
    for i = 1:n
        tok = stream.lookahead[i]
        k = kind(tok)
        if k == K"EndMarker"
            break
        end
        is_trivia = k ∈ (K"Whitespace", K"Comment", K"NewlineWs")
        f = is_trivia ? TRIVIA_FLAG : flags
        is_dotted(tok) && (f |= DOTOP_FLAG)
        outk = (is_trivia || remap_kind == K"None") ? k : remap_kind
        range = TaggedRange(SyntaxHead(outk, f), k, first_byte(tok),
                            last_byte(tok), lastindex(stream.ranges)+1)
        push!(stream.ranges, range)
    end
    Base._deletebeg!(stream.lookahead, n)
    stream.next_byte = last_byte(last(stream.ranges)) + 1
    # Defuse the time bomb
    stream.peek_count = 0
end

"""
    bump(stream [, flags=EMPTY_FLAGS];
         skip_newlines=false, error, remap_kind)

Shift the current token from the input to the output, adding the given flags.
"""
function bump(stream::ParseStream, flags=EMPTY_FLAGS; skip_newlines=false,
              error=nothing, remap_kind::Kind=K"None")
    emark = position(stream)
    _bump_n(stream, _lookahead_index(stream, 1, skip_newlines), flags, remap_kind)
    if !isnothing(error)
        emit(stream, emark, K"error", flags, error=error)
    end
    # Return last token location in output if needed for reset_node!
    return position(stream)
end

"""
Bump comments and whitespace tokens preceding the next token

**Skips newlines** by default.  Set skip_newlines=false to avoid that.
"""
function bump_trivia(stream::ParseStream, flags=EMPTY_FLAGS;
                     skip_newlines=true, error=nothing)
    emark = position(stream)
    _bump_n(stream, _lookahead_index(stream, 1, skip_newlines) - 1, EMPTY_FLAGS)
    if !isnothing(error)
        emit(stream, emark, K"error", flags, error=error)
    end
    return position(stream)
end

"""
Bump an invisible zero-width token into the output

This is useful when surrounding syntax implies the presence of a token.  For
example, `2x` means `2*x` via the juxtoposition rules.
"""
function bump_invisible(stream::ParseStream, kind, flags=EMPTY_FLAGS;
                        error=nothing)
    emit(stream, position(stream), kind, flags, error=error)
    return position(stream)
end

"""
Bump several tokens, gluing them together into a single token

This is for use in special circumstances where the parser needs to resolve
lexing ambiguities. There's no special whitespace handling — bump any
whitespace if necessary with bump_trivia.
"""
function bump_glue(stream::ParseStream, kind, flags, num_tokens)
    span = TaggedRange(SyntaxHead(kind, flags), K"None",
                       first_byte(stream.lookahead[1]),
                       last_byte(stream.lookahead[num_tokens]),
                       lastindex(stream.ranges) + 1)
    Base._deletebeg!(stream.lookahead, num_tokens)
    push!(stream.ranges, span)
    stream.next_byte = last_byte(last(stream.ranges)) + 1
    stream.peek_count = 0
    return position(stream)
end

"""
    bump_split(stream, token_spec1, [token_spec2 ...])

Bump the next token, splitting it into several pieces

Tokens are defined by a number of `token_spec` of shape `(nbyte, kind, flags)`.
The number of input bytes of the last spec is taken from the remaining bytes of
the input token, with the associated `nbyte` ignored.

This is a hack which helps resolves the occasional lexing ambiguity. For
example
* Whether .+ should be a single token or the composite (. +) which is used for
  standalone operators.
* Whether ... is splatting (most of the time) or three . tokens in import paths

TODO: Are these the only cases?  Can we replace this general utility with a
simpler one which only splits preceding dots?
"""
function bump_split(stream::ParseStream, split_spec...)
    tok = popfirst!(stream.lookahead)
    fbyte = first_byte(tok)
    for (i, (nbyte, k, f)) in enumerate(split_spec)
        lbyte = (i == length(split_spec)) ? last_byte(tok) : fbyte + nbyte - 1
        push!(stream.ranges, TaggedRange(SyntaxHead(k, f), kind(tok),
                                         fbyte, lbyte,
                                         lastindex(stream.ranges) + 1))
        fbyte += nbyte
    end
    stream.next_byte = last_byte(last(stream.ranges)) + 1
    stream.peek_count = 0
    # Returning position(stream) like the other bump* methods would be
    # ambiguous here; return nothing instead.
    nothing
end

"""
Reset kind or flags of an existing node in the output stream

This is a hack, but in some limited occasions the trailing syntax may change
the kind or flags of a token in a way which would require unbounded lookahead
in a recursive descent parser. Modifying the output with reset_node! is useful
in those cases.
"""
function reset_node!(stream::ParseStream, pos::ParseStreamPosition;
                     kind=nothing, flags=nothing)
    range = stream.ranges[pos.output_index]
    k = isnothing(kind)  ? (@__MODULE__).kind(range)  : kind
    f = isnothing(flags) ? (@__MODULE__).flags(range) : flags
    stream.ranges[pos.output_index] =
        TaggedRange(SyntaxHead(k, f), range.orig_kind,
                    first_byte(range), last_byte(range), range.start_mark)
end

"""
Move `numbytes` from the range at output position `pos+1` to the output
position `pos`. If the donor range becomes empty, mark it dead with
K"TOMBSTONE" and return `true`, otherwise return `false`.

Hack alert! This is used only for managing the complicated rules related to
dedenting triple quoted strings.
"""
function steal_node_bytes!(stream::ParseStream, pos::ParseStreamPosition, numbytes)
    i = pos.output_index
    r1 = stream.ranges[i]
    r2 = stream.ranges[i+1]
    @assert span(r1) == 0
    @assert numbytes <= span(r2)
    fb2 = r2.first_byte + numbytes
    rhs_empty = fb2 > last_byte(r2)
    head2 = rhs_empty ? SyntaxHead(K"TOMBSTONE", EMPTY_FLAGS) : r2.head
    stream.ranges[i]   = TaggedRange(r1.head, r1.orig_kind,
                                     r2.first_byte, fb2 - 1,
                                     r1.start_mark)
    stream.ranges[i+1] = TaggedRange(head2, r2.orig_kind,
                                     fb2, r2.last_byte,
                                     r2.start_mark)
    return rhs_empty
end

function Base.position(stream::ParseStream)
    ParseStreamPosition(stream.next_byte, lastindex(stream.ranges))
end

"""
    emit(stream, mark, kind, flags = EMPTY_FLAGS; error=nothing)

Emit a new text span into the output which covers source bytes from `mark` to
the end of the most recent token which was `bump()`'ed. The starting `mark`
should be a previous return value of `position()`.
"""
function emit(stream::ParseStream, mark::ParseStreamPosition, kind::Kind,
              flags::RawFlags = EMPTY_FLAGS; error=nothing)
    range = TaggedRange(SyntaxHead(kind, flags), K"None", mark.input_byte,
                        stream.next_byte-1, mark.output_index+1)
    if !isnothing(error)
        _emit_diagnostic(stream, first_byte(range), last_byte(range), error=error)
    end
    push!(stream.ranges, range)
    return position(stream)
end

function _emit_diagnostic(stream::ParseStream, fbyte, lbyte; kws...)
    push!(stream.diagnostics, Diagnostic(fbyte, lbyte; kws...))
    return nothing
end

"""
Emit a diagnostic at the position of the next token

If `whitespace` is true, the diagnostic is positioned on the whitespace before
the next token. Otherwise it's positioned at the next token as returned by `peek()`.

FIXME: Rename? This doesn't emit normal tokens into the output event list!
"""
function emit_diagnostic(stream::ParseStream; whitespace=false, kws...)
    i = _lookahead_index(stream, 1, true)
    begin_tok_i = i
    end_tok_i = i
    if whitespace
        # It's the whitespace which is the error. Find the range of the current
        # whitespace.
        begin_tok_i = 1
        end_tok_i = is_whitespace(stream.lookahead[i]) ? i : max(1, i-1)
    end
    fbyte = first_byte(stream.lookahead[begin_tok_i])
    lbyte = last_byte(stream.lookahead[end_tok_i])
    _emit_diagnostic(stream, fbyte, lbyte; kws...)
    return nothing
end

function emit_diagnostic(stream::ParseStream, mark::ParseStreamPosition; kws...)
    _emit_diagnostic(stream, mark.input_byte, stream.next_byte-1; kws...)
end

function emit_diagnostic(stream::ParseStream, r::NTuple{2,ParseStreamPosition}; kws...)
    emit_diagnostic(stream, first(r), last(r); kws...)
end

function emit_diagnostic(stream::ParseStream, mark::ParseStreamPosition,
                         end_mark::ParseStreamPosition; kws...)
    _emit_diagnostic(stream, mark.input_byte, end_mark.input_byte-1; kws...)
end

#-------------------------------------------------------------------------------
# Tree construction from the list of text ranges held by ParseStream

# API for extracting results from ParseStream

"""
    build_tree(::Type{NodeType}, stream::ParseStream;
               wrap_toplevel_as_kind=nothing, kws...)

Construct a tree with `NodeType` nodes from a ParseStream using depth-first
traversal. `NodeType` must have the constructors

    NodeType(head::SyntaxHead, span::Integer)
    NodeType(head::SyntaxHead, span::Integer, children::Vector{NodeType})

A single node which covers the input is expected, but if the ParseStream has
multiple nodes at the top level, `wrap_toplevel_as_kind` may be used to wrap
them in a single node.

The tree here is constructed depth-first, but it would also be possible to use
a bottom-up tree builder interface similar to rust-analyzer. (In that case we'd
traverse the list of ranges backward rather than forward.)
"""
function build_tree(::Type{NodeType}, stream::ParseStream;
                    wrap_toplevel_as_kind=nothing, kws...) where NodeType
    stack = Vector{NamedTuple{(:range,:node),Tuple{TaggedRange,NodeType}}}()
    for (span_index, range) in enumerate(stream.ranges)
        if kind(range) == K"TOMBSTONE"
            # Ignore invisible tokens which were created but never finalized.
            # See bump_invisible()
            continue
        end

        if isempty(stack) || range.start_mark > stack[end].range.start_mark
            # A leaf node (span covering a single token):
            # [a][b][stack[end]]
            #                   [range]
            node = NodeType(head(range), span(range))
            push!(stack, (range=range, node=node))
            continue
        end
        # An interior node, span covering multiple tokens:
        #
        # [a][b][stack[end]]
        #    [        range]
        #
        # We use start_mark rather than first_byte to determine node overlap.
        # This solve the following ambiguity between invisible nodes 1 and 2:
        #
        # [a][b]|[...]
        #       |--- invisible node 1
        #       `--- invisible node 2
        #
        # Does node 2 contain node 1? Using start_mark, we can distinguish the
        # cases:
        #
        # [a][b][2][1]  [a][b][2]...
        #                     [   1]
        j = length(stack)
        while j > 1 && range.start_mark < stack[j].range.start_mark
            j -= 1
        end
        children = [stack[k].node for k = j:length(stack)]
        resize!(stack, j-1)
        node = NodeType(head(range), span(range), children)
        push!(stack, (range=range, node=node))
    end
    # show(stdout, MIME"text/plain"(), stack[1].node)
    if length(stack) == 1
        return only(stack).node
    elseif !isnothing(wrap_toplevel_as_kind)
        # Mostly for debugging
        children = [x.node for x in stack]
        return NodeType(SyntaxHead(wrap_toplevel_as_kind, EMPTY_FLAGS), children...)
    else
        error("Found multiple nodes at top level")
    end
end

"""
    sourcetext(stream::ParseStream; steal_textbuf=true)

Return the source text being parsed by this `ParseStream` as a UTF-8 encoded
string.

If `steal_textbuf==true`, this is permitted to steal the content of the
stream's text buffer. Note that this leaves the `ParseStream` in an invalid
state for further parsing.
"""
function sourcetext(stream::ParseStream; steal_textbuf=false)
    if stream.text_root isa AbstractString && codeunit(stream.text_root) == UInt8
        return stream.text_root
    elseif steal_textbuf
        return String(stream.textbuf)
    else
        # Safe default for other cases is to copy the buffer. Technically this
        # could possibly be avoided in some situations, but might have side
        # effects such as mutating stream.text_root or stealing the storage of
        # stream.textbuf
        return String(copy(stream.textbuf))
    end
end

"""
    textbuf(stream)

Return the `Vector{UInt8}` text buffer being parsed by this `ParseStream`.
"""
textbuf(stream) = stream.textbuf

first_byte(stream::ParseStream) = first_byte(first(stream.ranges))
last_byte(stream::ParseStream) = last_byte(last(stream.ranges))
any_error(stream::ParseStream) = any_error(stream.diagnostics)
