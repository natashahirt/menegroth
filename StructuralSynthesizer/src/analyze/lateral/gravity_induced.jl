# =============================================================================
# Forces on the gravity frame from the design earthquake displacement
# =============================================================================
# ASCE 7-22 §12.12.4 (corpus: asce-7-22, PDF page 195): in Seismic Design
# Category D, E, or F, a member that is not in the seismic force-resisting
# system is designed for the gravity load effects and for the forces that
# come from the design earthquake displacement δDE.
# ACI 318-19 §18.14.3.1 (corpus: aci-318-19, page 353): when those induced
# moments and shears are calculated and do not exceed the design strengths,
# §18.14.3.2 applies. When they are not calculated, or they exceed, §18.14.3.3
# applies. The displacement used here is Cd·δe/Ie (ASCE 7-22 §12.8.6,
# Eq. 12.8-16, PDF page 187) on the drift-purpose cases. The solved model
# already includes the frame, so the adjoining members' stiffness is in the
# displacement.

"""One gravity member under §12.12.4."""
struct GravityInducedCheck
    kind::Symbol
    index::Int
    "False when the drift displacement or a frame element was missing."
    calculated::Bool
    "True when the induced moment or shear exceeds the design strength."
    exceeds::Bool
    section::String
    "Largest |M| from δDE, N·m."
    Mu_Nm::Float64
    "Largest |V| from δDE, N."
    Vu_N::Float64
    "Factored gravity axial used with the induced moment, compression positive, N."
    Pu_N::Float64
end

"""
    gravity_induced_checks(struc, elf, basic, material, params, sdc;
                          Cdx, Cdy, Ie, SDS) -> Vector{GravityInducedCheck}

Reinforced-concrete beams and columns only. Another material is not given
an ACI 318 §18.14 section. An empty drift-displacement list leaves every
member uncalculated, which selects §18.14.3.3.
"""
function gravity_induced_checks(struc, elf, basic, material, params, sdc::Symbol;
                              Cdx::Real, Cdy::Real, Ie::Real, SDS::Real)
    sdc in (:D, :E, :F) || return GravityInducedCheck[]
    Ie > 0 || throw(ArgumentError(
        "gravity induced forces: Ie must be positive (got $Ie)"))
    out = GravityInducedCheck[]
    stored = !isempty(elf.displacements)
    frame = stored ? _frame_checkers(material, (columns = params.columns, beams = params.beams)) :
                     nothing
    for (kind, members) in ((:column, struc.columns), (:beam, struc.beams))
        for (i, member) in enumerate(members)
            section = member.base.section
            _induced_rc(kind, section) || continue
            if !stored
                push!(out, _induced_unchecked(kind, i))
                continue
            end
            env = _induced_envelope(struc, elf, member, Cdx, Cdy, Ie)
            if env === nothing
                push!(out, _induced_unchecked(kind, i))
                continue
            end
            Pu = _induced_gravity_axial(struc, basic, member, SDS)
            exceeds = _induced_exceeds(kind, member, section, frame, env, Pu)
            route = gravity_frame_seismic_section(;
                sdc = sdc, induced_forces_calculated = true,
                induced_exceeds_strength = exceeds)
            push!(out, GravityInducedCheck(kind, i, true, exceeds, route.section,
                                           env.Mu, env.Vu, Pu))
        end
    end
    return out
end

_induced_unchecked(kind, i) = GravityInducedCheck(kind, i, false, true, "18.14.3.3", 0.0, 0.0, 0.0)

function _induced_rc(kind, section)
    if kind === :column
        return section isa RCColumnSection || section isa RCCircularSection
    end
    return section isa RCBeamSection || section isa RCTBeamSection
end

"""Largest moment and shear from the drift cases scaled to δDE."""
function _induced_envelope(struc, elf, member, Cdx, Cdy, Ie)
    els = _member_frame_elements(struc, member)
    isempty(els) && return nothing
    length(elf.displacements) == length(elf.cases) || return nothing
    Mu = 0.0
    Vu = 0.0
    saw = false
    for (i, case) in enumerate(elf.cases)
        case.purpose === :drift || continue
        Cd = case.direction === :y ? Cdy : Cdx
        # Eq. 12.8-16 with δdi = 0. The solved displacement is δe.
        u = (Cd / Ie) .* elf.displacements[i]
        for el in els
            f = _element_forces_from_u(el, u, Asap.AbstractLoad[]; resolution = 2)
            Mu = max(Mu, maximum(abs, f.My), maximum(abs, f.Mz))
            Vu = max(Vu, maximum(abs, f.Vy), maximum(abs, f.Vz))
            saw = true
        end
    end
    saw || return nothing
    return (Mu = Mu, Vu = Vu)
end

"""
1.2D + 1.6L + 0.2·SDS·D, compression positive, over the member's stations.

The vertical earthquake is the axial effect that acts with the design
displacement. ASCE 7-22 §12.4.2.2.
"""
function _induced_gravity_axial(struc, basic, member, SDS)
    els = _member_frame_elements(struc, member)
    isempty(els) && return 0.0
    Pu = 0.0
    for el in els
        D = _element_forces_from_u(el, basic.u[1],
                                   _loads_on_element(basic.loads[1], el); resolution = 2)
        L = _element_forces_from_u(el, basic.u[2],
                                   _loads_on_element(basic.loads[2], el); resolution = 2)
        # Compression is the negative axial in these diagrams. max, not
        # maximum: maximum(f, x) treats its first argument as a function.
        P = 1.2 .* D.P .+ 1.6 .* L.P .+ 0.2 * SDS .* min.(D.P, 0.0)
        Pu = max(Pu, max(0.0, -minimum(P)))
    end
    return Pu
end

"""
True when the induced moment or shear, at the gravity axial, is past the
design strength. A section that already fails under that axial with no
induced moment is not counted as within strength.
"""
function _induced_exceeds(kind, member, section, frame, env, Pu)
    geometry = _member_frame_geometry(member)
    k, cache = _member_frame_bundle(kind, member, section, frame)
    bare = _induced_demand(kind, Pu, 0.0, 0.0)
    loaded = _induced_demand(kind, Pu, env.Mu, env.Vu)
    holds(demand) = try
        explain_feasibility(k.checker, cache, 1, section, k.concrete, demand, geometry).passed
    catch
        false
    end
    return !(holds(bare) && holds(loaded))
end

function _induced_demand(kind, Pu, Mu, Vu)
    if kind === :column
        # M1 stays 0, the constructor's single-curvature stand-in. It has to be
        # a moment: a bare 0.0 does not promote with a Unitful Mux.
        zero = 0.0u"N*m"
        return RCColumnDemand(1; Pu = Pu * u"N", Mux = Mu * u"N*m", Muy = zero,
                              M1x = zero, M1y = zero)
    end
    return RCBeamDemand(1; Mu = Mu * u"N*m", Vu = Vu * u"N", Nu = Pu * u"N")
end
