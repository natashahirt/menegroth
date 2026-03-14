using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="SolverParamsData"/>.
    /// </summary>
    public class SolverParamsDataGoo : GH_Goo<SolverParamsData>
    {
        public SolverParamsDataGoo() { Value = new SolverParamsData(); }
        public SolverParamsDataGoo(SolverParamsData p) { Value = p; }
        public SolverParamsDataGoo(SolverParamsDataGoo other) { Value = other.Value; }

        public override bool IsValid => Value != null;
        public override string TypeName => "SolverParamsData";
        public override string TypeDescription => "Beam solver parameters (catalog preset or custom bounds)";

        public override IGH_Goo Duplicate() => new SolverParamsDataGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null SolverParamsData";
            return Value.Catalog == "custom"
                ? $"SolverParamsData (custom: {Value.MinWidthIn}-{Value.MaxWidthIn}\" × {Value.MinDepthIn}-{Value.MaxDepthIn}\", res={Value.ResolutionIn}\")"
                : $"SolverParamsData (catalog={Value.Catalog})";
        }
    }
}
