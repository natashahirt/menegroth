# AISC 360-16 Chapter G — Design of Members for Shear
# Source: corpus aisc-360-16, pp. 126–131.

"""
    get_Cv1(s::ISymmSection, mat::Metal; kv=5.34, rolled=true) -> Float64

Web shear strength coefficient `Cv1` per AISC 360-16 §G2.1 (corpus aisc-360-16,
pp. 126–127).

For rolled I-shapes meeting `h/tw ≤ 2.24 √(E/Fy)`, §G2.1(a) gives `Cv1 = 1.0`
together with `ϕ_v = 1.00`. For built-up shapes and rolled shapes outside that
limit, §G2.1(b) gives a three-branch formulation:

    h/tw ≤ 1.10 √(kv E/Fy):                        Cv1 = 1.0                   (Eq. G2-3)
    1.10 √(kv E/Fy) < h/tw ≤ 1.37 √(kv E/Fy):      Cv1 = 1.10 √(kv E/Fy)/(h/tw) (Eq. G2-4)
    h/tw > 1.37 √(kv E/Fy):                         Cv1 = 1.51 kv E / [(h/tw)² Fy] (Eq. G2-5)

# Arguments
- `kv`:     Plate buckling coefficient (default 5.34 for unstiffened webs, §G2.1)
- `rolled`: `true` for rolled shapes (§G2.1(a) two-branch),
            `false` for built-up shapes (§G2.1(b) three-branch)
"""
function get_Cv1(s::ISymmSection, mat::Metal; kv=5.34, rolled=true)
    E, Fy = mat.E, mat.Fy
    λ_w = s.λ_w

    if rolled
        # AISC 360-16 §G2.1(a): rolled I-shapes meeting h/tw ≤ 2.24√(E/Fy)
        # use Cv1 = 1.0 with ϕ_v = 1.00.
        limit = 2.24 * sqrt(E / Fy)
        Cv1 = λ_w <= limit ? 1.0 : 1.10 * sqrt(kv * E / Fy) / λ_w
    else
        # AISC 360-16 §G2.1(b): three-branch Cv1 (Eqs. G2-3 – G2-5)
        limit_inelastic = 1.10 * sqrt(kv * E / Fy)
        limit_elastic   = 1.37 * sqrt(kv * E / Fy)
        if λ_w <= limit_inelastic
            Cv1 = 1.0
        elseif λ_w <= limit_elastic
            Cv1 = 1.10 * sqrt(kv * E / Fy) / λ_w
        else
            Cv1 = 1.51 * kv * E / (Fy * λ_w^2)
        end
    end
    return Cv1
end

"""
    _Cv2(slenderness, mat::Metal, kv) -> Float64

Web shear buckling coefficient `Cv2` per AISC 360-16 §G2.2 (Eqs. G2-9, G2-10,
G2-11) (corpus aisc-360-16, p. 128). `slenderness` is the appropriate
width-to-thickness ratio for the element being checked (e.g., `h/tw` for stiffened
webs in §G2.2, or `bf/(2tf)` with `kv = 1.2` for I-shape flanges in §G6).
"""
function _Cv2(slenderness::Real, mat::Metal, kv::Real)
    E, Fy = mat.E, mat.Fy
    limit_inelastic = 1.10 * sqrt(kv * E / Fy)
    limit_elastic   = 1.37 * sqrt(kv * E / Fy)
    if slenderness <= limit_inelastic
        return 1.0                                              # Eq. G2-9
    elseif slenderness <= limit_elastic
        return 1.10 * sqrt(kv * E / Fy) / slenderness           # Eq. G2-10
    else
        return 1.51 * kv * E / (Fy * slenderness^2)             # Eq. G2-11
    end
end

"""
    get_Vn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true) -> Force

Nominal shear strength `Vn` per AISC 360-16 Chapter G (corpus aisc-360-16,
pp. 126, 131):

- Strong axis (web shear, §G2.1, Eq. G2-1):
    Vn = 0.6 Fy Aw Cv1,  with Aw = d·tw (AISC defines Aw as d·tw for web shear).
- Weak axis (shear in flanges, §G6, Eq. G6-1):
    Vn = 0.6 Fy bf tf Cv2  per resisting element; for an I-shape this is
    summed over both flanges, giving Vn_total = 2 · 0.6 Fy bf tf Cv2. `Cv2` is
    computed from §G2.2 using b/t = bf/(2tf) and kv = 1.2 per §G6.

# Arguments
- `axis`:   `:strong` (§G2.1 web shear) or `:weak` (§G6 flange shear)
- `kv`:     Plate buckling coefficient for §G2.1 only (default 5.34)
- `rolled`: `true` for rolled shapes (§G2.1(a)), `false` for built-up (§G2.1(b))
"""
function get_Vn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true)
    if axis == :strong
        # AISC 360-16 §G2.1, Eq. G2-1: Vn = 0.6 Fy Aw Cv1
        # AISC defines Aw = d·tw for the §G2 web-shear formulation; s.Aw is
        # the *clear* web area (h·tw) and is not used here.
        Cv1 = get_Cv1(s, mat; kv=kv, rolled=rolled)
        Aw  = s.d * s.tw
        return 0.6 * mat.Fy * Aw * Cv1
    else
        # AISC 360-16 §G6, Eq. G6-1 (corpus aisc-360-16, p. 131):
        #   Vn = 0.6 Fy bf tf Cv2  per resisting element,
        #   with Cv2 from §G2.2 using b/t = bf/(2tf) and kv = 1.2.
        # An I-shape has two flanges acting in parallel for weak-axis shear.
        kv_weak = 1.2
        slenderness = s.bf / (2 * s.tf)
        Cv2 = _Cv2(slenderness, mat, kv_weak)
        return 2 * 0.6 * mat.Fy * (s.bf * s.tf) * Cv2
    end
end

"""
    get_ϕVn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true, ϕ=nothing) -> Force

Design shear strength `ϕVn` per AISC 360-16 (LRFD).

# Resistance factor defaults (`ϕ`)
- Strong axis, rolled I-shape with `h/tw ≤ 2.24 √(E/Fy)` (§G2.1(a)): `ϕ = 1.00`.
- All other Chapter G provisions, including weak-axis §G6 (which inherits from
  §G1): `ϕ = 0.90` (corpus aisc-360-16, p. 126).
"""
function get_ϕVn(s::ISymmSection, mat::Metal; axis=:strong, kv=5.34, rolled=true, ϕ=nothing)
    if axis == :strong
        # §G2.1(a): ϕ = 1.0 when the rolled-shape limit is met. Caller may
        # override via `ϕ` if §G2.1(b) governs (in which case ϕ = 0.90).
        ϕ_use = isnothing(ϕ) ? 1.0 : ϕ
    else
        # §G1 default for §G6: ϕ = 0.90.
        ϕ_use = isnothing(ϕ) ? 0.9 : ϕ
    end
    return ϕ_use * get_Vn(s, mat; axis=axis, kv=kv, rolled=rolled)
end
