# ==============================================================================
# AISC 360-16 Chapter I — Composite Member Design
# ==============================================================================
# Organized by topic, mirroring the spec structure.

include("types.jl")            # AbstractSlabOnBeam, AbstractSteelAnchor, CompositeContext
include("effective_width.jl")  # I3.1a — b_eff
include("stud_strength.jl")   # I8.2a — Qn, Rg/Rp, validations
include("flexure.jl")         # I3.2  — Cf, PNA solver, Mn, partial composite, neg moment
include("construction.jl")    # I3.1b — construction-stage steel-alone check
include("deflection.jl")      # Commentary I3.2 — transformed I, I_LB, deflection
include("rebar_from_slab.jl") # Extract Asr/Fysr from FlatPlatePanelResult for neg moment
include("per_station.jl")     # I3.1a/I3.2a/I3.2b — per-station b_eff, DCR, governing station
