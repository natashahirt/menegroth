using Grasshopper.Kernel.Types;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Grasshopper Goo wrapper for <see cref="BuildingGeometry"/>.
    /// Enables clean wiring between GH components.
    /// </summary>
    public class BuildingGeometryGoo : GH_Goo<BuildingGeometry>
    {
        public BuildingGeometryGoo() { Value = new BuildingGeometry(); }
        public BuildingGeometryGoo(BuildingGeometry geo) { Value = geo; }
        public BuildingGeometryGoo(BuildingGeometryGoo other) { Value = other.Value; }

        public override bool IsValid => Value != null && Value.Vertices.Count >= 4;
        public override string TypeName => "BuildingGeometry";
        public override string TypeDescription => "Building geometry for structural sizing";

        public override IGH_Goo Duplicate() => new BuildingGeometryGoo(this);

        public override string ToString()
        {
            if (Value == null) return "Null BuildingGeometry";
            return $"BuildingGeometry ({Value.Vertices.Count} vertices, " +
                   $"{Value.BeamEdges.Count} beams, {Value.ColumnEdges.Count} columns)";
        }
    }
}
