# This file is a part of Julia. License is MIT: https://julialang.org/license

# Base.require is the implementation for the `import` statement
const require_lock = ReentrantLock()

# Cross-platform case-sensitive path canonicalization

if Sys.isunix() && !Sys.isapple()
    # assume case-sensitive filesystems, don't have to do anything
    isfile_casesensitive(path) = isaccessiblefile(path)
elseif Sys.iswindows()
    # GetLongPathName Win32 function returns the case-preserved filename on NTFS.
    function isfile_casesensitive(path)
        isaccessiblefile(path) || return false  # Fail fast
        basename(Filesystem.longpath(path)) == basename(path)
    end
elseif Sys.isapple()
    # HFS+ filesystem is case-preserving. The getattrlist API returns
    # a case-preserved filename. In the rare event that HFS+ is operating
    # in case-sensitive mode, this will still work but will be redundant.

    # Constants from <sys/attr.h>
    const ATRATTR_BIT_MAP_COUNT = 5
    const ATTR_CMN_NAME = 1
    const BITMAPCOUNT = 1
    const COMMONATTR = 5
    const FSOPT_NOFOLLOW = 1  # Don't follow symbolic links

    const attr_list = zeros(UInt8, 24)
    attr_list[BITMAPCOUNT] = ATRATTR_BIT_MAP_COUNT
    attr_list[COMMONATTR] = ATTR_CMN_NAME

    # This essentially corresponds to the following C code:
    # attrlist attr_list;
    # memset(&attr_list, 0, sizeof(attr_list));
    # attr_list.bitmapcount = ATTR_BIT_MAP_COUNT;
    # attr_list.commonattr = ATTR_CMN_NAME;
    # struct Buffer {
    #    u_int32_t total_length;
    #    u_int32_t filename_offset;
    #    u_int32_t filename_length;
    #    char filename[max_filename_length];
    # };
    # Buffer buf;
    # getattrpath(path, &attr_list, &buf, sizeof(buf), FSOPT_NOFOLLOW);
    function isfile_casesensitive(path)
        isaccessiblefile(path) || return false
        path_basename = String(basename(path))
        local casepreserved_basename
        header_size = 12
        buf = Vector{UInt8}(undef, length(path_basename) + header_size + 1)
        while true
            ret = ccall(:getattrlist, Cint,
                        (Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Culong),
                        path, attr_list, buf, sizeof(buf), FSOPT_NOFOLLOW)
            systemerror(:getattrlist, ret ≠ 0)
            filename_length = GC.@preserve buf unsafe_load(
              convert(Ptr{UInt32}, pointer(buf) + 8))
            if (filename_length + header_size) > length(buf)
                resize!(buf, filename_length + header_size)
                continue
            end
            casepreserved_basename =
              view(buf, (header_size+1):(header_size+filename_length-1))
            break
        end
        # Hack to compensate for inability to create a string from a subarray with no allocations.
        codeunits(path_basename) == casepreserved_basename && return true

        # If there is no match, it's possible that the file does exist but HFS+
        # performed unicode normalization. See  https://developer.apple.com/library/mac/qa/qa1235/_index.html.
        isascii(path_basename) && return false
        codeunits(Unicode.normalize(path_basename, :NFD)) == casepreserved_basename
    end
else
    # Generic fallback that performs a slow directory listing.
    function isfile_casesensitive(path)
        isaccessiblefile(path) || return false
        dir, filename = splitdir(path)
        any(readdir(dir) .== filename)
    end
end

# Check if the file is accessible. If stat fails return `false`

function isaccessibledir(dir)
    return try
        isdir(dir)
    catch err
        err isa IOError || rethrow()
        false
    end
end

function isaccessiblefile(file)
    return try
        isfile(file)
    catch err
        err isa IOError || rethrow()
        false
    end
end

function isaccessiblepath(path)
    return try
        ispath(path)
    catch err
        err isa IOError || rethrow()
        false
    end
end

## SHA1 ##

struct SHA1
    bytes::NTuple{20, UInt8}
end
function SHA1(bytes::Vector{UInt8})
    length(bytes) == 20 ||
        throw(ArgumentError("wrong number of bytes for SHA1 hash: $(length(bytes))"))
    return SHA1(ntuple(i->bytes[i], Val(20)))
end
SHA1(s::AbstractString) = SHA1(hex2bytes(s))
parse(::Type{SHA1}, s::AbstractString) = SHA1(s)
function tryparse(::Type{SHA1}, s::AbstractString)
    try
        return parse(SHA1, s)
    catch e
        if isa(e, ArgumentError)
            return nothing
        end
        rethrow(e)
    end
end

string(hash::SHA1) = bytes2hex(hash.bytes)
print(io::IO, hash::SHA1) = bytes2hex(io, hash.bytes)
show(io::IO, hash::SHA1) = print(io, "SHA1(\"", hash, "\")")

isless(a::SHA1, b::SHA1) = isless(a.bytes, b.bytes)
hash(a::SHA1, h::UInt) = hash((SHA1, a.bytes), h)
==(a::SHA1, b::SHA1) = a.bytes == b.bytes

# fake uuid5 function (for self-assigned UUIDs)
# TODO: delete and use real uuid5 once it's in stdlib

function uuid5(namespace::UUID, key::String)
    u::UInt128 = 0
    h = hash(namespace)
    for _ = 1:sizeof(u)÷sizeof(h)
        u <<= sizeof(h) << 3
        u |= (h = hash(key, h))
    end
    u &= 0xffffffffffff0fff3fffffffffffffff
    u |= 0x00000000000050008000000000000000
    return UUID(u)
end

const ns_dummy_uuid = UUID("fe0723d6-3a44-4c41-8065-ee0f42c8ceab")

function dummy_uuid(project_file::String)
    @lock require_lock begin
    cache = LOADING_CACHE[]
    if cache !== nothing
        uuid = get(cache.dummy_uuid, project_file, nothing)
        uuid === nothing || return uuid
    end
    project_path = try
        realpath(project_file)
    catch
        project_file
    end
    uuid = uuid5(ns_dummy_uuid, project_path)
    if cache !== nothing
        cache.dummy_uuid[project_file] = uuid
    end
    return uuid
    end
end

## package path slugs: turning UUID + SHA1 into a pair of 4-byte "slugs" ##

const slug_chars = String(['A':'Z'; 'a':'z'; '0':'9'])

function slug(x::UInt32, p::Int)
    y::UInt32 = x
    sprint(sizehint=p) do io
        n = length(slug_chars)
        for i = 1:p
            y, d = divrem(y, n)
            write(io, slug_chars[1+d])
        end
    end
end

function package_slug(uuid::UUID, p::Int=5)
    crc = _crc32c(uuid)
    return slug(crc, p)
end

function version_slug(uuid::UUID, sha1::SHA1, p::Int=5)
    crc = _crc32c(uuid)
    crc = _crc32c(sha1.bytes, crc)
    return slug(crc, p)
end

mutable struct CachedTOMLDict
    path::String
    inode::UInt64
    mtime::Float64
    size::Int64
    hash::UInt32
    d::Dict{String, Any}
end

function CachedTOMLDict(p::TOML.Parser, path::String)
    s = stat(path)
    content = read(path)
    crc32 = _crc32c(content)
    TOML.reinit!(p, String(content); filepath=path)
    d = TOML.parse(p)
    return CachedTOMLDict(
        path,
        s.inode,
        s.mtime,
        s.size,
        crc32,
        d,
   )
end

function get_updated_dict(p::TOML.Parser, f::CachedTOMLDict)
    s = stat(f.path)
    time_since_cached = time() - f.mtime
    rough_mtime_granularity = 0.1 # seconds
    # In case the file is being updated faster than the mtime granularity,
    # and have the same size after the update we might miss that it changed. Therefore
    # always check the hash in case we recently created the cache.
    if time_since_cached < rough_mtime_granularity || s.inode != f.inode || s.mtime != f.mtime || f.size != s.size
        content = read(f.path)
        new_hash = _crc32c(content)
        if new_hash != f.hash
            f.inode = s.inode
            f.mtime = s.mtime
            f.size = s.size
            f.hash = new_hash
            TOML.reinit!(p, String(content); filepath=f.path)
            return f.d = TOML.parse(p)
        end
    end
    return f.d
end

struct LoadingCache
    load_path::Vector{String}
    dummy_uuid::Dict{String, UUID}
    env_project_file::Dict{String, Union{Bool, String}}
    project_file_manifest_path::Dict{String, Union{Nothing, String}}
    require_parsed::Set{String}
end
const LOADING_CACHE = Ref{Union{LoadingCache, Nothing}}(nothing)
LoadingCache() = LoadingCache(load_path(), Dict(), Dict(), Dict(), Set())


struct TOMLCache
    p::TOML.Parser
    d::Dict{String, CachedTOMLDict}
end
const TOML_CACHE = TOMLCache(TOML.Parser(), Dict{String, Dict{String, Any}}())

parsed_toml(project_file::AbstractString) = parsed_toml(project_file, TOML_CACHE, require_lock)
function parsed_toml(project_file::AbstractString, toml_cache::TOMLCache, toml_lock::ReentrantLock)
    lock(toml_lock) do
        cache = LOADING_CACHE[]
        dd = if !haskey(toml_cache.d, project_file)
            d = CachedTOMLDict(toml_cache.p, project_file)
            toml_cache.d[project_file] = d
            d.d
        else
            d = toml_cache.d[project_file]
            # We are in a require call and have already parsed this TOML file
            # assume that it is unchanged to avoid hitting disk
            if cache !== nothing && project_file in cache.require_parsed
                d.d
            else
                get_updated_dict(toml_cache.p, d)
            end
        end
        if cache !== nothing
            push!(cache.require_parsed, project_file)
        end
        return dd
    end
end

## package identification: determine unique identity of package to be loaded ##

# Used by Pkg but not used in loading itself
function find_package(arg)
    pkg = identify_package(arg)
    pkg === nothing && return nothing
    return locate_package(pkg)
end

## package identity: given a package name and a context, try to return its identity ##
identify_package(where::Module, name::String) = identify_package(PkgId(where), name)

# identify_package computes the PkgId for `name` from the context of `where`
# or return `nothing` if no mapping exists for it
function identify_package(where::PkgId, name::String)::Union{Nothing,PkgId}
    where.name === name && return where
    where.uuid === nothing && return identify_package(name) # ignore `where`
    for env in load_path()
        uuid = manifest_deps_get(env, where, name)
        uuid === nothing && continue # not found--keep looking
        uuid.uuid === nothing || return uuid # found in explicit environment--use it
        return nothing # found in implicit environment--return "not found"
    end
    return nothing
end

# identify_package computes the PkgId for `name` from toplevel context
# by looking through the Project.toml files and directories
function identify_package(name::String)::Union{Nothing,PkgId}
    for env in load_path()
        uuid = project_deps_get(env, name)
        uuid === nothing || return uuid # found--return it
    end
    return nothing
end

## package location: given a package identity, find file to load ##
function locate_package(pkg::PkgId)::Union{Nothing,String}
    if pkg.uuid === nothing
        for env in load_path()
            # look for the toplevel pkg `pkg.name` in this entry
            found = project_deps_get(env, pkg.name)
            found === nothing && continue
            if pkg == found
                # pkg.name is present in this directory or project file,
                # return the path the entry point for the code, if it could be found
                # otherwise, signal failure
                return implicit_manifest_uuid_path(env, pkg)
            end
            @assert found.uuid !== nothing
            return locate_package(found) # restart search now that we know the uuid for pkg
        end
    else
        for env in load_path()
            path = manifest_uuid_path(env, pkg)
            path === nothing || return entry_path(path, pkg.name)
        end
        # Allow loading of stdlibs if the name/uuid are given
        # e.g. if they have been explicitly added to the project/manifest
        path = manifest_uuid_path(Sys.STDLIB::String, pkg)
        path === nothing || return entry_path(path, pkg.name)
    end
    return nothing
end

"""
    pathof(m::Module)

Return the path of the `m.jl` file that was used to `import` module `m`,
or `nothing` if `m` was not imported from a package.

Use [`dirname`](@ref) to get the directory part and [`basename`](@ref)
to get the file name part of the path.
"""
function pathof(m::Module)
    @lock require_lock begin
    pkgid = get(module_keys, m, nothing)
    pkgid === nothing && return nothing
    origin = get(pkgorigins, pkgid, nothing)
    origin === nothing && return nothing
    path = origin.path
    path === nothing && return nothing
    return fixup_stdlib_path(path)
    end
end

"""
    pkgdir(m::Module[, paths::String...])

Return the root directory of the package that imported module `m`,
or `nothing` if `m` was not imported from a package. Optionally further
path component strings can be provided to construct a path within the
package root.

```julia-repl
julia> pkgdir(Foo)
"/path/to/Foo.jl"

julia> pkgdir(Foo, "src", "file.jl")
"/path/to/Foo.jl/src/file.jl"
```

!!! compat "Julia 1.7"
    The optional argument `paths` requires at least Julia 1.7.
"""
function pkgdir(m::Module, paths::String...)
    rootmodule = moduleroot(m)
    path = pathof(rootmodule)
    path === nothing && return nothing
    return joinpath(dirname(dirname(path)), paths...)
end

## generic project & manifest API ##

const project_names = ("JuliaProject.toml", "Project.toml")
const manifest_names = ("JuliaManifest.toml", "Manifest.toml")
const preferences_names = ("JuliaLocalPreferences.toml", "LocalPreferences.toml")

# classify the LOAD_PATH entry to be one of:
#  - `false`: nonexistant / nothing to see here
#  - `true`: `env` is an implicit environment
#  - `path`: the path of an explicit project file
function env_project_file(env::String)::Union{Bool,String}
    @lock require_lock begin
    cache = LOADING_CACHE[]
    if cache !== nothing
        project_file = get(cache.env_project_file, env, nothing)
        project_file === nothing || return project_file
    end
    if isdir(env)
        for proj in project_names
            maybe_project_file = joinpath(env, proj)
            if isfile_casesensitive(maybe_project_file)
                project_file = maybe_project_file
                break
            end
        end
        project_file =true
    elseif basename(env) in project_names && isfile_casesensitive(env)
        project_file = env
    else
        project_file = false
    end
    if cache !== nothing
        cache.env_project_file[env] = project_file
    end
    return project_file
    end
end

function project_deps_get(env::String, name::String)::Union{Nothing,PkgId}
    project_file = env_project_file(env)
    if project_file isa String
        pkg_uuid = explicit_project_deps_get(project_file, name)
        pkg_uuid === nothing || return PkgId(pkg_uuid, name)
    elseif project_file
        return implicit_project_deps_get(env, name)
    end
    return nothing
end

function manifest_deps_get(env::String, where::PkgId, name::String)::Union{Nothing,PkgId}
    uuid = where.uuid
    @assert uuid !== nothing
    project_file = env_project_file(env)
    if project_file isa String
        # first check if `where` names the Project itself
        proj = project_file_name_uuid(project_file, where.name)
        if proj == where
            # if `where` matches the project, use [deps] section as manifest, and stop searching
            pkg_uuid = explicit_project_deps_get(project_file, name)
            return PkgId(pkg_uuid, name)
        end
        # look for manifest file and `where` stanza
        return explicit_manifest_deps_get(project_file, uuid, name)
    elseif project_file
        # if env names a directory, search it
        return implicit_manifest_deps_get(env, where, name)
    end
    return nothing
end

function manifest_uuid_path(env::String, pkg::PkgId)::Union{Nothing,String}
    project_file = env_project_file(env)
    if project_file isa String
        proj = project_file_name_uuid(project_file, pkg.name)
        if proj == pkg
            # if `pkg` matches the project, return the project itself
            return project_file_path(project_file, pkg.name)
        end
        # look for manifest file and `where` stanza
        return explicit_manifest_uuid_path(project_file, pkg)
    elseif project_file
        # if env names a directory, search it
        return implicit_manifest_uuid_path(env, pkg)
    end
    return nothing
end

# find project file's top-level UUID entry (or nothing)
function project_file_name_uuid(project_file::String, name::String)::PkgId
    d = parsed_toml(project_file)
    uuid′ = get(d, "uuid", nothing)::Union{String, Nothing}
    uuid = uuid′ === nothing ? dummy_uuid(project_file) : UUID(uuid′)
    name = get(d, "name", name)::String
    return PkgId(uuid, name)
end

function project_file_path(project_file::String, name::String)
    d = parsed_toml(project_file)
    joinpath(dirname(project_file), get(d, "path", "")::String)
end

# find project file's corresponding manifest file
function project_file_manifest_path(project_file::String)::Union{Nothing,String}
    @lock require_lock begin
    cache = LOADING_CACHE[]
    if cache !== nothing
        manifest_path = get(cache.project_file_manifest_path, project_file, missing)
        manifest_path === missing || return manifest_path
    end
    dir = abspath(dirname(project_file))
    d = parsed_toml(project_file)
    explicit_manifest = get(d, "manifest", nothing)::Union{String, Nothing}
    manifest_path = nothing
    if explicit_manifest !== nothing
        manifest_file = normpath(joinpath(dir, explicit_manifest))
        if isfile_casesensitive(manifest_file)
            manifest_path = manifest_file
        end
    end
    if manifest_path === nothing
        for mfst in manifest_names
            manifest_file = joinpath(dir, mfst)
            if isfile_casesensitive(manifest_file)
                manifest_path = manifest_file
                break
            end
        end
    end
    if cache !== nothing
        cache.project_file_manifest_path[project_file] = manifest_path
    end
    return manifest_path
    end
end

# given a directory (implicit env from LOAD_PATH) and a name,
# check if it is an implicit package
function entry_point_and_project_file_inside(dir::String, name::String)::Union{Tuple{Nothing,Nothing},Tuple{String,Nothing},Tuple{String,String}}
    path = normpath(joinpath(dir, "src", "$name.jl"))
    isfile_casesensitive(path) || return nothing, nothing
    for proj in project_names
        project_file = normpath(joinpath(dir, proj))
        isfile_casesensitive(project_file) || continue
        return path, project_file
    end
    return path, nothing
end

# given a project directory (implicit env from LOAD_PATH) and a name,
# find an entry point for `name`, and see if it has an associated project file
function entry_point_and_project_file(dir::String, name::String)::Union{Tuple{Nothing,Nothing},Tuple{String,Nothing},Tuple{String,String}}
    path = normpath(joinpath(dir, "$name.jl"))
    isfile_casesensitive(path) && return path, nothing
    dir = joinpath(dir, name)
    path, project_file = entry_point_and_project_file_inside(dir, name)
    path === nothing || return path, project_file
    dir = dir * ".jl"
    path, project_file = entry_point_and_project_file_inside(dir, name)
    path === nothing || return path, project_file
    return nothing, nothing
end

# given a path and a name, return the entry point
function entry_path(path::String, name::String)::Union{Nothing,String}
    isfile_casesensitive(path) && return normpath(path)
    path = normpath(joinpath(path, "src", "$name.jl"))
    isfile_casesensitive(path) && return path
    return nothing # source not found
end

## explicit project & manifest API ##

# find project file root or deps `name => uuid` mapping
# return `nothing` if `name` is not found
function explicit_project_deps_get(project_file::String, name::String)::Union{Nothing,UUID}
    d = parsed_toml(project_file)
    root_uuid = dummy_uuid(project_file)
    if get(d, "name", nothing)::Union{String, Nothing} === name
        uuid = get(d, "uuid", nothing)::Union{String, Nothing}
        return uuid === nothing ? root_uuid : UUID(uuid)
    end
    deps = get(d, "deps", nothing)::Union{Dict{String, Any}, Nothing}
    if deps !== nothing
        uuid = get(deps, name, nothing)::Union{String, Nothing}
        uuid === nothing || return UUID(uuid)
    end
    return nothing
end

function is_v1_format_manifest(raw_manifest::Dict)
    if haskey(raw_manifest, "manifest_format")
        if raw_manifest["manifest_format"] isa Dict && haskey(raw_manifest["manifest_format"], "uuid")
            # the off-chance where an old format manifest has a dep called "manifest_format"
            return true
        end
        return false
    else
        return true
    end
end

# returns a deps list for both old and new manifest formats
function get_deps(raw_manifest::Dict)
    if is_v1_format_manifest(raw_manifest)
        return raw_manifest
    else
        # if the manifest has no deps, there won't be a `deps` field
        return get(Dict{String, Any}, raw_manifest, "deps")
    end
end

# find `where` stanza and return the PkgId for `name`
# return `nothing` if it did not find `where` (indicating caller should continue searching)
function explicit_manifest_deps_get(project_file::String, where::UUID, name::String)::Union{Nothing,PkgId}
    manifest_file = project_file_manifest_path(project_file)
    manifest_file === nothing && return nothing # manifest not found--keep searching LOAD_PATH
    d = get_deps(parsed_toml(manifest_file))
    found_where = false
    found_name = false
    for (dep_name, entries) in d
        entries::Vector{Any}
        for entry in entries
            entry = entry::Dict{String, Any}
            uuid = get(entry, "uuid", nothing)::Union{String, Nothing}
            uuid === nothing && continue
            if UUID(uuid) === where
                found_where = true
                # deps is either a list of names (deps = ["DepA", "DepB"]) or
                # a table of entries (deps = {"DepA" = "6ea...", "DepB" = "55d..."}
                deps = get(entry, "deps", nothing)::Union{Vector{String}, Dict{String, Any}, Nothing}
                deps === nothing && continue
                if deps isa Vector{String}
                    found_name = name in deps
                    break
                else
                    deps = deps::Dict{String, Any}
                    for (dep, uuid) in deps
                        uuid::String
                        if dep === name
                            return PkgId(UUID(uuid), name)
                        end
                    end
                end
            end
        end
    end
    found_where || return nothing
    found_name || return PkgId(name)
    # Only reach here if deps was not a dict which mean we have a unique name for the dep
    name_deps = get(d, name, nothing)::Union{Nothing, Vector{Any}}
    if name_deps === nothing || length(name_deps) != 1
        error("expected a single entry for $(repr(name)) in $(repr(project_file))")
    end
    entry = first(name_deps::Vector{Any})::Dict{String, Any}
    uuid = get(entry, "uuid", nothing)::Union{String, Nothing}
    uuid === nothing && return nothing
    return PkgId(UUID(uuid), name)
end

# find `uuid` stanza, return the corresponding path
function explicit_manifest_uuid_path(project_file::String, pkg::PkgId)::Union{Nothing,String}
    manifest_file = project_file_manifest_path(project_file)
    manifest_file === nothing && return nothing # no manifest, skip env

    d = get_deps(parsed_toml(manifest_file))
    entries = get(d, pkg.name, nothing)::Union{Nothing, Vector{Any}}
    entries === nothing && return nothing # TODO: allow name to mismatch?
    for entry in entries
        entry = entry::Dict{String, Any}
        uuid = get(entry, "uuid", nothing)::Union{Nothing, String}
        uuid === nothing && continue
        if UUID(uuid) === pkg.uuid
            return explicit_manifest_entry_path(manifest_file, pkg, entry)
        end
    end
    return nothing
end

function explicit_manifest_entry_path(manifest_file::String, pkg::PkgId, entry::Dict{String,Any})
    path = get(entry, "path", nothing)::Union{Nothing, String}
    if path !== nothing
        path = normpath(abspath(dirname(manifest_file), path))
        return path
    end
    hash = get(entry, "git-tree-sha1", nothing)::Union{Nothing, String}
    hash === nothing && return nothing
    hash = SHA1(hash)
    # Keep the 4 since it used to be the default
    uuid = pkg.uuid::UUID # checked within `explicit_manifest_uuid_path`
    for slug in (version_slug(uuid, hash), version_slug(uuid, hash, 4))
        for depot in DEPOT_PATH
            path = joinpath(depot, "packages", pkg.name, slug)
            ispath(path) && return abspath(path)
        end
    end
    return nothing
end

## implicit project & manifest API ##

# look for an entry point for `name` from a top-level package (no environment)
# otherwise return `nothing` to indicate the caller should keep searching
function implicit_project_deps_get(dir::String, name::String)::Union{Nothing,PkgId}
    path, project_file = entry_point_and_project_file(dir, name)
    if project_file === nothing
        path === nothing && return nothing
        return PkgId(name)
    end
    proj = project_file_name_uuid(project_file, name)
    proj.name == name || return nothing
    return proj
end

# look for an entry-point for `name`, check that UUID matches
# if there's a project file, look up `name` in its deps and return that
# otherwise return `nothing` to indicate the caller should keep searching
function implicit_manifest_deps_get(dir::String, where::PkgId, name::String)::Union{Nothing,PkgId}
    @assert where.uuid !== nothing
    project_file = entry_point_and_project_file(dir, where.name)[2]
    project_file === nothing && return nothing # a project file is mandatory for a package with a uuid
    proj = project_file_name_uuid(project_file, where.name)
    proj == where || return nothing # verify that this is the correct project file
    # this is the correct project, so stop searching here
    pkg_uuid = explicit_project_deps_get(project_file, name)
    return PkgId(pkg_uuid, name)
end

# look for an entry-point for `pkg` and return its path if UUID matches
function implicit_manifest_uuid_path(dir::String, pkg::PkgId)::Union{Nothing,String}
    path, project_file = entry_point_and_project_file(dir, pkg.name)
    if project_file === nothing
        pkg.uuid === nothing || return nothing
        return path
    end
    proj = project_file_name_uuid(project_file, pkg.name)
    proj == pkg || return nothing
    return path
end

## other code loading functionality ##

function find_source_file(path::AbstractString)
    (isabspath(path) || isfile(path)) && return path
    base_path = joinpath(Sys.BINDIR::String, DATAROOTDIR, "julia", "base", path)
    return isfile(base_path) ? normpath(base_path) : nothing
end

cache_file_entry(pkg::PkgId) = joinpath(
    "compiled",
    "v$(VERSION.major).$(VERSION.minor)",
    pkg.uuid === nothing ? ""       : pkg.name),
    pkg.uuid === nothing ? pkg.name : package_slug(pkg.uuid)

function find_all_in_cache_path(pkg::PkgId)
    paths = String[]
    entrypath, entryfile = cache_file_entry(pkg)
    for path in joinpath.(DEPOT_PATH, entrypath)
        isdir(path) || continue
        for file in readdir(path, sort = false) # no sort given we sort later
            if !((pkg.uuid === nothing && file == entryfile * ".ji") ||
                 (pkg.uuid !== nothing && startswith(file, entryfile * "_")))
                 continue
            end
            filepath = joinpath(path, file)
            isfile_casesensitive(filepath) && push!(paths, filepath)
        end
    end
    if length(paths) > 1
        # allocating the sort vector is less expensive than using sort!(.. by=mtime), which would
        # call the relatively slow mtime multiple times per path
        p = sortperm(mtime.(paths), rev = true)
        return paths[p]
    else
        return paths
    end
end

# these return either the array of modules loaded from the path / content given
# or an Exception that describes why it couldn't be loaded
# and it reconnects the Base.Docs.META
function _include_from_serialized(path::String, depmods::Vector{Any})
    sv = ccall(:jl_restore_incremental, Any, (Cstring, Any), path, depmods)
    if isa(sv, Exception)
        return sv
    end
    sv = sv::SimpleVector
    restored = sv[1]::Vector{Any}
    for M in restored
        M = M::Module
        if isdefined(M, Base.Docs.META) && getfield(M, Base.Docs.META) !== nothing
            push!(Base.Docs.modules, M)
        end
        if parentmodule(M) === M
            register_root_module(M)
        end
    end
    inits = sv[2]::Vector{Any}
    if !isempty(inits)
        unlock(require_lock) # temporarily _unlock_ during these callbacks
        try
            ccall(:jl_init_restored_modules, Cvoid, (Any,), inits)
        finally
            lock(require_lock)
        end
    end
    return restored
end

function run_package_callbacks(modkey::PkgId)
    unlock(require_lock)
    try
        for callback in package_callbacks
            invokelatest(callback, modkey)
        end
    catch
        # Try to continue loading if a callback errors
        errs = current_exceptions()
        @error "Error during package callback" exception=errs
    finally
        lock(require_lock)
    end
    nothing
end

function _tryrequire_from_serialized(modkey::PkgId, build_id::UInt64, modpath::Union{Nothing, String}, depth::Int = 0)
    if root_module_exists(modkey)
        M = root_module(modkey)
        if PkgId(M) == modkey && module_build_id(M) === build_id
            return M
        end
    else
        if modpath === nothing
            modpath = locate_package(modkey)
            modpath === nothing && return nothing
        end
        mod = _require_search_from_serialized(modkey, String(modpath), depth)
        get!(PkgOrigin, pkgorigins, modkey).path = modpath
        if !isa(mod, Bool)
            run_package_callbacks(modkey)
            for M in mod::Vector{Any}
                M = M::Module
                if PkgId(M) == modkey && module_build_id(M) === build_id
                    return M
                end
            end
        end
    end
    return nothing
end

function _require_from_serialized(path::String)
    # loads a precompile cache file, ignoring stale_cachfile tests
    # load all of the dependent modules first
    local depmodnames
    io = open(path, "r")
    try
        isvalid_cache_header(io) || return ArgumentError("Invalid header in cache file $path.")
        depmodnames = parse_cache_header(io)[3]
        isvalid_file_crc(io) || return ArgumentError("Invalid checksum in cache file $path.")
    finally
        close(io)
    end
    ndeps = length(depmodnames)
    depmods = Vector{Any}(undef, ndeps)
    for i in 1:ndeps
        modkey, build_id = depmodnames[i]
        dep = _tryrequire_from_serialized(modkey, build_id, nothing)
        dep === nothing && return ErrorException("Required dependency $modkey failed to load from a cache file.")
        depmods[i] = dep::Module
    end
    # then load the file
    return _include_from_serialized(path, depmods)
end

# use an Int counter so that nested @time_imports calls all remain open
const TIMING_IMPORTS = Threads.Atomic{Int}(0)

# returns `true` if require found a precompile cache for this sourcepath, but couldn't load it
# returns `false` if the module isn't known to be precompilable
# returns the set of modules restored if the cache load succeeded
@constprop :none function _require_search_from_serialized(pkg::PkgId, sourcepath::String, depth::Int = 0)
    t_before = time_ns()
    paths = find_all_in_cache_path(pkg)
    for path_to_try in paths::Vector{String}
        staledeps = stale_cachefile(sourcepath, path_to_try)
        if staledeps === true
            continue
        end
        try
            touch(path_to_try) # update timestamp of precompilation file
        catch # file might be read-only and then we fail to update timestamp, which is fine
        end
        # finish loading module graph into staledeps
        for i in 1:length(staledeps)
            dep = staledeps[i]
            dep isa Module && continue
            modpath, modkey, build_id = dep::Tuple{String, PkgId, UInt64}
            dep = _tryrequire_from_serialized(modkey, build_id, modpath, depth + 1)
            if dep === nothing
                @debug "Required dependency $modkey failed to load from cache file for $modpath."
                staledeps = true
                break
            end
            staledeps[i] = dep::Module
        end
        if staledeps === true
            continue
        end
        restored = _include_from_serialized(path_to_try, staledeps)
        if isa(restored, Exception)
            @debug "Deserialization checks failed while attempting to load cache from $path_to_try" exception=restored
        else
            if TIMING_IMPORTS[] > 0
                elapsed = round((time_ns() - t_before) / 1e6, digits = 1)
                tree_prefix = depth == 0 ? "" : "  "^(depth-1)*"┌ "
                print(lpad(elapsed, 9), " ms  ")
                printstyled(tree_prefix, color = :light_black)
                println(pkg.name)
            end
            return restored
        end
    end
    return !isempty(paths)
end

# to synchronize multiple tasks trying to import/using something
const package_locks = Dict{PkgId,Threads.Condition}()

# to notify downstream consumers that a module was successfully loaded
# Callbacks take the form (mod::Base.PkgId) -> nothing.
# WARNING: This is an experimental feature and might change later, without deprecation.
const package_callbacks = Any[]
# to notify downstream consumers that a file has been included into a particular module
# Callbacks take the form (mod::Module, filename::String) -> nothing
# WARNING: This is an experimental feature and might change later, without deprecation.
const include_callbacks = Any[]

# used to optionally track dependencies when requiring a module:
const _concrete_dependencies = Pair{PkgId,UInt64}[] # these dependency versions are "set in stone", and the process should try to avoid invalidating them
const _require_dependencies = Any[] # a list of (mod, path, mtime) tuples that are the file dependencies of the module currently being precompiled
const _track_dependencies = Ref(false) # set this to true to track the list of file dependencies
function _include_dependency(mod::Module, _path::AbstractString)
    prev = source_path(nothing)
    if prev === nothing
        path = abspath(_path)
    else
        path = normpath(joinpath(dirname(prev), _path))
    end
    if _track_dependencies[]
        @lock require_lock begin
        push!(_require_dependencies, (mod, path, mtime(path)))
        end
    end
    return path, prev
end

"""
    include_dependency(path::AbstractString)

In a module, declare that the file specified by `path` (relative or absolute) is a
dependency for precompilation; that is, the module will need to be recompiled if this file
changes.

This is only needed if your module depends on a file that is not used via [`include`](@ref). It has
no effect outside of compilation.
"""
function include_dependency(path::AbstractString)
    _include_dependency(Main, path)
    return nothing
end

# we throw PrecompilableError when a module doesn't want to be precompiled
struct PrecompilableError <: Exception end
function show(io::IO, ex::PrecompilableError)
    print(io, "Declaring __precompile__(false) is not allowed in files that are being precompiled.")
end
precompilableerror(ex::PrecompilableError) = true
precompilableerror(ex::WrappedException) = precompilableerror(ex.error)
precompilableerror(@nospecialize ex) = false

# Call __precompile__(false) at the top of a tile prevent it from being precompiled (false)
"""
    __precompile__(isprecompilable::Bool)

Specify whether the file calling this function is precompilable, defaulting to `true`.
If a module or file is *not* safely precompilable, it should call `__precompile__(false)` in
order to throw an error if Julia attempts to precompile it.
"""
@noinline function __precompile__(isprecompilable::Bool=true)
    if !isprecompilable && ccall(:jl_generating_output, Cint, ()) != 0
        throw(PrecompilableError())
    end
    nothing
end

# require always works in Main scope and loads files from node 1
const toplevel_load = Ref(true)

"""
    require(into::Module, module::Symbol)

This function is part of the implementation of [`using`](@ref) / [`import`](@ref), if a module is not
already defined in `Main`. It can also be called directly to force reloading a module,
regardless of whether it has been loaded before (for example, when interactively developing
libraries).

Loads a source file, in the context of the `Main` module, on every active node, searching
standard locations for files. `require` is considered a top-level operation, so it sets the
current `include` path but does not use it to search for files (see help for [`include`](@ref)).
This function is typically used to load library code, and is implicitly called by `using` to
load packages.

When searching for files, `require` first looks for package code in the global array
[`LOAD_PATH`](@ref). `require` is case-sensitive on all platforms, including those with
case-insensitive filesystems like macOS and Windows.

For more details regarding code loading, see the manual sections on [modules](@ref modules) and
[parallel computing](@ref code-availability).
"""
function require(into::Module, mod::Symbol)
    @lock require_lock begin
    LOADING_CACHE[] = LoadingCache()
    try
        uuidkey = identify_package(into, String(mod))
        # Core.println("require($(PkgId(into)), $mod) -> $uuidkey")
        if uuidkey === nothing
            where = PkgId(into)
            if where.uuid === nothing
                hint, dots = begin
                    if isdefined(into, mod) && getfield(into, mod) isa Module
                        true, "."
                    elseif isdefined(parentmodule(into), mod) && getfield(parentmodule(into), mod) isa Module
                        true, ".."
                    else
                        false, ""
                    end
                end
                hint_message = hint ? ", maybe you meant `import/using $(dots)$(mod)`" : ""
                start_sentence = hint ? "Otherwise, run" : "Run"
                throw(ArgumentError("""
                    Package $mod not found in current path$hint_message.
                    - $start_sentence `import Pkg; Pkg.add($(repr(String(mod))))` to install the $mod package."""))
            else
                throw(ArgumentError("""
                Package $(where.name) does not have $mod in its dependencies:
                - You may have a partially installed environment. Try `Pkg.instantiate()`
                  to ensure all packages in the environment are installed.
                - Or, if you have $(where.name) checked out for development and have
                  added $mod as a dependency but haven't updated your primary
                  environment's manifest file, try `Pkg.resolve()`.
                - Otherwise you may need to report an issue with $(where.name)"""))
            end
        end
        if _track_dependencies[]
            push!(_require_dependencies, (into, binpack(uuidkey), 0.0))
        end
        return _require_prelocked(uuidkey)
    finally
        LOADING_CACHE[] = nothing
    end
    end
end

mutable struct PkgOrigin
    # version::VersionNumber
    path::Union{String,Nothing}
    cachepath::Union{String,Nothing}
end
PkgOrigin() = PkgOrigin(nothing, nothing)
const pkgorigins = Dict{PkgId,PkgOrigin}()

require(uuidkey::PkgId) = @lock require_lock _require_prelocked(uuidkey)

function _require_prelocked(uuidkey::PkgId)
    just_loaded_pkg = false
    if !root_module_exists(uuidkey)
        cachefile = _require(uuidkey)
        if cachefile !== nothing
            get!(PkgOrigin, pkgorigins, uuidkey).cachepath = cachefile
        end
        # After successfully loading, notify downstream consumers
        run_package_callbacks(uuidkey)
        just_loaded_pkg = true
    end
    if just_loaded_pkg && !root_module_exists(uuidkey)
        error("package `$(uuidkey.name)` did not define the expected \
              module `$(uuidkey.name)`, check for typos in package module name")
    end
    return root_module(uuidkey)
end

const loaded_modules = Dict{PkgId,Module}()
const module_keys = IdDict{Module,PkgId}() # the reverse

is_root_module(m::Module) = @lock require_lock haskey(module_keys, m)
root_module_key(m::Module) = @lock require_lock module_keys[m]

@constprop :none function register_root_module(m::Module)
    # n.b. This is called from C after creating a new module in `Base.__toplevel__`,
    # instead of adding them to the binding table there.
    @lock require_lock begin
    key = PkgId(m, String(nameof(m)))
    if haskey(loaded_modules, key)
        oldm = loaded_modules[key]
        if oldm !== m
            @warn "Replacing module `$(key.name)`"
        end
    end
    loaded_modules[key] = m
    module_keys[m] = key
    end
    nothing
end

register_root_module(Core)
register_root_module(Base)
register_root_module(Main)

# This is used as the current module when loading top-level modules.
# It has the special behavior that modules evaluated in it get added
# to the loaded_modules table instead of getting bindings.
baremodule __toplevel__
using Base
end

# get a top-level Module from the given key
root_module(key::PkgId) = @lock require_lock loaded_modules[key]
root_module(where::Module, name::Symbol) =
    root_module(identify_package(where, String(name)))
maybe_root_module(key::PkgId) = @lock require_lock get(loaded_modules, key, nothing)

root_module_exists(key::PkgId) = @lock require_lock haskey(loaded_modules, key)
loaded_modules_array() = @lock require_lock collect(values(loaded_modules))

function unreference_module(key::PkgId)
    if haskey(loaded_modules, key)
        m = pop!(loaded_modules, key)
        # need to ensure all modules are GC rooted; will still be referenced
        # in module_keys
    end
end

# Returns `nothing` or the name of the newly-created cachefile
function _require(pkg::PkgId)
    # handle recursive calls to require
    loading = get(package_locks, pkg, false)
    if loading !== false
        # load already in progress for this module
        wait(loading)
        return
    end
    package_locks[pkg] = Threads.Condition(require_lock)

    last = toplevel_load[]
    try
        toplevel_load[] = false
        # perform the search operation to select the module file require intends to load
        path = locate_package(pkg)
        get!(PkgOrigin, pkgorigins, pkg).path = path
        if path === nothing
            throw(ArgumentError("""
                Package $pkg is required but does not seem to be installed:
                 - Run `Pkg.instantiate()` to install all recorded dependencies.
                """))
        end

        # attempt to load the module file via the precompile cache locations
        if JLOptions().use_compiled_modules != 0
            m = _require_search_from_serialized(pkg, path)
            if !isa(m, Bool)
                return
            end
        end

        # if the module being required was supposed to have a particular version
        # but it was not handled by the precompile loader, complain
        for (concrete_pkg, concrete_build_id) in _concrete_dependencies
            if pkg == concrete_pkg
                @warn """Module $(pkg.name) with build ID $concrete_build_id is missing from the cache.
                     This may mean $pkg does not support precompilation but is imported by a module that does."""
                if JLOptions().incremental != 0
                    # during incremental precompilation, this should be fail-fast
                    throw(PrecompilableError())
                end
            end
        end

        if JLOptions().use_compiled_modules != 0
            if (0 == ccall(:jl_generating_output, Cint, ())) || (JLOptions().incremental != 0)
                # spawn off a new incremental pre-compile task for recursive `require` calls
                # or if the require search declared it was pre-compiled before (and therefore is expected to still be pre-compilable)
                cachefile = compilecache(pkg, path)
                if isa(cachefile, Exception)
                    if precompilableerror(cachefile)
                        verbosity = isinteractive() ? CoreLogging.Info : CoreLogging.Debug
                        @logmsg verbosity "Skipping precompilation since __precompile__(false). Importing $pkg."
                    else
                        @warn "The call to compilecache failed to create a usable precompiled cache file for $pkg" exception=m
                    end
                    # fall-through to loading the file locally
                else
                    m = _require_from_serialized(cachefile)
                    if isa(m, Exception)
                        @warn "The call to compilecache failed to create a usable precompiled cache file for $pkg" exception=m
                    else
                        return cachefile
                    end
                end
            end
        end

        # just load the file normally via include
        # for unknown dependencies
        uuid = pkg.uuid
        uuid = (uuid === nothing ? (UInt64(0), UInt64(0)) : convert(NTuple{2, UInt64}, uuid))
        old_uuid = ccall(:jl_module_uuid, NTuple{2, UInt64}, (Any,), __toplevel__)
        if uuid !== old_uuid
            ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), __toplevel__, uuid)
        end
        unlock(require_lock)
        try
            include(__toplevel__, path)
            return
        finally
            lock(require_lock)
            if uuid !== old_uuid
                ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), __toplevel__, old_uuid)
            end
        end
    finally
        toplevel_load[] = last
        loading = pop!(package_locks, pkg)
        notify(loading, all=true)
    end
    nothing
end

# relative-path load

"""
    include_string([mapexpr::Function,] m::Module, code::AbstractString, filename::AbstractString="string")

Like [`include`](@ref), except reads code from the given string rather than from a file.

The optional first argument `mapexpr` can be used to transform the included code before
it is evaluated: for each parsed expression `expr` in `code`, the `include_string` function
actually evaluates `mapexpr(expr)`.  If it is omitted, `mapexpr` defaults to [`identity`](@ref).

!!! compat "Julia 1.5"
    Julia 1.5 is required for passing the `mapexpr` argument.
"""
function include_string(mapexpr::Function, mod::Module, code::AbstractString,
                        filename::AbstractString="string")
    loc = LineNumberNode(1, Symbol(filename))
    try
        ast = Meta.parseall(code, filename=filename)
        @assert Meta.isexpr(ast, :toplevel)
        result = nothing
        line_and_ex = Expr(:toplevel, loc, nothing)
        for ex in ast.args
            if ex isa LineNumberNode
                loc = ex
                line_and_ex.args[1] = ex
                continue
            end
            ex = mapexpr(ex)
            # Wrap things to be eval'd in a :toplevel expr to carry line
            # information as part of the expr.
            line_and_ex.args[2] = ex
            result = Core.eval(mod, line_and_ex)
        end
        return result
    catch exc
        # TODO: Now that stacktraces are more reliable we should remove
        # LoadError and expose the real error type directly.
        rethrow(LoadError(filename, loc.line, exc))
    end
end

include_string(m::Module, txt::AbstractString, fname::AbstractString="string") =
    include_string(identity, m, txt, fname)

function source_path(default::Union{AbstractString,Nothing}="")
    s = current_task().storage
    if s !== nothing && haskey(s::IdDict{Any,Any}, :SOURCE_PATH)
        return s[:SOURCE_PATH]::Union{Nothing,String}
    end
    return default
end

function source_dir()
    p = source_path(nothing)
    return p === nothing ? pwd() : dirname(p)
end

"""
    Base.include([mapexpr::Function,] [m::Module,] path::AbstractString)

Evaluate the contents of the input source file in the global scope of module `m`.
Every module (except those defined with [`baremodule`](@ref)) has its own
definition of `include` omitting the `m` argument, which evaluates the file in that module.
Returns the result of the last evaluated expression of the input file. During including,
a task-local include path is set to the directory containing the file. Nested calls to
`include` will search relative to that path. This function is typically used to load source
interactively, or to combine files in packages that are broken into multiple source files.

The optional first argument `mapexpr` can be used to transform the included code before
it is evaluated: for each parsed expression `expr` in `path`, the `include` function
actually evaluates `mapexpr(expr)`.  If it is omitted, `mapexpr` defaults to [`identity`](@ref).

!!! compat "Julia 1.5"
    Julia 1.5 is required for passing the `mapexpr` argument.
"""
Base.include # defined in Base.jl

# Full include() implementation which is used after bootstrap
function _include(mapexpr::Function, mod::Module, _path::AbstractString)
    @noinline # Workaround for module availability in _simplify_include_frames
    path, prev = _include_dependency(mod, _path)
    for callback in include_callbacks # to preserve order, must come before eval in include_string
        invokelatest(callback, mod, path)
    end
    code = read(path, String)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path
    try
        return include_string(mapexpr, mod, code, path)
    finally
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
end

"""
    evalfile(path::AbstractString, args::Vector{String}=String[])

Load the file using [`include`](@ref), evaluate all expressions,
and return the value of the last one.
"""
function evalfile(path::AbstractString, args::Vector{String}=String[])
    return Core.eval(Module(:__anon__),
        Expr(:toplevel,
             :(const ARGS = $args),
             :(eval(x) = $(Expr(:core, :eval))(__anon__, x)),
             :(include(x) = $(Expr(:top, :include))(__anon__, x)),
             :(include(mapexpr::Function, x) = $(Expr(:top, :include))(mapexpr, __anon__, x)),
             :(include($path))))
end
evalfile(path::AbstractString, args::Vector) = evalfile(path, String[args...])

function load_path_setup_code(load_path::Bool=true)
    code = """
    append!(empty!(Base.DEPOT_PATH), $(repr(map(abspath, DEPOT_PATH))))
    append!(empty!(Base.DL_LOAD_PATH), $(repr(map(abspath, DL_LOAD_PATH))))
    """
    if load_path
        load_path = map(abspath, Base.load_path())
        path_sep = Sys.iswindows() ? ';' : ':'
        any(path -> path_sep in path, load_path) &&
            error("LOAD_PATH entries cannot contain $(repr(path_sep))")
        code *= """
        append!(empty!(Base.LOAD_PATH), $(repr(load_path)))
        ENV["JULIA_LOAD_PATH"] = $(repr(join(load_path, Sys.iswindows() ? ';' : ':')))
        Base.set_active_project(nothing)
        """
    end
    return code
end

# this is called in the external process that generates precompiled package files
function include_package_for_output(pkg::PkgId, input::String, depot_path::Vector{String}, dl_load_path::Vector{String}, load_path::Vector{String},
                                    concrete_deps::typeof(_concrete_dependencies), source::Union{Nothing,String})
    append!(empty!(Base.DEPOT_PATH), depot_path)
    append!(empty!(Base.DL_LOAD_PATH), dl_load_path)
    append!(empty!(Base.LOAD_PATH), load_path)
    ENV["JULIA_LOAD_PATH"] = join(load_path, Sys.iswindows() ? ';' : ':')
    set_active_project(nothing)
    Base._track_dependencies[] = true
    get!(Base.PkgOrigin, Base.pkgorigins, pkg).path = input
    append!(empty!(Base._concrete_dependencies), concrete_deps)
    uuid_tuple = pkg.uuid === nothing ? (UInt64(0), UInt64(0)) : convert(NTuple{2, UInt64}, pkg.uuid)

    ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), Base.__toplevel__, uuid_tuple)
    if source !== nothing
        task_local_storage()[:SOURCE_PATH] = source
    end

    try
        Base.include(Base.__toplevel__, input)
    catch ex
        precompilableerror(ex) || rethrow()
        @debug "Aborting `create_expr_cache'" exception=(ErrorException("Declaration of __precompile__(false) not allowed"), catch_backtrace())
        exit(125) # we define status = 125 means PrecompileableError
    end
end

const PRECOMPILE_TRACE_COMPILE = Ref{String}()
function create_expr_cache(pkg::PkgId, input::String, output::String, concrete_deps::typeof(_concrete_dependencies), internal_stderr::IO = stderr, internal_stdout::IO = stdout)
    @nospecialize internal_stderr internal_stdout
    rm(output, force=true)   # Remove file if it exists
    depot_path = map(abspath, DEPOT_PATH)
    dl_load_path = map(abspath, DL_LOAD_PATH)
    load_path = map(abspath, Base.load_path())
    path_sep = Sys.iswindows() ? ';' : ':'
    any(path -> path_sep in path, load_path) &&
        error("LOAD_PATH entries cannot contain $(repr(path_sep))")

    deps_strs = String[]
    function pkg_str(_pkg::PkgId)
        if _pkg.uuid === nothing
            "Base.PkgId($(repr(_pkg.name)))"
        else
            "Base.PkgId(Base.UUID(\"$(_pkg.uuid)\"), $(repr(_pkg.name)))"
        end
    end
    for (pkg, build_id) in concrete_deps
        push!(deps_strs, "$(pkg_str(pkg)) => $(repr(build_id))")
    end
    deps_eltype = sprint(show, eltype(concrete_deps); context = :module=>nothing)
    deps = deps_eltype * "[" * join(deps_strs, ",") * "]"
    trace = isassigned(PRECOMPILE_TRACE_COMPILE) ? `--trace-compile=$(PRECOMPILE_TRACE_COMPILE[])` : ``
    io = open(pipeline(`$(julia_cmd()::Cmd) -O0
                       --output-ji $output --output-incremental=yes
                       --startup-file=no --history-file=no --warn-overwrite=yes
                       --color=$(have_color === nothing ? "auto" : have_color ? "yes" : "no")
                       $trace
                       -`, stderr = internal_stderr, stdout = internal_stdout),
              "w", stdout)
    # write data over stdin to avoid the (unlikely) case of exceeding max command line size
    write(io.in, """
        Base.include_package_for_output($(pkg_str(pkg)), $(repr(abspath(input))), $(repr(depot_path)), $(repr(dl_load_path)),
            $(repr(load_path)), $deps, $(repr(source_path(nothing))))
        """)
    close(io.in)
    return io
end

function compilecache_dir(pkg::PkgId)
    entrypath, entryfile = cache_file_entry(pkg)
    return joinpath(DEPOT_PATH[1], entrypath)
end

function compilecache_path(pkg::PkgId, prefs_hash::UInt64)::String
    entrypath, entryfile = cache_file_entry(pkg)
    cachepath = joinpath(DEPOT_PATH[1], entrypath)
    isdir(cachepath) || mkpath(cachepath)
    if pkg.uuid === nothing
        abspath(cachepath, entryfile) * ".ji"
    else
        crc = _crc32c(something(Base.active_project(), ""))
        crc = _crc32c(unsafe_string(JLOptions().image_file), crc)
        crc = _crc32c(unsafe_string(JLOptions().julia_bin), crc)
        crc = _crc32c(prefs_hash, crc)
        project_precompile_slug = slug(crc, 5)
        abspath(cachepath, string(entryfile, "_", project_precompile_slug, ".ji"))
    end
end

"""
    Base.compilecache(module::PkgId)

Creates a precompiled cache file for a module and all of its dependencies.
This can be used to reduce package load times. Cache files are stored in
`DEPOT_PATH[1]/compiled`. See [Module initialization and precompilation](@ref)
for important notes.
"""
function compilecache(pkg::PkgId, internal_stderr::IO = stderr, internal_stdout::IO = stdout)
    @nospecialize internal_stderr internal_stdout
    path = locate_package(pkg)
    path === nothing && throw(ArgumentError("$pkg not found during precompilation"))
    return compilecache(pkg, path, internal_stderr, internal_stdout)
end

const MAX_NUM_PRECOMPILE_FILES = Ref(10)

function compilecache(pkg::PkgId, path::String, internal_stderr::IO = stderr, internal_stdout::IO = stdout,
                      ignore_loaded_modules::Bool = true)

    @nospecialize internal_stderr internal_stdout
    # decide where to put the resulting cache file
    cachepath = compilecache_dir(pkg)

    # build up the list of modules that we want the precompile process to preserve
    concrete_deps = copy(_concrete_dependencies)
    if ignore_loaded_modules
        for (key, mod) in loaded_modules
            if !(mod === Main || mod === Core || mod === Base)
                push!(concrete_deps, key => module_build_id(mod))
            end
        end
    end
    # run the expression and cache the result
    verbosity = isinteractive() ? CoreLogging.Info : CoreLogging.Debug
    @logmsg verbosity "Precompiling $pkg"

    # create a temporary file in `cachepath` directory, write the cache in it,
    # write the checksum, _and then_ atomically move the file to `cachefile`.
    mkpath(cachepath)
    tmppath, tmpio = mktemp(cachepath)
    local p
    try
        close(tmpio)
        p = create_expr_cache(pkg, path, tmppath, concrete_deps, internal_stderr, internal_stdout)
        if success(p)
            # append checksum to the end of the .ji file:
            open(tmppath, "a+") do f
                write(f, _crc32c(seekstart(f)))
            end
            # inherit permission from the source file (and make them writable)
            chmod(tmppath, filemode(path) & 0o777 | 0o200)

            # Read preferences hash back from .ji file (we can't precompute because
            # we don't actually know what the list of compile-time preferences are without compiling)
            prefs_hash = preferences_hash(tmppath)
            cachefile = compilecache_path(pkg, prefs_hash)

            # prune the directory with cache files
            if pkg.uuid !== nothing
                entrypath, entryfile = cache_file_entry(pkg)
                cachefiles = filter!(x -> startswith(x, entryfile * "_"), readdir(cachepath))
                if length(cachefiles) >= MAX_NUM_PRECOMPILE_FILES[]
                    idx = findmin(mtime.(joinpath.(cachepath, cachefiles)))[2]
                    rm(joinpath(cachepath, cachefiles[idx]))
                end
            end

            # this is atomic according to POSIX:
            rename(tmppath, cachefile; force=true)
            return cachefile
        end
    finally
        rm(tmppath, force=true)
    end
    if p.exitcode == 125
        return PrecompilableError()
    else
        error("Failed to precompile $pkg to $tmppath.")
    end
end

module_build_id(m::Module) = ccall(:jl_module_build_id, UInt64, (Any,), m)

isvalid_cache_header(f::IOStream) = (0 != ccall(:jl_read_verify_header, Cint, (Ptr{Cvoid},), f.ios))
isvalid_file_crc(f::IOStream) = (_crc32c(seekstart(f), filesize(f) - 4) == read(f, UInt32))

struct CacheHeaderIncludes
    id::PkgId
    filename::String
    mtime::Float64
    modpath::Vector{String}   # seemingly not needed in Base, but used by Revise
end

function parse_cache_header(f::IO)
    modules = Vector{Pair{PkgId, UInt64}}()
    while true
        n = read(f, Int32)
        n == 0 && break
        sym = String(read(f, n)) # module name
        uuid = UUID((read(f, UInt64), read(f, UInt64))) # pkg UUID
        build_id = read(f, UInt64) # build UUID (mostly just a timestamp)
        push!(modules, PkgId(uuid, sym) => build_id)
    end
    totbytes = read(f, Int64) # total bytes for file dependencies + preferences
    # read the list of requirements
    # and split the list into include and requires statements
    includes = CacheHeaderIncludes[]
    requires = Pair{PkgId, PkgId}[]
    while true
        n2 = read(f, Int32)
        totbytes -= 4
        if n2 == 0
            break
        end
        depname = String(read(f, n2))
        totbytes -= n2
        mtime = read(f, Float64)
        totbytes -= 8
        n1 = read(f, Int32)
        totbytes -= 4
        # map ids to keys
        modkey = (n1 == 0) ? PkgId("") : modules[n1].first
        modpath = String[]
        if n1 != 0
            # determine the complete module path
            while true
                n1 = read(f, Int32)
                totbytes -= 4
                if n1 == 0
                    break
                end
                push!(modpath, String(read(f, n1)))
                totbytes -= n1
            end
        end
        if depname[1] == '\0'
            push!(requires, modkey => binunpack(depname))
        else
            push!(includes, CacheHeaderIncludes(modkey, depname, mtime, modpath))
        end
    end
    prefs = String[]
    while true
        n2 = read(f, Int32)
        totbytes -= 4
        if n2 == 0
            break
        end
        push!(prefs, String(read(f, n2)))
        totbytes -= n2
    end
    prefs_hash = read(f, UInt64)
    totbytes -= 8
    srctextpos = read(f, Int64)
    totbytes -= 8
    @assert totbytes == 0 "header of cache file appears to be corrupt (totbytes == $(totbytes))"
    # read the list of modules that are required to be present during loading
    required_modules = Vector{Pair{PkgId, UInt64}}()
    while true
        n = read(f, Int32)
        n == 0 && break
        sym = String(read(f, n)) # module name
        uuid = UUID((read(f, UInt64), read(f, UInt64))) # pkg UUID
        build_id = read(f, UInt64) # build id
        push!(required_modules, PkgId(uuid, sym) => build_id)
    end
    return modules, (includes, requires), required_modules, srctextpos, prefs, prefs_hash
end

function parse_cache_header(cachefile::String; srcfiles_only::Bool=false)
    io = open(cachefile, "r")
    try
        !isvalid_cache_header(io) && throw(ArgumentError("Invalid header in cache file $cachefile."))
        ret = parse_cache_header(io)
        srcfiles_only || return ret
        modules, (includes, requires), required_modules, srctextpos, prefs, prefs_hash = ret
        srcfiles = srctext_files(io, srctextpos)
        delidx = Int[]
        for (i, chi) in enumerate(includes)
            chi.filename ∈ srcfiles || push!(delidx, i)
        end
        deleteat!(includes, delidx)
        return modules, (includes, requires), required_modules, srctextpos, prefs, prefs_hash
    finally
        close(io)
    end
end



preferences_hash(f::IO) = parse_cache_header(f)[end]
function preferences_hash(cachefile::String)
    io = open(cachefile, "r")
    try
        if !isvalid_cache_header(io)
            throw(ArgumentError("Invalid header in cache file $cachefile."))
        end
        return preferences_hash(io)
    finally
        close(io)
    end
end


function cache_dependencies(f::IO)
    defs, (includes, requires), modules, srctextpos, prefs, prefs_hash = parse_cache_header(f)
    return modules, map(chi -> (chi.filename, chi.mtime), includes)  # return just filename and mtime
end

function cache_dependencies(cachefile::String)
    io = open(cachefile, "r")
    try
        !isvalid_cache_header(io) && throw(ArgumentError("Invalid header in cache file $cachefile."))
        return cache_dependencies(io)
    finally
        close(io)
    end
end

function read_dependency_src(io::IO, filename::AbstractString)
    modules, (includes, requires), required_modules, srctextpos, prefs, prefs_hash = parse_cache_header(io)
    srctextpos == 0 && error("no source-text stored in cache file")
    seek(io, srctextpos)
    return _read_dependency_src(io, filename)
end

function _read_dependency_src(io::IO, filename::AbstractString)
    while !eof(io)
        filenamelen = read(io, Int32)
        filenamelen == 0 && break
        fn = String(read(io, filenamelen))
        len = read(io, UInt64)
        if fn == filename
            return String(read(io, len))
        end
        seek(io, position(io) + len)
    end
    error(filename, " is not stored in the source-text cache")
end

function read_dependency_src(cachefile::String, filename::AbstractString)
    io = open(cachefile, "r")
    try
        !isvalid_cache_header(io) && throw(ArgumentError("Invalid header in cache file $cachefile."))
        return read_dependency_src(io, filename)
    finally
        close(io)
    end
end

function srctext_files(f::IO, srctextpos::Int64)
    files = Set{String}()
    srctextpos == 0 && return files
    seek(f, srctextpos)
    while !eof(f)
        filenamelen = read(f, Int32)
        filenamelen == 0 && break
        fn = String(read(f, filenamelen))
        len = read(f, UInt64)
        push!(files, fn)
        seek(f, position(f) + len)
    end
    return files
end

# Test to see if this UUID is mentioned in this `Project.toml`; either as
# the top-level UUID (e.g. that of the project itself), as a dependency,
# or as an extra for Preferences.
function get_uuid_name(project::Dict{String, Any}, uuid::UUID)
    uuid_p = get(project, "uuid", nothing)::Union{Nothing, String}
    name = get(project, "name", nothing)::Union{Nothing, String}
    if name !== nothing && uuid_p !== nothing && UUID(uuid_p) == uuid
        return name
    end
    deps = get(project, "deps", nothing)::Union{Nothing, Dict{String, Any}}
    if deps !== nothing
        for (k, v) in deps
            if uuid == UUID(v::String)
                return k
            end
        end
    end
    for subkey in ("deps", "extras")
        subsection = get(project, subkey, nothing)::Union{Nothing, Dict{String, Any}}
        if subsection !== nothing
            for (k, v) in subsection
                if uuid == UUID(v::String)
                    return k
                end
            end
        end
    end
    return nothing
end

function get_uuid_name(project_toml::String, uuid::UUID)
    project = parsed_toml(project_toml)
    return get_uuid_name(project, uuid)
end

# If we've asked for a specific UUID, this function will extract the prefs
# for that particular UUID.  Otherwise, it returns all preferences.
function filter_preferences(prefs::Dict{String, Any}, pkg_name)
    if pkg_name === nothing
        return prefs
    else
        return get(Dict{String, Any}, prefs, pkg_name)::Dict{String, Any}
    end
end

function collect_preferences(project_toml::String, uuid::Union{UUID,Nothing})
    # We'll return a list of dicts to be merged
    dicts = Dict{String, Any}[]

    project = parsed_toml(project_toml)
    pkg_name = nothing
    if uuid !== nothing
        # If we've been given a UUID, map that to the name of the package as
        # recorded in the preferences section.  If we can't find that mapping,
        # exit out, as it means there's no way preferences can be set for that
        # UUID, as we only allow actual dependencies to have preferences set.
        pkg_name = get_uuid_name(project, uuid)
        if pkg_name === nothing
            return dicts
        end
    end

    # Look first inside of `Project.toml` to see we have preferences embedded within there
    proj_preferences = get(Dict{String, Any}, project, "preferences")::Dict{String, Any}
    push!(dicts, filter_preferences(proj_preferences, pkg_name))

    # Next, look for `(Julia)LocalPreferences.toml` files next to this `Project.toml`
    project_dir = dirname(project_toml)
    for name in preferences_names
        toml_path = joinpath(project_dir, name)
        if isfile(toml_path)
            prefs = parsed_toml(toml_path)
            push!(dicts, filter_preferences(prefs, pkg_name))

            # If we find `JuliaLocalPreferences.toml`, don't look for `LocalPreferences.toml`
            break
        end
    end

    return dicts
end

"""
    recursive_prefs_merge(base::Dict, overrides::Dict...)

Helper function to merge preference dicts recursively, honoring overrides in nested
dictionaries properly.
"""
function recursive_prefs_merge(base::Dict{String, Any}, overrides::Dict{String, Any}...)
    new_base = Base._typeddict(base, overrides...)

    for override in overrides
        # Clear entries are keys that should be deleted from any previous setting.
        override_clear = get(override, "__clear__", nothing)
        if override_clear isa Vector{String}
            for k in override_clear
                delete!(new_base, k)
            end
        end

        for (k, override_k) in override
            # Note that if `base` has a mapping that is _not_ a `Dict`, and `override`
            new_base_k = get(new_base, k, nothing)
            if new_base_k isa Dict{String, Any} && override_k isa Dict{String, Any}
                new_base[k] = recursive_prefs_merge(new_base_k, override_k)
            else
                new_base[k] = override_k
            end
        end
    end
    return new_base
end

function get_preferences(uuid::Union{UUID,Nothing} = nothing)
    merged_prefs = Dict{String,Any}()
    for env in reverse(load_path())
        project_toml = env_project_file(env)
        if !isa(project_toml, String)
            continue
        end

        # Collect all dictionaries from the current point in the load path, then merge them in
        dicts = collect_preferences(project_toml, uuid)
        merged_prefs = recursive_prefs_merge(merged_prefs, dicts...)
    end
    return merged_prefs
end

function get_preferences_hash(uuid::Union{UUID, Nothing}, prefs_list::Vector{String})
    # Start from a predictable hash point to ensure that the same preferences always
    # hash to the same value, modulo changes in how Dictionaries are hashed.
    h = UInt(0)
    uuid === nothing && return UInt64(h)

    # Load the preferences
    prefs = get_preferences(uuid)

    # Walk through each name that's called out as a compile-time preference
    for name in prefs_list
        prefs_value = get(prefs, name, nothing)
        if prefs_value !== nothing
            h = hash(prefs_value, h)
        end
    end
    # We always return a `UInt64` so that our serialization format is stable
    return UInt64(h)
end

get_preferences_hash(m::Module, prefs_list::Vector{String}) = get_preferences_hash(PkgId(m).uuid, prefs_list)

# This is how we keep track of who is using what preferences at compile-time
const COMPILETIME_PREFERENCES = Dict{UUID,Set{String}}()

# In `Preferences.jl`, if someone calls `load_preference(@__MODULE__, key)` while we're precompiling,
# we mark that usage as a usage at compile-time and call this method, so that at the end of `.ji` generation,
# we can record the list of compile-time preferences and embed that into the `.ji` header
function record_compiletime_preference(uuid::UUID, key::String)
    pref = get!(Set{String}, COMPILETIME_PREFERENCES, uuid)
    push!(pref, key)
    return nothing
end
get_compiletime_preferences(uuid::UUID) = collect(get(Vector{String}, COMPILETIME_PREFERENCES, uuid))
get_compiletime_preferences(m::Module) = get_compiletime_preferences(PkgId(m).uuid)
get_compiletime_preferences(::Nothing) = String[]

# returns true if it "cachefile.ji" is stale relative to "modpath.jl"
# otherwise returns the list of dependencies to also check
@constprop :none function stale_cachefile(modpath::String, cachefile::String; ignore_loaded::Bool = false)
    io = open(cachefile, "r")
    try
        if !isvalid_cache_header(io)
            @debug "Rejecting cache file $cachefile due to it containing an invalid cache header"
            return true # invalid cache file
        end
        modules, (includes, requires), required_modules, srctextpos, prefs, prefs_hash = parse_cache_header(io)
        id = isempty(modules) ? nothing : first(modules).first
        modules = Dict{PkgId, UInt64}(modules)

        # Check if transitive dependencies can be fulfilled
        ndeps = length(required_modules)
        depmods = Vector{Any}(undef, ndeps)
        for i in 1:ndeps
            req_key, req_build_id = required_modules[i]
            # Module is already loaded
            if root_module_exists(req_key)
                M = root_module(req_key)
                if PkgId(M) == req_key && module_build_id(M) === req_build_id
                    depmods[i] = M
                elseif ignore_loaded
                    # Used by Pkg.precompile given that there it's ok to precompile different versions of loaded packages
                    @goto locate_branch
                else
                    @debug "Rejecting cache file $cachefile because module $req_key is already loaded and incompatible."
                    return true # Won't be able to fulfill dependency
                end
            else
                @label locate_branch
                path = locate_package(req_key)
                get!(PkgOrigin, pkgorigins, req_key).path = path
                if path === nothing
                    @debug "Rejecting cache file $cachefile because dependency $req_key not found."
                    return true # Won't be able to fulfill dependency
                end
                depmods[i] = (path, req_key, req_build_id)
            end
        end

        # check if this file is going to provide one of our concrete dependencies
        # or if it provides a version that conflicts with our concrete dependencies
        # or neither
        skip_timecheck = false
        for (req_key, req_build_id) in _concrete_dependencies
            build_id = get(modules, req_key, UInt64(0))
            if build_id !== UInt64(0)
                if build_id === req_build_id
                    skip_timecheck = true
                    break
                end
                @debug "Rejecting cache file $cachefile because it provides the wrong uuid (got $build_id) for $req_key (want $req_build_id)"
                return true # cachefile doesn't provide the required version of the dependency
            end
        end

        # now check if this file is fresh relative to its source files
        if !skip_timecheck
            if !samefile(includes[1].filename, modpath)
                @debug "Rejecting cache file $cachefile because it is for file $(includes[1].filename) not file $modpath"
                return true # cache file was compiled from a different path
            end
            for (modkey, req_modkey) in requires
                # verify that `require(modkey, name(req_modkey))` ==> `req_modkey`
                if identify_package(modkey, req_modkey.name) != req_modkey
                    @debug "Rejecting cache file $cachefile because uuid mapping for $modkey => $req_modkey has changed"
                    return true
                end
            end
            for chi in includes
                f, ftime_req = chi.filename, chi.mtime
                # Issue #13606: compensate for Docker images rounding mtimes
                # Issue #20837: compensate for GlusterFS truncating mtimes to microseconds
                # The `ftime != 1.0` condition below provides compatibility with Nix mtime.
                ftime = mtime(f)
                if ftime != ftime_req && ftime != floor(ftime_req) && ftime != trunc(ftime_req, digits=6) && ftime != 1.0
                    @debug "Rejecting stale cache file $cachefile (mtime $ftime_req) because file $f (mtime $ftime) has changed"
                    return true
                end
            end
        end

        if !isvalid_file_crc(io)
            @debug "Rejecting cache file $cachefile because it has an invalid checksum"
            return true
        end

        if isa(id, PkgId)
            curr_prefs_hash = get_preferences_hash(id.uuid, prefs)
            if prefs_hash != curr_prefs_hash
                @debug "Rejecting cache file $cachefile because preferences hash does not match 0x$(string(prefs_hash, base=16)) != 0x$(string(curr_prefs_hash, base=16))"
                return true
            end

            get!(PkgOrigin, pkgorigins, id).cachepath = cachefile
        end

        return depmods # fresh cachefile
    finally
        close(io)
    end
end

"""
    @__FILE__ -> AbstractString

Expand to a string with the path to the file containing the
macrocall, or an empty string if evaluated by `julia -e <expr>`.
Return `nothing` if the macro was missing parser source information.
Alternatively see [`PROGRAM_FILE`](@ref).
"""
macro __FILE__()
    __source__.file === nothing && return nothing
    return String(__source__.file::Symbol)
end

"""
    @__DIR__ -> AbstractString

Expand to a string with the absolute path to the directory of the file
containing the macrocall.
Return the current working directory if run from a REPL or if evaluated by `julia -e <expr>`.
"""
macro __DIR__()
    __source__.file === nothing && return nothing
    _dirname = dirname(String(__source__.file::Symbol))
    return isempty(_dirname) ? pwd() : abspath(_dirname)
end

"""
    precompile(f, args::Tuple{Vararg{Any}})

Compile the given function `f` for the argument tuple (of types) `args`, but do not execute it.
"""
function precompile(@nospecialize(f), args::Tuple)
    precompile(Tuple{Core.Typeof(f), args...})
end

const ENABLE_PRECOMPILE_WARNINGS = Ref(false)
function precompile(argt::Type)
    ret = ccall(:jl_compile_hint, Int32, (Any,), argt) != 0
    if !ret && ENABLE_PRECOMPILE_WARNINGS[]
        @warn "Inactive precompile statement" maxlog=100 form=argt _module=nothing _file=nothing _line=0
    end
    return ret
end

precompile(include_package_for_output, (PkgId, String, Vector{String}, Vector{String}, Vector{String}, typeof(_concrete_dependencies), Nothing))
precompile(include_package_for_output, (PkgId, String, Vector{String}, Vector{String}, Vector{String}, typeof(_concrete_dependencies), String))
precompile(create_expr_cache, (PkgId, String, String, typeof(_concrete_dependencies), IO, IO))
