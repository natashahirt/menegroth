using System;
using System.Collections.Generic;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Container for building geometry extracted from Rhino/Grasshopper.
    /// Holds vertices, edges, faces, supports, and unit info ready for JSON serialisation.
    /// </summary>
    public class BuildingGeometry
    {
        public string Units { get; set; } = "feet";
        public List<double[]> Vertices { get; set; } = new List<double[]>();
        public List<int[]> BeamEdges { get; set; } = new List<int[]>();
        public List<int[]> ColumnEdges { get; set; } = new List<int[]>();
        public List<int[]> StrutEdges { get; set; } = new List<int[]>();
        public List<int> Supports { get; set; } = new List<int>();

        /// <summary>
        /// When false (default), input vertices are architectural reference points
        /// (panel corners / facade line). Edge and corner columns are automatically
        /// offset inward to their structural centerlines.
        /// When true, vertices are already structural centerlines — no offset is applied.
        /// </summary>
        public bool GeometryIsCenterline { get; set; } = false;

        // Faces grouped by category (floor, roof, grade)
        public Dictionary<string, List<List<double[]>>> Faces { get; set; }
            = new Dictionary<string, List<List<double[]>>>();

        /// <summary>
        /// Serialise the geometry portion to a JObject for inclusion in the API payload.
        /// </summary>
        public JObject ToJson()
        {
            var obj = new JObject
            {
                ["units"] = Units,
                ["vertices"] = JToken.FromObject(Vertices),
                ["edges"] = new JObject
                {
                    ["beams"] = JToken.FromObject(BeamEdges),
                    ["columns"] = JToken.FromObject(ColumnEdges),
                    ["braces"] = JToken.FromObject(StrutEdges)
                },
                ["supports"] = JToken.FromObject(Supports),
            };

            if (Faces.Count > 0)
                obj["faces"] = JToken.FromObject(Faces);

            return obj;
        }

        /// <summary>
        /// Compute a simple hash of the geometry for change detection.
        /// </summary>
        public string ComputeHash()
        {
            var json = ToJson().ToString(Formatting.None);
            using (var sha = System.Security.Cryptography.SHA256.Create())
            {
                var bytes = System.Text.Encoding.UTF8.GetBytes(json);
                var hash = sha.ComputeHash(bytes);
                return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
            }
        }
    }
}
