# One-way tributary of one strip: edge areas against the area their width profiles carry.
#
#     julia --project=external/Asap scripts/runners/diag_one_way_profile.jl

using Asap, Meshes, Unitful

strip = [(160.074, -93.337), (160.074, -92.632), (166.074, -92.632), (165.017, -93.337)]
pts = [Meshes.Point(x * u"m", y * u"m") for (x, y) in strip]
tribs = Asap.get_tributary_polygons(pts; axis = [0.0, -1.0])
n = length(strip)
for i in 1:n
    a, b = strip[i], strip[mod1(i + 1, n)]
    L = hypot(b[1] - a[1], b[2] - a[2])
    ps, ws = Asap._extract_depth_profile(tribs[i])
    prof = sum((0.5 * (ws[j] + ws[j + 1]) * (ps[j + 1] - ps[j]) * L for j in 1:length(ps) - 1); init = 0.0)
    println("edge $i  L=$(round(L; digits = 4))  area=$(round(tribs[i].area; digits = 5))  " *
            "profile=$(round(prof; digits = 5))")
    println("    s=", round.(ps; digits = 4))
    println("    w=", round.(ws; digits = 4))
end
