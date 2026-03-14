using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="VaultParamsData"/>.
    /// </summary>
    public class GH_VaultParamsData : GH_Goo<VaultParamsData>
    {
        public GH_VaultParamsData() { Value = new VaultParamsData(); }
        public GH_VaultParamsData(VaultParamsData p) { Value = p; }
        public GH_VaultParamsData(GH_VaultParamsData other) { Value = other.Value; }

        public override bool IsValid => Value != null;
        public override string TypeName => "VaultParamsData";
        public override string TypeDescription => "Vault-specific parameter overrides";

        public override IGH_Goo Duplicate() => new GH_VaultParamsData(this);

        public override string ToString()
        {
            if (Value == null) return "Null VaultParamsData";
            return Value.Lambda.HasValue
                ? $"VaultParamsData (lambda={Value.Lambda.Value:0.###})"
                : "VaultParamsData";
        }
    }
}
