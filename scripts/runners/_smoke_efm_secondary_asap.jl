#!/usr/bin/env julia
# Smoke test for the EFM secondary direction running through the ASAP solver
# (was previously hard-pinned to Hardy Cross).  Also exercises the FEA edge-beam
# wiring with `has_edge_beam=true` to confirm it doesn't crash.

using Test, Logging
disable_logging(Logging.Warn)

using Unitful
using Unitful: @u_str
using Asap
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer
const SR = StructuralSizer

skel = SS.gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
struc = SS.BuildingStructure(skel)
opts = SR.FlatPlateOptions(method=SR.EFM(solver=:asap, pattern_loading=false))
SS.initialize!(struc; material=SR.NWC_4000, floor_type=:flat_plate, floor_opts=opts)
println("EFM(:asap) full pipeline OK; first slab thickness = ",
        round(ustrip(u"inch", first(struc.slabs).result.thickness), digits=2), " in")

# FEA path with edge beam configured
skel2 = SS.gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
struc2 = SS.BuildingStructure(skel2)
opts2 = SR.FlatPlateOptions(method=SR.FEA(pattern_loading=false), edge_beam_βt=2.5)
SS.initialize!(struc2; material=SR.NWC_4000, floor_type=:flat_plate, floor_opts=opts2)
println("FEA + edge_beam_βt=2.5 OK; first slab thickness = ",
        round(ustrip(u"inch", first(struc2.slabs).result.thickness), digits=2), " in")
