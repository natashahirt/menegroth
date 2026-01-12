# ─────────────────────────────────────────────────────────────────
# Layer 1: Abstract Interface (in StructuralBase or StructuralSizer)
# ─────────────────────────────────────────────────────────────────
abstract type AbstractSection end
abstract type AbstractISection <: AbstractSection end  # I-shaped (W, I_symm, etc.)

# Required interface - any section must provide these
function area(s::AbstractSection) end
function Ix(s::AbstractSection) end
function Iy(s::AbstractSection) end
function J(s::AbstractSection) end
function Zx(s::AbstractSection) end
function Sx(s::AbstractSection) end

# ─────────────────────────────────────────────────────────────────
# Layer 2: Database Sections (keep in AsapToolkit, immutable)
# ─────────────────────────────────────────────────────────────────
struct WSection <: AbstractISection
    name::String
    A::typeof(1.0u"mm^2")
    d::typeof(1.0u"mm")
    bf::typeof(1.0u"mm")
    tw::typeof(1.0u"mm")
    tf::typeof(1.0u"mm")
    Ix::typeof(1.0u"mm^4")
    # ... (loaded from AISC database)
end

# Interface implementation is trivial - just return fields
area(s::WSection) = s.A
Ix(s::WSection) = s.Ix

# ─────────────────────────────────────────────────────────────────
# Layer 3: Parametric Sections (your I_symm, in StructuralSizer)
# ─────────────────────────────────────────────────────────────────
mutable struct ParametricI{T} <: AbstractISection
    # Input parameters
    h::T
    w::T
    tw::T
    tf::T
    material::Metal
    Lb::T
    
    # Cached computed properties (lazily evaluated or on construction)
    _cache::IProperties{T}
end

# Computed on demand
area(s::ParametricI) = s._cache.A
Ix(s::ParametricI) = s._cache.Ix

# ─────────────────────────────────────────────────────────────────
# Layer 4: Design Checks (separate from geometry, in StructuralSizer/codes)
# ─────────────────────────────────────────────────────────────────
# Works on ANY AbstractISection - database or parametric!
function check_flexure(s::AbstractISection, Mu; code::AISC360 = AISC360())
    Mn = nominal_moment(s, code)
    return Mu / (code.ϕb * Mn)
end

function nominal_moment(s::AbstractISection, code::AISC360)
    # Your existing Mn logic, but now works for W sections too!
    Mp = material(s).Fy * Zx(s)
    # ... slenderness checks using generic interface
end