using System;
using System.Drawing;
using Grasshopper.Kernel;

namespace StructuralSizer.GH
{
    /// <summary>
    /// Assembly information for the Grasshopper plugin.
    /// Grasshopper reads this to populate the component tab and metadata.
    /// </summary>
    public class StructuralSizerInfo : GH_AssemblyInfo
    {
        public override string Name => "Menegroth";
        public override string Description =>
            "Structural sizing via a Julia REST API — beams, columns, slabs, foundations.";
        public override Guid Id => new Guid("A1B2C3D4-0000-1111-2222-333344445555");
        public override string AuthorName => "Natasha K. Hirt";
        public override string AuthorContact => "";
        public override string Version => "0.1.0";
        public override Bitmap? Icon => null;
    }
}
