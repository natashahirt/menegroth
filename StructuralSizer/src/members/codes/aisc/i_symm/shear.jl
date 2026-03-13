# AISC 360 Chapter G - Design of Members for Shear

"""
    get_Cv1(s::ISymmSection, mat::Metal; kv=5.34, rolled=true) -> Float64

Web shear coefficient Cv1 per AISC 360-16 Section G2.1.
For rolled I-shapes, `ϕ_v = 1.0` when h/tw ≤ 2.24√(E/Fy).

# Arguments
- `kv`: Plate buckling coefficient (default 5.34 for unstiffened webs)
- `rolled`: `true` for rolled shapes, `false` for built-up
"""
function get_Cv1(s::ISymmSection, mat::Metal; kv=5.34, rolled=true)
    E, Fy = mat.E, mat.Fy
    λ_w = s.λ_w
    
    if rolled
        limit = 2.24 * sqrt(E / Fy)
        Cv1 = λ_w <= limit ? 1.0 : 1.10 * sqrt(kv * E / Fy) / λ_w
    else
        # Built-up sections: three-branch Cv1 per AISC G2.1(b)
        limit_inelastic = 1.10 * sqrt(kv * E / Fy)
        limit_elastic   = 1.37 * sqrt(kv * E / Fy)
        if λ_w <= limit_inelastic
            Cv1 = 1.0
        elseif λ_w <= limit_elastic
            Cv1 = 1.10 * sqrt(kv * E / Fy) / λ_w
        else
            Cv1 = 1.51 * kv * E / (Fy * λ_w^2)  # Elastic web buckling
        end
    end
    return Cv1
end

"""
    get_Vn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true) -> Force

Nominal shear strength per AISC 360-16: Chapter G2.1 (strong axis, web shear)
or Chapter G7 (weak axis, flange shear).

# Arguments
- `axis`: `:strong` (web shear, G2.1) or `:weak` (flange shear, G7)
- `kv`: Plate buckling coefficient
- `rolled`: `true` for rolled shapes, `false` for built-up
"""
function get_Vn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true)
    if axis == :strong
        # G2.1: Vn = 0.6 Fy Aw Cv1,  Aw = d × tw  (AISC 360-16 §G2.1)
        # Note: s.Aw is the *clear* web area (h × tw); AISC G2 uses full depth.
        Cv1 = get_Cv1(s, mat; kv=kv, rolled=rolled)
        Aw  = s.d * s.tw
        return 0.6 * mat.Fy * Aw * Cv1
    else
        # G7: Shear in Flanges (Weak Axis)
        # Vn = 0.6 * Fy * Aw_flanges * Cv2
        # Aw = 2 * bf * tf
        # For flanges of rolled shapes, Cv2 is typically 1.0 (compact)
        Aw_weak = 2 * s.bf * s.tf
        Cv2 = 1.0 # Simplified assumption for rolled shapes
        return 0.6 * mat.Fy * Aw_weak * Cv2
    end
end

"""
    get_ϕVn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true, ϕ=nothing) -> Force

Design shear strength ϕVn per AISC 360-16 (LRFD).
Defaults: `ϕ = 1.0` for strong-axis rolled I-shapes (G2.1(a)),
`ϕ = 0.9` for weak-axis (G7/G1).
"""
function get_ϕVn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true, ϕ=nothing)
    if axis == :strong
        # G2.1(a): ϕ=1.0 for rolled I-shapes satisfying h/tw limit (most do)
        # Default ϕ=1.0 if not provided
        ϕ_use = isnothing(ϕ) ? 1.0 : ϕ
    else
        # G7: Weak axis shear -> G1 says ϕ=0.9 usually
        ϕ_use = isnothing(ϕ) ? 0.9 : ϕ
    end
    return ϕ_use * get_Vn(s, mat; axis=axis, kv=kv, rolled=rolled)
end
