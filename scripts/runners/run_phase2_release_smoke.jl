# Phase 2 smoke test: Segment/Beam release fields + resolve_release / resolve_edge_releases.
# Run: SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/run_phase2_release_smoke.jl
using StructuralSynthesizer
const SS = StructuralSynthesizer

seg(edge, L; kw...) = SS.Segment(edge, L; kw...)
beam(seg_idxs, L; kw...) = SS.Beam(seg_idxs, L; kw...)

npass = 0; nfail = 0
check(name, cond) = (cond ? (global npass += 1; println("PASS  ", name)) :
                            (global nfail += 1; println("FAIL  ", name)))

# --- Segment back-compat + new kwargs ---
s0 = seg(1, 3.0)
check("Segment default release_start", s0.release_start === :default)
check("Segment default release_end", s0.release_end === :default)
s1 = seg(2, 4.0; Lb=2.0, Cb=1.1, release_start=:pinned, release_end=:fixed)
check("Segment kw release_start", s1.release_start === :pinned)
check("Segment kw release_end", s1.release_end === :fixed)
check("Segment kw Lb preserved", s1.Lb == 2.0)

# --- Beam torsion_released field ---
b0 = beam([1], 3.0)
check("Beam default torsion_released nothing", getfield(b0, :torsion_released) === nothing)
b1 = beam([1], 3.0; torsion_released=true)
check("Beam torsion_released override", getfield(b1, :torsion_released) === true)

# --- resolve_release: default => :fixedfixed (placeholder) ---
bdef = beam([1], 3.0; role=:girder)
check("default single-seg => :fixedfixed",
      SS.resolve_release(bdef, [seg(1, 3.0)], nothing) === :fixedfixed)

# --- explicit per-end mappings (single segment) ---
bg = beam([1], 3.0; role=:beam)
check("(:pinned,:fixed) => :freefixed",
      SS.resolve_release(bg, [seg(1, 3.0; release_start=:pinned, release_end=:fixed)], nothing) === :freefixed)
check("(:fixed,:pinned) => :fixedfree",
      SS.resolve_release(bg, [seg(1, 3.0; release_start=:fixed, release_end=:pinned)], nothing) === :fixedfree)
check("(:pinned,:pinned) torsion=false => :freefree",
      SS.resolve_release(bg, [seg(1, 3.0; release_start=:pinned, release_end=:pinned)], nothing) === :freefree)
bt = beam([1], 3.0; role=:joist, torsion_released=true)
check("(:pinned,:pinned) torsion=true => :joist",
      SS.resolve_release(bt, [seg(1, 3.0; release_start=:pinned, release_end=:pinned)], nothing) === :joist)

# --- multi-segment: interior must be fixed; only outer ends matter ---
chain_ok = [seg(1, 1.0; release_start=:pinned, release_end=:fixed),
            seg(2, 1.0; release_start=:fixed, release_end=:fixed),
            seg(3, 1.0; release_start=:fixed, release_end=:pinned)]
bm = beam([1,2,3], 3.0; role=:beam)
check("multi-seg collapse (:pinned..:pinned) => :freefree",
      SS.resolve_release(bm, chain_ok, nothing) === :freefree)
edge_rel = SS.resolve_edge_releases(bm, chain_ok, nothing)
check("multi-seg edge releases first=:freefixed", edge_rel[1] === :freefixed)
check("multi-seg edge releases interior=:fixedfixed", edge_rel[2] === :fixedfixed)
check("multi-seg edge releases last=:fixedfree", edge_rel[3] === :fixedfree)

# --- interior :pinned must error ---
chain_bad = [seg(1, 1.0; release_start=:fixed, release_end=:pinned),
             seg(2, 1.0; release_start=:fixed, release_end=:fixed)]
threw = Ref(false)
try
    SS.resolve_release(bm, chain_bad, nothing)
catch e
    threw[] = true
    println("      (expected error) ", sprint(showerror, e))
end
check("interior :pinned errors", threw[])

println("\nPhase 2 smoke: $npass passed, $nfail failed")
nfail == 0 || error("Phase 2 smoke test failures: $nfail")
