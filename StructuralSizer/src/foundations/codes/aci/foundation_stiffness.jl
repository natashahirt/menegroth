# ACI 336.2R §5.2 and §5.3. The corpus text layer drops the equation glyphs;
# these expressions were read from the page images.
# corpus: aci-336-combined-footings-mats, PDF pages 8–9 (printed 336.2R-8/9).

"""
    wall_footing_kr(E, Es, B, h, walls) -> Float64

Relative stiffness of a footing, ACI 336.2R §5.2 Eq. (5-1) and (5-2)
(corpus: `aci-336-combined-footings-mats`, PDF page 8, printed 336.2R-8).

```
Kr = E' I_B / (E_s B^3)
E' I_B = E' I_F + Σ E' I_b + E' t_w h_w^3 / 12
```

§1.1 (PDF page 2) defines `Kr` as dimensionless, `I_B` as the inertia of one
unit width of the superstructure, and `I_F` as the inertia per unit width of
the foundation. A unit-width rectangle is `h^3/12`. The `ℓ^4` printed beside
those two symbols does not match a unit-width inertia, and it would make
Eq. (5-1) a length. `h^3/12` is the value that keeps `Kr` dimensionless.

Each wall contributes `t_w h_w^3/12` (length^4). Dividing by `B` puts that
term on the unit-width basis the section states for `E'I_B`. `E'` is the
modulus passed in; Eq. (5-2) uses that one modulus on the footing and the walls.

# ENGINEERING JUDGMENT
Eq. (5-2) also adds the framed members `Σ E' I_b`. This function receives the
walls on the footing and no beam stiffness, so that sum is omitted.
"""
function wall_footing_kr(E, Es, B::Length, h::Length, walls)
    Bm = uconvert(u"m", B)
    hm = uconvert(u"m", h)
    Bm > 0u"m" || throw(ArgumentError("foundation width B must be positive (Eq. 5-1)"))
    hm > 0u"m" || throw(ArgumentError("footing thickness h must be positive (Eq. 5-1)"))
    Es_Pa = ustrip(u"Pa", Es)
    Es_Pa > 0 || throw(ArgumentError("soil modulus Es must be positive (Eq. 5-1)"))
    I_m3 = ustrip(u"m", hm)^3 / 12
    B_m = ustrip(u"m", Bm)
    for leg in walls
        I_wall = ustrip(u"m^4", leg.tw * leg.hw^3 / 12)
        I_m3 += I_wall / B_m
    end
    return ustrip(u"Pa", E) * I_m3 / (Es_Pa * B_m^3)
end

"""
    footing_lambda(ks, Ec, B, h) -> 1/length

Characteristic of a footing on elastic soil, ACI 336.2R §5.3 Eq. (5-3)
(corpus: `aci-336-combined-footings-mats`, PDF page 9, printed 336.2R-9):

```
λ = (K_s / (4 E_c I))^(1/4)
```

# ENGINEERING JUDGMENT
The printed equation does not define `K_s` or `I`. §1.1 defines lowercase
`k_s` (force/length^3) and does not define `K_s`. User ruling 2026-11-07:
`K_s = k_s · B` and `I = B · h^3/12`, the footing cross-section about its
bending axis. `B` cancels. The spacing gate is `1.75/λ` (§5.3 and §6.1.2
Step 3, PDF page 11).
"""
function footing_lambda(ks, Ec, B::Length, h::Length)
    Bm = uconvert(u"m", B)
    hm = uconvert(u"m", h)
    Bm > 0u"m" || throw(ArgumentError("foundation width B must be positive (Eq. 5-3)"))
    hm > 0u"m" || throw(ArgumentError("footing thickness h must be positive (Eq. 5-3)"))
    # K_s = k_s * B is force/length^2. I = B * h^3/12 is length^4.
    Ks = uconvert(u"N/m^2", ks * Bm)
    I = Bm * hm^3 / 12
    ratio = Ks / (4 * uconvert(u"N*m^2", Ec * I))
    return ratio^(1//4)
end
