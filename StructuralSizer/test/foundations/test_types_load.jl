using StructuralSizer
using Unitful

println("Types loaded OK")

# Test Soil with ks
s = StructuralSizer.medium_sand
println("ks = ", s.ks)

# Test backward compat (ks defaults to nothing)
s2 = StructuralSizer.Soil(100.0u"kPa", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 20.0u"MPa")
println("ks default = ", s2.ks)

# Test Soil with explicit ks
s3 = StructuralSizer.Soil(100.0u"kPa", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 20.0u"MPa"; ks=30000.0u"kPa/m")
println("ks explicit = ", s3.ks)

# Test options
opts = SpreadFootingOptions()
println("SpreadFootingOptions OK: bar_size=", opts.bar_size)

fopts = FoundationOptions()
println("FoundationOptions OK: strategy=", fopts.strategy)

# Test mat methods
println("RigidMat: ", RigidMat())
println("ShuklaAFM: ", ShuklaAFM())
println("WinklerFEA: ", WinklerFEA())

println("\nAll types and options loaded successfully!")
