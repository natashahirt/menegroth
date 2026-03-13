using System;
using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="DesignParamsData"/>.
    /// Enables clean wiring between GH components.
    /// </summary>
    public class GH_DesignParamsData : GH_Goo<DesignParamsData>
    {
        public GH_DesignParamsData() { Value = new DesignParamsData(); }
        public GH_DesignParamsData(DesignParamsData p) { Value = p; }
        public GH_DesignParamsData(GH_DesignParamsData other) { Value = other.Value; }

        public override bool IsValid => Value != null;
        public override string TypeName => "DesignParamsData";
        public override string TypeDescription => "Design parameters for structural sizing";

        public override IGH_Goo Duplicate() => new GH_DesignParamsData(this);

        public override string ToString()
        {
            if (Value == null) return "Null DesignParamsData";
            return $"DesignParamsData (floor={Value.FloorType}, concrete={Value.Concrete})";
        }
    }
}
