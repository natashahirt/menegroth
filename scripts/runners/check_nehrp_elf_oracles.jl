# Reproduce the NEHRP 2020 Design Examples Vol. 1 ELF numbers
# (corpus: nehrp-2020-design-examples-v1, PDF pp. 148-149 and 191-194)
# with plain arithmetic, before any of them become test oracles.

# Example 4, §4.5.1.7 (PDF pp. 148-149)
Ta4 = 0.02 * 234.25^0.75
T4 = 1.4 * Ta4
println("Ex4 Ta=", Ta4, "  CuTa=", T4)
println("Ex4 12.8-3 = ", 1.10 / 8, "  12.8-4 = ", 0.65 / (T4 * 8),
        "  12.8-4 at T=1.68 = ", 0.65 / (1.68 * 8),
        "  12.8-6 (SDS=1.10) = ", 0.044 * 1.10)
println("Ex4 V(cap) = ", 0.65 / (T4 * 8) * 43_099)

# Example 5, §5.5.3.6 (PDF pp. 191-194)
Ta5 = 0.020 * 238^0.75
T5 = 1.4 * Ta5
k5 = 1 + (T5 - 0.5) / 2
println("\nEx5 Ta=", Ta5, "  CuTa=", T5, "  k=", k5)
println("Ex5 12.8-3 = ", 1.101 / 8, "  12.8-4 = ", 0.65 / (T5 * 8),
        "  12.8-6 = ", 0.044 * 1.101, "  12.8-7 = ", 0.5 * 0.65 / 8)
println("Ex5 V(cap)*25844 = ", 0.65 / (T5 * 8) * 25_844,
        "  V(floor)*25844 = ", 0.044 * 1.101 * 25_844)

h = [238, 225, 212, 199, 186, 173, 160, 147, 134, 121, 108, 95, 82, 69, 56, 43, 30, 17]
w = [1263; fill(1440, 16); 1555]
whk_printed = [7_941_532, 8_276_512, 7_525_512, 6_801_579, 6_105_409, 5_437_767,
               4_799_497, 4_191_536, 3_614_936, 3_070_888, 2_560_756, 2_086_130,
               1_648_895, 1_251_340, 896_334, 587_639, 330_535, 144_016]
Fx_printed = [146.2, 152.3, 138.5, 125.2, 112.4, 100.1, 88.3, 77.1, 66.5, 56.5,
              47.1, 38.4, 30.3, 23.0, 16.5, 10.8, 6.1, 2.7]
println("sum w = ", sum(w), "  sum printed whk = ", sum(whk_printed))
for kk in (1.6, k5)
    whk = w .* h .^ kk
    Fx = whk ./ sum(whk) .* 1238
    println("\nk = ", kk)
    println("  max rel err whk  = ", maximum(abs.(whk ./ whk_printed .- 1)))
    println("  max abs err Fx   = ", maximum(abs.(Fx .- Fx_printed)))
    println("  Fx = ", round.(Fx; digits=1))
end
whk = whk_printed
Fx = whk ./ sum(whk) .* 1238
println("\nFrom printed whk: max abs err Fx = ", maximum(abs.(Fx .- Fx_printed)))
println("Vx = ", round.(cumsum(Fx); digits=1))
