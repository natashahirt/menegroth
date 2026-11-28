# ==============================================================================
# Geometry Converters
# ==============================================================================

"""
    to_steel_geometry(geom) -> SteelMemberGeometry

Convert any geometry to steel geometry. Concrete geometry now carries per-axis
`kx`/`ky`, which map directly onto `SteelMemberGeometry`'s `Kx`/`Ky`.
"""
function to_steel_geometry(geom::ConcreteMemberGeometry)
    SteelMemberGeometry(geom.L; Lb=geom.Lu, Kx=geom.kx, Ky=geom.ky)
end
to_steel_geometry(geom::SteelMemberGeometry) = geom

"""
    to_concrete_geometry(geom) -> ConcreteMemberGeometry

Convert any geometry to concrete geometry, preserving per-axis effective length
factors (`Kx → kx`, `Ky → ky`). The previous version collapsed both axes onto
`Ky`, which silently discarded strong-axis bracing information.
"""
function to_concrete_geometry(geom::SteelMemberGeometry)
    ConcreteMemberGeometry(geom.L; Lu=geom.Lb, kx=geom.Kx, ky=geom.Ky)
end
to_concrete_geometry(geom::ConcreteMemberGeometry) = geom

"""
    convert_geometries(geometries, target::Symbol)

Convert geometries to target type (`:steel` or `:concrete`).
"""
function convert_geometries(geometries::Vector, target::Symbol)
    if target === :steel
        return [to_steel_geometry(g) for g in geometries]
    elseif target === :concrete
        return [to_concrete_geometry(g) for g in geometries]
    else
        throw(ArgumentError("Unknown target=$target. Use :steel or :concrete"))
    end
end

# ==============================================================================
# Demand Converters
# ==============================================================================

"""
    to_steel_demands(demands) -> Vector{MemberDemand}

Convert RC demands to steel demands. Preserves end moments (M1x, M2x, M1y, M2y)
and the `transverse_load` flag so the AISC B1 amplification path sees the
same Cm context as the ACI slenderness path.
"""
function to_steel_demands(demands::Vector{<:RCColumnDemand})
    [MemberDemand(d.member_idx;
                  Pu_c=d.Pu, Mux=d.Mux, Muy=d.Muy,
                  M1x=d.M1x, M2x=d.M2x, M1y=d.M1y, M2y=d.M2y,
                  transverse_load=d.transverse_load)
     for d in demands]
end
to_steel_demands(demands::Vector{<:MemberDemand}) = demands

"""
    to_rc_demands(demands; βdns=0.6) -> Vector{RCColumnDemand}

Convert steel/general member demands to RC column demands. Forwards end
moments (`M1x/M2x/M1y/M2y`) and the `transverse_load` flag so the ACI
slenderness path can compute `Cm = 0.6 − 0.4·(M1/M2)` per ACI 318-19
§6.6.4.5.3 instead of falling back on the conservative `M1=0` stand-in.
"""
function to_rc_demands(demands::Vector{<:MemberDemand}; βdns=0.6)
    [RCColumnDemand(d.member_idx;
                    Pu=d.Pu_c, Mux=d.Mux, Muy=d.Muy,
                    M1x=d.M1x, M2x=d.M2x, M1y=d.M1y, M2y=d.M2y,
                    βdns=βdns,
                    transverse_load=d.transverse_load)
     for d in demands]
end
to_rc_demands(demands::Vector{<:RCColumnDemand}; βdns=nothing) = demands

