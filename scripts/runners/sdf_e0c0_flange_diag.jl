#=
Diagnose why two (apparently symmetric) beams in star/e0c0 get different
sections: Beam 44 rectangular RC, Beam 11 a T-beam. The hypothesis is that the
flange derivation (StructuralSynthesizer/.../tbeam_flange.jl) is orientation /
vertex-ordering dependent, so mirror beams take different branches of the
all-or-nothing `return nothing` gates and one group falls back to rectangular.

This re-designs the e0c0 waffle (cache ON), then for the target beams AND their
reconstructed groups replays the flange derivation step by step: chord +
direction, role (framed vs girder), per-side webs / slab-edge rays, hf list,
and the final `_compute_flange_params` spec (nothing => rectangular). It also
prints a whole-floor table (section type + chord direction) so mirror pairs and
the exact point of symmetry breaking are visible.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_flange_diag.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSy = StructuralSynthesizer
const SSz = StructuralSizer

const TARGETS = [11, 44]

_r2(x) = round(x; digits = 2)
_xy(skel, v) = SSy._vertex_xy_m(skel, v)

"""Short section-type tag for a solved beam member."""
function _sec_tag(s, bi)
    sec = try
        SSy.section(s.beams[bi])
    catch
        return "?"
    end
    sec isa SSz.RCTBeamSection && return "T(bw=$(_r2(ustrip(u"inch", sec.bw)))in,bf=$(_r2(ustrip(u"inch", sec.bf)))in)"
    sec isa SSz.RCBeamSection  && return "RECT(b=$(_r2(ustrip(u"inch", sec.b)))in)"
    return string(nameof(typeof(sec)))
end

"""Chord summary (endpoints + unit direction) or a reason it is nothing."""
function _chord_line(struc, bi, chords)
    c = chords[bi]
    c === nothing && return "chord=nothing (non-straight or degenerate)"
    q = (c.p[1] + c.L * c.u[1], c.p[2] + c.L * c.u[2])
    return "p=($(_r2(c.p[1])),$(_r2(c.p[2]))) q=($(_r2(q[1])),$(_r2(q[2]))) " *
           "u=($(_r2(c.u[1])),$(_r2(c.u[2]))) L=$(_r2(c.L))m"
end

"""Rebuild beam groups by bucketing members on their stored group id."""
function _beam_groups(s)
    groups = Dict{UInt64, Vector{Int}}()
    for bi in 1:length(s.beams)
        gid = SSy.group_id(s.beams[bi])
        push!(get!(groups, gid, Int[]), bi)
    end
    return groups
end

"""Replay _compute_flange_params for one reconstructed group; print the gate path."""
function _diagnose_group(s, gid, idxs, chords, home, edge_hf)
    println("  group $gid  members=", idxs)
    framed = count(mi -> haskey(home, mi), idxs)
    role = framed == length(idxs) ? "FRAMED(level)" :
           framed == 0 ? "GIRDER" : "MIXED($framed/$(length(idxs)))"
    println("    role=", role)

    if role == "GIRDER"
        hfs = Union{Nothing, typeof(1.0u"m")}[]
        for mi in idxs, si in SSy.segment_indices(s.beams[mi])
            append!(hfs, get(edge_hf, s.segments[si].edge_idx, ()))
        end
        println("    edge_hf entries=", length(hfs),
                "  any_nothing=", any(isnothing, hfs),
                isempty(hfs) ? "  (empty -> tries _boundary_group_hf)" : "")
        for mi in idxs
            mf = try SSy._girder_member_flange(s, mi, chords) catch e; "ERR $(sprint(showerror,e))" end
            println("    member $mi girder_flange=", mf === nothing ? "nothing" :
                    (mf isa String ? mf : "MemberFlange(one_side=$(mf.one_side))"))
        end
        spec = try SSy._girder_group_flange(s, idxs, chords, edge_hf) catch e; "ERR $(sprint(showerror,e))" end
        println("    => group spec: ", spec === nothing ? "nothing (RECTANGULAR)" :
                (spec isa String ? spec : "FLANGE hf=$(spec.hf)"))
    elseif role == "FRAMED(level)"
        for mi in idxs
            slab, fl = home[mi]
            hf = try SSy._slab_flange_hf(slab) catch; nothing end
            mf = try SSy._framed_member_flange(s, mi, slab, fl, chords) catch e; "ERR $(sprint(showerror,e))" end
            println("    member $mi  slab_hf=", hf,
                    "  framed_flange=", mf === nothing ? "nothing" :
                    (mf isa String ? mf : "MemberFlange(one_side=$(mf.one_side))"))
        end
        spec = try SSy._framed_group_flange(s, idxs, chords, home) catch e; "ERR $(sprint(showerror,e))" end
        println("    => group spec: ", spec === nothing ? "nothing (RECTANGULAR)" :
                (spec isa String ? spec : "FLANGE hf=$(spec.hf)"))
    end
end

function main(plan = "star/e0c0")
    p = rib_parameters(plan, :waffle)
    p.max_iterations = parse(Int, get(ENV, "SCENE_MAX_ITER", "12"))
    p.skip_visualization = true
    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    design = design_building(struc, p; restore = false)
    s = design.structure

    println("\n========== e0c0 FLANGE SYMMETRY DIAG ==========")
    println("summary: pass=", design.summary.all_checks_pass,
            "  critical=", design.summary.critical_element,
            "  ratio=", _r2(design.summary.critical_ratio))
    println("beams=", length(s.beams))

    chords  = [SSy._beam_chord(s, b) for b in s.beams]
    home    = SSy._framing_home(s)
    edge_hf = SSy._edge_slab_thickness(s)
    groups  = _beam_groups(s)

    # Whole-floor table: index, group, role, section, chord direction.
    println("\n-- all beams (idx | gid | role | section | chord) --")
    for bi in 1:length(s.beams)
        gid = SSy.group_id(s.beams[bi])
        role = haskey(home, bi) ? "framed" : "girder?"
        println("  B$bi  g=", gid, "  ", rpad(role, 8),
                rpad(_sec_tag(s, bi), 22), "  ", _chord_line(s, bi, chords))
    end

    for t in TARGETS
        println("\n========== Beam $t ==========")
        t <= length(s.beams) || (println("  out of range"); continue)
        br = get(design.beams, t, nothing)
        if br !== nothing
            # Generic dump of every demand/result field on the row.
            println("  design.beams[$t] fields:")
            for pn in propertynames(br)
                v = getproperty(br, pn)
                v isa Union{Number, Unitful.Quantity, String, Symbol, Bool} &&
                    println("      ", rpad(string(pn), 18), " = ", v)
            end
        end
        gid = SSy.group_id(s.beams[t])
        println("  group_id=", gid, "  section=", _sec_tag(s, t))
        println("  ", _chord_line(s, t, chords))

        # Per-side flange geometry: the available overhang on each side.
        mf = try SSy._girder_member_flange(s, t, chords) catch e; "ERR $(sprint(showerror,e))" end
        if mf !== nothing && !(mf isa String)
            println("  _MemberFlange internals:")
            for pn in propertynames(mf)
                v = getproperty(mf, pn)
                vv = v === nothing ? "nothing" :
                     (v isa Union{Number, Unitful.Quantity, Bool} ? string(v) :
                      string(nameof(typeof(v))) * "(" *
                      join((string(fn, "=", getfield(v, fn)) for fn in fieldnames(typeof(v))), ",") * ")")
                println("      ", rpad(string(pn), 12), " = ", vv)
            end
        else
            println("  _MemberFlange = ", mf)
        end

        # Nearest parallel web each side (centerline distance, m) + the member index.
        lw, rw = try SSy._nearest_parallel_webs(chords, t) catch e; (nothing, nothing) end
        wtag(w) = w === nothing ? "none" :
            join((string(fn, "=", getfield(w, fn)) for fn in fieldnames(typeof(w))), " ")
        println("  nearest_parallel_webs: left=", wtag(lw), "  right=", wtag(rw))

        _diagnose_group(s, gid, groups[gid], chords, home, edge_hf)
    end
    println("========== END DIAG ==========\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
