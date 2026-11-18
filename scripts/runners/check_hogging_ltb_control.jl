# Lightest W shape whose hogging strength (bottom flange unbraced over the
# whole span, Cb = 1, as in `_hogging_ltb_inputs`) reaches Mu⁻, against the
# lightest shape with the deck-braced sagging strength (Lb = 0).
#
#   julia --project=StructuralSynthesizer scripts/runners/check_hogging_ltb_control.jl

using Printf
using Unitful
using StructuralSizer

const SZ = StructuralSizer

shapes = sort(SZ.all_W(); by = s -> ustrip(u"inch^2", s.A))
mat = SZ.A992_Steel
const KIP_FT = 1355.8179483314004  # N·m per kip·ft

lightest(L, Mu; Lb = L, Cb = 1.0) = findfirst(shapes) do s
    0.9 * ustrip(u"N*m", SZ.get_Mn(s, mat; Lb = Lb, Cb = Cb)) / KIP_FT >= Mu
end

for L_ft in (14.0, 18.0), Mu in (5.0, 8.6, 10.0, 15.0, 20.0, 30.0)
    L = L_ft * u"ft"
    hog = lightest(L, Mu)
    sag = lightest(L, Mu; Lb = 0.0u"ft")
    @printf("L=%4.0f ft  Mu=%5.1f kip·ft   hogging Lb=L, Cb=1: %-8s   deck-braced: %-8s\n",
            L_ft, Mu, hog === nothing ? "none" : shapes[hog].name,
            sag === nothing ? "none" : shapes[sag].name)
end
