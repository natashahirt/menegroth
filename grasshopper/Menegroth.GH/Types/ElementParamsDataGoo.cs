using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="ElementParamsData"/>.
    /// </summary>
    public class ElementParamsDataGoo : GH_Goo<ElementParamsData>
    {
        public ElementParamsDataGoo() { Value = new ElementParamsData(); }
        public ElementParamsDataGoo(ElementParamsData p) { Value = p; }
        public ElementParamsDataGoo(ElementParamsDataGoo other) { Value = other?.Value ?? new ElementParamsData(); }

        public override bool IsValid => Value != null;
        public override string TypeName => "ElementParamsData";
        public override string TypeDescription => "Element sizing parameters (beam/column, NLP bounds)";

        public override IGH_Goo Duplicate() => new ElementParamsDataGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null ElementParamsData";

            string solver = Value.SolverType.ToUpperInvariant();
            string section = Value.Section == "beam" ? "Beam" : "Column";
            string type = Value.ElementType switch
            {
                "steel_w" => "Steel W",
                "steel_hss" => "Steel HSS",
                "rc_rect" => "RC Rect",
                "rc_tbeam" => "RC T",
                "rc_circular" => "RC Circ",
                "pixelframe" => "PixelFrame",
                _ => Value.ElementType
            };

            string bounds = "";
            if (Value.ElementType == "steel_w" && Value.DepthIn.HasValue)
                bounds = $" d=[{Value.DepthIn.Value.Min:F0}-{Value.DepthIn.Value.Max:F0}\"]";
            else if (Value.ElementType == "steel_hss" && Value.OuterDimensionIn.HasValue)
                bounds = $" OD=[{Value.OuterDimensionIn.Value.Min:F1}-{Value.OuterDimensionIn.Value.Max:F1}\"]";
            else if ((Value.ElementType == "rc_rect" || Value.ElementType == "rc_tbeam") && Value.WidthIn.HasValue)
                bounds = $" b=[{Value.WidthIn.Value.Min:F0}-{Value.WidthIn.Value.Max:F0}\"]";
            else if (Value.ElementType == "rc_circular" && Value.DiameterIn.HasValue)
                bounds = $" D=[{Value.DiameterIn.Value.Min:F0}-{Value.DiameterIn.Value.Max:F0}\"]";
            else if (Value.ElementType == "pixelframe" && Value.FcKsi.HasValue)
                bounds = $" fc=[{Value.FcKsi.Value.Min:F1}-{Value.FcKsi.Value.Max:F1}ksi]";

            return $"{type} {section} {solver}{bounds}";
        }
    }
}
