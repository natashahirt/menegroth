# Quick test for RC column catalog generation
using StructuralSizer
using Unitful

println("Testing RC column catalogs...")
println("=" ^ 50)

# New naming convention - Rectangular
println("\n--- Rectangular Catalogs ---")

c1 = square_rc_columns()
println("square_rc_columns: $(length(c1)) sections")

c2 = rectangular_rc_columns()
println("rectangular_rc_columns: $(length(c2)) sections")

c3 = low_capacity_rc_columns()
println("low_capacity_rc_columns: $(length(c3)) sections")

c4 = high_capacity_rc_columns()
println("high_capacity_rc_columns: $(length(c4)) sections")

c5 = all_rc_rect_columns()
println("all_rc_rect_columns: $(length(c5)) sections")

# New naming convention - Circular
println("\n--- Circular Catalogs ---")

c6 = standard_circular_columns()
println("standard_circular_columns: $(length(c6)) sections")

c7 = low_capacity_circular_columns()
println("low_capacity_circular_columns: $(length(c7)) sections")

c8 = high_capacity_circular_columns()
println("high_capacity_circular_columns: $(length(c8)) sections")

c9 = all_rc_circular_columns()
println("all_rc_circular_columns: $(length(c9)) sections")

# Unified catalog function
println("\n--- rc_column_catalog() API ---")

c10 = rc_column_catalog(:rect, :standard)
println("rc_column_catalog(:rect, :standard): $(length(c10)) sections")

c11 = rc_column_catalog(:rect, :rectangular)
println("rc_column_catalog(:rect, :rectangular): $(length(c11)) sections")

c12 = rc_column_catalog(:rect, :low_capacity)
println("rc_column_catalog(:rect, :low_capacity): $(length(c12)) sections")

c13 = rc_column_catalog(:rect, :high_capacity)
println("rc_column_catalog(:rect, :high_capacity): $(length(c13)) sections")

c14 = rc_column_catalog(:rect, :all)
println("rc_column_catalog(:rect, :all): $(length(c14)) sections")

c15 = rc_column_catalog(:circular, :standard)
println("rc_column_catalog(:circular, :standard): $(length(c15)) sections")

c16 = rc_column_catalog(:circular, :all)
println("rc_column_catalog(:circular, :all): $(length(c16)) sections")

println("\n" * "=" ^ 50)
println("All catalogs generated successfully!")

# Check that rectangular catalog has non-square columns
rect_count = count(s -> ustrip(u"inch", s.b) != ustrip(u"inch", s.h), c2)
println("\nRectangular sections in rectangular_rc_columns: $rect_count")
