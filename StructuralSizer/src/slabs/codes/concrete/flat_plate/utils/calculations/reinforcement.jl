# =============================================================================
# Phase 5: Reinforcement Design (ACI 318-11 §13.3, §10.5)

"""
    minimum_reinforcement(b, h, fy)

Minimum reinforcement per ACI 318-11 §13.3.1 / §7.12.2.1 for shrinkage and temperature.

# Minimum Ratios (ACI 318-11 §7.12.2.1)
- fy < 60 ksi:  ρ_min = 0.0020
- 60 ≤ fy < 77 ksi: ρ_min = 0.0018
- fy ≥ 77 ksi:  ρ_min = max(0.0014, 0.0018 × 60000/fy)

# Arguments
- `b`: Strip width
- `h`: Total slab thickness (gross section)
- `fy`: Reinforcement yield strength

# Returns
- As_min = ρ_min × b × h

# Reference
- ACI 318-11 §13.3.1, §7.12.2.1
- StructurePoint Example: fy=60ksi → As_min = 0.0018 × b × h
"""
function minimum_reinforcement(b::Length, h::Length, fy::Pressure)
    # ACI 318-11 §7.12.2.1 thresholds
    # Round to nearest psi to avoid Asap ksi ↔ Unitful psi conversion gap
    fy_psi = round(Int, ustrip(u"psi", fy))
    
    ρ_min = if fy_psi < 60_000      # fy < 60 ksi (Grade 40/50)
        0.0020
    elseif fy_psi < 77_000          # 60 ksi ≤ fy < 77 ksi (Grade 60)
        0.0018
    else                            # fy ≥ 77 ksi (Grade 80+)
        max(0.0014, 0.0018 * 60_000 / fy_psi)
    end
    
    return ρ_min * b * h
end


"""
    effective_depth(h; cover=0.75u"inch", bar_diameter=0.5u"inch", two_way=true)

Effective depth for slab reinforcement design.

For **two-way** slabs (default), bars run in both directions — the second layer
sits below the first, so each direction has a different d:

    d₁ = h − cover − db/2        (top layer)
    d₂ = h − cover − 3·db/2      (bottom layer)
    d_avg = (d₁ + d₂)/2 = h − cover − db

ACI R22.6.1 and StructurePoint both use d_avg for two-way design (moments,
punching shear, deflection).

For **one-way** slabs (`two_way=false`), only one bar layer:

    d = h − cover − db/2

# Arguments
- `h`: Total slab thickness
- `cover`: Clear cover to reinforcement (default 0.75" per ACI Table 20.6.1.3.1)
- `bar_diameter`: Assumed bar diameter (default #4 = 0.5")
- `two_way`: Use average depth for two orthogonal bar layers (default `true`)

# Reference
- ACI 318-11 R11.11.1: "d shall be the average of the effective depths in the
  two orthogonal directions"
- StructurePoint Example: d_avg = 5.75 in (h=7", cover=0.75", #4 bars)
"""
function effective_depth(h::Length; cover=0.75u"inch", bar_diameter=0.5u"inch", two_way=true)
    if two_way
        # d_avg = h − cover − db  (average of both bar layers)
        return h - cover - bar_diameter
    else
        # d = h − cover − db/2  (single bar layer)
        return h - cover - bar_diameter / 2
    end
end

"""
    inner_layer_effective_depth(h, cover, db_primary, db_secondary) -> Length

Effective depth of the inner (secondary-direction) reinforcement layer in a
two-way slab.  The secondary bars sit physically below the primary bars
(cover requirements per ACI 318-11 §7.7 plus the bar-spacing geometry of
§7.6 force a layered placement), so:

    d_inner = h − cover − db_primary − db_secondary / 2

with `db_primary` the diameter of the bars in the outer (primary) layer and
`db_secondary` the diameter of the bars in the inner (secondary) layer.

# Reference
- ACI 318-11 §7.7 (concrete cover, page 100)
- ACI 318-11 §7.6 (spacing of reinforcement, page 96)
"""
function inner_layer_effective_depth(h::Length, cover::Length,
                                     db_primary::Length, db_secondary::Length)
    return h - cover - db_primary - db_secondary / 2
end

"""
    max_bar_spacing(h)

Maximum spacing of primary flexural reinforcement at critical sections in
two-way slabs.

    s_max = min(2·h, 18 in)

The combined limit comes from two ACI 318-11 clauses:

  §13.3.2 (verbatim, p. 245):
    "Spacing of reinforcement at critical sections shall not exceed two times
     the slab thickness, except for portions of slab area of cellular or
     ribbed construction. ..."

  §7.6.5  (verbatim, p. 96):
    "In walls and slabs other than concrete joist construction, primary
     flexural reinforcement shall not be spaced farther apart than three
     times the wall or slab thickness, nor farther apart than 18 in."

§13.3.2 governs at critical sections of two-way slabs (2h is more stringent
than the 3h of §7.6.5 for the same h); §7.6.5 contributes the absolute 18 in
ceiling that takes over once 2h > 18 in (i.e. h > 9 in).

# Reference
- ACI 318-11 §13.3.2 (page 245)
- ACI 318-11 §7.6.5  (page 96)
"""
function max_bar_spacing(h::Length)
    return min(2 * h, 18.0u"inch")
end


# ─────────────────────────────────────────────────────────────────────────────
# Phase 6 (Punching / Shear / Moment-Transfer): MOVED to codes/aci/punching.jl
# All punching geometry, capacity, demand, gamma_f/v, Jc, combined stress,
# one-way shear, effective_slab_width, and punching_check functions are now
# shared between slabs and foundations via the shared ACI module.
# ─────────────────────────────────────────────────────────────────────────────


