using System;
using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="DesignParams"/>.
    /// Enables clean wiring between GH components.
    /// </summary>
    public class GH_DesignParams : GH_Goo<DesignParams>
    {
        public GH_DesignParams() { Value = new DesignParams(); }
        public GH_DesignParams(DesignParams p) { Value = p; }
        public GH_DesignParams(GH_DesignParams other) { Value = other.Value; }

        public override bool IsValid => Value != null;
        public override string TypeName => "DesignParams";
        public override string TypeDescription => "Design parameters for structural sizing";

        public override IGH_Goo Duplicate() => new GH_DesignParams(this);

        public override string ToString()
        {
            if (Value == null) return "Null DesignParams";
            return $"DesignParams (floor={Value.FloorType}, concrete={Value.Concrete})";
        }
    }
}
