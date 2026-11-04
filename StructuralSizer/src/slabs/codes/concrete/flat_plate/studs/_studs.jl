# Barrel file for punching shear reinforcement design
include("stud_catalog.jl")       # Headed stud catalogs (StudSpec, INCON, Ancon)
include("outer_section.jl")      # Outer critical section beyond studs / stirrups (§11.11.5.4, §11.11.7.2)
include("shear_caps.jl")         # Shear cap design (ACI §13.2.6)
include("column_capitals.jl")    # Column capital design (ACI §13.1.2)
include("closed_stirrups.jl")    # Closed stirrup design (ACI §11.11.3)
