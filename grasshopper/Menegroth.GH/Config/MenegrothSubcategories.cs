namespace Menegroth.GH.Config
{
    /// <summary>
    /// Ribbon subcategory strings for the Menegroth Grasshopper tab.
    /// Grasshopper orders subcategories lexicographically only; there is no separate
    /// sort-order API on <c>GH_Component</c>. Each constant prepends one Unicode
    /// format character in the range U+200B..U+200F so the intended workflow order
    /// (Inputs → Analysis → Results → Assistant → Component Parameters) is preserved
    /// while the ribbon label still reads as plain English (no visible digits or letters).
    /// </summary>
    public static class MenegrothSubcategories
    {
        public const string Inputs = "\u200BInputs";
        public const string Analysis = "\u200CAnalysis";
        public const string Results = "\u200DResults";
        public const string Assistant = "\u200EAssistant";
        public const string ComponentParameters = "\u200FComponent Parameters";
    }
}
