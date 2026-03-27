using Documenter
using StructuralSynthesizer
using StructuralSizer

# Copy logo from project assets; Documenter expects docs/src/assets/logo.svg
# Use abspath so the source path resolves correctly whether make.jl is run
# directly (julia docs/make.jl) or via include() from scripts/runners/build_docs.jl.
assets_dir = joinpath(@__DIR__, "src", "assets")
mkpath(assets_dir)
src_logo = abspath(joinpath(@__DIR__, "..", "assets", "menegroth_logo.svg"))
dst_logo = joinpath(assets_dir, "logo.svg")
if isfile(src_logo)
    cp(src_logo, dst_logo; force = true)
else
    @warn "Logo not copied: source not found" src_logo
end

makedocs(
    sitename = "menegroth",
    format = Documenter.HTML(prettyurls = get(ENV, "CI", "false") == "true"),
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",

        "StructuralSizer" => [
            "Overview" => "sizer/overview.md",

            "Materials" => [
                "Steel"           => "sizer/materials/steel.md",
                "Concrete"        => "sizer/materials/concrete.md",
                "FRC"             => "sizer/materials/frc.md",
                "Timber"          => "sizer/materials/timber.md",
                "Fire Protection" => "sizer/materials/fire_protection.md",
            ],

            "Loads" => [
                "Combinations"    => "sizer/loads/combinations.md",
                "Gravity Loads"   => "sizer/loads/gravity.md",
                "Pattern Loading" => "sizer/loads/pattern_loading.md",
            ],

            "Members" => [
                "Types & Demands" => "sizer/members/types.md",
                "Sections" => [
                    "Steel"    => "sizer/members/sections/steel.md",
                    "Concrete" => "sizer/members/sections/concrete.md",
                    "Timber"   => "sizer/members/sections/timber.md",
                    "Catalogs" => "sizer/members/sections/catalogs.md",
                ],
                "Design Codes" => [
                    "AISC — W Shapes"     => "sizer/members/codes/aisc/i_symm.md",
                    "AISC — HSS Rect"     => "sizer/members/codes/aisc/hss_rect.md",
                    "AISC — HSS Round"    => "sizer/members/codes/aisc/hss_round.md",
                    "AISC — Generic"      => "sizer/members/codes/aisc/generic.md",
                    "AISC — Fire"         => "sizer/members/codes/aisc/fire.md",
                    "ACI — Beams"         => "sizer/members/codes/aci/beams.md",
                    "ACI — Columns"       => "sizer/members/codes/aci/columns.md",
                    "NDS"                 => "sizer/members/codes/nds.md",
                    "fib MC2010"          => "sizer/members/codes/fib.md",
                    "PixelFrame"          => "sizer/members/codes/pixelframe.md",
                ],
                "Optimization" => "sizer/members/optimize.md",
            ],

            "Slabs" => [
                "Types & Options"  => "sizer/slabs/types.md",
                "Design Codes" => [
                    "Flat Plate / Flat Slab" => "sizer/slabs/codes/concrete/flat_plate.md",
                    "Waffle"               => "sizer/slabs/codes/concrete/waffle.md",
                    "Hollow Core"          => "sizer/slabs/codes/concrete/hollow_core.md",
                    "General Concrete"     => "sizer/slabs/codes/concrete/general.md",
                    "Steel Deck"           => "sizer/slabs/codes/steel.md",
                    "Timber"               => "sizer/slabs/codes/timber.md",
                    "Vault"                => "sizer/slabs/codes/vault.md",
                    "Custom"               => "sizer/slabs/codes/custom.md",
                ],
                "Optimization" => "sizer/slabs/optimize.md",
            ],

            "Foundations" => [
                "Types & Options" => "sizer/foundations/types.md",
                "ACI"             => "sizer/foundations/codes/aci.md",
                "IS Code"         => "sizer/foundations/codes/is.md",
            ],

            "Shared Codes" => [
                "ACI Shared"  => "sizer/codes_shared/aci.md",
                "AISC Shared" => "sizer/codes_shared/aisc.md",
            ],

            "Optimization Framework" => [
                "Solvers"    => "sizer/optimize/solvers.md",
                "Objectives" => "sizer/optimize/objectives.md",
            ],
        ],

        "StructuralSynthesizer" => [
            "Overview" => "synthesizer/overview.md",

            "Building Types" => [
                "Skeleton"        => "synthesizer/building_types/skeleton.md",
                "Structure"       => "synthesizer/building_types/structure.md",
                "Cells & Slabs"   => "synthesizer/building_types/cells.md",
                "Members"         => "synthesizer/building_types/members.md",
                "Foundations"     => "synthesizer/building_types/foundations.md",
                "Tributary Cache" => "synthesizer/building_types/tributary_cache.md",
            ],

            "Design" => [
                "Types & Parameters"  => "synthesizer/design/types.md",
                "Workflow & Pipeline" => "synthesizer/design/workflow.md",
            ],

            "Core" => [
                "Initialize"   => "synthesizer/core/initialize.md",
                "Size"         => "synthesizer/core/size.md",
                "Tributaries"  => "synthesizer/core/tributaries.md",
                "Snapshots"    => "synthesizer/core/snapshots.md",
            ],

            "Geometry" => [
                "Frame Lines"      => "synthesizer/geometry/frame_lines.md",
                "Slab Validation"  => "synthesizer/geometry/slab_validation.md",
            ],

            "Generate" => [
                "Medium Office" => "synthesizer/generate/medium_office.md",
            ],

            "Analyze" => [
                "Asap / FEM"   => "synthesizer/analyze/asap.md",
                "Members"      => "synthesizer/analyze/members.md",
                "Slabs"        => "synthesizer/analyze/slabs.md",
                "Foundations"   => "synthesizer/analyze/foundations.md",
            ],

            "Post-Processing" => [
                "Embodied Carbon" => "synthesizer/postprocess/embodied_carbon.md",
                "Reports"         => "synthesizer/postprocess/reports.md",
            ],
        ],

        "HTTP API" => [
            "Overview & Endpoints" => "api/overview.md",
            "Schema"               => "api/schema.md",
            "Serialization"        => "api/serialization.md",
            "Validation"           => "api/validation.md",
            "Deployment"           => "api/deployment.md",
            "Grasshopper Client"   => "api/grasshopper.md",
        ],

        "Reference" => [
            "Design Codes" => "reference/design_codes.md",
            "Solver Trace Threading" => "reference/solver_trace_threading.md",
            "Type Hierarchy" => "reference/type_hierarchy.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/natashahirt/menegroth.git",
    devbranch = "main",
)
