# Flat-plate column bracing: the sway / nonsway designation.
#
# ACI 318-11 §10.10.5 (corpus: aci-318-11, page 154) requires every story to
# be designated nonsway or sway. §10.10.5.2: nonsway when
# Q = ΣPu Δo / (Vus ℓc) ≤ 0.05. Nonsway columns are designed by §10.10.6,
# sway columns by §10.10.7.
#
# A flat plate is not a lateral force-resisting system — the shear-wall core
# takes sidesway. A flat-plate column therefore carries no sway moment, and
# the §10.10.7.3 Q-method gives M = Mns + δs·Ms = Mns with the P-δ check along
# the length at the braced k. So k = 1.0 either way: R10.10.6.3 recommends it
# for a nonsway (braced) column, and it is the §10.10.7.2 minimum (k ≥ 1.0)
# for the sway along-length check. The Jackson–Moreland alignment chart
# (Fig. R10.10.1.1) is not consulted: a flat plate on pinned footings has
# ψ → ∞ and no finite sway k there, which is the physical statement that the
# frame cannot stand on its own. That statement is surfaced as a clean
# lateral-inadequacy error upstream (from the real story Q, once a lateral
# solve has populated `col.story_properties`), not as a chart exception here.

"""
    flat_plate_story_is_sway(struc, slab, col) -> Bool

§10.10.5.2 when `col.story_properties` is present (real Q from a lateral
solve). Otherwise a wall that meets the slab is the bracing element and the
story is nonsway by inspection (R10.10.5, page 154); no wall and no Q is not
designated nonsway, so the story is sway.
"""
function flat_plate_story_is_sway(struc, slab, col)
    # The design kernel's support has no story_properties. A building column
    # does, once compute_story_properties! has run.
    if hasproperty(col, :story_properties)
        sp = col.story_properties
        if sp !== nothing
            story = SwayStoryProperties(sp.ΣPu, 0.0, sp.Vus, sp.Δo, sp.lc)
            return is_sway_frame(story)
        end
    end
    return isempty(supporting_wall_segments(struc, slab))
end

"""
    flat_plate_column_geometry(col, slab, struc; h) -> ConcreteMemberGeometry

Slenderness geometry for one flat-plate column.

Nonsway (§10.10.5.2 Q ≤ 0.05, or a wall by inspection): braced, k = 1 about
both axes (R10.10.6.3). Sway (Q > 0.05): k = 1.0 about both axes.

A flat plate is not a lateral force-resisting system — the shear-wall core
takes sidesway, so a flat-plate column carries no sway moment (Ms = 0). The
§10.10.7.3 Q-method then gives M = Mns + δs·Ms = Mns, and the P-δ check along
the length uses the braced k. ACI 318-11 §10.10.7.2 requires k ≥ 1.0 for a
sway member; k = 1.0 is that minimum and is the value the Q-method's
along-length check uses (R10.10.6.3). The alignment chart (Fig. R10.10.1.1)
is not consulted: a flat plate on pinned footings has ψ → ∞ there and no
finite sway k, which is the physical statement that the frame cannot stand on
its own — that verdict is raised as a clean lateral-inadequacy error upstream
(from the real story stability index Q), not as a chart exception here.

Whether the story is actually sway is decided by [`flat_plate_story_is_sway`],
which uses the real Q from `col.story_properties` when a lateral solve has
populated it, and otherwise the wall-presence proxy. Sets `col.braced`.
"""
function flat_plate_column_geometry(col, slab, struc; h::Length)
    (isnothing(col.c1) || isnothing(col.c2)) && throw(ArgumentError(
        "flat-plate column k needs c1 and c2"))
    sway = flat_plate_story_is_sway(struc, slab, col)
    # The kernel support has no braced flag. The geometry returned below
    # carries the designation either way.
    hasproperty(col, :braced) && (col.braced = !sway)
    # k = 1.0 both ways: braced (R10.10.6.3) when nonsway; the §10.10.7.2
    # minimum / §10.10.7.3 along-length value when sway. `h` is retained in the
    # signature for call-site compatibility but is no longer needed for a chart k.
    return ConcreteMemberGeometry(col.base.L; Lu = col.base.L,
                                  kx = 1.0, ky = 1.0, braced = !sway)
end

"""One geometry per column, in `columns` order, at slab thickness `h`."""
function flat_plate_column_geometries(columns, slab, struc; h::Length)
    return [flat_plate_column_geometry(col, slab, struc; h) for col in columns]
end
