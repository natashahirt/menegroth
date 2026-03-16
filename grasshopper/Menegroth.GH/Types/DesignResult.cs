using System.Collections.Generic;
using Newtonsoft.Json.Linq;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Parsed design result from the Julia API.
    /// Constructed once from raw JSON in DesignRun; passed by reference to all downstream components.
    /// </summary>
    public class DesignResult
    {
        public string RawJson { get; set; } = "";
        public string Status { get; set; } = "unknown";
        public double ComputeTime { get; set; }
        /// <summary>Per-phase wall-clock times (s): prepare, pipeline, capture, analysis_model, restore, serialize_visualization.</summary>
        public Dictionary<string, double> PhaseTimings { get; set; } = new Dictionary<string, double>();
        public string ErrorMessage { get; set; } = "";
        public string GeometryHash { get; set; } = "";

        /// <summary>Length unit from design: "ft" (imperial) or "m" (metric).</summary>
        public string LengthUnit { get; set; } = "ft";

        /// <summary>Effective display unit for mesh edge and report: "ft" or "m". Set by DesignRun from report units override.</summary>
        public string DisplayLengthUnit { get; set; }

        // Summary
        public bool AllPass { get; set; }
        public double CriticalRatio { get; set; }
        public string CriticalElement { get; set; } = "";
        public double ConcreteVolumeFt3 { get; set; }
        public double SteelWeightLb { get; set; }
        public double RebarWeightLb { get; set; }
        public double EmbodiedCarbonKgCO2e { get; set; }

        // Per-element results
        public List<SlabResult> Slabs { get; set; } = new List<SlabResult>();
        public List<ColumnResult> Columns { get; set; } = new List<ColumnResult>();
        public List<BeamResult> Beams { get; set; } = new List<BeamResult>();
        public List<FoundationResult> Foundations { get; set; } = new List<FoundationResult>();

        // Visualization (kept as JToken to avoid duplicating the full viz schema on the C# side;
        // Visualization reads these lazily)
        public JToken Visualization { get; set; }
        public double SuggestedScaleFactor { get; set; } = 1.0;
        public double MaxDisplacementFt { get; set; }

        public int FailureCount
        {
            get
            {
                int n = 0;
                foreach (var s in Slabs) if (!s.Ok) n++;
                foreach (var c in Columns) if (!c.Ok) n++;
                foreach (var b in Beams) if (!b.Ok) n++;
                foreach (var f in Foundations) if (!f.Ok) n++;
                return n;
            }
        }

        public bool IsError => Status == "error";

        /// <summary>
        /// Parse a raw JSON response into a <see cref="DesignResult"/>.
        /// Handles both success ("ok") and error responses gracefully.
        /// </summary>
        public static DesignResult FromJson(string json)
        {
            var r = new DesignResult { RawJson = json ?? "" };

            if (string.IsNullOrWhiteSpace(json))
            {
                r.Status = "error";
                r.ErrorMessage = "Server returned empty response. The design may have crashed or timed out.";
                return r;
            }

            JObject root;
            try
            {
                root = JObject.Parse(json);
            }
            catch
            {
                r.Status = "error";
                r.ErrorMessage = "Failed to parse server response as JSON. Response may be truncated or corrupted.";
                return r;
            }

            r.Status = root["status"]?.ToString() ?? "unknown";
            r.ComputeTime = root["compute_time_s"]?.ToObject<double>() ?? 0;
            r.GeometryHash = root["geometry_hash"]?.ToString() ?? "";
            r.LengthUnit = root["length_unit"]?.ToString()?.ToLowerInvariant() ?? "ft";

            var phaseTimings = root["phase_timings"] as JObject;
            if (phaseTimings != null)
            {
                foreach (var prop in phaseTimings.Properties())
                {
                    var val = prop.Value?.ToObject<double>();
                    if (val.HasValue)
                        r.PhaseTimings[prop.Name] = val.Value;
                }
            }

            if (r.Status == "error")
            {
                r.ErrorMessage = root["message"]?.ToString() ?? "Unknown server error";
                return r;
            }

            // Summary
            var summary = root["summary"];
            if (summary != null)
            {
                r.AllPass = summary["all_pass"]?.ToObject<bool>() ?? false;
                r.CriticalRatio = summary["critical_ratio"]?.ToObject<double>() ?? 0;
                r.CriticalElement = summary["critical_element"]?.ToString() ?? "";
                r.ConcreteVolumeFt3 = summary["concrete_volume"]?.ToObject<double>() ?? 0;
                r.SteelWeightLb = summary["steel_weight"]?.ToObject<double>() ?? 0;
                r.RebarWeightLb = summary["rebar_weight"]?.ToObject<double>() ?? 0;
                r.EmbodiedCarbonKgCO2e = summary["embodied_carbon_kgCO2e"]?.ToObject<double>() ?? 0;
            }

            // Slabs
            var slabs = root["slabs"] as JArray;
            if (slabs != null)
            {
                foreach (var s in slabs)
                {
                    bool converged = s["converged"]?.ToObject<bool>() ?? true;
                    bool deflOk = s["deflection_ok"]?.ToObject<bool>() ?? true;
                    bool punchOk = s["punching_ok"]?.ToObject<bool>() ?? true;
                    r.Slabs.Add(new SlabResult
                    {
                        Id = s["id"]?.ToObject<int>() ?? 0,
                        ThicknessIn = s["thickness"]?.ToObject<double>() ?? 0,
                        Ok = converged && deflOk && punchOk,
                        Converged = converged,
                        FailureReason = s["failure_reason"]?.ToString() ?? "",
                        FailingCheck = s["failing_check"]?.ToString() ?? "",
                        DeflectionRatio = s["deflection_ratio"]?.ToObject<double>() ?? 0,
                        PunchingMaxRatio = s["punching_max_ratio"]?.ToObject<double>() ?? 0,
                    });
                }
            }

            // Columns
            var columns = root["columns"] as JArray;
            if (columns != null)
            {
                foreach (var c in columns)
                {
                    r.Columns.Add(new ColumnResult
                    {
                        Id = c["id"]?.ToObject<int>() ?? 0,
                        Section = c["section"]?.ToString() ?? "",
                        AxialRatio = c["axial_ratio"]?.ToObject<double>() ?? 0,
                        InteractionRatio = c["interaction_ratio"]?.ToObject<double>() ?? 0,
                        Ok = c["ok"]?.ToObject<bool>() ?? true,
                    });
                }
            }

            // Beams
            var beams = root["beams"] as JArray;
            if (beams != null)
            {
                foreach (var b in beams)
                {
                    r.Beams.Add(new BeamResult
                    {
                        Id = b["id"]?.ToObject<int>() ?? 0,
                        Section = b["section"]?.ToString() ?? "",
                        FlexureRatio = b["flexure_ratio"]?.ToObject<double>() ?? 0,
                        ShearRatio = b["shear_ratio"]?.ToObject<double>() ?? 0,
                        Ok = b["ok"]?.ToObject<bool>() ?? true,
                    });
                }
            }

            // Foundations
            var foundations = root["foundations"] as JArray;
            if (foundations != null)
            {
                foreach (var f in foundations)
                {
                    r.Foundations.Add(new FoundationResult
                    {
                        Id = f["id"]?.ToObject<int>() ?? 0,
                        LengthFt = f["length"]?.ToObject<double>() ?? 0,
                        WidthFt = f["width"]?.ToObject<double>() ?? 0,
                        DepthFt = f["depth"]?.ToObject<double>() ?? 0,
                        BearingRatio = f["bearing_ratio"]?.ToObject<double>() ?? 0,
                        Ok = f["ok"]?.ToObject<bool>() ?? true,
                    });
                }
            }

            // Visualization (store raw JToken for Visualization to consume)
            var vizToken = root["visualization"];
            if (vizToken != null && vizToken.Type != JTokenType.Null)
            {
                r.Visualization = vizToken;
                r.SuggestedScaleFactor = vizToken["suggested_scale_factor"]?.ToObject<double>() ?? 1.0;
                r.MaxDisplacementFt = vizToken["max_displacement"]?.ToObject<double>() ?? 0;
            }

            return r;
        }
    }

    // ─── Per-element result types ─────────────────────────────────────────────

    public class SlabResult
    {
        public int Id { get; set; }
        public double ThicknessIn { get; set; }
        public bool Ok { get; set; }
        public bool Converged { get; set; }
        public string FailureReason { get; set; } = "";
        public string FailingCheck { get; set; } = "";
        public double DeflectionRatio { get; set; }
        public double PunchingMaxRatio { get; set; }
        public double MaxRatio => System.Math.Max(DeflectionRatio, PunchingMaxRatio);
        public string Label => $"t={ThicknessIn:F2}\"";
    }

    public class ColumnResult
    {
        public int Id { get; set; }
        public string Section { get; set; } = "";
        public double AxialRatio { get; set; }
        public double InteractionRatio { get; set; }
        public bool Ok { get; set; }
        public double MaxRatio => System.Math.Max(AxialRatio, InteractionRatio);
    }

    public class BeamResult
    {
        public int Id { get; set; }
        public string Section { get; set; } = "";
        public double FlexureRatio { get; set; }
        public double ShearRatio { get; set; }
        public bool Ok { get; set; }
        public double MaxRatio => System.Math.Max(FlexureRatio, ShearRatio);
    }

    public class FoundationResult
    {
        public int Id { get; set; }
        public double LengthFt { get; set; }
        public double WidthFt { get; set; }
        public double DepthFt { get; set; }
        public double BearingRatio { get; set; }
        public bool Ok { get; set; }
        public string Label => $"{LengthFt:F1}' x {WidthFt:F1}'";
    }
}
