using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="SlabParamsData"/>.
    /// </summary>
    public class SlabParamsDataGoo : GH_Goo<SlabParamsData>
    {
        public SlabParamsDataGoo() { Value = new SlabParamsData(); }
        public SlabParamsDataGoo(SlabParamsData p) { Value = p; }
        public SlabParamsDataGoo(SlabParamsDataGoo other) { Value = other.Value; }

        public override bool IsValid => Value != null;
        public override string TypeName => "SlabParamsData";
        public override string TypeDescription => "Slab face category override";

        public override IGH_Goo Duplicate() => new SlabParamsDataGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null SlabParamsData";
            var category = string.IsNullOrWhiteSpace(Value.Category) ? "floor" : Value.Category;
            var nFaces = Value.Faces?.Count ?? 0;
            var floorType = string.IsNullOrWhiteSpace(Value.FloorType) ? "vault" : Value.FloorType;
            return $"SlabParamsData ({category} | {floorType}, {nFaces} face{(nFaces == 1 ? "" : "s")})";
        }
    }
}
