# A finalized design, written so a later process can rebuild the scene.
#
# The picture (`design.asap_model`) is not stored. Scene-mesh changes, such as
# where a slab outline sits relative to a column, are applied by
# `build_analysis_model!` after the file is loaded. The design-phase frame is
# not stored either: `to_asap!` rebuilds it, then the sized section and roll
# recorded here are stamped onto each element. `build_analysis_model!` copies
# those properties; it does not read the placeholder solve `to_asap!` runs.

using Serialization

"""Bytes `MGDS` as a little-endian `UInt32`."""
const DESIGN_ARCHIVE_MAGIC = 0x5344474d
# 2: `Slab` carries `tributary_polygons`. A version 1 file cannot be read.
# 3: `BuildingDesign.scope_notes`, member `check`, per-check foundation
#    utilizations. A version 2 file cannot be read.
const DESIGN_ARCHIVE_VERSION = 3

"""
Sized frame properties for one skeleton edge, in SI.

`Ay` and `Az` may be `Inf` (Bernoulli–Euler). `Ψ` is the element roll in radians.
"""
struct FrameSectionRecord
    A::Float64
    E::Float64
    G::Float64
    Ix::Float64
    Iy::Float64
    J::Float64
    ρ::Float64
    Ay::Float64
    Az::Float64
    Ψ::Float64
end

"""
Versioned design file.

`git_commit` is recorded and not checked on load. `julia_version` and
`packages` are checked: a mismatch throws rather than returning a design the
current structs might misread.
"""
struct DesignArchive{D<:BuildingDesign}
    format_version::Int
    git_commit::String
    julia_version::String
    packages::Dict{String, String}
    frame_sections::Vector{FrameSectionRecord}
    design::D
end

"""Package versions that must match before a design archive is returned."""
function _archive_package_versions()
    return Dict{String, String}(
        "StructuralSynthesizer" => string(pkgversion(@__MODULE__)),
        "StructuralSizer" => string(pkgversion(StructuralSizer)),
        "Asap" => string(pkgversion(Asap)),
    )
end

"""`HEAD`, with `-dirty` when the worktree is not clean. Empty when git cannot answer."""
function _design_archive_git_commit()
    src = pathof(@__MODULE__)
    src === nothing && return ""
    root = dirname(dirname(dirname(src)))
    try
        sha = readchomp(pipeline(`git -C $root rev-parse HEAD`, stderr = devnull))
        dirty = readchomp(pipeline(`git -C $root status --porcelain`, stderr = devnull))
        return isempty(dirty) ? sha : sha * "-dirty"
    catch
        return ""
    end
end

function _assert_archive_versions(julia_version::String, packages::Dict{String, String})
    running = string(VERSION)
    running == julia_version || error(
        "design archive was written by Julia $julia_version; this process is Julia $running")
    expected = _archive_package_versions()
    for name in sort!(collect(keys(expected)))
        got = get(packages, name, "")
        got == expected[name] || error(
            "design archive $name version $(isempty(got) ? "(missing)" : got); " *
            "this process has $(expected[name])")
    end
    return nothing
end

function _archive_frame_elements(model)
    if hasproperty(model, :frame_elements)
        return model.frame_elements
    elseif hasproperty(model, :elements)
        return model.elements
    else
        error("design archive: frame model $(typeof(model)) has no frame elements")
    end
end

function _frame_section_record(el)::FrameSectionRecord
    hasproperty(el, :section) || error(
        "design archive: frame element $(typeof(el)) has no section")
    hasproperty(el, :Ψ) || error(
        "design archive: frame element $(typeof(el)) has no roll angle")
    s = el.section
    return FrameSectionRecord(
        ustrip(u"m^2", s.A),
        ustrip(u"Pa", s.E),
        ustrip(u"Pa", s.G),
        ustrip(u"m^4", s.Ix),
        ustrip(u"m^4", s.Iy),
        ustrip(u"m^4", s.J),
        ustrip(u"kg/m^3", s.ρ),
        ustrip(u"m^2", s.Ay),
        ustrip(u"m^2", s.Az),
        Float64(el.Ψ),
    )
end

"""One record per skeleton edge, in edge order. Throws if the frame was never built."""
function _frame_section_records(struc::BuildingStructure)
    frames = _archive_frame_elements(struc.asap_model)
    nedge = length(struc.skeleton.edge_indices)
    if isempty(frames)
        nedge == 0 || error(
            "design archive: structure has $nedge edges but no frame model. Run to_asap! before saving.")
        return FrameSectionRecord[]
    end
    length(frames) == nedge || error(
        "design archive: frame model has $(length(frames)) elements but the skeleton has $nedge edges")
    return FrameSectionRecord[_frame_section_record(el) for el in frames]
end

function _section_from_record(rec::FrameSectionRecord)
    return Asap.Section(
        rec.A * u"m^2",
        rec.E * u"Pa",
        rec.G * u"Pa",
        rec.Ix * u"m^4",
        rec.Iy * u"m^4",
        rec.J * u"m^4",
        rec.ρ * u"kg/m^3";
        Ay = rec.Ay * u"m^2",
        Az = rec.Az * u"m^2",
    )
end

"""
Replace the solved models with empty stand-ins for the duration of `f`.

Tributary loads, rigid links, and the wall mesh point at those models, so they
are cleared too. Analysis caches can hold a factorization. The live design is
restored when `f` returns, including when `f` throws.
"""
function _with_solver_state_cleared(f, design::BuildingDesign)
    struc = design.structure
    saved = (
        analysis = design.asap_model,
        edges = design.asap_model_frame_edge_indices,
        frame = struc.asap_model,
        tributary = struc.cell_tributary_loads,
        dead = struc.cell_dead_loads,
        live = struc.cell_live_loads,
        links = struc.asap_rigid_links,
        layout = struc.diaphragm_layout,
        mesh = struc.wall_mesh,
        caches = struc._analysis_caches,
    )
    design.asap_model = nothing
    design.asap_model_frame_edge_indices = Int[]
    struc.asap_model = Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[])
    struc.cell_tributary_loads = empty(saved.tributary)
    struc.cell_dead_loads = empty(saved.dead)
    struc.cell_live_loads = empty(saved.live)
    struc.asap_rigid_links = Asap.RigidLink[]
    struc.diaphragm_layout = nothing
    struc.wall_mesh = WallMesh()
    struc._analysis_caches = empty(saved.caches)
    try
        return f()
    finally
        design.asap_model = saved.analysis
        design.asap_model_frame_edge_indices = saved.edges
        struc.asap_model = saved.frame
        struc.cell_tributary_loads = saved.tributary
        struc.cell_dead_loads = saved.dead
        struc.cell_live_loads = saved.live
        struc.asap_rigid_links = saved.links
        struc.diaphragm_layout = saved.layout
        struc.wall_mesh = saved.mesh
        struc._analysis_caches = saved.caches
    end
end

"""
    save_design(path, design) -> path

Write `design` to `path`. The live object is unchanged.

The file is little-endian magic `MGDS`, format version, then a Julia
serialization of the design with its solved models removed. Load it with
[`load_design`](@ref), then call [`build_analysis_model!`](@ref) and
[`build_scene`](@ref).
"""
function save_design(path::AbstractString, design::BuildingDesign)
    records = _frame_section_records(design.structure)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    open(path, "w") do io
        write(io, htol(UInt32(DESIGN_ARCHIVE_MAGIC)))
        write(io, htol(UInt16(DESIGN_ARCHIVE_VERSION)))
        _with_solver_state_cleared(design) do
            archive = DesignArchive(
                DESIGN_ARCHIVE_VERSION,
                _design_archive_git_commit(),
                string(VERSION),
                _archive_package_versions(),
                records,
                design,
            )
            serialize(io, archive)
        end
    end
    return path
end

"""
    load_design(path) -> BuildingDesign

Read a design archive. Throws if the magic, format version, Julia version, or
StructuralSynthesizer / StructuralSizer / Asap version does not match this process.

The analysis model is absent. The frame model is the result of `to_asap!` with
the saved section and roll stamped onto each element. Call
`build_analysis_model!` before `build_scene`.
"""
function load_design(path::AbstractString)
    archive = open(path) do io
        magic = ltoh(read(io, UInt32))
        magic == DESIGN_ARCHIVE_MAGIC || error(
            "design archive: bad magic 0x$(string(magic, base=16)); expected MGDS")
        version = Int(ltoh(read(io, UInt16)))
        version == DESIGN_ARCHIVE_VERSION || error(
            "design archive format $version; this build reads version $DESIGN_ARCHIVE_VERSION")
        payload = deserialize(io)
        payload isa DesignArchive || error(
            "design archive payload is $(typeof(payload)), not a DesignArchive")
        payload.format_version == DESIGN_ARCHIVE_VERSION || error(
            "design archive format $(payload.format_version); this build reads version $DESIGN_ARCHIVE_VERSION")
        _assert_archive_versions(payload.julia_version, payload.packages)
        payload
    end
    design = archive.design
    _restore_frame!(design, archive.frame_sections)
    return design
end

"""Rebuild the frame and replace each placeholder section with the saved one."""
function _restore_frame!(design::BuildingDesign, records::Vector{FrameSectionRecord})
    isempty(records) && return design
    struc = design.structure
    to_asap!(struc; params = design.params)
    frames = _archive_frame_elements(struc.asap_model)
    length(frames) == length(records) || error(
        "design archive has $(length(records)) frame sections but to_asap! built $(length(frames)) elements")
    for (el, rec) in zip(frames, records)
        el.section = _section_from_record(rec)
        el.Ψ = rec.Ψ
    end
    return design
end
