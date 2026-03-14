using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;

namespace Menegroth.GH.Helpers
{
    /// <summary>
    /// Color mapping for structural visualization: utilization, deflection, and material.
    /// </summary>
    public static class VisualizationColorMapper
    {
        public static readonly Color ColumnTypeColor = Color.SteelBlue;
        public static readonly Color BeamTypeColor = Color.Coral;
        public static readonly Color OtherTypeColor = Color.DimGray;
        public static readonly Color DefaultMaterialColor = Color.FromArgb(200, 200, 200);
        
        /// <summary>
        /// Earthen/masonry material color for vaults (warm terracotta/adobe tone).
        /// </summary>
        public static readonly Color EarthenMaterialColor = Color.FromArgb(194, 154, 108);
        
        /// <summary>
        /// Concrete material color (neutral gray).
        /// </summary>
        public static readonly Color ConcreteMaterialColor = Color.FromArgb(180, 180, 180);

        /// <summary>
        /// Green → yellow → red gradient by utilization ratio (0 → 1).
        /// Elements above 1.0 or failing are magenta.
        /// </summary>
        public static Color UtilizationColor(double ratio, bool ok, IList<Color> gradient = null)
        {
            if (!ok || ratio > 1.0)
                return Color.FromArgb(200, 0, 120);

            ratio = Math.Max(0.0, Math.Min(ratio, 1.0));
            if (gradient != null && gradient.Count >= 2)
                return InterpolateGradient(gradient, ratio);

            int r, g, b;
            if (ratio <= 0.5)
            {
                double t = ratio / 0.5;
                r = (int)(0 + t * 220);
                g = (int)(180 + t * 20);
                b = 0;
            }
            else
            {
                double t = (ratio - 0.5) / 0.5;
                r = 220;
                g = (int)(200 - t * 160);
                b = 0;
            }

            return Color.FromArgb(r, g, b);
        }

        /// <summary>
        /// Blue → cyan → yellow → red gradient by displacement magnitude.
        /// Normalized against the building's max displacement.
        /// </summary>
        public static Color DeflectionColor(double displacement, double maxDisplacement, IList<Color> gradient = null)
        {
            if (maxDisplacement < 1e-12)
                return Color.FromArgb(40, 80, 200);

            double t = Math.Max(0.0, Math.Min(displacement / maxDisplacement, 1.0));
            if (gradient != null && gradient.Count >= 2)
                return InterpolateGradient(gradient, t);

            int r, g, b;
            if (t <= 0.33)
            {
                double s = t / 0.33;
                r = (int)(40 * (1 - s));
                g = (int)(80 + s * 175);
                b = (int)(200 * (1 - s) + s * 200);
            }
            else if (t <= 0.66)
            {
                double s = (t - 0.33) / 0.33;
                r = (int)(s * 240);
                g = (int)(255 - s * 55);
                b = (int)(200 * (1 - s));
            }
            else
            {
                double s = (t - 0.66) / 0.34;
                r = (int)(240 - s * 20);
                g = (int)(200 * (1 - s) + s * 30);
                b = 0;
            }

            return Color.FromArgb(
                Math.Max(0, Math.Min(255, r)),
                Math.Max(0, Math.Min(255, g)),
                Math.Max(0, Math.Min(255, b)));
        }

        public static Color? ParseHexColor(string hex)
        {
            if (string.IsNullOrWhiteSpace(hex))
                return null;

            string s = hex.Trim();
            if (s.StartsWith("#", StringComparison.Ordinal))
                s = s.Substring(1);

            if (s.Length == 6)
            {
                if (!int.TryParse(s.Substring(0, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int r) ||
                    !int.TryParse(s.Substring(2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int g) ||
                    !int.TryParse(s.Substring(4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int b))
                    return null;
                return Color.FromArgb(r, g, b);
            }

            if (s.Length == 8)
            {
                if (!int.TryParse(s.Substring(0, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int r) ||
                    !int.TryParse(s.Substring(2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int g) ||
                    !int.TryParse(s.Substring(4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int b) ||
                    !int.TryParse(s.Substring(6, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int a))
                    return null;
                return Color.FromArgb(a, r, g, b);
            }

            return null;
        }

        public static Color ResolveMaterialColor(string hex, Color fallback)
        {
            var parsed = ParseHexColor(hex);
            return parsed ?? fallback;
        }

        /// <summary>
        /// Diverging color for signed analytical quantities.
        /// Negative (compression/hogging) → blue, zero → white, positive (tension/sagging) → red.
        /// <paramref name="absMax"/> is the max |value| across the building (symmetric normalization).
        /// </summary>
        public static Color DivergingColor(double value, double absMax)
        {
            if (absMax < 1e-12)
                return Color.FromArgb(235, 235, 235);

            // Map to [-1, +1]
            double t = Math.Max(-1.0, Math.Min(value / absMax, 1.0));

            int r, g, b;
            if (t >= 0)
            {
                // White → red (positive / tension / sagging)
                r = 255;
                g = (int)(255 * (1.0 - t));
                b = (int)(255 * (1.0 - t));
            }
            else
            {
                // White → blue (negative / compression / hogging)
                double s = -t;
                r = (int)(255 * (1.0 - s));
                g = (int)(255 * (1.0 - s));
                b = 255;
            }

            return Color.FromArgb(
                Math.Max(0, Math.Min(255, r)),
                Math.Max(0, Math.Min(255, g)),
                Math.Max(0, Math.Min(255, b)));
        }

        /// <summary>
        /// Sequential color for always-positive analytical quantities (von Mises, shear magnitude).
        /// 0 → light gray/white, max → deep orange/red.
        /// </summary>
        public static Color SequentialColor(double value, double maxValue)
        {
            if (maxValue < 1e-12)
                return Color.FromArgb(235, 235, 235);

            double t = Math.Max(0.0, Math.Min(value / maxValue, 1.0));

            // White → yellow → orange → red
            int r, g, b;
            if (t <= 0.5)
            {
                double s = t / 0.5;
                r = (int)(240 + s * 15);
                g = (int)(240 - s * 50);
                b = (int)(240 - s * 200);
            }
            else
            {
                double s = (t - 0.5) / 0.5;
                r = 255;
                g = (int)(190 - s * 160);
                b = (int)(40 - s * 40);
            }

            return Color.FromArgb(
                Math.Max(0, Math.Min(255, r)),
                Math.Max(0, Math.Min(255, g)),
                Math.Max(0, Math.Min(255, b)));
        }

        /// <summary>
        /// Dispatch to the correct analytical ramp based on whether the quantity is signed or absolute.
        /// Signed: bending moment, membrane force, surface stress, frame axial/moment/shear.
        /// Absolute: von Mises, transverse shear magnitude.
        /// </summary>
        public static Color AnalyticalColor(double value, double absMax, bool isDiverging)
        {
            return isDiverging ? DivergingColor(value, absMax) : SequentialColor(value, absMax);
        }

        public static Color InterpolateGradient(IList<Color> gradient, double t)
        {
            if (gradient == null || gradient.Count == 0)
                return Color.White;
            if (gradient.Count == 1)
                return gradient[0];

            t = Math.Max(0.0, Math.Min(1.0, t));
            double pos = t * (gradient.Count - 1);
            int i0 = (int)Math.Floor(pos);
            int i1 = Math.Min(i0 + 1, gradient.Count - 1);
            double a = pos - i0;
            var c0 = gradient[i0];
            var c1 = gradient[i1];
            return Color.FromArgb(
                (int)(c0.R * (1.0 - a) + c1.R * a),
                (int)(c0.G * (1.0 - a) + c1.G * a),
                (int)(c0.B * (1.0 - a) + c1.B * a));
        }
    }
}
