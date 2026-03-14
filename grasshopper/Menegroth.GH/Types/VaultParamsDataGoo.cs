using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="VaultParamsData"/>.
    /// </summary>
    public class VaultParamsDataGoo : GH_Goo<VaultParamsData>
    {
        public VaultParamsDataGoo() { Value = new VaultParamsData(); }
        public VaultParamsDataGoo(VaultParamsData p) { Value = p; }
        public VaultParamsDataGoo(VaultParamsDataGoo other) { Value = other.Value; }

        public override bool IsValid => Value != null;
        public override string TypeName => "VaultParamsData";
        public override string TypeDescription => "Vault-specific parameter overrides";

        public override IGH_Goo Duplicate() => new VaultParamsDataGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null VaultParamsData";
            return Value.Lambda.HasValue
                ? $"VaultParamsData (lambda={Value.Lambda.Value:0.###})"
                : "VaultParamsData";
        }
    }
}
