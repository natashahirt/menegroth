# AISC 360 Chapter G - Design of Members for Shear

"""
    get_Cv1(s::ISymmSection, mat::Metal; kv=5.34, rolled=true)

Web shear coefficient Cv1 (AISC G2.1).
- `kv`: Web plate buckling coefficient (5.34 for unstiffened webs)
- `rolled`: true for rolled I-shapes, false for built-up (default: true)

For rolled I-shapes: h/tw ≤ 2.24√(E/Fy) → Cv1 = 1.0 (G2-3)
For built-up: h/tw ≤ 1.10√(kv*E/Fy) → Cv1 = 1.0 (G2-4)
Otherwise: Cv1 = 1.10√(kv*E/Fy) / (h/tw) (G2-5)
"""
function get_Cv1(s::ISymmSection, mat::Metal; kv=5.34, rolled=true)
    d, tw, tf = s.d, s.tw, s.tf
    E, Fy = mat.E, mat.Fy
    
    h = d - 2 * tf  # Clear distance between flanges
    λ = h / tw
    
    if rolled
        # Rolled I-shapes (G2-3)
        limit = 2.24 * sqrt(E / Fy)
        if λ <= limit
            Cv1 = 1.0
        else
            # Use built-up formula for rolled shapes exceeding limit
            Cv1 = 1.10 * sqrt(kv * E / Fy) / λ
        end
    else
        # Built-up I-shapes (G2-4, G2-5)
        limit = 1.10 * sqrt(kv * E / Fy)
        if λ <= limit
            Cv1 = 1.0
        else
            Cv1 = 1.10 * sqrt(kv * E / Fy) / λ
        end
    end
    
    return Cv1
end

"""
    get_Vn(s::ISymmSection, mat::Metal; kv=5.34)

Nominal shear strength (AISC G2.1).

# Arguments
- `s`: ISymmSection
- `mat`: Metal material  
- `kv`: Web plate buckling coefficient (5.34 for unstiffened)
"""
function get_Vn(s::ISymmSection, mat::Metal; kv=5.34, rolled=true)
    d, tw, tf = s.d, s.tw, s.tf
    Fy = mat.Fy
    
    h = d - 2 * tf  # Clear distance between flanges
    Aw = h * tw  # Area of web (G2.1)
    Cv1 = get_Cv1(s, mat; kv=kv, rolled=rolled)
    
    # Eq G2-1
    Vn = 0.6 * Fy * Aw * Cv1
    return Vn
end

"""
    get_ϕVn(s::ISymmSection, mat::Metal; kv=5.34, ϕ=1.0, rolled=true)

Design shear strength (LRFD).
ϕ = 1.0 for most rolled I-shapes per G2.1(a).
"""
get_ϕVn(s::ISymmSection, mat::Metal; kv=5.34, ϕ=1.0, rolled=true) = 
    ϕ * get_Vn(s, mat; kv=kv, rolled=rolled)
