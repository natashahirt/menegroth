# Poker-table material and section seeds.
#
# There is no aluminum specification and no NDS / APA plywood source in the
# curated corpus (`corpus.list_sources`). Values below are ENGINEERING JUDGMENT
# for a first solve, not code-derived allowables.

using Asap
using Unitful

"""Typical 6061-T6 published properties. Not an AA ADM check."""
const AL_E = 68.9u"GPa"
const AL_NU = 0.33
const AL_G = AL_E / (2 * (1 + AL_NU))
const AL_RHO = 2700.0u"kg/m^3"
const AL_FY = 241.0u"MPa"  # ~35 ksi typical T6 yield; judgment, not a code φFy

"""Isotropic stand-in for 3/4 in hardwood plywood. Not NDS / APA."""
const WOOD_E = 8.3u"GPa"          # ~1.2e6 psi plate-equivalent
const WOOD_NU = 0.30
const WOOD_RHO = 580.0u"kg/m^3"   # ~36 pcf
const WOOD_T = 0.75u"inch"

function round_tube(od::Quantity, wall::Quantity)
    Do = ustrip(u"m", od)
    Di = max(Do - 2 * ustrip(u"m", wall), 0.0)
    A = π / 4 * (Do^2 - Di^2)
    I = π / 64 * (Do^4 - Di^4)
    J = 2 * I
    return Asap.Section(A * u"m^2", AL_E, AL_G, I * u"m^4", I * u"m^4", J * u"m^4", AL_RHO)
end

function solid_rod(d::Quantity)
    D = ustrip(u"m", d)
    A = π / 4 * D^2
    I = π / 64 * D^4
    J = 2 * I
    return Asap.Section(A * u"m^2", AL_E, AL_G, I * u"m^4", I * u"m^4", J * u"m^4", AL_RHO)
end

# Seed sections — optimization variables later, not final shop sizes.
const SEC_LEG = round_tube(1.5u"inch", 0.125u"inch")
const SEC_SPIDER = round_tube(1.0u"inch", 0.065u"inch")
const SEC_KING = round_tube(1.25u"inch", 0.125u"inch")
const SEC_ROD = solid_rod(0.375u"inch")
const SEC_MODULE = round_tube(1.0u"inch", 0.083u"inch")
const SEC_RAIL = round_tube(1.25u"inch", 0.065u"inch")

const WOOD_SECTION = Asap.ShellSection(WOOD_T, WOOD_E, WOOD_NU; ρ = WOOD_RHO, name = :plywood_field)

section_area(sec::Asap.Section) = sec.A  # m², stripped in Asap
