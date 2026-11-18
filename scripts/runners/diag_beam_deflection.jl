# Where the frame-model beam deflection comes from on a steel two-way plan.
#
# Runs the steel two-way joist system until it stops, keeps the structure as it
# was at that point, and splits each span's unfactored live-load deflection
# into the span's own bending (relative to the line through its end points)
# and the movement of those end points. No library code is changed.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/diag_beam_deflection.jl [plan]

include(joinpath(@__DIR__, "sdf_rib_design.jl"))
using Printf
using LinearAlgebra: norm

const ASAP = SS.Asap
const M_TO_IN = 39.37007874015748
const M4_TO_IN4 = M_TO_IN^4
const LIVE_LIMIT = 1 / 360

"""Steel joists at the 1.25 m module, two-way RC slab, non-composite steel."""
function steel_twoway_parameters(plan_name::AbstractString)
    params = system_parameters(plan_name, :two_way)
    beams = SR.SteelBeamOptions()
    params.floor = SR.TwoWayOptions()
    params.beams = beams
    params.columns = SR.SteelColumnOptions()
    params.materials = MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60,
                                       steel = SR.A992_Steel)
    params.framing_opts = (
        materials = (steel = SR.A992_Steel,),
        module_spacing = (WAFFLE_PAN_M, WAFFLE_PAN_M),
        analysis = :grillage,
        beam_options = beams,
    )
    params.max_iterations = 4
    params.skip_visualization = true
    return params
end

_section_name(beam) = try
    s = SS.section(beam)
    s === nothing ? "none" : (hasproperty(s, :name) && s.name !== nothing ? string(s.name) : string(typeof(s)))
catch
    "none"
end

_xy_m(skel, v) = (c = SS.Meshes.coords(skel.vertices[v]);
                  (ustrip(u"m", c.x), ustrip(u"m", c.y)))

"""Beams whose chain touches each skeleton vertex, as `(beam index, :end or :through)`."""
function _beams_at_vertices(struc)
    out = Dict{Int, Vector{Tuple{Int, Symbol}}}()
    for (bi, beam) in enumerate(struc.beams)
        verts = SS._beam_chain_vertices(struc, beam)
        for (k, v) in enumerate(verts)
            kind = (k == 1 || k == length(verts)) ? :end : :through
            push!(get!(out, v, Tuple{Int, Symbol}[]), (bi, kind))
        end
    end
    return out
end

"""What holds up vertex `v` for beam `bi`: column/wall, or the other beams there."""
function _support_text(struc, lookup, at_vertex, v, bi)
    v in lookup.fixed && return "column or wall"
    others = [(j, k) for (j, k) in get(at_vertex, v, Tuple{Int, Symbol}[]) if j != bi]
    isempty(others) && return "nothing"
    parts = String[]
    for (j, k) in others
        b = struc.beams[j]
        push!(parts, "beam $j $(b.role) L$(b.level) $(_section_name(b)) ($(k === :end ? "ends" : "passes"))")
    end
    return join(parts, "; ")
end

"""`(station m, uz m)` along `beam` under the live case, element profiles included."""
function _live_profile(struc, beam, u_L, by_L; resolution = 21)
    skel = struc.skeleton
    verts = SS._beam_chain_vertices(struc, beam)
    xy = [_xy_m(skel, v) for v in verts]
    samples = Tuple{Float64, Float64}[]
    for si in SS.segment_indices(beam)
        edge = struc.segments[si].edge_idx
        for ei in SS._frame_element_indices(struc, edge)
            el = struc.asap_model.frame_elements[ei]
            sa = SR._station_on_polyline(ustrip(u"m", el.nodeStart.position[1]),
                                         ustrip(u"m", el.nodeStart.position[2]), xy)[2]
            sb = SR._station_on_polyline(ustrip(u"m", el.nodeEnd.position[1]),
                                         ustrip(u"m", el.nodeEnd.position[2]), xy)[2]
            p = ASAP.element_deflection_profile(el, u_L, by_L[ei]; resolution = resolution)
            n = length(p)
            for i in 1:n
                push!(samples, (sa + (sb - sa) * (i - 1) / (n - 1), p[i]))
            end
        end
    end
    sort!(samples; by = first)
    return samples
end

function _interp(samples, s)
    s <= samples[1][1] && return samples[1][2]
    s >= samples[end][1] && return samples[end][2]
    i = searchsortedlast(first.(samples), s)
    (s0, u0), (s1, u1) = samples[i], samples[i + 1]
    return s1 == s0 ? u1 : u0 + (u1 - u0) * (s - s0) / (s1 - s0)
end

"""Span rows for one member: length, own bending, end movement, absolute peak."""
function _span_rows(struc, beam, lookup, u_L, by_L)
    samples = _live_profile(struc, beam, u_L, by_L)
    seg_L = [SS.to_meters(struc.segments[s].L) for s in SS.segment_indices(beam)]
    bounds = SS._member_span_bounds(struc, beam, seg_L; lookup = lookup)
    rows = NamedTuple[]
    for j in 1:(length(bounds) - 1)
        a, b = bounds[j], bounds[j + 1]
        b - a > 1e-6 || continue
        sel = [(s, u) for (s, u) in samples if a - 1e-8 <= s <= b + 1e-8]
        pushfirst!(sel, (a, _interp(samples, a)))
        push!(sel, (b, _interp(samples, b)))
        own = SR.chord_deflection(first.(sel), last.(sel))
        absolute = maximum(abs(u) for (_, u) in sel)
        push!(rows, (L = b - a, own = own, absolute = absolute,
                     end0 = -sel[1][2], end1 = -sel[end][2]))
    end
    return rows
end

function main(plan_name::AbstractString)
    params = steel_twoway_parameters(plan_name)
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    println("Plan $plan_name, steel two-way, design until it stops")
    t0 = time()
    stopped = try
        design_building(struc, params; restore = false)
        nothing
    catch err
        sprint(showerror, err)
    end
    @printf("Design stopped after %.0f s\n", time() - t0)
    println(stopped === nothing ? "The design finished." : stopped)
    println()

    model = struc.asap_model
    dead, live, _ = SS._service_dead_live_loads(struc)
    _, u_L = ASAP.solve(model, Vector{ASAP.AbstractLoad}[dead, live], struc.asap_rigid_links)

    # Load and stiffness sanity: applied live load against the cells' live
    # pressure times area, and the same solve after a forced stiffness rebuild.
    F_L = ASAP.create_F(model, live)
    Fz = sum(F_L[n.globalID[3]] for n in model.nodes)
    expected = sum(ustrip(u"N", c.live_load * c.area) for c in struc.cells if c.floor_type != :grade)
    @printf("Applied live load %.1f kN; cell live load times area %.1f kN\n", -Fz / 1e3, expected / 1e3)
    z_dofs = [n.globalID[3] for n in model.nodes]
    before = minimum(u_L[z_dofs])
    idx = model.freeDOFs
    F_free = ASAP.create_F(model, live)[idx]
    resid = norm(model.S[idx, idx] * u_L[idx] - F_free) / norm(F_free)
    @printf("Residual of the live solve against the assembled matrix: %.2e\n", resid)
    S_old = copy(model.S)
    K_old = [copy(el.K) for el in model.frame_elements]
    ASAP.update!(model)
    @printf("Assembled matrix change on rebuild: %.2e (relative)\n",
            norm(model.S - S_old) / norm(model.S))
    stale = [i for (i, el) in enumerate(model.frame_elements)
             if norm(el.K - K_old[i]) > 1e-9 * max(norm(el.K), 1.0)]
    println("Frame elements whose stiffness changed on rebuild: $(length(stale)) of $(length(model.frame_elements))")
    owner = Dict{Int, Int}()
    for (bi, b) in enumerate(struc.beams), si in SS.segment_indices(b)
        for ei in SS._frame_element_indices(struc, struc.segments[si].edge_idx)
            owner[ei] = bi
        end
    end
    for i in stale[1:min(end, 12)]
        el = model.frame_elements[i]
        bi = get(owner, i, 0)
        what = bi == 0 ? "not a beam" : "beam $bi $(struc.beams[bi].role) L$(struc.beams[bi].level)"
        @printf("  element %d (%s): Ix now %.0f in^4, stiffness norm %.3g -> %.3g\n",
                i, what, ustrip(u"inch^4", el.section.Ix), norm(K_old[i]), norm(el.K))
    end
    _, u_L = ASAP.solve(model, Vector{ASAP.AbstractLoad}[dead, live], struc.asap_rigid_links)
    @printf("Largest live sag %.3f in as solved; %.3f in after rebuilding the stiffness\n",
            -before * M_TO_IN, -minimum(u_L[z_dofs]) * M_TO_IN)
    n_shell = length(model.shell_elements)
    println("Frame elements $(length(model.frame_elements)), shell elements $n_shell, rigid links $(length(struc.asap_rigid_links))")
    for (label, ei) in (("first grid beam", first(SS._frame_element_indices(struc, struc.segments[first(SS.segment_indices(struc.beams[14]))].edge_idx))),)
        el = model.frame_elements[ei]
        @printf("%s element: Ix %.0f in^4, E %.0f ksi, release %s\n", label,
                ustrip(u"inch^4", el.section.Ix), ustrip(u"ksi", el.section.E), nameof(typeof(el).parameters[1]))
    end
    println()
    by_L = ASAP.frame_loads_by_element(model, live)
    lookup = SS.beam_support_lookup(struc)
    at_vertex = _beams_at_vertices(struc)
    Ix_max = maximum(ustrip(u"inch^4", SR.Ix(s)) for s in SR.preferred_W())

    for (k, pass) in enumerate(SS._beam_sizing_passes(struc, params.beams))
        group_ids, demands, L_totals = SS._beam_group_demands(
            struc, pass.accept; resolution = 200, shell_demands = nothing)[1:3]
        println("=== Sizing pass $k: $(length(group_ids)) groups ===")
        println("Need is the Ix for L/360 live from the current demand. " *
                "Own is the same from the span's bending alone. Preferred max is " *
                @sprintf("%.0f in^4.", Ix_max))
        for (g, gid) in enumerate(group_ids)
            d = demands[g]
            I_ref = d.I_ref
            need_abs = d.δ_max_LL * I_ref / (LIVE_LIMIT * L_totals[g]) * M4_TO_IN4
            members = struc.member_groups[gid].member_indices
            need_own = 0.0
            worst = nothing
            for mi in members
                beam = struc.beams[mi]
                Ix_m = maximum(ustrip(u"m^4", struc.asap_model.frame_elements[ei].section.Ix)
                               for si in SS.segment_indices(beam)
                               for ei in SS._frame_element_indices(struc, struc.segments[si].edge_idx))
                for r in _span_rows(struc, beam, lookup, u_L, by_L)
                    need = r.own * Ix_m / (LIVE_LIMIT * r.L) * M4_TO_IN4
                    if need > need_own
                        need_own = need
                        worst = (mi = mi, r = r, Ix = Ix_m * M4_TO_IN4)
                    end
                end
            end
            flag = need_abs > Ix_max ? "  NO PREFERRED W" : ""
            beam0 = struc.beams[first(members)]
            @printf("group %2d  %-6s L%d  n=%2d  L=%5.2f m  %-9s need %8.0f in^4  own %7.0f in^4%s\n",
                    g, beam0.role, beam0.level, length(members), L_totals[g],
                    _section_name(beam0), need_abs, need_own, flag)
            if need_abs > Ix_max && worst !== nothing
                beam = struc.beams[worst.mi]
                verts = SS._beam_chain_vertices(struc, beam)
                r = worst.r
                @printf("    beam %d, span %.2f m, Ix %.0f in^4 in the solve\n",
                        worst.mi, r.L, worst.Ix)
                @printf("    live deflection: absolute %.3f in, own bending %.3f in, ends move %.3f in and %.3f in\n",
                        r.absolute * M_TO_IN, r.own * M_TO_IN,
                        r.end0 * M_TO_IN, r.end1 * M_TO_IN)
                for (label, v) in (("start", first(verts)), ("end", last(verts)))
                    x, y = _xy_m(struc.skeleton, v)
                    println("    $label ($(round(x; digits = 2)), $(round(y; digits = 2))): ",
                            _support_text(struc, lookup, at_vertex, v, worst.mi))
                end
            end
        end
        println()
    end
end

main(isempty(ARGS) ? "grid/x1y1" : ARGS[1])
