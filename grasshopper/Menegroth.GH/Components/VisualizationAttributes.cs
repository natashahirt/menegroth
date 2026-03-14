using Grasshopper.Kernel;
using Grasshopper.Kernel.Attributes;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Custom attributes for the Visualization component.
    /// Reserved for future VisualizationOptions (e.g. gradient colors) when added.
    /// </summary>
    public class VisualizationAttributes : GH_ComponentAttributes
    {
        public VisualizationAttributes(IGH_Component owner) : base(owner) { }
    }
}
