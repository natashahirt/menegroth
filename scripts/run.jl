import Pkg; Pkg.activate(); Pkg.add("Revise") # add Revise to global environment
Pkg.develop(path="StructuralSynthesizer") # Links the local folder as a package
using Revise
using Unitful
using StructuralSynthesizer

skel = gen_medium_office(160.0u"ft", 110.0u"ft", 13.0u"ft", 4, 3, 4)
display(visualize(skel))