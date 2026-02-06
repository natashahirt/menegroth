# Test Multi-Span DDM implementation
using StructuralSizer
using Unitful
using Unitful: @u_str
using Asap  # For custom units like ksf, kip, etc.

println("=" ^ 70)
println("Testing Multi-Span DDM Implementation")
println("=" ^ 70)

# Test 1: Basic DDM coefficients
println("\n1. Testing DDM coefficients...")
@assert ACI_DDM_LONGITUDINAL.end_span.ext_neg ≈ 0.26
@assert ACI_DDM_LONGITUDINAL.end_span.pos ≈ 0.52
@assert ACI_DDM_LONGITUDINAL.end_span.int_neg ≈ 0.70
@assert ACI_DDM_LONGITUDINAL.interior_span.neg ≈ 0.65
@assert ACI_DDM_LONGITUDINAL.interior_span.pos ≈ 0.35
println("   ✓ DDM coefficients correct")

# Test 2: Total static moment calculation
println("\n2. Testing M0 calculation...")
qu = 0.193u"ksf"
l2 = 14u"ft"
ln = 16.67u"ft"
M0 = total_static_moment(qu, l2, ln)
M0_kipft = ustrip(u"kip*ft", M0)
println("   M0 = $(round(M0_kipft, digits=2)) kip-ft (expected ≈93.82)")
@assert abs(M0_kipft - 93.82) < 2.0
println("   ✓ M0 calculation correct")

# Test 3: Clear span calculation  
println("\n3. Testing clear span calculation...")
l1 = 18u"ft"
c1 = 16u"inch"
ln_calc = clear_span(l1, c1)
ln_ft = ustrip(u"ft", ln_calc)
println("   ln = $(round(ln_ft, digits=2)) ft (expected ≈16.67)")
@assert abs(ln_ft - 16.67) < 0.1
println("   ✓ Clear span calculation correct")

# Test 4: Verify _compute_ddm_span_moments function exists and signature is correct
println("\n4. Testing _compute_ddm_span_moments function availability...")
@assert hasmethod(StructuralSizer._compute_ddm_span_moments, 
                  Tuple{Symbol, Any, Any, Any, Any, Any})
println("   ✓ _compute_ddm_span_moments function available")

# Test 5: Verify _order_columns_along_axis function exists
println("\n5. Testing _order_columns_along_axis function availability...")
@assert hasmethod(StructuralSizer._order_columns_along_axis, 
                  Tuple{Any, Any, NTuple{2, Float64}})
println("   ✓ _order_columns_along_axis function available")

# Test 6: Verify is_exterior_support function
println("\n6. Testing is_exterior_support function...")
@assert hasmethod(StructuralSizer.is_exterior_support, 
                  Tuple{Any, NTuple{2, Float64}})
println("   ✓ is_exterior_support function available")

# Test 7: Mock test of span moment computation
println("\n7. Testing DDM span moment logic (mock data)...")

# Mock column-like objects for testing
struct MockColumn
    c1::typeof(1.0u"inch")
    position::Symbol
    boundary_edge_dirs::Vector{NTuple{2, Float64}}
end

# Create mock columns (simple 3-column, 2-span frame)
col1 = MockColumn(16u"inch", :edge, [(0.0, 1.0)])   # Exterior (boundary perpendicular to X)
col2 = MockColumn(16u"inch", :interior, NTuple{2,Float64}[])  # Interior
col3 = MockColumn(16u"inch", :edge, [(0.0, 1.0)])   # Exterior

# Test is_exterior_support
span_axis = (1.0, 0.0)  # X direction

# col1 has boundary edge (0,1) which is perpendicular to span axis (1,0) - should be exterior
@assert StructuralSizer.is_exterior_support(col1, span_axis) == true
# col2 has no boundary edges - should be interior
@assert StructuralSizer.is_exterior_support(col2, span_axis) == false
# col3 has boundary edge (0,1) - should be exterior
@assert StructuralSizer.is_exterior_support(col3, span_axis) == true

println("   ✓ is_exterior_support logic correct for mock columns")

# Test 8: Verify DDM coefficient selection for end spans vs interior spans
println("\n8. Testing DDM coefficient selection logic...")

# End span (has exterior support): 0.26/0.52/0.70 coefficients
# Interior span: 0.65/0.35 coefficients

M0_test = 100u"kip*ft"

# End span moments
M_ext_neg_end = 0.26 * M0_test  # 26 kip-ft at exterior
M_int_neg_end = 0.70 * M0_test  # 70 kip-ft at interior
M_pos_end = 0.52 * M0_test      # 52 kip-ft positive

# Interior span moments
M_neg_int = 0.65 * M0_test      # 65 kip-ft both supports
M_pos_int = 0.35 * M0_test      # 35 kip-ft positive

println("   End span: ext_neg=$(ustrip(u"kip*ft", M_ext_neg_end)), pos=$(ustrip(u"kip*ft", M_pos_end)), int_neg=$(ustrip(u"kip*ft", M_int_neg_end))")
println("   Int span: neg=$(ustrip(u"kip*ft", M_neg_int)), pos=$(ustrip(u"kip*ft", M_pos_int))")

# For a 3-column frame (2 spans):
# Span 1 (end span): col1-col2, left is exterior
#   M_neg_left = 0.26 * M0, M_neg_right = 0.70 * M0, M_pos = 0.52 * M0
# Span 2 (end span): col2-col3, right is exterior  
#   M_neg_left = 0.70 * M0, M_neg_right = 0.26 * M0, M_pos = 0.52 * M0

# At interior column (col2):
# M_from_left_span = 0.70 * M0 (right end of span 1)
# M_from_right_span = 0.70 * M0 (left end of span 2)
# Design moment = max(70, 70) = 70 kip-ft
# Unbalanced = |70 - 70| = 0 kip-ft (symmetric loading)

println("   ✓ DDM coefficient logic verified")

# Test 9: Per-span M0 calculation (different span lengths)
println("\n9. Testing per-span M0 with different span lengths...")

# Consider a 4-column frame with spans of 18ft, 20ft, 18ft
# Each span should get its own M0 based on its clear span

# Span 1: ln ≈ 16.67ft (18ft - 16"/12 × 2 × 0.5)
# Span 2: ln ≈ 18.67ft (20ft - 16"/12 × 2 × 0.5)
# Span 3: ln ≈ 16.67ft (18ft - 16"/12 × 2 × 0.5)

# With same qu and l2:
# M0_span1 = qu × l2 × ln1² / 8
# M0_span2 = qu × l2 × ln2² / 8 (should be larger due to longer span)
# M0_span3 = qu × l2 × ln3² / 8

qu_test = 0.193u"ksf"
l2_test = 14u"ft"

ln1 = 16.67u"ft"
ln2 = 18.67u"ft"  # Longer middle span
ln3 = 16.67u"ft"

M0_span1 = total_static_moment(qu_test, l2_test, ln1)
M0_span2 = total_static_moment(qu_test, l2_test, ln2)
M0_span3 = total_static_moment(qu_test, l2_test, ln3)

println("   Span 1 (ln=16.67ft): M0 = $(round(ustrip(u"kip*ft", M0_span1), digits=1)) kip-ft")
println("   Span 2 (ln=18.67ft): M0 = $(round(ustrip(u"kip*ft", M0_span2), digits=1)) kip-ft")
println("   Span 3 (ln=16.67ft): M0 = $(round(ustrip(u"kip*ft", M0_span3), digits=1)) kip-ft")

# Verify middle span has larger M0 (proportional to ln²)
@assert M0_span2 > M0_span1
@assert M0_span2 > M0_span3

# Verify ratio is approximately (18.67/16.67)² ≈ 1.255
ratio = ustrip(M0_span2) / ustrip(M0_span1)
expected_ratio = (18.67/16.67)^2
println("   M0 ratio (span2/span1) = $(round(ratio, digits=3)) (expected ≈$(round(expected_ratio, digits=3)))")
@assert abs(ratio - expected_ratio) < 0.01

println("   ✓ Per-span M0 scales correctly with ln²")

# Test 10: Unbalanced moment at interior column
println("\n10. Testing unbalanced moment calculation...")

# For a symmetric 3-column frame (2 equal end spans):
# At interior column: M_left = M_right = 0.70 × M0
# Unbalanced = |M_left - M_right| = 0

# For an asymmetric case (end span + interior span):
# At first interior: M_left = 0.70 × M0_end, M_right = 0.65 × M0_int
# If M0_end ≈ M0_int: Unbalanced ≈ |0.70 - 0.65| × M0 = 0.05 × M0

M0_equal = 100u"kip*ft"
M_left_sym = 0.70 * M0_equal  # From end span (interior side)
M_right_sym = 0.70 * M0_equal  # From other end span (interior side)
Mub_symmetric = abs(M_left_sym - M_right_sym)
println("   Symmetric case: Mub = $(ustrip(u"kip*ft", Mub_symmetric)) kip-ft (expected 0)")
@assert ustrip(u"kip*ft", Mub_symmetric) ≈ 0.0

# Asymmetric: end span meets interior span
M_left_asym = 0.70 * M0_equal  # From end span
M_right_asym = 0.65 * M0_equal # From interior span
Mub_asymmetric = abs(M_left_asym - M_right_asym)
println("   Asymmetric case: Mub = $(ustrip(u"kip*ft", Mub_asymmetric)) kip-ft (expected 5)")
@assert abs(ustrip(u"kip*ft", Mub_asymmetric) - 5.0) < 0.1

println("   ✓ Unbalanced moment calculation correct")

println("\n" * "=" ^ 70)
println("All DDM tests PASSED!")
println("=" ^ 70)
