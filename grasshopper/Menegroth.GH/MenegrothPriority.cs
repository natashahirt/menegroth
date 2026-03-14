using Grasshopper;
using Grasshopper.Kernel;

namespace Menegroth.GH
{
    /// <summary>
    /// Registers Menegroth ribbon/tab appearance at load time.
    /// </summary>
    public class MenegrothPriority : GH_AssemblyPriority
    {
        public override GH_LoadingInstruction PriorityLoad()
        {
            var icon = IconResources.RibbonIcon;
            if (icon != null)
            {
                Instances.ComponentServer.AddCategoryIcon("Menegroth", icon);
            }

            Instances.ComponentServer.AddCategorySymbolName("Menegroth", 'M');
            return GH_LoadingInstruction.Proceed;
        }
    }
}
