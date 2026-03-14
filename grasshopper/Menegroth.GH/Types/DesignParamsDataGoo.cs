using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="DesignParamsData"/>.
    /// Enables clean wiring between GH components.
    /// </summary>
    public class DesignParamsDataGoo : GH_Goo<DesignParamsData>
    {
        public DesignParamsDataGoo() { Value = new DesignParamsData(); }
        public DesignParamsDataGoo(DesignParamsData p) { Value = p; }
        public DesignParamsDataGoo(DesignParamsDataGoo other) { Value = other.Value; }

        public override bool IsValid => Value != null;
        public override string TypeName => "DesignParamsData";
        public override string TypeDescription => "Design parameters for structural sizing";

        public override IGH_Goo Duplicate() => new DesignParamsDataGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null DesignParamsData";
            return $"DesignParamsData (floor={Value.FloorType}, concrete={Value.Concrete})";
        }
    }
}
