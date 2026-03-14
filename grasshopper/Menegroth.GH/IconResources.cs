using System;
using System.Drawing;
using System.Linq;
using System.Reflection;

namespace Menegroth.GH
{
    internal static class IconResources
    {
        private static Bitmap? _ribbonIcon;

        internal static Bitmap? RibbonIcon
        {
            get
            {
                if (_ribbonIcon != null)
                {
                    return _ribbonIcon;
                }

                var asm = Assembly.GetExecutingAssembly();
                var names = asm.GetManifestResourceNames();
                var resourceName = names.FirstOrDefault(n =>
                    n.EndsWith("menegroth_icon.png", StringComparison.OrdinalIgnoreCase) ||
                    n.EndsWith("menegroth_logo_48w.png", StringComparison.OrdinalIgnoreCase));

                if (resourceName == null)
                {
                    return null;
                }

                using var stream = asm.GetManifestResourceStream(resourceName);
                if (stream == null)
                {
                    return null;
                }

                // Clone so we can dispose stream safely.
                using var source = new Bitmap(stream);
                _ribbonIcon = new Bitmap(source);
                return _ribbonIcon;
            }
        }
    }
}
