using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="DesignResult"/>.
    /// Enables typed wiring between DesignRun and downstream result/visualization components.
    /// </summary>
    public class GH_DesignResult : GH_Goo<DesignResult>
    {
        public GH_DesignResult() { Value = new DesignResult(); }
        public GH_DesignResult(DesignResult r) { Value = r; }
        public GH_DesignResult(GH_DesignResult other) { Value = other.Value; }

        public override bool IsValid => Value != null && Value.Status != "unknown";
        public override string TypeName => "DesignResult";
        public override string TypeDescription => "Parsed structural design result";

        public override IGH_Goo Duplicate() => new GH_DesignResult(this);

        public override string ToString()
        {
            if (Value == null) return "Null DesignResult";
            if (Value.IsError) return $"DesignResult (error: {Value.ErrorMessage})";
            int total = Value.Slabs.Count + Value.Columns.Count + Value.Beams.Count + Value.Foundations.Count;
            int failures = Value.FailureCount;
            return failures == 0
                ? $"DesignResult ({total} elements, all pass, {Value.ComputeTime:F1}s)"
                : $"DesignResult ({total} elements, {failures} failures, {Value.ComputeTime:F1}s)";
        }
    }
}
