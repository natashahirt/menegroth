using Grasshopper.Kernel.Types;

namespace StructuralSizer.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="SizerResult"/>.
    /// Enables typed wiring between SizerRun and downstream result/visualization components.
    /// </summary>
    public class GH_SizerResult : GH_Goo<SizerResult>
    {
        public GH_SizerResult() { Value = new SizerResult(); }
        public GH_SizerResult(SizerResult r) { Value = r; }
        public GH_SizerResult(GH_SizerResult other) { Value = other.Value; }

        public override bool IsValid => Value != null && Value.Status != "unknown";
        public override string TypeName => "SizerResult";
        public override string TypeDescription => "Parsed structural design result";

        public override IGH_Goo Duplicate() => new GH_SizerResult(this);

        public override string ToString()
        {
            if (Value == null) return "Null SizerResult";
            if (Value.IsError) return $"SizerResult (error: {Value.ErrorMessage})";
            int total = Value.Slabs.Count + Value.Columns.Count + Value.Beams.Count + Value.Foundations.Count;
            int failures = Value.FailureCount;
            return failures == 0
                ? $"SizerResult ({total} elements, all pass, {Value.ComputeTime:F1}s)"
                : $"SizerResult ({total} elements, {failures} failures, {Value.ComputeTime:F1}s)";
        }
    }
}
