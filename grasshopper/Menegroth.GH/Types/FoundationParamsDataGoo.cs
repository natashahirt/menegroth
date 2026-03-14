using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="FoundationParamsData"/>.
    /// </summary>
    public class FoundationParamsDataGoo : GH_Goo<FoundationParamsData>
    {
        public FoundationParamsDataGoo() { Value = new FoundationParamsData(); }
        public FoundationParamsDataGoo(FoundationParamsData p) { Value = p; }
        public FoundationParamsDataGoo(FoundationParamsDataGoo other) { Value = other?.Value ?? new FoundationParamsData(); }

        public override bool IsValid => Value != null;
        public override string TypeName => "FoundationParamsData";
        public override string TypeDescription => "Foundation design parameter overrides";

        public override IGH_Goo Duplicate() => new FoundationParamsDataGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null FoundationParamsData";
            var parts = new System.Collections.Generic.List<string>();
            if (!string.IsNullOrEmpty(Value.Soil)) parts.Add($"soil={Value.Soil}");
            if (!string.IsNullOrEmpty(Value.Strategy)) parts.Add($"strategy={Value.Strategy}");
            if (Value.MatCoverageThreshold.HasValue) parts.Add($"mat_thresh={Value.MatCoverageThreshold}");
            return parts.Count > 0
                ? $"FoundationParamsData ({string.Join(", ", parts)})"
                : "FoundationParamsData (defaults)";
        }
    }
}
