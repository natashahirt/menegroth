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
        public SolverParamsDataGoo(SolverParamsDataGoo other) { Value = other?.Value ?? new SolverParamsData(); }

        public override bool IsValid => Value != null;
        public override string TypeName => "SolverParamsData";
        public override string TypeDescription => "Solver parameters (MIP/NLP, beam or column catalog)";

        public override IGH_Goo Duplicate() => new SolverParamsDataGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null SolverParamsData";
            if (Value.Section == "beam")
            {
                if (Value.BeamType == "pixelframe")
                    return $"SolverParamsData ({Value.SolverType} PixelFrame beam fc={Value.PixelFrameFcPreset ?? "standard"})";
                return Value.Catalog == "custom"
                    ? $"SolverParamsData ({Value.SolverType} beam custom: {Value.MinWidthIn}-{Value.MaxWidthIn}\" × {Value.MinDepthIn}-{Value.MaxDepthIn}\")"
                    : $"SolverParamsData ({Value.SolverType} beam catalog={Value.Catalog})";
            }
            if (Value.ColumnType == "pixelframe")
                return $"SolverParamsData ({Value.SolverType} PixelFrame column fc={Value.PixelFrameFcPreset ?? "standard"})";
            return $"SolverParamsData ({Value.SolverType} column catalog={Value.ColumnCatalog})";
        }
    }
}
